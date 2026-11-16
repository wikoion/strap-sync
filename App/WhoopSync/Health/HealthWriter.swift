import Foundation
import HealthKit
import SyncCore

/// Writes the outbox to Apple Health: heart rate, HRV (SDNN), steps, resting heart rate, breathing rate, sleep
/// and blood oxygen. Each type is written only once Health allows it, so one declined type doesn't hold up the rest.
/// It reads nothing from Health, so it asks only to write.
///
/// Never add `appleSleepingWristTemperature` to the share set: it's reserved for Apple Watch, and asking
/// for it raises an exception Swift can't catch, killing the app at launch (ryanbr/noop #1366).
@MainActor
final class HealthWriter: ObservableObject {
    @Published private(set) var allowed: Set<PlannedSample.Kind> = []
    @Published private(set) var lastWrite: Date?
    @Published private(set) var lastError: String?

    private let health = HKHealthStore()
    private let flusher = HealthFlush()

    private static let types: [PlannedSample.Kind: HKSampleType] = [
        .heartRate: HKQuantityType(.heartRate),
        .hrv: HKQuantityType(.heartRateVariabilitySDNN),
        .steps: HKQuantityType(.stepCount),
        .restingHR: HKQuantityType(.restingHeartRate),
        .respiratoryRate: HKQuantityType(.respiratoryRate),
        .sleep: HKCategoryType(.sleepAnalysis),
        .spo2: HKQuantityType(.oxygenSaturation),
    ]

    static func name(_ kind: PlannedSample.Kind) -> String {
        switch kind {
        case .heartRate: return "Heart rate"
        case .hrv: return "HRV"
        case .steps: return "Steps"
        case .restingHR: return "Resting heart rate"
        case .respiratoryRate: return "Breathing rate"
        case .sleep: return "Sleep"
        case .spo2: return "Blood oxygen"
        }
    }

    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    var missing: [PlannedSample.Kind] { PlannedSample.Kind.allCases.filter { !allowed.contains($0) } }

    init() { refresh() }

    func refresh() {
        guard available else { return allowed = [] }
        allowed = Set(Self.types.filter { health.authorizationStatus(for: $0.value) == .sharingAuthorized }.keys)
    }

    func requestAccess() async {
        guard available else { return lastError = "Apple Health isn't available on this device" }
        do {
            try await health.requestAuthorization(toShare: Set(Self.types.values), read: [])
        } catch {
            lastError = "Health permission failed: \(error.localizedDescription)"
        }
        refresh()
        let off = missing.map(Self.name)
        log(off.isEmpty ? "Apple Health: allowed to write every type"
                        : "Apple Health: not allowed yet: \(off.joined(separator: ", ")) (Settings → Health → Data Access & Devices → Strap Sync)")
    }

    /// Saves every unwritten outbox row Health allows, oldest first, in batches, after deleting what this app wrote
    /// for each night being rewritten. Returns how many were saved. The order, and why staging waits while a batch
    /// is saved (`saving`), are in HealthFlush.
    @discardableResult
    func flush(store: Store, device: HKDevice?) async -> Int {
        refresh()
        guard !allowed.isEmpty, !flusher.running else { return 0 }
        let out = await flusher.run(store, kinds: allowed,
                                    clear: { try await self.clearNight($0) },
                                    save: { try await self.health.save($0.map { self.sample($0, device: device) }) })
        if out.saved > 0 {
            lastWrite = Date()
            lastError = nil
            log("Apple Health: saved \(out.saved) samples")
        }
        if let e = out.clearError {
            lastError = "Clearing an old night from Apple Health failed: \(e.localizedDescription)"
            log(lastError!)
        }
        if let e = out.readError { lastError = "Reading the outbox failed: \(e)" }
        if let e = out.saveError {
            lastError = "Saving to Apple Health failed: \(e.localizedDescription)"
            log(lastError!)
        }
        return out.saved
    }

    /// A batch is being saved: staging a night waits (HealthFlush).
    var saving: Bool { flusher.saving }

    // MARK: The zone redo (zoneRedo1)

