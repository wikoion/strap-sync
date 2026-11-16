import Foundation
import SQLite3
import XCTest
@testable import SyncCore

/// A dry run of the zone history and `zoneRedo1` on copies of a phone's files, on the Mac, through the code the app
/// runs (`ZoneLog`, `ZoneHistory`, `ZoneRedo`). It writes nothing and is skipped unless `STRAPSYNC_DRYRUN_DIR` is set:
///
///     cd Packages/SyncCore
///     STRAPSYNC_DRYRUN_DIR=/path/to/copy STRAPSYNC_DRYRUN_ZONE=<the phone's zone> \
///       STRAPSYNC_DRYRUN_WELLMAXX_DB=/path/to/wellmaxx.sqlite swift test --filter ZoneDryRunTests
///
/// - The folder holds copies of the app's daily logs (Documents/logs/*.log), with their modification times kept
///   (`cp -p`), either in it or in a `logs` folder inside it.
/// - Optionally a copy of the app's database, `sync.sqlite` (with `sync.sqlite-wal` if there is one), in it or in a
///   `WhoopSync` folder inside it.
/// - The redo works from what Health has, which the Mac can't read: `STRAPSYNC_DRYRUN_WELLMAXX_DB`, a copy of
///   Wellmaxx's database, stands in for it (its `samples` rows from `STRAPSYNC_DRYRUN_SOURCE`, by default
///   com.richarddraycott.WhoopSync). They have no sync identifier, so each is matched to the outbox row of the same
///   kind, start and end.
/// - Databases are copied to a temporary folder before they're opened, so the copies aren't touched.
/// - `STRAPSYNC_DRYRUN_ZONE` is the phone's zone now, a TimeZone identifier; without it, the Mac's.
/// - "Now" is the newest log's modification time; the app's own record of zones is taken to start just after it.
///
/// It prints (a) each log file's process segments and the reconstructed history, as instants and offsets, and
/// (b) for the last 16 days, by night and kind: the samples the redo would rewrite, those it leaves as they are,
/// outbox rows it leaves alone because Health doesn't have them, and samples in Health with no outbox row.
final class ZoneDryRunTests: XCTestCase {
    func testDryRun() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["STRAPSYNC_DRYRUN_DIR"] else { throw XCTSkip("set STRAPSYNC_DRYRUN_DIR to a folder of copied logs") }
        let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let logs = ZoneLog.files(in: dir).isEmpty ? dir.appendingPathComponent("logs") : dir
        let files = ZoneLog.files(in: logs)
        guard let newest = files.map(\.modified).max() else { return XCTFail("no *.log files in \(dir.path) or its logs folder") }
        let current = try env["STRAPSYNC_DRYRUN_ZONE"].map { id in
            try XCTUnwrap(TimeZone(identifier: id), "STRAPSYNC_DRYRUN_ZONE: not a time zone: \(id)")
        } ?? TimeZone.current
        let now = Int(newest), live = now + 1

        // What the app does: its own record starts at launch; before it, the owner's time-zones.json where it
        // reaches (AppModel.readZoneFile), and the logs elsewhere (AppModel.reconstructZones).
        let recorded = [ZoneHistory.Entry(since: live, zone: current.identifier)]
        let fromLogs = ZoneHistory(recorded).before(ZoneLog.reconstruct(files, current: current, until: live))
        let fileURL = dir.appendingPathComponent(ZoneFile.name)
        var zoneFile: ZoneFile?, fileNote = "none in the folder"
        if FileManager.default.fileExists(atPath: fileURL.path) {
            switch ZoneFile.parse(try Data(contentsOf: fileURL)) {
            case .success(let f):
                zoneFile = f
                fileNote = "\(f.entries.count) zones from \(utc(f.start)) until \(utc(f.until))"
            case .failure(let problem):
                fileNote = "IGNORED, as the app would: \(problem)"
            }
        }
        let periods = ZoneHistory.effective(recorded: recorded, logs: fromLogs, file: zoneFile)
        let history = ZoneHistory(periods)

