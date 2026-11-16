import XCTest
@testable import SyncCore

/// The zone history samples are stamped with: looking up a sample's zone, recording the phone's zone, reconstructing
/// the past from the app's logs, and the one-time rewrite. Every date, time and offset is made up.
final class ZoneTests: XCTestCase {
    let hour = 3600

    // MARK: Synthetic logs

    /// A line every `step` minutes from `from` to `to` (local "HH:MM"), as a download would log.
    func every(_ from: String, _ to: String, step: Int = 15, _ message: String = "History: complete, 3 chunks, 900 records") -> [(String, String)] {
        let a = seconds(from), b = seconds(to)
        return stride(from: a, through: b, by: step * 60).map { (clock($0), message) }
    }

    func seconds(_ hm: String) -> Int {
        let p = hm.split(separator: ":").map { Int($0)! }
        return p[0] * 3600 + p[1] * 60 + (p.count > 2 ? p[2] : 0)
    }

    func clock(_ s: Int) -> String { String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }

    /// A day's log as the app writes it, its time the instant its last line was written at `lastOffset`.
    func file(_ day: String, _ lines: [(String, String)], lastOffset: Int) -> ZoneLog.File {
        let text = lines.map { "\($0.0) \($0.1)" }.joined(separator: "\n") + "\n"
        let last = ZoneLog.dayStart(day)! + seconds(lines.last!.0)
        return ZoneLog.File(day: day, text: text, modified: Double(last - lastOffset) + 0.4)
    }

    /// An instant: a date's local time at an offset.
    func at(_ day: String, _ hm: String, _ offset: Int = 0) -> Int { ZoneLog.dayStart(day)! + seconds(hm) - offset }

    // MARK: Lookup and recording

    func testASamplesZoneIsTheOneInEffectAtItsStart() {
        let h = ZoneHistory([.init(since: 2_000, zone: "GMT-0500"), .init(since: 1_000, zone: "GMT+0100"), .init(since: 3_000, zone: nil)])
        XCTAssertNil(h.zone(at: 999), "nothing is known before the first entry")
        XCTAssertEqual(h.zone(at: 1_000), "GMT+0100")
        XCTAssertEqual(h.zone(at: 1_999), "GMT+0100")
        XCTAssertEqual(h.zone(at: 2_000), "GMT-0500")
        XCTAssertNil(h.zone(at: 3_000), "an unknown stretch")
        XCTAssertEqual(h.offset(at: 2_500), -5 * hour)
    }

    func testTheHistoryOnlyGrowsWhenTheZoneChanges() {
        var h = ZoneHistory()
        let first = h.observing("Asia/Tokyo", at: 1_000)
        XCTAssertEqual(first, .init(since: 1_000, zone: "Asia/Tokyo"))
        h.add(first!)
        XCTAssertNil(h.observing("Asia/Tokyo", at: 5_000), "the same zone again adds nothing")
        let moved = h.observing("GMT-0300", at: 9_000)
        XCTAssertEqual(moved, .init(since: 9_000, zone: "GMT-0300"))
        h.add(moved!)
        XCTAssertEqual(h.observing("Asia/Tokyo", at: 8_000)?.since, 9_001, "a clock set back can't reorder the history")
        XCTAssertEqual(h.entries.map(\.since), [1_000, 9_000])
    }

    func testThePastGoesOnlyBeforeTheFirstRecordedEntry() {
        let h = ZoneHistory([.init(since: 10_000, zone: "GMT-0800")])
        let past: [ZoneHistory.Entry] = [.init(since: 1_000, zone: "GMT"), .init(since: 2_000, zone: "GMT"),
                                         .init(since: 5_000, zone: "GMT-0800"), .init(since: 12_000, zone: "GMT+0100")]
        XCTAssertEqual(h.before(past), [.init(since: 1_000, zone: "GMT"), .init(since: 5_000, zone: "GMT-0800")])
    }

