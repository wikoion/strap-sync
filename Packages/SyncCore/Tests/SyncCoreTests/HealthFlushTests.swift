import XCTest
@testable import SyncCore

/// The order `HealthFlush` writes the outbox to Health in, against an outbox and a Health store kept in memory, with
/// nights staged at each point a flush can be interrupted: during a clear's delete, during a batch's save, and between
/// flushes. All values are made up.
@MainActor
final class HealthFlushTests: XCTestCase {
    static let day = 86_400
    static let base = 1_780_000_000 - 1_780_000_000 % 3600

    /// The outbox as `Store` keeps it: rows by sync identifier, pending clears, and nights staged as
    /// `Store.stageNight` stages them.
    final class MemoryOutbox: FlushOutbox {
        struct Row: Equatable {
            var sample: PlannedSample
            var written: Bool
        }

        var rows: [String: Row] = [:]
        var pending: [NightClear] = []

        /// Adds samples with more data than the stored ones, unwritten, as `Store.plan` does.
        func plan(_ samples: [PlannedSample]) {
            for s in samples where (rows[s.syncId]?.sample.version ?? .min) < s.version {
                rows[s.syncId] = Row(sample: s, written: false)
            }
        }

        func stageNight(start: Int, end: Int, samples: [PlannedSample], neighbours: [Range<Int>]) {
            let clear = NightClear(night: start, end)
            if !pending.contains(clear) { pending.append(clear) }
            rows = rows.filter { !(NightClear.kinds.contains($0.value.sample.kind) && $0.value.sample.start >= start && $0.value.sample.start < end) }
            for s in clear.rewrites(rows.values.filter(\.written).map(\.sample), neighbours: neighbours) {
                rows[s.syncId]?.written = false
            }
            for s in samples { rows[s.syncId] = Row(sample: s, written: false) }
        }

        func clears() throws -> [NightClear] { pending.sorted { ($0.start, $0.end) < ($1.start, $1.end) } }

        func removeClear(_ clear: NightClear) throws { pending.removeAll { $0 == clear } }

        func unwritten(limit: Int, kinds: Set<PlannedSample.Kind>) throws -> [PlannedSample] {
            let due = rows.values.filter { r in
                !r.written && kinds.contains(r.sample.kind) && !pending.contains { $0.covers(r.sample) }
            }
            return Array(due.map(\.sample).sorted { ($0.start, $0.syncId) < ($1.start, $1.syncId) }.prefix(limit))
        }

        func markWritten(_ samples: [PlannedSample]) throws {
            for s in samples where rows[s.syncId]?.sample.version == s.version { rows[s.syncId]?.written = true }
        }

        var samples: [String: PlannedSample] { rows.mapValues(\.sample) }
        var unwrittenCount: Int { rows.values.filter { !$0.written }.count }
    }

    struct Failure: Error {}

    /// Apple Health as it treats this app's samples: one per sync identifier, replaced by an equal or higher
    /// version, and deleted by a clear when it overlaps the span (ends included: the most a clear could take).
    @MainActor
    final class MemoryHealth {
        enum Event: Equatable {
            case cleared(NightClear)
            case saved([String])
        }

        var samples: [String: PlannedSample] = [:]
        var events: [Event] = []
        /// Run while the flush waits on a delete or a save: whatever they do happens before it carries on.
        var duringClear: ((NightClear) -> Void)?
        var duringSave: (([PlannedSample]) -> Void)?
        var clearFails: () -> Bool = { false }
        var saveFails: () -> Bool = { false }

        func clear(_ clear: NightClear) async throws {
            await Task.yield()
            duringClear?(clear)
            if clearFails() { throw Failure() }
            samples = samples.filter { !clear.covers($0.value) }
            events.append(.cleared(clear))
        }

        func save(_ batch: [PlannedSample]) async throws {
            await Task.yield()
            duringSave?(batch)
            if saveFails() { throw Failure() }
            for s in batch where (samples[s.syncId]?.version ?? .min) <= s.version { samples[s.syncId] = s }
            events.append(.saved(batch.map(\.syncId)))
        }

