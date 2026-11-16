import Foundation
import SQLite3
import XCTest
@testable import SyncCore

/// A dry run of night writing on a copy of a phone's database, on the Mac, through the code the app runs each pass
/// (`MinuteSummary.summarise`, `Sleep.nights`, `Sleep.soFar`, `Sleep.due`). It writes nothing and is skipped unless
/// `STRAPSYNC_DRYRUN_DB` is set:
///
///     cd Packages/SyncCore
///     STRAPSYNC_DRYRUN_DB=/path/to/copy/sync.sqlite STRAPSYNC_DRYRUN_LOG=/path/to/copy/2026-11-16.log \
///       swift test --filter NightDryRunTests
///
/// - The database (with its `-wal`, if there is one) is copied to a temporary folder before it's opened. Minutes are
///   made again from its motion records (kept 14 days), so a pass at any second sees what the app had then, the
///   newest minute part-filled.
/// - Every stored night is played through with a download every 5 minutes, at several offsets into the minute, and
///   the phone locked throughout (no night so far is ever written: the app before `Sleep.due`), unlocked throughout,
///   and locked and unlocked at random. However it went, the last version written of every night that's over must
///   be the one written with the phone locked throughout, and every version longer than the one before.
/// - With `STRAPSYNC_DRYRUN_LOG`, one of the app's daily logs (its name the day, its times in the Mac's zone or
///   `STRAPSYNC_DRYRUN_ZONE`), that day is played as it went: a pass after each download in the log, with the data up
///   to when it was requested; the phone locked while the log has Health refusing ("Protected health data is
///   inaccessible"), and a pass when that stops. The log can't show the phone locked while nothing waits for
///   Health, so it's taken as unlocked then. The nights written are printed as the app logs them, with the phone
///   locked whatever the log says (which should give the log's own lines) and as the log has it.
final class NightDryRunTests: XCTestCase {
    /// One pass of `AppModel.processNights`, as far as choosing what to write goes.
    struct Replay {
        let points: [MotionPoint]
        let whole: [MinuteSummary]
        var doneUntil = 0
        var lastStart: Int?
        var writes: [(dataUntil: Int, night: Sleep.Night, soFar: Bool)] = []

        /// What the app's `minutes` table held with records up to `d`: the last 48 hours, as the pass reads them.
        func minutes(until d: Int) -> [MinuteSummary] {
            let newest = d - d % 60
            let lo = first(in: whole.count) { whole[$0].minute >= d - 48 * 3600 }, hi = first(in: whole.count) { whole[$0].minute >= newest }
            let a = first(in: points.count) { points[$0].ts >= newest }, b = first(in: points.count) { points[$0].ts > d }
            return Array(whole[lo..<hi]) + MinuteSummary.summarise(Array(points[a..<b]))
        }

        @discardableResult
        mutating func pass(dataUntil d: Int, unlocked: Bool) -> [(night: Sleep.Night, soFar: Bool)] {
            let minutes = minutes(until: d)
            guard let lastMinute = minutes.last?.minute else { return [] }
            let nights = Sleep.nights(minutes, dataUntil: lastMinute + 60, now: d)
            let soFar = unlocked ? Sleep.soFar(minutes) : nil
            var out: [(night: Sleep.Night, soFar: Bool)] = []
            for night in Sleep.due(finished: nights, soFar: soFar, doneUntil: doneUntil, lastStart: lastStart) {
                doneUntil = night.end
                lastStart = night.start
                out.append((night, !nights.contains(night)))
                writes.append((d, night, !nights.contains(night)))
            }
            return out
        }