    // MARK: Reconstruction from the logs

    func testOneZoneThroughout() {
        let files = [file("2030-03-04", [("07:12:09", "App launched by opening it")] + every("07:30", "23:45"), lastOffset: 9 * hour),
                     file("2030-03-05", every("00:00", "18:00"), lastOffset: 9 * hour)]
        let until = at("2030-03-05", "18:30", 9 * hour)
        XCTAssertEqual(ZoneLog.changes(files, until: until), [.init(since: at("2030-03-04", "07:12:09", 9 * hour), offset: 9 * hour)])
        // The phone's own zone where it has the offset found; a fixed one where it doesn't.
        XCTAssertEqual(ZoneLog.reconstruct(files, current: TimeZone(identifier: "Asia/Tokyo")!, until: until),
                       [.init(since: at("2030-03-04", "07:12:09", 9 * hour), zone: "Asia/Tokyo")])
        XCTAssertEqual(ZoneLog.reconstruct(files, current: TimeZone(secondsFromGMT: -3 * hour)!, until: until).map(\.zone), ["GMT+0900"])
        XCTAssertEqual(ZoneLog.changes(files, until: at("2030-03-04", "12:00", 9 * hour)).count, 1, "nothing after `until`")
    }

    /// The case that broke nights: a log's lines keep the zone their process started in, so after a move the lines
    /// never jump; only a new process, and each file's time, show the new zone. Day B's first two processes started
    /// before the move, the third after it.
    func testAMoveShowsAtTheFirstProcessInTheNewZone() {
        let files = [
            file("2030-01-08", [("08:00:00", "App launched by opening it")] + every("08:15", "23:45") + [("23:59:00", "Apple Health: saved 12 samples")],
                 lastOffset: 0),
            file("2030-01-09", every("00:00", "10:15") + [("10:30:00", "App launched by opening it")] + every("10:45", "20:00")
                 + [("21:15:00", "iOS relaunched the app for the strap"), ("21:15:01", "App launched by iOS for the strap")]
                 + every("21:30", "23:45") + [("23:59:00", "Apple Health: saved 12 samples")],
                 lastOffset: -7 * hour),
            file("2030-01-10", every("00:00", "09:45"), lastOffset: -7 * hour),
            file("2030-01-11", [("06:00:00", "App launched by opening it")] + every("06:15", "23:45") + [("23:59:00", "Apple Health: saved 12 samples")],
                 lastOffset: -8 * hour),
        ]
        let until = at("2030-01-12", "09:00", -8 * hour)
        XCTAssertEqual(ZoneLog.changes(files, until: until), [
            .init(since: at("2030-01-08", "08:00"), offset: 0),
            // 21:15 at UTC-7: the third process of day B. The second, from 10:30, keeps the zone before it.
            .init(since: at("2030-01-09", "21:15", -7 * hour), offset: -7 * hour),
            .init(since: at("2030-01-11", "06:00", -8 * hour), offset: -8 * hour),
        ])
        let current = TimeZone(secondsFromGMT: -8 * hour)!
        let history = ZoneHistory(ZoneLog.reconstruct(files, current: current, until: until) + [.init(since: until, zone: current.identifier)])
        // A night slept before the move, and one after.
        XCTAssertEqual(history.offset(at: at("2030-01-08", "23:30")), 0)
        XCTAssertEqual(history.offset(at: at("2030-01-09", "07:30")), 0)
        XCTAssertEqual(history.offset(at: at("2030-01-10", "07:30")), -7 * hour)
        XCTAssertEqual(history.offset(at: at("2030-01-10", "15:00")), -7 * hour)
        // The hours between the last line of day B's second process and the third keep the zone before.
        XCTAssertEqual(history.offset(at: at("2030-01-10", "03:00")), 0)
        XCTAssertEqual(history.zone(at: at("2030-01-11", "13:59")), "GMT-0700")
        XCTAssertEqual(history.zone(at: at("2030-01-11", "14:00")), "GMT-0800")
    }