        /// Whether `id` was saved after the last delete of `clear`.
        func savedAfterCleared(_ id: String, _ clear: NightClear) -> Bool {
            guard let cleared = events.lastIndex(of: .cleared(clear)) else { return false }
            return events[cleared...].contains { if case .saved(let ids) = $0 { return ids.contains(id) } else { return false } }
        }
    }

    /// The app: nights staged as `AppModel.processNights` stages them, waiting while a batch is being saved, and
    /// staged once the flush is done, as `AppModel.flush` does.
    @MainActor
    final class Phone {
        let outbox = MemoryOutbox()
        let health = MemoryHealth()
        let flush = HealthFlush()
        var batchSize = 100
        /// Off only to show why staging waits.
        var waitsForSaves = true
        private(set) var waited = 0
        private var waiting: [(start: Int, end: Int, samples: [PlannedSample])] = []
        /// Each night as last staged, by its start: the nights `Sleep.nights` would find.
        private var nights: [Int: Range<Int>] = [:]

        func stage(_ night: (start: Int, end: Int, samples: [PlannedSample])) {
            if waitsForSaves, flush.saving {
                waiting.append(night)
                waited += 1
                return
            }
            nights[night.start] = night.start..<night.end
            outbox.stageNight(start: night.start, end: night.end, samples: night.samples,
                              neighbours: nights.filter { $0.key != night.start }.map(\.value))
        }

        @discardableResult
        func runFlush() async -> HealthFlush.Outcome {
            let out = await flush.run(outbox, kinds: Set(PlannedSample.Kind.allCases), batchSize: batchSize,
                                      clear: health.clear, save: health.save)
            if !waiting.isEmpty, !flush.saving {
                let nights = waiting
                waiting = []
                nights.forEach(stage)
                await runFlush()
            }
            return out
        }
    }

    /// A night as staging writes it: 30-minute sleep stages (their identifiers move with `shift`), a resting heart
    /// rate, and a breathing rate an hour. (The app keys resting heart rate by the day of waking, so two nights
    /// ending the same day share one; here each night has its own.)
    static func night(_ start: Int, hours: Int = 8, version: Int, shift: Int = 0) -> (start: Int, end: Int, samples: [PlannedSample]) {
        let end = start + hours * 3600
        var out: [PlannedSample] = []
        var t = start + shift
        while t < end {
            let e = min(t + 1800, end)
            out.append(PlannedSample(kind: .sleep, syncId: "whoopsync:stage:\(t)", start: t, end: e,
                                     value: Double(3 + t / 1800 % 3), version: version))
            t = e
        }
        out.append(PlannedSample(kind: .restingHR, syncId: "whoopsync:rhr:\(start)", start: start + 3600,
                                 end: start + 5400, value: 50, version: version))
        for h in stride(from: start - start % 3600, to: end, by: 3600) {
            out.append(PlannedSample(kind: .respiratoryRate, syncId: "whoopsync:resp:\(h)", start: max(h, start),
                                     end: min(h + 3600, end), value: 14, version: version))
        }
        return (start, end, out)
    }

    static func heartRates(from start: Int, minutes: Int, version: Int = 100_060) -> [PlannedSample] {
        (0..<minutes).map { i in
            let m = start + i * 60
            return PlannedSample(kind: .heartRate, syncId: "whoopsync:hr:\(m)", start: m, end: m + 60, value: 60, version: version)
        }
    }

    /// Nights a day and a half apart, so no night's clear reaches another night.
    static func slot(_ i: Int) -> Int { base + i * 36 * 3600 }

    /// Puts a night in Health as an earlier flush left it: written there, and marked written.
    func written(_ phone: Phone, _ n: (start: Int, end: Int, samples: [PlannedSample])) {
        for s in n.samples {
            phone.health.samples[s.syncId] = s
            phone.outbox.rows[s.syncId] = MemoryOutbox.Row(sample: s, written: true)
        }
    }

    // MARK: -