    /// This app's own samples in Health of the kinds it may write, starting from `from`, with their sync identifiers,
    /// versions and zones. An app allowed only to write can read back what it wrote (checked in the iOS 18.6
    /// Simulator, 14 Nov 2026, from a later launch too), so this needs no read permission.
    func ownSamples(from: Int) async throws -> [ZoneRedo.HealthSample] {
        refresh()
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: TimeInterval(from)), end: nil, options: .strictStartDate),
        ])
        var out: [ZoneRedo.HealthSample] = []
        for kind in allowed.sorted(by: { $0.rawValue < $1.rawValue }) {
            let samples: [HKSample]
            switch Self.types[kind] {
            case let type as HKQuantityType:
                samples = try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)], sortDescriptors: [])
                    .result(for: health)
            case let type as HKCategoryType:
                samples = try await HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: predicate)], sortDescriptors: [])
                    .result(for: health)
            default:
                continue
            }
            for sample in samples {
                let m = sample.metadata ?? [:]
                let value: Double
                if let q = sample as? HKQuantitySample {
                    value = q.quantity.doubleValue(for: Self.unit(kind)) * (kind == .spo2 ? 100 : 1)
                } else {
                    value = Double((sample as? HKCategorySample)?.value ?? 0)
                }
                out.append(ZoneRedo.HealthSample(kind: kind, syncId: m[HKMetadataKeySyncIdentifier] as? String,
                                                 start: Int(sample.startDate.timeIntervalSince1970.rounded()),
                                                 end: Int(sample.endDate.timeIntervalSince1970.rounded()), value: value,
                                                 version: (m[HKMetadataKeySyncVersion] as? NSNumber)?.intValue,
                                                 zone: m[HKMetadataKeyTimeZone] as? String))
            }
        }
        return out
    }

    enum RestampOutcome {
        case done(ZoneRedo.Plan, read: Int, changed: Int)
        /// Nothing done; try again later.
        case wait(String)
    }

    /// zoneRedo1's work, from what Health has (ZoneRedo has why): reads this app's own samples of the last 16 days and
    /// marks the outbox rows of those with the wrong zone for writing again, with the zone history's zone and the
    /// next sync version. In the same pass (restoreLost1), a night Health lost whose rows the outbox still has, all
    /// written and at its newest version, with nothing of the app's in Health around it, is written again the same
    /// way (`ZoneRedo.lostNights`). Other outbox rows Health doesn't have are never touched, and nothing new is
    /// written. The flush then writes them, in its batches.
    ///
    /// Only with no night clear pending and none staged while Health was read: a clear could otherwise delete a
    /// sample from Health after it was read, and this would put it back. (A batch saved meanwhile is harmless: saves
    /// delete nothing, and a row bumped while its batch is saved stays unwritten, `markWritten` matching versions.)
    /// If Health gives nothing while the outbox says it was given samples, nothing is done: reading may not work yet.
    func restampZones(store: Store, now: Int) async -> RestampOutcome {
        let from = now - ZoneRedo.days * 86_400
        let reach = from - 86_400  // a day before, so a night at the window's start sees what's around it
        do {
            guard try store.clears().isEmpty else { return .wait("a night is still to be cleared") }
            let generation = store.stagingGeneration
            let samples = try await ownSamples(from: reach)
            guard store.stagingGeneration == generation, try store.clears().isEmpty else {
                return .wait("a night was staged while Health was read")
            }
            if samples.isEmpty, try store.writtenCount(from: from) > 0 { return .wait("Apple Health returned none of its samples") }
            // A lost night only when every night kind was read: one not read would make every night look lost.
            let written = NightClear.kinds.isSubset(of: allowed) ? try store.writtenIds(from: reach) : []
            let plan = ZoneRedo.plan(health: samples, outbox: try store.outboxRows(from: reach), written: written, history: store.zones, now: now)
            return .done(plan, read: samples.count, changed: try store.rezone(plan.all))
        } catch {
            return .wait("\(error.localizedDescription)")
        }
    }

    /// Deletes this app's own sleep, resting-heart-rate and breathing samples overlapping a span.
    private func clearNight(_ clear: NightClear) async throws {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: TimeInterval(clear.start)),
                                        end: Date(timeIntervalSince1970: TimeInterval(clear.end)), options: []),
        ])
        var removed = 0
        for kind in NightClear.kinds.sorted(by: { $0.rawValue < $1.rawValue }) where allowed.contains(kind) {
            removed += try await health.deleteObjects(of: Self.types[kind]!, predicate: predicate)
        }
        if removed > 0 { log("Apple Health: removed \(removed) earlier samples for a night being rewritten") }
    }

    private func sample(_ p: PlannedSample, device: HKDevice?) -> HKSample {
        var metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: p.syncId,
            HKMetadataKeySyncVersion: p.version,
        ]
        // The zone it was recorded in, from the outbox row (the zone history at its start), so readers don't have to
        // guess. Not the phone's zone now: a night rewritten after a change of zone would get the new zone, and a
        // reader would put its wake time in the evening. None where the zone isn't known, rather than a wrong one.
        if let zone = p.zone { metadata[HKMetadataKeyTimeZone] = zone }
        // Strap Sync's own keys (skin temperature and ECGs on heart rate, RMSSD on HRV), for any app reading Health:
        // docs/SHARING.md, "Through Apple Health".
        for (key, value) in p.metadata {
            switch value {
            case .number(let n): metadata[key] = NSNumber(value: n)
            case .text(let s): metadata[key] = s as NSString
            case .date(let t): metadata[key] = Date(timeIntervalSince1970: TimeInterval(t))
            }
        }
        let start = Date(timeIntervalSince1970: TimeInterval(p.start))
        let end = Date(timeIntervalSince1970: TimeInterval(p.end))
        switch p.kind {
        case .sleep:
            return HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: Int(p.value),
                                    start: start, end: end, device: device, metadata: metadata)
        case .heartRate, .restingHR:
            metadata[HKMetadataKeyHeartRateSensorLocation] = HKHeartRateSensorLocation.wrist.rawValue
        default:
            break
        }
        let value = p.kind == .spo2 ? p.value / 100 : p.value  // HealthKit takes a fraction: 0.97 is 97%
        return HKQuantitySample(type: Self.types[p.kind] as! HKQuantityType, quantity: HKQuantity(unit: Self.unit(p.kind), doubleValue: value),
                                start: start, end: end, device: device, metadata: metadata)
    }

    /// The unit each quantity kind is written in.
    static func unit(_ kind: PlannedSample.Kind) -> HKUnit {
        switch kind {
        case .heartRate, .restingHR, .respiratoryRate: return HKUnit.count().unitDivided(by: .minute())
        case .hrv: return .secondUnit(with: .milli)
        case .steps, .sleep: return .count()
        case .spo2: return .percent()
        }
    }
}