    /// Moving east, the new process's local times run ahead: kept in the old zone, its lines would end after the
    /// next process's began, so the change can only be at its start.
    func testAMoveEastMovesTheChangeBackToTheProcessThatNeedsIt() {
        let files = [
            file("2030-05-01", [("06:00:00", "App launched by opening it")] + every("06:15", "23:59", step: 16), lastOffset: -5 * hour),
            file("2030-05-02", every("00:00", "07:00") + [("15:00:00", "App launched in the background")] + every("15:15", "17:00")
                 + [("18:00:00", "App launched by opening it")] + every("18:15", "23:45"), lastOffset: 0),
        ]
        let changes = ZoneLog.changes(files, until: at("2030-05-03", "00:00"))
        XCTAssertEqual(changes, [.init(since: at("2030-05-01", "06:00", -5 * hour), offset: -5 * hour),
                                 .init(since: at("2030-05-02", "15:00"), offset: 0)])
    }

    /// Summer time ending inside a process: its local time goes back an hour, and the file's time has the later offset.
    func testSummerTimeEndingInsideAProcess() {
        let files = [
            file("2030-10-26", [("09:00:00", "App launched by opening it")] + every("09:05", "23:55", step: 5), lastOffset: hour),
            file("2030-10-27", every("00:00", "01:55", step: 5) + every("01:00", "23:55", step: 5), lastOffset: 0),
        ]
        XCTAssertEqual(ZoneLog.changes(files, until: at("2030-10-28", "00:00")), [
            .init(since: at("2030-10-26", "09:00", hour), offset: hour),
            .init(since: at("2030-10-27", "01:00"), offset: 0),
        ])
    }

    /// No log for a day: nothing is known about it. Nor before the first line.
    func testMissingFilesLeaveTheirDaysUnknown() {
        let files = [
            file("2030-02-01", every("00:00", "23:45") + [("23:59:00", "Apple Health: saved 3 samples")], lastOffset: 2 * hour),
            file("2030-02-03", every("00:00", "23:45"), lastOffset: 2 * hour),
        ]
        let history = ZoneHistory(ZoneLog.reconstruct(files, current: TimeZone(secondsFromGMT: 0)!, until: at("2030-02-04", "00:00", 2 * hour)))
        XCTAssertNil(history.zone(at: at("2030-01-31", "12:00", 2 * hour)))
        XCTAssertEqual(history.zone(at: at("2030-02-01", "12:00", 2 * hour)), "GMT+0200")
        XCTAssertNil(history.zone(at: at("2030-02-02", "12:00", 2 * hour)))
        XCTAssertEqual(history.zone(at: at("2030-02-03", "12:00", 2 * hour)), "GMT+0200")
        // Nor after the last line, when the app's own record starts more than a day later.
        let late = ZoneHistory(ZoneLog.reconstruct(files, current: TimeZone(secondsFromGMT: 0)!, until: at("2030-02-06", "00:00")))
        XCTAssertNil(late.zone(at: at("2030-02-05", "00:00")))
        XCTAssertTrue(ZoneLog.changes([], until: 1_000).isEmpty)
    }

    /// A file whose time doesn't match its last line (copied, say) gives no offset of its own: its lines carry the one
    /// before. Lines that aren't log lines are skipped.
    func testAFileWithoutAUsableTimeCarriesTheOffsetBefore() {
        var second = file("2030-04-02", every("00:00", "12:00"), lastOffset: -3 * hour)
        second = ZoneLog.File(day: second.day, text: second.text + "  a message's second line\nnot a log line\n", modified: second.modified + 5 * 86_400)
        let files = [file("2030-04-01", every("08:00", "23:45"), lastOffset: -3 * hour), second]
        XCTAssertEqual(ZoneLog.changes(files, until: at("2030-04-02", "13:00", -3 * hour)),
                       [.init(since: at("2030-04-01", "08:00", -3 * hour), offset: -3 * hour)])
    }