    func testAClearCoversItsKindsOverlappingItsSpanEndsIncluded() {
        let c = NightClear(night: 10_000, 20_000)
        XCTAssertEqual(c, NightClear(start: 2800, end: 27_200))
        func s(_ kind: PlannedSample.Kind, _ start: Int, _ end: Int) -> PlannedSample {
            PlannedSample(kind: kind, syncId: "x", start: start, end: end, value: 1, version: 1)
        }
        XCTAssertTrue(c.covers(s(.sleep, 0, 2800)))
        XCTAssertTrue(c.covers(s(.restingHR, 27_200, 30_000)))
        XCTAssertTrue(c.covers(s(.respiratoryRate, 15_000, 16_000)))
        XCTAssertFalse(c.covers(s(.sleep, 0, 2799)))
        XCTAssertFalse(c.covers(s(.sleep, 27_201, 30_000)))
        XCTAssertFalse(c.covers(s(.heartRate, 15_000, 15_060)))
        XCTAssertFalse(c.covers(s(.hrv, 15_000, 15_300)))
    }

    /// 13 Nov 2026: a long write (a one-time rewrite of heart rate) was under way when two more nights were staged.
    /// They wait for the save, are staged once the flush is done, and are written after their clears.
    func testNightsStagedDuringALongSaveAreWrittenAfterTheirClears() async {
        let phone = Phone()
        phone.outbox.plan(Self.heartRates(from: Self.slot(0), minutes: 1100))
        let earlier = (0..<6).map { Self.night(Self.slot($0), version: 1) }
        earlier.forEach { written(phone, $0) }
        let staged = (0..<6).map { Self.night(Self.slot($0), version: 2, shift: 600) }
        for n in staged[2...] { phone.stage(n) }
        var savingSeen: [Bool] = []
        phone.health.duringSave = { [unowned phone] _ in
            savingSeen.append(phone.flush.saving)
            if savingSeen.count == 1 {
                let before = phone.outbox.pending
                phone.stage(staged[1])
                phone.stage(staged[0])
                XCTAssertEqual(phone.outbox.pending, before, "a clear was registered during a save")
            }
        }
        phone.health.duringClear = { [unowned phone] _ in XCTAssertFalse(phone.flush.saving) }

        let out = await phone.runFlush()
        XCTAssertNil(out.clearError)
        XCTAssertNil(out.saveError)
        XCTAssertEqual(phone.waited, 2)
        XCTAssertTrue(savingSeen.allSatisfy { $0 })
        XCTAssertFalse(phone.flush.saving)
        XCTAssertEqual(phone.health.samples, phone.outbox.samples)
        XCTAssertEqual(phone.outbox.unwrittenCount, 0)
        XCTAssertTrue(phone.outbox.pending.isEmpty)
        for n in staged {
            let clear = NightClear(night: n.start, n.end)
            for s in n.samples {
                XCTAssertEqual(phone.health.samples[s.syncId], s)
                XCTAssertTrue(phone.health.savedAfterCleared(s.syncId, clear), s.syncId)
            }
        }
        // The earlier stages, under other identifiers, are gone.
        for n in earlier { for s in n.samples where s.kind == .sleep { XCTAssertNil(phone.health.samples[s.syncId]) } }
    }

    /// A night staged again while its own samples are being saved (unchanged, so the same identifiers and versions)
    /// waits, and is written again after its clear.
    func testANightStagedAgainWhileItIsBeingSavedIsWritten() async {
        let phone = Phone()
        let n = Self.night(Self.slot(0), version: 3)
        phone.stage(n)
        var saves = 0
        phone.health.duringSave = { [unowned phone] _ in
            saves += 1
            if saves == 1 { phone.stage(n) }
        }
        await phone.runFlush()
        XCTAssertEqual(phone.waited, 1)
        for s in n.samples { XCTAssertEqual(phone.health.samples[s.syncId], s) }
        XCTAssertEqual(phone.health.samples, phone.outbox.samples)
    }

