#if DEBUG
import HealthKit
import SwiftUI
import SyncCore

/// An end-to-end check of zoneRedo1 against Apple Health, in the Simulator: a Debug build launched there with
/// `-zoneCheck YES` runs it instead of the app (`scripts/zone-check.sh` does it all, with a UI test allowing Health
/// access). It goes through the app's own writer and store, in a temporary folder, with made-up samples:
///
/// 1. A night (stages, resting heart rate, breathing) and heart rate are written in zone A.
/// 2. The phone moves to zone B. The night is staged again as a build before the zone history did it: starting
///    later, stamped B. Its clear deletes the first version's later stages from Health, but the outbox keeps those
///    rows, written. Heart rate is rewritten with new metadata, stamped B too.
/// 3. Some rows lose their stored zone (as rows from before the column), one stamped-B sample loses its outbox row,
///    one heart-rate sample is deleted from Health but stays in the outbox.
/// 4. Two earlier nights are deleted from Health, as the race fixed on 14 Nov 2026 lost one, their rows left in the
///    outbox, written: L, all at its newest version, and M, staged twice (the first version's rows that start
///    before the second's stay in the outbox).
/// 5. A time-zones.json says night L was in zone C, though the logs had A.
/// 6. The redo runs as the app runs it (`HealthWriter.restampZones`), then a flush.
///
/// It passes when Health has exactly the samples it had before plus night L's, L's in zone C: every one with an outbox row in the
/// zone history's zone, the rewritten ones one sync version up and the rest unchanged, and nothing else the
/// outbox had but Health didn't (night M, the stale stages, the deleted heart rate) has come back.
@MainActor
enum ZoneCheck {
    static var enabled: Bool {
        #if targetEnvironment(simulator)
        return UserDefaults.standard.bool(forKey: "zoneCheck")
        #else
        return false
        #endif
    }

    static func run() async -> String {
        do {
            let problems = try await check()
            let text = problems.failures.isEmpty ? "PASS\n" + problems.notes.joined(separator: "\n")
                : "FAIL\n" + (problems.failures + problems.notes).joined(separator: "\n")
            log("Zone check: " + text.replacingOccurrences(of: "\n", with: "; "))
            return text
        } catch {
            return "FAIL\n\(error)"
        }
    }

    private static func check() async throws -> (failures: [String], notes: [String]) {
        var failures: [String] = [], notes: [String] = []
        func expect(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { failures.append(what()) } }

        let writer = HealthWriter()
        await writer.requestAccess()
        guard writer.missing.isEmpty else { return (["Health access wasn't given for every type"], []) }
        let hk = HKHealthStore()
        // A clean slate: this app's samples from earlier checks.
        for kind in PlannedSample.Kind.allCases {
            _ = try await hk.deleteObjects(of: sampleType(kind), predicate: HKQuery.predicateForObjects(from: .default()))
        }
        let store = try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("zone-check-\(UUID().uuidString)"))

        let now = Int(Date().timeIntervalSince1970)
        let base = now - now % 3600 - 3 * 86_400  // the night, three days ago
        let a = "Asia/Tokyo", b = "GMT-0800"
        _ = try store.addPastZones([.init(since: base - 2 * 86_400, zone: a)])  // as the logs had it