        /// The first index in 0..<count for which `after` holds, when it holds from there on.
        func first(in count: Int, _ after: (Int) -> Bool) -> Int {
            var lo = 0, hi = count
            while lo < hi {
                let mid = (lo + hi) / 2
                if after(mid) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
    }

    func testEveryStoredNightEndsUpTheSameHoweverThePhoneWasLocked() throws {
        let (points, whole) = try data()
        let first = try XCTUnwrap(points.first?.ts), last = try XCTUnwrap(points.last?.ts)
        print("\n==== Strap Sync night dry run (writes nothing) ====")
        print("Motion records: \(points.count), \(clock(first, day: true)) to \(clock(last, day: true)); \(whole.count) minutes")

        // Locked and unlocked for about an hour at a time.
        func random(_ seed: UInt64) -> [Bool] {
            var s = seed, on = false
            return (0..<(last - first) / 300 + 2).map { _ in
                s = s &* 6364136223846793005 &+ 1442695040888963407
                if (s >> 33) % 12 == 0 { on.toggle() }
                return on
            }
        }
        let variants: [(name: String, unlocked: (Int) -> Bool)] = [
            ("locked throughout", { _ in false }), ("unlocked throughout", { _ in true }),
            ("at random, 1", { [r = random(1)] in r[$0] }), ("at random, 2", { [r = random(2)] in r[$0] }),
            ("at random, 3", { [r = random(3)] in r[$0] }),
        ]
        let underWay = Sleep.open(Replay(points: points, whole: whole).minutes(until: last), dataUntil: last - last % 60 + 60)?.night
        if let underWay { print("A night was under way when the copy was made, since \(clock(underWay.start, day: true)): left out") }
        for offset in [7, 29, 52] {
            var reference: [Int: Sleep.Night] = [:]
            for v in variants {
                var replay = Replay(points: points, whole: whole)
                for (k, d) in stride(from: first - first % 300 + 300 + offset, through: last, by: 300).enumerated() {
                    replay.pass(dataUntil: d, unlocked: v.unlocked(k))
                }
                // And one with everything there is, locked: a night that's over by then is written as over.
                replay.pass(dataUntil: last, unlocked: false)
                var final = Dictionary(replay.writes.map { ($0.night.start, $0.night) }) { _, newer in newer }
                // A night still under way when the copy was made has no last version yet.
                final[underWay?.start ?? 0] = nil
                var end: [Int: Int] = [:]
                for w in replay.writes {
                    if let before = end[w.night.start] {
                        XCTAssertGreaterThan(w.night.end, before, "\(v.name), :\(offset): a version no longer than the one before, \(text(w.night))")
                    }
                    end[w.night.start] = w.night.end
                }
                let soFar = replay.writes.filter(\.soFar)
                if v.name == variants[0].name {
                    reference = final
                    XCTAssertTrue(soFar.isEmpty)
                    print("\nDownloads at :\(String(format: "%02d", offset)) past every 5 minutes. With the phone locked throughout:")
                    for start in final.keys.sorted() {
                        let versions = replay.writes.filter { $0.night.start == start }
                        print("  \(clock(start, day: true)) \(text(final[start]!))" + (versions.count == 1 ? ""
                            : "; written first as " + versions.dropLast().map { "\(clock($0.night.start))–\(clock($0.night.end)) at \(clock($0.dataUntil))" }.joined(separator: ", ")))
                    }
                } else {
                    XCTAssertEqual(final, reference, "\(v.name), :\(offset)")
                    let differ = Set(final.keys).symmetricDifference(reference.keys).count + final.filter { reference[$0.key] != nil && reference[$0.key] != $0.value }.count
                    print("  \(v.name): \(final.count) nights, \(differ) ending up different; \(soFar.count) versions written so far "
                          + "(\(Set(soFar.map(\.night.start)).count) nights)")
                }
            }
        }
    }

    func testADayAsTheLogHasIt() throws {
        let (points, whole) = try data()
        guard let path = ProcessInfo.processInfo.environment["STRAPSYNC_DRYRUN_LOG"] else { throw XCTSkip("set STRAPSYNC_DRYRUN_LOG to one of the app's daily logs") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = zone
        parse.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let day = String(url.deletingPathExtension().lastPathComponent.prefix(10))

        var downloads: [(at: Int, until: Int)] = [], refusals: [Int] = [], saves: [Int] = [], logged: [String] = []
        var requested: Int?, firstLine: Int?
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard line.count > 9, let date = parse.date(from: "\(day) \(line.prefix(8))") else { continue }
            let t = Int(date.timeIntervalSince1970), message = line.dropFirst(9)
            firstLine = firstLine ?? t
            if message.hasPrefix("History: download requested") { requested = t }
            if message.hasPrefix("History data "), let r = requested { downloads.append((t, r - 1)); requested = nil }
            if message.contains("Protected health data is inaccessible") { refusals.append(t) }
            if message.hasPrefix("Apple Health: saved") || message.hasPrefix("Apple Health: removed") { saves.append(t) }
            if message.hasPrefix("Sleep: ") || message.hasPrefix("Sleep so far: ") {
                logged.append("\(line.prefix(8)) \(message.split(separator: ";")[0])")
            }
        }
        let start = try XCTUnwrap(firstLine, "no lines with a time in \(url.path)")
        // The phone was unlocked between a refusal with none in the minute after it and the next write to Health.
        let unlocks = refusals.filter { r in !refusals.contains { $0 > r && $0 <= r + 65 } }.compactMap { r in saves.first { $0 > r } }
        var events = downloads.map { d in (at: d.at, until: d.until, unlocked: !refusals.contains { $0 >= d.at && $0 <= d.at + 5 }) }
        for u in unlocks {
            if let d = downloads.last(where: { $0.at <= u }) { events.append((u, d.until, true)) }
        }
        events.sort { $0.at < $1.at }

        print("\n==== Strap Sync night dry run of \(day) (writes nothing) ====")
        print("\(downloads.count) downloads; Health refused \(refusals.count) times; unlocked after a refusal at \(unlocks.map { clock($0, seconds: true) }.joined(separator: ", "))")
        print("\nThe log's own lines:")
        for l in logged { print("  \(l)") }
        for (name, follow) in [("With the phone locked whatever the log says (the app before the night so far was written)", false),
                               ("As the log has the phone, locked and unlocked", true)] {
            var replay = Replay(points: points, whole: whole)
            replay.pass(dataUntil: start - 1, unlocked: false)  // what was written before the day began
            print("\n\(name):")
            for e in events {
                for w in replay.pass(dataUntil: e.until, unlocked: follow && e.unlocked) {
                    print("  \(clock(e.at, seconds: true)) \(w.soFar ? "Sleep so far" : "Sleep"): \(text(w.night))"
                          + " (data to \(clock(e.until, seconds: true))\(e.unlocked ? ", unlocked" : ", locked"))")
                }
            }
        }
    }

    // MARK: The copy

    func data() throws -> (points: [MotionPoint], whole: [MinuteSummary]) {
        guard let path = ProcessInfo.processInfo.environment["STRAPSYNC_DRYRUN_DB"] else { throw XCTSkip("set STRAPSYNC_DRYRUN_DB to a copy of sync.sqlite") }
        let fm = FileManager.default, db = (path as NSString).expandingTildeInPath
        let temp = fm.temporaryDirectory.appendingPathComponent("strapsync-dryrun-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let copy = temp.appendingPathComponent("sync.sqlite").path
        for suffix in ["", "-wal"] where fm.fileExists(atPath: db + suffix) { try fm.copyItem(atPath: db + suffix, toPath: copy + suffix) }
        var handle: OpaquePointer?, stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt); sqlite3_close(handle) }
        guard sqlite3_open(copy, &handle) == SQLITE_OK,
              sqlite3_prepare_v2(handle, "SELECT ts, bpm, steps, step_sw, state, motion, skin FROM motion ORDER BY ts", -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "dryrun", code: 1, userInfo: [NSLocalizedDescriptionKey: "couldn't read motion from a copy of \(db)"])
        }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func double(_ i: Int32) -> Double? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i) }
        var points: [MotionPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            points.append(MotionPoint(ts: int(0), bpm: int(1), stepCounter: int(2), stepSoftware: int(3) != 0, bandState: int(4),
                                      motion: double(5), skinTempC: double(6)))
        }
        return (points, MinuteSummary.summarise(points))
    }

    // MARK: Formatting

    var zone: TimeZone {
        ProcessInfo.processInfo.environment["STRAPSYNC_DRYRUN_ZONE"].flatMap(TimeZone.init(identifier:)) ?? .current
    }

    func clock(_ t: Int, day: Bool = false, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = day ? "d MMM HH:mm" : seconds ? "HH:mm:ss" : "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    /// A night as the app logs it.
    func text(_ n: Sleep.Night) -> String {
        "\(clock(n.start))–\(clock(n.end)), \(n.asleepSeconds / 3600)h \(n.asleepSeconds % 3600 / 60)m asleep, woke \(n.awakenings)×"
    }
}