    /// Why staging waits: a clear registered while its night's samples are being saved deletes them once saved,
    /// and they're already marked written.
    func testWhyStagingWaitsForASave() async {
        let phone = Phone()
        phone.waitsForSaves = false
        let n = Self.night(Self.slot(0), version: 3)
        phone.stage(n)
        var saves = 0
        phone.health.duringSave = { [unowned phone] _ in
            saves += 1
            if saves == 1 { phone.stage(n) }
        }
        await phone.runFlush()
        await phone.runFlush()
        XCTAssertEqual(phone.outbox.unwrittenCount, 0)
        XCTAssertTrue(phone.outbox.pending.isEmpty)
        XCTAssertTrue(phone.health.samples.isEmpty, "the night survived, so this no longer shows why staging waits")
    }

    /// A night staged during another night's delete (no save is under way) has its clear run in the same flush,
    /// before any of its samples are saved.
    func testAClearRegisteredDuringADeleteRunsBeforeTheNextBatch() async {
        let phone = Phone()
        let first = Self.night(Self.slot(0), version: 2, shift: 300)
        let second = Self.night(Self.slot(1), version: 2, shift: 300)
        written(phone, Self.night(Self.slot(1), version: 1))
        phone.stage(first)
        phone.health.duringClear = { [unowned phone] c in
            if c == NightClear(night: first.start, first.end) { phone.stage(second) }
        }
        let out = await phone.runFlush()
        XCTAssertEqual(phone.waited, 0)
        XCTAssertEqual(out.saved, first.samples.count + second.samples.count)
        XCTAssertEqual(phone.health.samples, phone.outbox.samples)
        for s in second.samples { XCTAssertTrue(phone.health.savedAfterCleared(s.syncId, NightClear(night: second.start, second.end))) }
    }

    /// A night staged again during its own clear's delete: the clear is still the same span, and the delete under
    /// way removes everything, so its newest samples are what Health ends up with.
    func testANightStagedAgainDuringItsOwnClear() async {
        let phone = Phone()
        written(phone, Self.night(Self.slot(0), version: 1))
        phone.stage(Self.night(Self.slot(0), version: 2, shift: 300))
        let newest = Self.night(Self.slot(0), version: 3, shift: 900)
        var deletes = 0
        phone.health.duringClear = { [unowned phone] _ in
            deletes += 1
            if deletes == 1 { phone.stage(newest) }
        }
        await phone.runFlush()
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(phone.health.samples, Dictionary(uniqueKeysWithValues: newest.samples.map { ($0.syncId, $0) }))
        XCTAssertEqual(phone.health.samples, phone.outbox.samples)
    }

    /// While a clear can't run (the phone is locked, say), the samples it covers wait and everything else is written.
    func testSamplesAPendingClearCoversWaitUntilItHasRun() async {
        let phone = Phone()
        let old = Self.night(Self.slot(0), version: 1)
        written(phone, old)
        let n = Self.night(Self.slot(0), version: 2, shift: 600)
        phone.stage(n)
        let hr = Self.heartRates(from: Self.slot(0), minutes: 300)
        phone.outbox.plan(hr)
        // Breathing a day and a half away: no pending clear covers it.
        let far = PlannedSample(kind: .respiratoryRate, syncId: "whoopsync:resp:\(Self.slot(1))", start: Self.slot(1),
                                end: Self.slot(1) + 3600, value: 15, version: 4)
        phone.outbox.plan([far])

        phone.health.clearFails = { true }
        let locked = await phone.runFlush()
        XCTAssertNotNil(locked.clearError)
        XCTAssertNil(locked.saveError)
        XCTAssertEqual(locked.saved, hr.count + 1)
        XCTAssertEqual(phone.health.samples[far.syncId], far)
        for s in old.samples { XCTAssertEqual(phone.health.samples[s.syncId], s) }
        for s in n.samples where s.kind == .sleep { XCTAssertNil(phone.health.samples[s.syncId]) }
        XCTAssertEqual(phone.outbox.unwrittenCount, n.samples.count)

        phone.health.clearFails = { false }
        let unlocked = await phone.runFlush()
        XCTAssertEqual(unlocked.saved, n.samples.count)
        XCTAssertEqual(phone.health.samples, phone.outbox.samples)
        for s in n.samples { XCTAssertTrue(phone.health.savedAfterCleared(s.syncId, NightClear(night: n.start, n.end))) }
    }