        // 1. Written in zone A.
        let first = (0..<10).map { stage(base + $0 * 1500, 1500) }
            + [sample(.restingHR, "rhr", base + 1800, 1800, 52), sample(.respiratoryRate, "resp", base, 3600, 14.5),
               sample(.respiratoryRate, "resp", base + 3600, 3600, 14.1)]
        try store.stageNight(start: base, end: base + 15_000, samples: first, neighbours: [])
        let heartRate = (0..<60).map { sample(.heartRate, "hr", base - 3600 + $0 * 600, 60, Double(55 + $0 % 20)) }
        try store.plan(heartRate)
        // Stamped with A's offset under another name: right already.
        let sameOffset = (0..<2).map { sample(.heartRate, "hr", base + 11 * 3600 + $0 * 600, 60, 61).with(zone: "GMT+0900") }
        try store.plan(sameOffset)
        // Nights L and M, the days before.
        let l = base - 86_400, m = base - 36 * 3600
        let nightL = (0..<8).map { stage(l + $0 * 1800, 1800, version: 3) }
            + [sample(.restingHR, "rhr", l + 3600, 1800, 51), sample(.respiratoryRate, "resp", l, 3600, 14.2)]
        try store.stageNight(start: l, end: l + 8 * 1800, samples: nightL, neighbours: [])
        try store.stageNight(start: m, end: m + 12 * 1800, samples: (0..<12).map { stage(m + $0 * 1800, 1800, version: 2) }, neighbours: [])
        await writer.flush(store: store, device: nil)
        try store.stageNight(start: m + 3600, end: m + 3600 + 12 * 1800,
                             samples: (0..<12).map { stage(m + 3600 + $0 * 1800, 1800, version: 3) } + [sample(.restingHR, "rhr", m + 7200, 1800, 53)],
                             neighbours: [])

        // 2. The phone moves to B; the night is staged again, starting later, and heart rate rewritten, stamped B.
        try store.recordZone(b, at: base + 86_400)
        let secondStart = base + 14_700
        let second = (0..<9).map { stage(secondStart + $0 * 1800, 1800, version: 2).with(zone: b) }
            + [sample(.restingHR, "rhr", secondStart + 3600, 1800, 50, version: 2).with(zone: b),
               sample(.respiratoryRate, "resp", secondStart, 3600, 13.9, version: 2).with(zone: b)]
        try store.stageNight(start: secondStart, end: secondStart + 9 * 1800, samples: second, neighbours: [])
        let backfilled = heartRate.prefix(30).map { $0.with(metadata: [HealthMetadata.skinTemperature: .number(33.1)]).with(zone: b) }
        try store.plan(Array(backfilled))
        await writer.flush(store: store, device: nil)