    func testLogLinesAndLaunches() {
        let lines = ZoneLog.lines("07:00:01 iOS relaunched the app for the strap\n07:00:01 App launched by iOS for the strap\n"
                                  + "07:05:00 History: complete\nnot a line\n25:00:00 History: complete\n", dayStart: 0)
        XCTAssertEqual(lines.map(\.local), [25_201, 25_201, 25_500])
        XCTAssertEqual(lines.map(\.launch), [true, true, false])
        XCTAssertEqual(ZoneLog.dayStart("1970-01-02"), 86_400)
        XCTAssertEqual(ZoneLog.dayStart("2030-03-01"), Int(ISO8601DateFormatter().date(from: "2030-03-01T00:00:00Z")!.timeIntervalSince1970))
        // A process's setup lines just before its launch line belong to it; one launch right after another is one process.
        let segments = ZoneLog.segments(ZoneLog.lines("11:58:00 a\n11:59:30 b\n12:00:00 setting up\n12:00:02 iOS relaunched the app\n"
                                                      + "12:00:02 App launched by iOS\n12:05:00 c\n", dayStart: 0))
        XCTAssertEqual(segments.map(\.range), [0..<2, 2..<6])
        XCTAssertEqual(segments.map(\.launch), [false, true])
    }

    // MARK: Stamping and the rewrite

    func sample(_ kind: PlannedSample.Kind, _ start: Int, zone: String? = nil, version: Int = 2) -> PlannedSample {
        PlannedSample(kind: kind, syncId: "whoopsync:\(kind):\(start)", start: start, end: start + 60, value: 60, version: version,
                      metadata: kind == .hrv ? [HealthMetadata.rmssd: .number(41.5)] : [:], zone: zone)
    }

    func testARewriteKeepsTheZoneTheSampleWasStoredWith() {
        let stored = Outbox.Row(sample: sample(.heartRate, 1_000, zone: "GMT"), syncVersion: 2)
        let more = Outbox.merge(sample(.heartRate, 1_000, version: 3), over: stored)
        XCTAssertEqual(more?.sample.zone, "GMT")
        XCTAssertEqual(more?.forHealth.zone, "GMT")
        let fresh = Outbox.merge(sample(.heartRate, 1_000, version: 3), over: Outbox.Row(sample: sample(.heartRate, 1_000), syncVersion: 2))
        XCTAssertNil(fresh?.sample.zone, "none stored: the outbox fills it in from the history")
    }