    /// A night staged again whose clear reaches into the next night, already written: that night's samples are
    /// written again after the clear.
    func testANearbyNightKeepsItsSamples() async {
        let phone = Phone()
        let n = Self.night(Self.slot(0), hours: 6, version: 1)
        let next = Self.night(Self.slot(0) + 7 * 3600, hours: 6, version: 1)
        phone.stage(n)
        phone.stage(next)
        await phone.runFlush()
        XCTAssertEqual(phone.health.samples.count, n.samples.count + next.samples.count)

        let again = Self.night(Self.slot(0), hours: 6, version: 2, shift: 600)
        phone.stage(again)
        let clear = NightClear(night: again.start, again.end)
        XCTAssertTrue(next.samples.contains(where: clear.covers))
        await phone.runFlush()
        XCTAssertEqual(phone.health.samples, phone.outbox.samples)
        for s in next.samples { XCTAssertEqual(phone.health.samples[s.syncId], s) }
        for s in next.samples where clear.covers(s) { XCTAssertTrue(phone.health.savedAfterCleared(s.syncId, clear)) }
    }

    /// Nights staged and restaged at random points (between flushes, during deletes, during saves), more heart rate
    /// planned meanwhile, deletes and saves failing at random: once the flushes have caught up, Health holds exactly
    /// the outbox's samples, every night as last staged.
    func testAnyInterleavingEndsWithHealthMatchingTheOutbox() async {
        final class Dice {
            var state: UInt64
            init(_ seed: UInt64) { state = seed }
            func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
            func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
            func chance(_ p: Double) -> Bool { Double(next() % 1000) < p * 1000 }
        }

        for seed in 1...300 {
            let dice = Dice(UInt64(seed))
            let phone = Phone()
            phone.batchSize = 3 + dice.int(40)
            // Nights a day and a half apart, or (every other seed) close enough for a clear to reach the next one.
            let spacing = seed % 2 == 0 ? 36 * 3600 : 8 * 3600 + 1800
            // Each night only grows when staged again, as a night does when you go back to sleep, up to 7 hours: a
            // night that shrank would leave samples behind in its clear's margin, outside this test.
            var hours = [5, 5, 5, 5]
            var hrVersion = 100_000
            func restage() {
                let i = dice.int(hours.count)
                hours[i] = min(7, hours[i] + dice.int(2))
                // Few versions and shifts, so a night is often staged again unchanged.
                phone.stage(Self.night(Self.base + i * spacing, hours: hours[i], version: 1 + dice.int(3), shift: 300 * dice.int(2)))
            }
            func moreHeartRate() {
                hrVersion += 1 + dice.int(5)
                phone.outbox.plan(Self.heartRates(from: Self.base + dice.int(4) * spacing + 600 * dice.int(40), minutes: 1 + dice.int(30),
                                                  version: hrVersion))
            }
            var interruptions = 0
            phone.health.duringClear = { _ in
                guard interruptions < 4, dice.chance(0.3) else { return }
                interruptions += 1
                restage()
            }
            phone.health.duringSave = { _ in
                guard interruptions < 4, dice.chance(0.3) else { return }
                interruptions += 1
                if dice.chance(0.5) { restage() } else { moreHeartRate() }
            }
            phone.health.clearFails = { dice.chance(0.15) }
            phone.health.saveFails = { dice.chance(0.15) }
            for _ in 0..<12 {
                switch dice.int(3) {
                case 0: restage()
                case 1: moreHeartRate()
                default:
                    interruptions = 0
                    await phone.runFlush()
                }
            }
            phone.health.duringClear = nil
            phone.health.duringSave = nil
            phone.health.clearFails = { false }
            phone.health.saveFails = { false }
            await phone.runFlush()
            XCTAssertEqual(phone.outbox.unwrittenCount, 0, "seed \(seed)")
            XCTAssertTrue(phone.outbox.pending.isEmpty, "seed \(seed)")
            XCTAssertEqual(phone.health.samples, phone.outbox.samples, "seed \(seed)")
        }
    }
}