        print("\n==== Strap Sync time-zone dry run (writes nothing) ====")
        print("Logs: \(files.count) files in \(logs.path)")
        print("Phone's zone now: \(current.identifier), \(ZoneHistory.offsetText(current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(now)))))")
        print("Now (newest log's time): \(utc(now))")
        print("\(ZoneFile.name): \(fileNote)")

        print("\n(a) Log files: process segments (local times) and the offsets assigned")
        for f in ZoneLog.analyse(files) {
            print("  \(f.day): \(f.lines.count) lines, file time \(utc(Int(f.modified))), last line's offset "
                  + (f.endOffset.map(ZoneHistory.offsetText) ?? "none (the file's time doesn't fit its last line)"))
            for (s, offset) in f.segments {
                let first = f.lines[s.range.lowerBound].local, last = f.lines[s.range.upperBound - 1].local
                let kind = s.launch ? "process start" : (s.range.lowerBound == 0 ? "carried on  " : "clock jump  ")
                let instant = offset.map { " = \(utc(first - $0))" } ?? ""
                print("    \(kind) \(localClock(first))–\(localClock(last)) (\(s.range.count) lines) "
                      + (offset.map(ZoneHistory.offsetText) ?? "unknown") + instant)
            }
        }
        func show(_ periods: [ZoneHistory.Period]) {
            for p in periods {
                let at = Date(timeIntervalSince1970: TimeInterval(p.since))
                let what = p.source == .recorded ? "the app's own record from here"
                    : p.source == .file ? "from \(ZoneFile.name)"
                    : (p.zone == nil ? "logs: unknown" : (p.zone == current.identifier ? "logs: the phone's zone" : "logs: fixed offset"))
                let offset = p.zone.flatMap(TimeZone.init(identifier:)).map { ZoneHistory.offsetText($0.secondsFromGMT(for: at)) } ?? "no zone"
                print("  from \(utc(p.since))  \(offset)  (\(what))")
            }
        }
        if zoneFile != nil {
            print("\n(a) Reconstructed from the logs alone:")
            show(ZoneHistory.effective(recorded: recorded, logs: fromLogs, file: nil))
        }
        print("\n(a) History in effect, as the redo uses it (each holds until the next):")
        show(periods)