    /// What Health has decides, not the outbox: only Health's own samples with the wrong zone are rewritten, and only
    /// through their own outbox rows. Rows Health no longer has (a stale night version, deleted by a clear) stay out.
    func testTheRedoReplacesOnlyWhatHealthHasWithTheWrongZone() {
        let now = 2_000_000_000, day = 86_400
        let moved = now - 10 * day
        let history = ZoneHistory([.init(since: now - 30 * day, zone: "Asia/Tokyo"), .init(since: moved, zone: "GMT-0800")])
        func health(_ s: PlannedSample, zone: String?, version: Int) -> ZoneRedo.HealthSample {
            .init(kind: s.kind, syncId: s.syncId, start: s.start, end: s.end, value: s.value, version: version, zone: zone)
        }
        let night = sample(.sleep, moved - 6 * hour)                          // slept before the move, rewritten after it
        let hrv = sample(.hrv, moved - 2 * hour, version: 1_000_002)           // RMSSD backfilled after the move
        let named = sample(.heartRate, moved - 3 * hour)                       // written live, in the phone's named zone
        let fixed = sample(.heartRate, moved - 4 * hour, zone: "Asia/Tokyo")   // stamped with the same offset, fixed
        let after = sample(.heartRate, moved + hour)                           // right already
        let unstamped = sample(.steps, moved - 5 * hour)
        let stale = sample(.sleep, moved - 7 * hour)                           // in the outbox, written, gone from Health
        let gone = sample(.respiratoryRate, moved - 8 * hour)                  // in Health only (its row pruned)
        let moving = sample(.restingHR, moved - 9 * hour)                      // its row now has another span
        let old = sample(.spo2, now - 17 * day)
        let outbox = Dictionary(uniqueKeysWithValues: [
            Outbox.Row(sample: night, syncVersion: 2), Outbox.Row(sample: hrv, syncVersion: 1_000_003),
            Outbox.Row(sample: named, syncVersion: 2), Outbox.Row(sample: fixed, syncVersion: 2),
            Outbox.Row(sample: after.with(zone: "GMT-0800"), syncVersion: 2), Outbox.Row(sample: unstamped, syncVersion: 2),
            Outbox.Row(sample: stale, syncVersion: 2), Outbox.Row(sample: old, syncVersion: 2),
            Outbox.Row(sample: PlannedSample(kind: .restingHR, syncId: moving.syncId, start: moving.start + 60, end: moving.end, value: 50,
                                             version: 2), syncVersion: 2),
        ].map { ($0.sample.syncId, $0) })
        let inHealth = [
            health(night, zone: "GMT-0800", version: 2), health(hrv, zone: "GMT-0800", version: 1_000_004),
            health(named, zone: "Asia/Tokyo", version: 2), health(fixed, zone: "GMT+0900", version: 2),
            health(after, zone: "GMT-0800", version: 2), health(unstamped, zone: nil, version: 2),
            health(gone, zone: "GMT-0800", version: 2), health(moving, zone: "GMT-0800", version: 2),
            health(old, zone: "GMT-0800", version: 2),
            ZoneRedo.HealthSample(kind: .heartRate, syncId: nil, start: moved - hour, end: moved, value: 60, version: nil, zone: nil),
        ]
        let plan = ZoneRedo.plan(health: inHealth, outbox: outbox, history: history, now: now)
        XCTAssertEqual(plan.rewrites.map(\.row.sample.syncId), [night, unstamped, hrv].map(\.syncId))
        XCTAssertEqual(plan.rewrites.map(\.row.sample.zone), ["Asia/Tokyo", "Asia/Tokyo", "Asia/Tokyo"])
        XCTAssertEqual(plan.rewrites.map(\.row.syncVersion), [3, 3, 1_000_005], "one above both the outbox's and Health's")
        XCTAssertEqual(plan.rewrites.map(\.storedVersion), [2, 2, 1_000_003])
        XCTAssertEqual(plan.rewrites.map(\.row.sample.version), [2, 2, 1_000_002], "the data's own version is unchanged")
        XCTAssertEqual(plan.rewrites[2].row.sample.metadata, hrv.metadata, "metadata kept")
        XCTAssertEqual(Set(plan.right.compactMap(\.syncId)), Set([named, fixed, after].map(\.syncId)), "same offset counts as right")
        XCTAssertEqual(plan.noRow.compactMap(\.syncId), [moving, gone].map(\.syncId))
        XCTAssertEqual(plan.noSyncId.count, 1)
        XCTAssertEqual(plan.notInHealth.map(\.sample.syncId), [stale.syncId], "never touched")
        XCTAssertFalse(plan.rewrites.contains { $0.row.sample.syncId == old.syncId }, "older than 16 days")
    }