        // 3. Rows from before the zone column, a row pruned, a sample gone from Health.
        try store.db.run("UPDATE outbox SET zone = NULL WHERE sync_id LIKE 'whoopsync:hr:%' AND start < ?", [[.int(base + 3 * 3600)]])
        let pruned = heartRate[5].syncId, goneFromHealth = heartRate[40].syncId
        try store.db.run("DELETE FROM outbox WHERE sync_id = ?", [[.text(pruned)]])
        _ = try await hk.deleteObjects(of: HKQuantityType(.heartRate),
                                       predicate: HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [goneFromHealth]))
        let staleStages = first.filter { $0.kind == .sleep && $0.end >= secondStart - 7200 }.map(\.syncId)
        // 4. Nights L and M lost from Health.
        let spanL = (start: l, end: l + 8 * 1800), spanM = (start: m, end: m + 3600 + 12 * 1800)
        for span in [spanL, spanM] {
            for kind in NightClear.kinds {
                _ = try await hk.deleteObjects(of: sampleType(kind), predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    HKQuery.predicateForObjects(from: .default()),
                    HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: TimeInterval(span.start - 1)),
                                                end: Date(timeIntervalSince1970: TimeInterval(span.end + 1)), options: []),
                ]))
            }
        }
        let outboxNow = try store.outboxRows(from: base - 3 * 86_400)
        let rowsM = outboxNow.values.filter { NightClear.kinds.contains($0.sample.kind) && $0.sample.start >= spanM.start && $0.sample.start < spanM.end }
        let versionsM = Set(rowsM.filter { $0.sample.kind == .sleep }.map(\.sample.version))
        expect(versionsM == [2, 3], "night M should have rows of two versions, has \(versionsM.sorted())")

        let before = try await writer.ownSamples(from: base - 3 * 86_400)
        let inHealthBefore = Set(before.compactMap(\.syncId))
        expect(staleStages.allSatisfy { !inHealthBefore.contains($0) }, "the first version's later stages should be gone from Health")
        expect(!inHealthBefore.contains(goneFromHealth), "the deleted heart-rate sample should be gone from Health")
        expect(before.contains { $0.zone == b }, "some samples should be stamped B before the redo")
        expect(!before.contains { $0.start < spanM.end + 7200 && $0.end > spanL.start - 7200 && $0.start > spanM.start - 7200 && $0.end < spanL.end + 7200
                    && NightClear.kinds.contains($0.kind) },
               "nights L and M should be gone from Health")

        // 5. The owner's file: night L was in C.
        let c = "Asia/Kolkata"
        let file = try ZoneFile.parse(Data("""
            {"zones": [{"since": "\(iso(l - 3600))", "zone": "\(c)"}], "until": "\(iso(l + 5 * 3600))"}
            """.utf8)).get()
        store.setZoneFile(file)
        expect(store.zonePeriods.map(\.source) == [.logs, .file, .logs, .recorded], "sources: \(store.zonePeriods.map(\.source.rawValue))")

        // 6. The redo, as the app runs it, then the flush.
        guard case .done(let plan, let read, let changed) = await writer.restampZones(store: store, now: now) else {
            return (failures + ["the redo didn't run"], notes)
        }
        await writer.flush(store: store, device: nil)
        let after = try await writer.ownSamples(from: base - 3 * 86_400)

        // The same samples plus night L, nothing else resurrected, nothing lost.
        func shape(_ s: ZoneRedo.HealthSample) -> String { "\(s.syncId ?? "?") \(s.kind.rawValue) \(s.start) \(s.end) \(s.value)" }
        func shape(_ s: PlannedSample) -> String { "\(s.syncId) \(s.kind.rawValue) \(s.start) \(s.end) \(s.value)" }
        let shapesBefore = Set(before.map(shape)), shapesAfter = Set(after.map(shape)), shapesL = Set(nightL.map(shape))
        expect(after.count == before.count + nightL.count && shapesAfter == shapesBefore.union(shapesL),
               "Health's samples changed: \(shapesAfter.subtracting(shapesBefore.union(shapesL)).sorted()) added, "
               + "\(shapesBefore.union(shapesL).subtracting(shapesAfter).sorted()) missing")
        expect(plan.restored.count == 1 && plan.restored.first?.start == spanL.start && plan.restored.first?.end == spanL.end
               && Set(plan.restored.first?.rewrites.map(\.row.sample.syncId) ?? []) == Set(nightL.map(\.syncId)),
               "restored: \(plan.restored.map { "\($0.start)–\($0.end) (\($0.rewrites.count) rows)" })")
        for s in after where nightL.contains(where: { $0.syncId == s.syncId }) {
            expect(s.zone == c, "night L's \(s.syncId ?? "?") came back in \(s.zone ?? "no zone"), not C from the file")
            expect(s.version == (outboxNow[s.syncId ?? ""]?.syncVersion ?? 0) + 1, "night L's \(s.syncId ?? "?") came back at version \(s.version ?? 0)")
        }
        expect(!after.contains { s in rowsM.contains { $0.sample.syncId == s.syncId } }, "night M came back")
        let inHealthAfter = Set(after.compactMap(\.syncId))
        expect(staleStages.allSatisfy { !inHealthAfter.contains($0) }, "a stale stage came back")
        expect(!inHealthAfter.contains(goneFromHealth), "the deleted heart-rate sample came back")

        // Zones and versions.
        let rewritten = Set(plan.rewrites.map(\.row.sample.syncId))
        let beforeById = Dictionary(before.compactMap { s in s.syncId.map { ($0, s) } }) { x, _ in x }
        for s in after {
            guard let id = s.syncId, let old = beforeById[id] else { continue }
            if id == pruned {
                expect(s.zone == old.zone && s.version == old.version, "the sample without an outbox row was changed")
                continue
            }
            let expected = store.zones.zone(at: s.start)
            expect(ZoneRedo.sameZone(s.zone, expected, from: s.start, to: s.end), "\(id): zone \(s.zone ?? "none"), the history has \(expected ?? "none")")
            if rewritten.contains(id) {
                expect(s.zone == expected, "\(id): rewritten with \(s.zone ?? "none"), not \(expected ?? "none")")
                expect(s.version == (old.version ?? 0) + 1, "\(id): version \(s.version ?? 0), was \(old.version ?? 0)")
            } else {
                expect(s.version == old.version && s.zone == old.zone, "\(id): changed without being rewritten")
            }
        }
        let expectedRewrites = second.count + backfilled.count - 1  // all stamped B, but the pruned one
        expect(plan.rewrites.count == expectedRewrites && changed == expectedRewrites + nightL.count,
               "rewrote \(plan.rewrites.count) (\(changed) changed), expected \(expectedRewrites)")
        expect(plan.noRow.compactMap(\.syncId) == [pruned], "no outbox row: \(plan.noRow.compactMap(\.syncId))")
        expect(Set(plan.notInHealth.map(\.sample.syncId)) == Set(staleStages + [goneFromHealth] + rowsM.map(\.sample.syncId)),
               "outbox rows not in Health: \(plan.notInHealth.map(\.sample.syncId))")
        expect(plan.right.count == before.count - plan.rewrites.count - 1, "right already: \(plan.right.count)")

        notes.append("Health had \(read) samples; rewrote \(plan.rewrites.count) in place (+1 version, zone from the history), "
                     + "\(plan.right.count) right already, \(plan.noRow.count) with no outbox row left as it was, "
                     + "\(plan.notInHealth.count) outbox rows not in Health left out (\(staleStages.count) stale stages, 1 heart rate, "
                     + "\(rowsM.count) of night M, two versions); restored \(plan.restored.count) lost night (night L: "
                     + "\(plan.restored.first?.rewrites.count ?? 0) rows, in C from time-zones.json, one version up)")
        func offset(_ s: ZoneRedo.HealthSample) -> String {
            s.zone.flatMap(TimeZone.init(identifier:)).map { ZoneHistory.offsetText($0.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.start)))) } ?? "no zone"
        }
        let byOffset = Dictionary(grouping: after, by: offset).map { "\($0.value.count) \($0.key)" }.sorted()
        notes.append("Afterwards: \(after.count) samples (\(before.count) before); by zone offset: \(byOffset.joined(separator: ", "))")
        return (failures, notes)
    }

    private static func iso(_ t: Int) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(t))) }

    private static func stage(_ start: Int, _ length: Int, version: Int = 1) -> PlannedSample {
        PlannedSample(kind: .sleep, syncId: "whoopsync:stage:\(start)", start: start, end: start + length,
                      value: Double(HKCategoryValueSleepAnalysis.asleepCore.rawValue), version: version)
    }

    private static func sample(_ kind: PlannedSample.Kind, _ name: String, _ start: Int, _ length: Int, _ value: Double, version: Int = 2) -> PlannedSample {
        PlannedSample(kind: kind, syncId: "whoopsync:\(name):\(start)", start: start, end: start + length, value: value, version: version)
    }

    private static func sampleType(_ kind: PlannedSample.Kind) -> HKSampleType {
        switch kind {
        case .heartRate: return HKQuantityType(.heartRate)
        case .hrv: return HKQuantityType(.heartRateVariabilitySDNN)
        case .steps: return HKQuantityType(.stepCount)
        case .restingHR: return HKQuantityType(.restingHeartRate)
        case .respiratoryRate: return HKQuantityType(.respiratoryRate)
        case .sleep: return HKCategoryType(.sleepAnalysis)
        case .spo2: return HKQuantityType(.oxygenSaturation)
        }
    }
}

/// The zone check's result, for the UI test to read.
struct ZoneCheckView: View {
    @State private var result = "Running the zone check…"

    var body: some View {
        ScrollView { Text(result).font(.footnote.monospaced()).accessibilityIdentifier("zoneCheckResult").padding() }
            .task { result = await ZoneCheck.run() }
    }
}
#endif