        let from = now - ZoneRedo.days * 86_400
        // As the app reads them: from a day before the window, so a night at its start sees what's around it.
        let outboxCopy = try outbox(in: dir, from: from - 86_400)
        let wellmaxx = try env["STRAPSYNC_DRYRUN_WELLMAXX_DB"].map { path in
            try standIn(URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                        source: env["STRAPSYNC_DRYRUN_SOURCE"] ?? "com.richarddraycott.WhoopSync", from: from - 86_400)
        }
        if let outboxCopy, let wellmaxx {
            let plan = report(rows: outboxCopy.rows, written: outboxCopy.written, health: wellmaxx, history: history, now: now, from: from)
            try diagnose(plan.restored, db: outboxCopy.db, now: now)
        } else {
            if outboxCopy != nil { print("\n(b) No STRAPSYNC_DRYRUN_WELLMAXX_DB: without a stand-in for what Health has, there's no redo to show.") }
            if wellmaxx != nil { print("\n(b) No sync.sqlite: without the outbox, there's no redo to show.") }
            print("\n(b) The offset a sample starting at each time of day gets (every kind is stamped with the zone at its")
            print("    start: sleep, resting heart rate, breathing, blood oxygen, steps, heart rate, HRV)")
            func offset(_ t: Int) -> String { history.offset(at: t).map(ZoneHistory.offsetText) ?? "no zone" }
            for day in stride(from: from - from % 86_400, through: now, by: 86_400) {
                let changes = history.entries.filter { $0.since > day && $0.since < day + 86_400 }
                let pieces = ["00:00:00Z \(offset(day))"] + changes.map { "\(utc($0.since).suffix(9)) \(offset($0.since))" }
                print("  \(utc(day).prefix(10)): " + pieces.joined(separator: ", "))
            }
        }
        print("==== end of dry run ====\n")
    }

    // MARK: With the databases

    /// What the redo would do with these outbox rows, given what Health has (`health`, the stand-in).
    @discardableResult
    func report(rows: [Outbox.Row], written: Set<String>, health standIn: [ZoneRedo.HealthSample], history: ZoneHistory, now: Int,
                from: Int) -> ZoneRedo.Plan {
        // The stand-in has no sync identifiers: take the outbox row's of the same kind, start and end, if just one.
        var byShape: [String: [Outbox.Row]] = [:]
        for r in rows { byShape["\(r.sample.kind.rawValue):\(r.sample.start):\(r.sample.end)", default: []].append(r) }
        var unmatched: [ZoneRedo.HealthSample] = []
        let health = standIn.map { h -> ZoneRedo.HealthSample in
            let rows = byShape["\(h.kind.rawValue):\(h.start):\(h.end)"] ?? []
            if rows.count == 1 { return .init(kind: h.kind, syncId: rows[0].sample.syncId, start: h.start, end: h.end, value: h.value, version: nil, zone: h.zone) }
            unmatched.append(h)
            return .init(kind: h.kind, syncId: "unmatched:\(h.kind.rawValue):\(h.start):\(h.end)", start: h.start, end: h.end, value: h.value,
                         version: nil, zone: h.zone)
        }
        let plan = ZoneRedo.plan(health: health, outbox: Dictionary(rows.map { ($0.sample.syncId, $0) }) { a, _ in a },
                                 written: written, history: history, now: now)
        let unmatchedIds = Set(health.compactMap(\.syncId).filter { $0.hasPrefix("unmatched:") })
        let noRowMatched = plan.noRow.filter { !unmatchedIds.contains($0.syncId ?? "") }
        print("\n(b) zoneRedo1, with Wellmaxx's copy standing in for Health (\(standIn.filter { $0.start >= from }.count) samples in the last \(ZoneRedo.days) days):")
        print("    rewrite \(plan.rewrites.count); right already \(plan.right.count); outbox rows not in Health, left alone "
              + "\(plan.notInHealth.count); in Health with no outbox row \(unmatched.count + noRowMatched.count) "
              + "(\(plan.noRow.count) of them wrongly stamped, left as they are)")

        struct Counts { var rewrite = 0, right = 0, outboxOnly = 0, noRow = 0, wrongFrom: Set<String> = [], to: Set<String> = [] }
        func offset(_ zone: String?, at t: Int) -> String {
            zone.flatMap(TimeZone.init(identifier:)).map { ZoneHistory.offsetText($0.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t)))) } ?? "none"
        }
        func counts(_ range: Range<Int>) -> [PlannedSample.Kind: Counts] {
            var out: [PlannedSample.Kind: Counts] = [:]
            for r in plan.rewrites {
                guard let h = r.health, range.contains(h.start) else { continue }
                out[h.kind, default: Counts()].rewrite += 1
                out[h.kind]!.wrongFrom.insert(offset(h.zone, at: h.start))
                out[h.kind]!.to.insert(offset(r.row.sample.zone, at: h.start))
            }
            for h in plan.right where range.contains(h.start) { out[h.kind, default: Counts()].right += 1 }
            for o in plan.notInHealth where range.contains(o.sample.start) { out[o.sample.kind, default: Counts()].outboxOnly += 1 }
            for h in unmatched + noRowMatched where range.contains(h.start) { out[h.kind, default: Counts()].noRow += 1 }
            return out
        }
        func line(_ c: [PlannedSample.Kind: Counts]) -> String {
            PlannedSample.Kind.allCases.compactMap { k in
                guard let n = c[k] else { return nil }
                var parts: [String] = []
                if n.rewrite > 0 { parts.append("rewrite \(n.rewrite) (\(n.wrongFrom.sorted().joined(separator: "/")) → \(n.to.sorted().joined(separator: "/")))") }
                if n.right > 0 { parts.append("right \(n.right)") }
                if n.outboxOnly > 0 { parts.append("not in Health \(n.outboxOnly)") }
                if n.noRow > 0 { parts.append("no outbox row \(n.noRow)") }
                return "\(name(k)): " + parts.joined(separator: ", ")
            }.joined(separator: "; ")
        }

        print("\n(b) Nights (Health's sleep samples less than two hours apart; kinds within two hours of them):")
        for n in ZoneRedo.nights(health.filter { $0.kind == .sleep && $0.start >= from }.map { ($0.start, $0.end) }) {
            let zone = history.zone(at: n.start).flatMap(TimeZone.init(identifier:))
            let local = zone.map { " (\(clock(n.start, $0))–\(clock(n.end, $0)) local at \(ZoneHistory.offsetText($0.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(n.start))))))" } ?? " (no zone)"
            print("  \(utc(n.start))–\(utc(n.end))\(local)")
            print("    " + line(counts((n.start - 7200)..<(n.end + 7200))))
        }
        print("\n(b) Each day (UTC), each kind:")
        for day in stride(from: from - from % 86_400, through: now, by: 86_400) {
            let c = counts(day..<(day + 86_400))
            if !c.isEmpty { print("  \(utc(day).prefix(10)): " + line(c)) }
        }

        print("\n(b) Lost nights it would write again (Health has none of the app's sleep, resting HR or breathing within two")
        print("    hours; the outbox has the night's rows, written, all of one version, the highest there): \(plan.restored.count)")
        for n in plan.restored {
            let zone = history.zone(at: n.start).flatMap(TimeZone.init(identifier:))
            let version = n.rewrites.first { $0.row.sample.kind == .sleep }?.row.sample.version ?? 0
            print("  \(utc(n.start))–\(utc(n.end))" + (zone.map { " (\(clock(n.start, $0))–\(clock(n.end, $0)) local)" } ?? " (no zone)")
                  + ": \(n.count(.sleep)) sleep (version \(version)), \(n.count(.restingHR)) resting HR, \(n.count(.respiratoryRate)) breathing; zone "
                  + (zone.map { ZoneHistory.offsetText($0.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(n.start)))) } ?? "none"))
        }
        return plan
    }

    /// Why the stager didn't stage each lost night again: what `AppModel.processNights` checks, on the database copy.
    func diagnose(_ nights: [ZoneRedo.Restore], db: URL, now: Int) throws {
        guard !nights.isEmpty else { return }
        try withCopy(of: db) { handle in
            let kv = Dictionary(query(handle, "SELECT key, value FROM kv").compactMap { r in r[0].map { ($0, r[1] ?? "") } }) { a, _ in a }
            print("\n(b) Why the stager left them: nightsRedo6 \(kv["nightsRedo6"] ?? "not run"), restageFrom \(kv["restageFrom"] ?? "none")")
            // The minutes the restage looked at: stored, and before the first stored one rebuilt from motion
            // (AppModel.rebuildMinutes), over the 14 days before now.
            let from = now - 14 * 86_400
            var minutes = query(handle, "SELECT minute, records, worn, hr, motion, sleep_flag, skin FROM minutes WHERE minute >= \(from) ORDER BY minute").compactMap { r -> MinuteSummary? in
                guard let m = r[0].flatMap(Int.init) else { return nil }
                return MinuteSummary(minute: m, records: r[1].flatMap(Int.init) ?? 0, worn: r[2].flatMap(Int.init) ?? 0, meanHR: r[3].flatMap(Double.init),
                                     motion: r[4].flatMap(Double.init), sleepFlag: r[5].flatMap(Int.init) ?? 0, skinTempC: r[6].flatMap(Double.init))
            }
            let firstStored = minutes.first?.minute ?? now
            let motion = query(handle, "SELECT ts, bpm, steps, step_sw, state, motion, skin, spo2 FROM motion WHERE ts >= \(from) AND ts < \(firstStored) ORDER BY ts").compactMap { r -> MotionPoint? in
                guard let ts = r[0].flatMap(Int.init) else { return nil }
                return MotionPoint(ts: ts, bpm: r[1].flatMap(Int.init) ?? 0, stepCounter: r[2].flatMap(Int.init) ?? 0, stepSoftware: r[3] == "1",
                                   bandState: r[4].flatMap(Int.init) ?? 0, motion: r[5].flatMap(Double.init), skinTempC: r[6].flatMap(Double.init),
                                   spo2Raw: r[7].flatMap(Int.init) ?? 0)
            }
            let rebuilt = MinuteSummary.summarise(motion)
            minutes = rebuilt + minutes
            print("    minutes from \(utc(from)): \(minutes.count - rebuilt.count) stored, \(rebuilt.count) rebuilt from motion")
            let found = minutes.last.map { Sleep.nights(minutes, dataUntil: $0.minute + 60, now: now) } ?? []
            for n in nights {
                print("  \(utc(n.start))–\(utc(n.end)):")
                let stages = query(handle, "SELECT start, end, model FROM stages WHERE start < \(n.end + 43_200) AND end > \(n.start - 43_200)")
                print("    stages saved within 12 h of it: " + (stages.isEmpty ? "none" : stages.map { "\(utc(Int($0[0] ?? "") ?? 0))–\(utc(Int($0[1] ?? "") ?? 0)) model \($0[2] ?? "")" }.joined(separator: ", ")))
                let rr = query(handle, "SELECT COUNT(*) FROM rr WHERE source = \(Source.history.rawValue) AND ts >= \(n.start - 600) AND ts < \(n.end + 600)").first?[0] ?? "0"
                print("    history RR intervals in it: \(rr) (staging needs 1000)")
                let overlapping = found.filter { $0.start < n.end && $0.end > n.start }
                print("    nights found in those minutes overlapping it: " + (overlapping.isEmpty ? "none" : overlapping.map { "\(utc($0.start))–\(utc($0.end))" }.joined(separator: ", ")))
                if overlapping.isEmpty {
                    let inside = minutes.filter { $0.minute >= n.start && $0.minute < n.end }
                    let outside = minutes.filter { ($0.minute < n.start || $0.minute >= n.end) && $0.worn > 0 }.compactMap(\.meanHR)
                    func median(_ xs: [Double]) -> String { xs.isEmpty ? "none" : String(format: "%.1f", xs.sorted()[xs.count / 2]) }
                    print("    its minutes: \(inside.count), band asleep \(inside.filter(Sleep.bandAsleep).count); median heart rate inside "
                          + "\(median(inside.compactMap(\.meanHR))) vs \(median(outside)) outside (a night must be lower)")
                }
            }
        }
    }

    /// Wellmaxx's copies of the app's samples starting from `from`, as Health's stand-in: no sync identifiers or
    /// versions, and the zone as its offset.
    func standIn(_ db: URL, source: String, from: Int) throws -> [ZoneRedo.HealthSample] {
        try withCopy(of: db) { handle in
            let columns = query(handle, "PRAGMA table_info(samples)").compactMap { $0[1] }
            for c in ["source_bundle", "start_utc", "end_utc", "type", "tz_offset_s"] where !columns.contains(c) {
                XCTFail("Wellmaxx's samples table has no \(c) column")
                return []
            }
            let kinds: [String: PlannedSample.Kind] = ["sleep_stage": .sleep, "resting_hr": .restingHR, "respiratory_rate": .respiratoryRate,
                                                       "heart_rate": .heartRate, "hrv": .hrv, "steps": .steps, "spo2": .spo2]
            let source = source.replacingOccurrences(of: "'", with: "''")
            let rows = query(handle, "SELECT type, start_utc, end_utc, tz_offset_s FROM samples WHERE source_bundle = '\(source)' AND start_utc >= \(from * 1000)")
            print("\nWellmaxx: \(db.path) (copied): \(rows.count) samples from \(source)")
            return rows.compactMap { r in
                guard let kind = r[0].flatMap({ kinds[$0] }), let start = r[1].flatMap(Double.init), let end = r[2].flatMap(Double.init) else { return nil }
                let zone = r[3].flatMap(Double.init).flatMap { TimeZone(secondsFromGMT: Int($0))?.identifier }
                return .init(kind: kind, syncId: nil, start: Int((start / 1000).rounded()), end: Int((end / 1000).rounded()), value: 0,
                             version: nil, zone: zone)
            }
        }
    }

    /// Runs `body` on a temporary copy of a database (and its -wal), so the copy given isn't touched.
    func withCopy<T>(of db: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("strapsync-dryrun-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let copy = temp.appendingPathComponent(db.lastPathComponent)
        for suffix in ["", "-wal"] where fm.fileExists(atPath: db.path + suffix) {
            try fm.copyItem(at: URL(fileURLWithPath: db.path + suffix), to: URL(fileURLWithPath: copy.path + suffix))
        }
        var handle: OpaquePointer?
        guard sqlite3_open(copy.path, &handle) == SQLITE_OK else {
            sqlite3_close(handle)
            throw NSError(domain: "dryrun", code: 1, userInfo: [NSLocalizedDescriptionKey: "couldn't open a copy of \(db.path)"])
        }
        defer { sqlite3_close(handle) }
        return try body(handle)
    }

    /// The outbox rows starting from `from` and the sync identifiers of those Health was given, from a temporary
    /// copy of the database, or nil without one.
    func outbox(in dir: URL, from: Int) throws -> (rows: [Outbox.Row], written: Set<String>, db: URL)? {
        guard let db = [dir, dir.appendingPathComponent("WhoopSync")].map({ $0.appendingPathComponent("sync.sqlite") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return try withCopy(of: db) { handle in
            let columns = query(handle, "PRAGMA table_info(outbox)").compactMap { $0[1] }
            let zone = columns.contains("zone") ? "zone" : "NULL"
            let basis = columns.contains("basis") ? "basis" : "NULL"
            print("\nDatabase: \(db.path) (copied; outbox \(columns.contains("zone") ? "has" : "has no") zone column)")
            let table = query(handle, "SELECT kind, sync_id, start, end, value, version, \(basis), \(zone), written FROM outbox WHERE start >= \(from)")
            let rows = table.compactMap { r -> Outbox.Row? in
                guard let kind = r[0].flatMap(Int.init).flatMap(PlannedSample.Kind.init(rawValue:)), let id = r[1],
                      let start = r[2].flatMap(Int.init), let end = r[3].flatMap(Int.init), let version = r[5].flatMap(Int.init) else { return nil }
                let sample = PlannedSample(kind: kind, syncId: id, start: start, end: end, value: r[4].flatMap(Double.init) ?? 0,
                                           version: r[6].flatMap(Int.init) ?? version, zone: r[7])
                return Outbox.Row(sample: sample, syncVersion: version)
            }
            return (rows, Set(table.filter { $0[8] == "1" }.compactMap { $0[1] }), db)
        }
    }

    func query(_ db: OpaquePointer?, _ sql: String) -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(stmt)).map { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } })
        }
        return out
    }

    // MARK: Formatting

    func name(_ kind: PlannedSample.Kind) -> String {
        switch kind {
        case .heartRate: return "heart rate"
        case .hrv: return "HRV"
        case .steps: return "steps"
        case .restingHR: return "resting HR"
        case .respiratoryRate: return "breathing"
        case .sleep: return "sleep"
        case .spo2: return "SpO2"
        }
    }

    func utc(_ t: Int) -> String { clock(t, TimeZone(identifier: "UTC")!, format: "yyyy-MM-dd HH:mm:ss'Z'") }

    func clock(_ t: Int, _ zone: TimeZone, format: String = "HH:mm") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    /// A line's local time ("as if UTC" seconds) as the log shows it.
    func localClock(_ local: Int) -> String { clock(local, TimeZone(identifier: "UTC")!, format: "MM-dd HH:mm:ss") }
}