    /// A night Health lost but the outbox has, written, all at the newest version, comes back; nothing else does.
    func testOnlyAWholeLostNightAtItsNewestVersionIsWrittenAgain() {
        let now = 2_000_000_000, day = 86_400
        let history = ZoneHistory([.init(since: now - 30 * day, zone: "Asia/Tokyo")])
        func stages(_ start: Int, _ count: Int, version: Int) -> [PlannedSample] {
            (0..<count).map { PlannedSample(kind: .sleep, syncId: "whoopsync:stage:\(start + $0 * 1800)", start: start + $0 * 1800,
                                            end: start + ($0 + 1) * 1800, value: 3, version: version) }
        }
        func other(_ kind: PlannedSample.Kind, _ start: Int) -> PlannedSample {
            PlannedSample(kind: kind, syncId: "whoopsync:\(kind):\(start)", start: start, end: start + 1800, value: 50, version: 300)
        }
        func health(_ s: PlannedSample) -> ZoneRedo.HealthSample {
            .init(kind: s.kind, syncId: s.syncId, start: s.start, end: s.end, value: s.value, version: s.version, zone: "Asia/Tokyo")
        }
        let lostStart = now - 5 * day
        let lost = stages(lostStart, 12, version: 7) + [other(.restingHR, lostStart + 7200), other(.respiratoryRate, lostStart + 3600)]
        // Next to a night Health has: the earlier version's rows its clear deleted.
        let currentStart = now - 3 * day
        let stale = stages(currentStart - 3 * 1800, 3, version: 6), current = stages(currentStart, 10, version: 7)
        // Two versions, none in Health: left alone.
        let mixedStart = now - 7 * day
        let mixed = stages(mixedStart, 2, version: 6) + stages(mixedStart + 3600, 8, version: 7)
        // Health has a breathing sample an hour after it: left alone.
        let nearStart = now - 9 * day
        let near = stages(nearStart, 6, version: 7)
        // Not all given to Health yet: left alone (the flush writes them anyway).
        let pendingStart = now - 11 * day
        let pending = stages(pendingStart, 6, version: 7)
        let old = stages(now - 17 * day, 6, version: 7)
        let all = lost + stale + current + mixed + near + pending + old
        let outbox = Dictionary(uniqueKeysWithValues: all.map { ($0.syncId, Outbox.Row(sample: $0, syncVersion: $0.version)) })
        let written = Set(all.map(\.syncId)).subtracting([pending[2].syncId])
        let inHealth = current.map(health) + [health(other(.respiratoryRate, near.last!.end + 3600))]
        let plan = ZoneRedo.plan(health: inHealth, outbox: outbox, written: written, history: history, now: now)
        XCTAssertEqual(plan.restored.count, 1)
        let night = plan.restored[0]
        XCTAssertEqual(night.start, lostStart)
        XCTAssertEqual(night.end, lostStart + 12 * 1800)
        XCTAssertEqual(Set(night.rewrites.map(\.row.sample.syncId)), Set(lost.map(\.syncId)), "its sleep, resting HR and breathing")
        XCTAssertEqual([night.count(.sleep), night.count(.restingHR), night.count(.respiratoryRate)], [12, 1, 1])
        XCTAssertTrue(night.rewrites.allSatisfy { $0.row.sample.zone == "Asia/Tokyo" && $0.row.syncVersion == $0.storedVersion + 1 && $0.health == nil })
        XCTAssertEqual(plan.all.count, plan.rewrites.count + 14)
        let restoredIds = Set(night.rewrites.map(\.row.sample.syncId))
        for left in [stale, mixed, near, pending] { XCTAssertTrue(left.allSatisfy { !restoredIds.contains($0.syncId) }) }
        XCTAssertTrue(plan.notInHealth.allSatisfy { !restoredIds.contains($0.sample.syncId) })
        XCTAssertTrue(Set(plan.notInHealth.map(\.sample.syncId)).isSuperset(of: (stale + mixed + near + pending).map(\.syncId)))
    }

    // MARK: The owner's time-zones.json

    func zoneFile(_ text: String) -> Result<ZoneFile, ZoneFile.Problem> { ZoneFile.parse(Data(text.utf8)) }

    func testAZoneFileIsReadStrictly() throws {
        let good = """
            {"zones": [{"since": "2030-01-01T00:00:00Z", "zone": "Europe/Paris"},
                       {"since": "2030-01-09T18:30:00Z", "zone": "America/Chicago"}],
             "until": "2030-01-20T00:00:00Z"}
            """
        let file = try zoneFile(good).get()
        XCTAssertEqual(file.entries, [.init(since: at("2030-01-01", "00:00"), zone: "Europe/Paris"),
                                      .init(since: at("2030-01-09", "18:30"), zone: "America/Chicago")])
        XCTAssertEqual(file.until, at("2030-01-20", "00:00"))
        XCTAssertEqual(try zoneFile(#"{"zones": [{"since": "2030-01-01T09:00:00+09:00", "zone": "UTC"}], "until": "2030-01-02T00:00:00Z"}"#).get().start,
                       at("2030-01-01", "00:00"), "an offset in the date is fine")
        let bad: [(String, String)] = [
            ("{\"zones\": [", "not valid JSON"),
            ("[]", "not a JSON object"),
            (#"{"zones": [{"since": "2030-01-01T00:00:00Z", "zone": "Europe/Paris"}]}"#, "keys"),
            (#"{"zones": [], "until": "2030-01-20T00:00:00Z"}"#, "non-empty"),
            (#"{"zones": [{"since": "2030-01-01T00:00:00Z", "zone": "Europe/Paris"}], "until": "2030-01-20T00:00:00Z", "note": 1}"#, "keys"),
            (#"{"zones": [{"since": "2030-01-01T00:00:00Z", "zone": "Paris"}], "until": "2030-01-20T00:00:00Z"}"#, "time zone name"),
            (#"{"zones": [{"since": "2030-01-01T00:00:00Z", "zone": "GMT-0800"}], "until": "2030-01-20T00:00:00Z"}"#, "time zone name"),
            (#"{"zones": [{"since": "2030-01-01T00:00:00Z", "zone": "Etc/GMT+8"}], "until": "2030-01-20T00:00:00Z"}"#, "time zone name"),
            (#"{"zones": [{"since": "2030-01-01T00:00:00Z", "zone": "CET"}], "until": "2030-01-20T00:00:00Z"}"#, "time zone name"),
            (#"{"zones": [{"since": "2030-01-01T00:00:00Z", "zone": "Mars/Olympus_Mons"}], "until": "2030-01-20T00:00:00Z"}"#, "time zone name"),
            (#"{"zones": [{"since": "1 Jan 2030", "zone": "Europe/Paris"}], "until": "2030-01-20T00:00:00Z"}"#, "zones[0].since"),
            (#"{"zones": [{"since": "2030-01-05T00:00:00Z", "zone": "Europe/Paris"}, {"since": "2030-01-02T00:00:00Z", "zone": "Asia/Tokyo"}], "until": "2030-01-20T00:00:00Z"}"#, "doesn't start after"),
            (#"{"zones": [{"since": "2030-01-05T00:00:00Z", "zone": "Europe/Paris"}, {"since": "2030-01-05T00:00:00Z", "zone": "Asia/Tokyo"}], "until": "2030-01-20T00:00:00Z"}"#, "doesn't start after"),
            (#"{"zones": [{"since": "2030-01-05T00:00:00Z", "zone": "Europe/Paris", "until": "2030-01-06T00:00:00Z"}], "until": "2030-01-20T00:00:00Z"}"#, "zones[0] needs"),
            (#"{"zones": [{"since": "2030-01-05T00:00:00Z", "zone": "Europe/Paris"}], "until": "2030-01-04T00:00:00Z"}"#, "until"),
        ]
        for (text, why) in bad {
            guard case .failure(let problem) = zoneFile(text) else { XCTFail("accepted: \(text)"); continue }
            XCTAssertTrue(problem.description.contains(why), "\(text): \(problem)")
        }
    }

    /// Where the file reaches, it replaces the logs; after its `until` the logs are back; the app's own record wins
    /// from its first entry on, cutting the file short.
    func testTheFileOverridesTheLogsAndTheRecordOverridesTheFile() throws {
        let logs: [ZoneHistory.Entry] = [.init(since: at("2030-01-01", "08:00"), zone: "GMT"),
                                         .init(since: at("2030-01-10", "04:15"), zone: "GMT-0700"),
                                         .init(since: at("2030-01-12", "14:00"), zone: "GMT-0800")]
        let recorded: [ZoneHistory.Entry] = [.init(since: at("2030-01-20", "12:00"), zone: "America/Vancouver")]
        let file = try zoneFile("""
            {"zones": [{"since": "2029-12-20T00:00:00Z", "zone": "Atlantic/Reykjavik"},
                       {"since": "2030-01-10T04:15:00Z", "zone": "America/Vancouver"}],
             "until": "2030-01-15T00:00:00Z"}
            """).get()
        let periods = ZoneHistory.effective(recorded: recorded, logs: logs, file: file)
        XCTAssertEqual(periods, [
            .init(since: at("2029-12-20", "00:00"), zone: "Atlantic/Reykjavik", source: .file),
            .init(since: at("2030-01-10", "04:15"), zone: "America/Vancouver", source: .file),
            .init(since: at("2030-01-15", "00:00"), zone: "GMT-0800", source: .logs),
            .init(since: at("2030-01-20", "12:00"), zone: "America/Vancouver", source: .recorded),
        ])
        let history = ZoneHistory(periods)
        XCTAssertEqual(history.offset(at: at("2030-01-11", "12:00")), -8 * hour, "the file's UTC-8, not the logs' UTC-7")
        XCTAssertNil(history.zone(at: at("2029-12-19", "00:00")), "nothing before the file or the logs")

        // A file reaching past the app's own record: cut short there.
        let long = try zoneFile(#"{"zones": [{"since": "2030-01-05T00:00:00Z", "zone": "Asia/Tokyo"}, {"since": "2030-01-25T00:00:00Z", "zone": "Europe/Paris"}], "until": "2030-02-01T00:00:00Z"}"#).get()
        XCTAssertEqual(ZoneHistory.effective(recorded: recorded, logs: logs, file: long), [
            .init(since: at("2030-01-01", "08:00"), zone: "GMT", source: .logs),
            .init(since: at("2030-01-05", "00:00"), zone: "Asia/Tokyo", source: .file),
            .init(since: at("2030-01-20", "12:00"), zone: "America/Vancouver", source: .recorded),
        ])
        // One starting after it changes nothing; with no file, the logs, then the record.
        let late = try zoneFile(#"{"zones": [{"since": "2030-01-21T00:00:00Z", "zone": "Asia/Tokyo"}], "until": "2030-02-01T00:00:00Z"}"#).get()
        XCTAssertEqual(ZoneHistory.effective(recorded: recorded, logs: logs, file: late), ZoneHistory.effective(recorded: recorded, logs: logs, file: nil))
        XCTAssertEqual(ZoneHistory.effective(recorded: recorded, logs: logs, file: nil).map(\.source), [.logs, .logs, .logs, .recorded])
        // After a file that starts before the logs and ends before them: nothing known until the logs start.
        let early = try zoneFile(#"{"zones": [{"since": "2029-12-01T00:00:00Z", "zone": "Asia/Tokyo"}], "until": "2029-12-10T00:00:00Z"}"#).get()
        XCTAssertEqual(ZoneHistory.effective(recorded: recorded, logs: logs, file: early).prefix(3), [
            .init(since: at("2029-12-01", "00:00"), zone: "Asia/Tokyo", source: .file),
            .init(since: at("2029-12-10", "00:00"), zone: nil, source: .logs),
            .init(since: at("2030-01-01", "08:00"), zone: "GMT", source: .logs),
        ])
    }
}
