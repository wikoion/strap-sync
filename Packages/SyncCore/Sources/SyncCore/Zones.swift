import Foundation

/// The phone's time zone over time, so each sample is stamped with the zone it was recorded in
/// (HKMetadataKeyTimeZone), not the one the phone has when the sample is written. A sample written again later
/// (a restaged night, a version bump, a metadata backfill) would otherwise take the zone of the day it's rewritten:
/// after a change of zone, a reader would put a night's wake time in the evening and file the night as a nap.
///
/// Each entry holds from its `since` until the next. A nil zone means it isn't known there: samples starting then
/// go to Health with no zone, rather than a guess. Before the first entry nothing is known either.
///
/// The app adds an entry whenever it sees the phone in another zone (`observing`): at launch, at each history
/// download and when iOS says the zone changed. What came before the first of those is reconstructed once from the
/// app's own logs (`ZoneLog`).
public struct ZoneHistory: Equatable {
    public struct Entry: Equatable {
        public let since: Int
        /// A TimeZone identifier: the phone's own zone, or a fixed offset such as "GMT-0800". Nil: not known.
        public let zone: String?

        public init(since: Int, zone: String?) {
            self.since = since; self.zone = zone
        }
    }

    public private(set) var entries: [Entry]

    public init(_ entries: [Entry] = []) {
        self.entries = entries.sorted { $0.since < $1.since }
    }

    /// The zone in effect at `t`. A sample's zone is the one at its start.
    public func zone(at t: Int) -> String? {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].since <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : entries[lo - 1].zone
    }

    /// Seconds east of UTC at `t`, in the zone in effect then.
    public func offset(at t: Int) -> Int? {
        zone(at: t).flatMap(TimeZone.init(identifier:)).map { $0.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t))) }
    }

    /// The entry to add when the phone is seen in `zone` at `t`, or nil when that's the latest entry's zone already:
    /// the history only gains an entry when the zone changes. Never before the latest entry, so a clock set back
    /// can't reorder them.
    public func observing(_ zone: String, at t: Int) -> Entry? {
        guard let last = entries.last else { return Entry(since: t, zone: zone) }
        guard last.zone != zone else { return nil }
        return Entry(since: max(t, last.since + 1), zone: zone)
    }

    public mutating func add(_ entry: Entry) {
        entries.removeAll { $0.since == entry.since }
        entries.insert(entry, at: entries.firstIndex { $0.since > entry.since } ?? entries.count)
    }

    /// Of `past` (reconstructed from the logs), the entries to add before this history's first one: those that start
    /// earlier, leaving out any that repeats the zone of the one before it.
    public func before(_ past: [Entry]) -> [Entry] {
        let first = entries.first?.since ?? .max
        var out: [Entry] = []
        for e in past.sorted(by: { $0.since < $1.since }) where e.since < first {
            if let last = out.last, last.zone == e.zone { continue }
            out.append(e)
        }
        return out
    }

    /// "UTC+05:30", "UTC-08:00".
    public static func offsetText(_ seconds: Int) -> String {
        let m = abs(seconds) / 60
        return String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", m / 60, m % 60)
    }

    /// Entries as instants and offsets, for the log: no zone names.
    public static func describe(_ entries: [Entry]) -> String {
        entries.map { e in
            let at = Date(timeIntervalSince1970: TimeInterval(e.since))
            let offset = e.zone.flatMap(TimeZone.init(identifier:)).map { offsetText($0.secondsFromGMT(for: at)) } ?? "unknown"
            return "from \(utc(e.since)) \(offset)"
        }.joined(separator: "; ")
    }

    /// An instant as "yyyy-MM-dd HH:mm:ssZ".
    public static func utc(_ t: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }
}

// MARK: - The owner's own record, and the history in effect

/// The zones the owner says the phone was in, for a past the logs got wrong (the phone's own zone can be wrong for
/// days): `Documents/time-zones.json`, which the Files app can reach. For the instants it covers it replaces the
/// reconstruction from the logs; the app's own record wins from its first entry on. docs/DEVELOPMENT.md has the
/// format:
///
///     {"zones": [{"since": "2030-01-01T00:00:00Z", "zone": "Europe/Paris"},
///                {"since": "2030-01-09T18:30:00Z", "zone": "America/Chicago"}],
///      "until": "2030-01-20T00:00:00Z"}
///
/// It covers `zones[0].since` up to `until`. Read strictly: anything off and the whole file is ignored.
public struct ZoneFile: Equatable {
    public static let name = "time-zones.json"

    /// Oldest first, each holding until the next, the last until `until`. IANA zone names.
    public let entries: [ZoneHistory.Entry]
    public let until: Int

    public var start: Int { entries[0].since }

    /// Why a file was ignored.
    public struct Problem: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    public static func parse(_ data: Data) -> Result<ZoneFile, Problem> {
        func fail(_ why: String) -> Result<ZoneFile, Problem> { .failure(Problem(description: why)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return fail("not valid JSON") }
        guard let top = json as? [String: Any] else { return fail("not a JSON object") }
        guard Set(top.keys) == ["zones", "until"] else { return fail("needs exactly the keys \"zones\" and \"until\", has \(top.keys.sorted())") }
        guard let list = top["zones"] as? [Any], !list.isEmpty else { return fail("\"zones\" must be a non-empty array") }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime]
        func instant(_ value: Any?, _ what: String) -> Int? {
            (value as? String).flatMap(dates.date(from:)).map { Int($0.timeIntervalSince1970) }
        }
        // An IANA place name the system knows (or UTC): not an abbreviation ("CET") or an offset ("GMT-0800"), nor an
        // Etc/GMT name, whose sign is the reverse of what it looks like. Not just the system's list of known names,
        // which can lack a newer name for a place (iOS lists Asia/Calcutta, not Asia/Kolkata).
        func known(_ zone: String) -> Bool {
            if zone == "UTC" || zone == "GMT" { return true }
            return zone.contains("/") && !zone.hasPrefix("Etc/") && TimeZone(identifier: zone) != nil
        }
        var entries: [ZoneHistory.Entry] = []
        for (i, item) in list.enumerated() {
            guard let e = item as? [String: Any], Set(e.keys) == ["since", "zone"] else {
                return fail("zones[\(i)] needs exactly the keys \"since\" and \"zone\"")
            }
            guard let since = instant(e["since"], "since") else { return fail("zones[\(i)].since isn't a date like 2030-01-01T00:00:00Z") }
            guard let zone = e["zone"] as? String, known(zone) else {
                return fail("zones[\(i)].zone isn't a time zone name like Europe/Paris: \(e["zone"].map { "\($0)" } ?? "missing")")
            }
            if let last = entries.last, since <= last.since { return fail("zones[\(i)] doesn't start after zones[\(i - 1)]") }
            entries.append(ZoneHistory.Entry(since: since, zone: zone))
        }
        guard let until = instant(top["until"], "until") else { return fail("\"until\" isn't a date like 2030-01-01T00:00:00Z") }
        guard until > entries[entries.count - 1].since else { return fail("\"until\" isn't after the last zone's since") }
        return .success(ZoneFile(entries: entries, until: until))
    }
}

extension ZoneHistory {
    /// Where a stretch of the history comes from.
    public enum Source: String {
        /// The app's own record: the phone's zone as it saw it.
        case recorded
        /// Reconstructed from the app's logs (`ZoneLog`).
        case logs
        /// The owner's `time-zones.json` (`ZoneFile`).
        case file
    }

    public struct Period: Equatable {
        public let since: Int
        public let zone: String?
        public let source: Source

        public init(since: Int, zone: String?, source: Source) {
            self.since = since; self.zone = zone; self.source = source
        }
    }

    /// The history in effect: the app's own record from its first entry on; before it, the owner's file where it
    /// reaches (it covers its first `since` up to `until`, or to the record's start if that's earlier), and the
    /// reconstruction from the logs elsewhere.
    public static func effective(recorded: [Entry], logs: [Entry], file: ZoneFile?) -> [Period] {
        let recorded = recorded.sorted { $0.since < $1.since }
        let own = recorded.first?.since ?? .max
        let logs = ZoneHistory(logs)
        var out: [Period] = []
        func add(_ since: Int, _ zone: String?, _ source: Source) {
            if let last = out.last, last.zone == zone, last.source == source { return }
            out.append(Period(since: since, zone: zone, source: source))
        }
        /// The logs' stretch [from, to): the zone they have at `from` (none before their first entry), then their changes.
        func addLogs(from: Int?, to: Int) {
            if let from, from < to { add(from, logs.zone(at: from), .logs) }
            for e in logs.entries where e.since < to && (from.map { e.since > $0 } ?? true) { add(e.since, e.zone, .logs) }
        }
        if let file, file.start < own {
            let end = min(file.until, own)
            addLogs(from: nil, to: file.start)
            for e in file.entries where e.since < end { add(e.since, e.zone, .file) }
            if end < own { addLogs(from: end, to: own) }
        } else {
            addLogs(from: nil, to: own)
        }
        for e in recorded { add(e.since, e.zone, .recorded) }
        return out
    }

    public init(_ periods: [Period]) {
        self.init(periods.map { Entry(since: $0.since, zone: $0.zone) })
    }

    /// Periods as instants, offsets and sources, for the log: no zone names.
    public static func describe(_ periods: [Period]) -> String {
        periods.map { p in
            let offset = p.zone.flatMap(TimeZone.init(identifier:)).map {
                offsetText($0.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(p.since))))
            } ?? "unknown"
            return "from \(utc(p.since)) \(offset) (\(p.source.rawValue))"
        }.joined(separator: "; ")
    }
}

/// Reconstructs the phone's UTC offset over time from the app's daily logs (Documents/logs/yyyy-MM-dd.log), for the
/// time before the app kept a zone history. Pure apart from `files(in:)`, which reads them.
///
/// What the logs say:
/// - Each line starts "HH:MM:SS", the local time of a DateFormatter made when the process started. It keeps that
///   process's zone for its whole life: a change of zone shows only in a new process. So a file's lines fall into
///   process segments, each in one zone; a new one starts at "App launched…" or "iOS relaunched the app…" (and
///   takes in the lines logged in the few seconds before it, at the same time, while the app set itself up).
/// - The file's name is the local date of its lines, and its modification time is the instant its last line was
///   written. So the last line's local time minus that instant, to the nearest 15 minutes, is the offset of the
///   process that wrote it.
///
/// How the offsets are assigned, a file at a time in date order:
/// - A file's last segment has its modification time's offset. The other segments keep the offset in effect
///   before them (carried from the previous file) unless their lines say otherwise: lines are appended in order,
///   so converted to instants they must never go back. Where they would, the change came earlier, at a process
///   start.
/// - So a change of zone is placed at the start of the first process segment that has the new offset, converted
///   with that offset; what came before keeps the old one.
/// - Inside a process the offset changes only with summer time, where the local time jumps back (or forward) an
///   hour; that's allowed too, only when nothing else fits.
/// - Where the lines can't be fitted at all, that stretch is left unknown.
///
/// Between lines, the offset holds for up to `maxSilence`; across a longer silence (a day with no log, say) it's
/// unknown, as before the first line.
public enum ZoneLog {
    public struct File {
        /// The file's name without ".log": the local date of its lines, yyyy-MM-dd.
        public let day: String
        public let text: String
        /// Its modification time, unix seconds: when its last line was written.
        public let modified: Double

        public init(day: String, text: String, modified: Double) {
            self.day = day; self.text = text; self.modified = modified
        }
    }

    /// From `since`, the phone's offset (seconds east of UTC), or nil where it isn't known.
    public struct Change: Equatable {
        public let since: Int
        public let offset: Int?

        public init(since: Int, offset: Int?) {
            self.since = since; self.offset = offset
        }
    }

    /// How a line logged by a new process starts.
    public static let launchMarkers = ["App launched", "iOS relaunched the app"]
    /// The longest gap between lines that an offset is carried across.
    public static let maxSilence = 24 * 3600
    /// Lines logged up to this long before a launch line, at its time or just before, belong to its process.
    static let launchLead = 10
    /// Clock corrections: lines may go back this much, and converted lines may seem to go back this much.
    static let slack = 60
    /// A jump forward in local time this big can be summer time starting.
    static let forwardJump = 45 * 60

    /// The app's daily logs in a folder, with their modification times.
    public static func files(in directory: URL) -> [File] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            // The time first: a line appended meanwhile only adds a line a moment later than it.
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  let data = try? Data(contentsOf: url) else { return nil }
            return File(day: url.deletingPathExtension().lastPathComponent, text: String(decoding: data, as: UTF8.self),
                        modified: modified.timeIntervalSince1970)
        }
    }

    /// The history as zone entries: the phone's own `current` zone where it has the offset found, a fixed-offset zone
    /// elsewhere ("GMT-0800"), nil where nothing is known. Nothing from `until` on (where the app's own record
    /// starts).
    public static func reconstruct(_ files: [File], current: TimeZone, until: Int) -> [ZoneHistory.Entry] {
        entries(changes(files, until: until), current: current, until: until)
    }

    /// The offsets the logs show, oldest first, up to `until`.
    public static func changes(_ files: [File], until: Int? = nil) -> [Change] {
        timeline(analyse(files).flatMap(\.spans), until: until)
    }

    /// What one file says: its process segments with their offsets (nil: not known), and the stretches they cover.
    struct FileResult {
        let day: String
        let lines: [Line]
        let modified: Double
        let endOffset: Int?
        let segments: [(segment: Segment, offset: Int?)]
        let spans: [Span]
    }

    /// Each file's segments and offsets, in date order (see the type's comment).
    static func analyse(_ files: [File]) -> [FileResult] {
        let parsed = files.compactMap(Parsed.init).sorted { $0.dayStart < $1.dayStart }
        var out: [FileResult] = []
        var carried: Int?
        var previousEnd: Int?
        for p in parsed {
            let neighbours = parsed.filter { abs($0.dayStart - p.dayStart) <= 3 * 86_400 }.compactMap(\.endOffset)
            let segments = segments(p.lines)
            var offsets: [Int?] = Array(repeating: nil, count: segments.count)
            var spans: [Span] = []
            if let assigned = assign(segments, p.lines, end: p.endOffset, carried: carried, neighbours: neighbours) {
                offsets = assigned
                for (s, o) in zip(segments, assigned) { spans += self.spans(p.lines[s.range], offset: o) }
                carried = assigned.last
            } else if let end = p.endOffset, let last = segments.last {
                // Only the last segment is known, by the file's time; what came before it in the file is unknown.
                offsets[offsets.count - 1] = end
                let known = self.spans(p.lines[last.range], offset: end)
                if let previousEnd, let first = known.first?.from, first - 1 > previousEnd {
                    spans.append(Span(from: previousEnd + 1, to: first - 1, offset: nil))
                }
                spans += known
                carried = end
            }
            previousEnd = Int(p.modified)
            out.append(FileResult(day: p.day, lines: p.lines, modified: p.modified, endOffset: p.endOffset,
                                  segments: Array(zip(segments, offsets)), spans: spans))
        }
        return out
    }

    /// Changes as zone entries (see `reconstruct`); consecutive ones with the same zone are merged.
    public static func entries(_ changes: [Change], current: TimeZone, until: Int?) -> [ZoneHistory.Entry] {
        var out: [ZoneHistory.Entry] = []
        for (i, c) in changes.enumerated() {
            let end = i + 1 < changes.count ? changes[i + 1].since : max(c.since + 1, until ?? c.since + 1)
            let zone = c.offset.flatMap { identifier($0, from: c.since, to: end, current: current) }
            if let last = out.last, last.zone == zone { continue }
            out.append(ZoneHistory.Entry(since: c.since, zone: zone))
        }
        return out
    }

    /// The phone's own zone when it has this offset throughout, else a fixed-offset zone.
    static func identifier(_ offset: Int, from: Int, to: Int, current: TimeZone) -> String? {
        func at(_ t: Int) -> Int { current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t))) }
        if at(from) == offset, at(max(from, to - 1)) == offset { return current.identifier }
        return TimeZone(secondsFromGMT: offset)?.identifier
    }

    // MARK: Parsing

    struct Line {
        /// The line's local time as if it were UTC: the file's date plus HH:MM:SS.
        let local: Int
        let launch: Bool
    }

    struct Parsed {
        let day: String
        let dayStart: Int
        let lines: [Line]
        let modified: Double
        /// The offset of the process that wrote the last line, or nil when the file's time doesn't fit it.
        let endOffset: Int?

        init?(_ file: File) {
            guard let start = ZoneLog.dayStart(file.day) else { return nil }
            let lines = ZoneLog.lines(file.text, dayStart: start)
            guard let last = lines.last else { return nil }
            day = file.day
            dayStart = start
            self.lines = lines
            modified = file.modified
            let raw = Double(last.local) - file.modified
            let offset = Int((raw / 900).rounded()) * 900
            endOffset = abs(raw - Double(offset)) <= 300 && abs(offset) <= 14 * 3600 ? offset : nil
        }
    }

    /// Seconds from 1970-01-01 to the start of a yyyy-MM-dd date, as if it were UTC.
    static func dayStart(_ day: String) -> Int? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let m = parts[1], d = parts[2], y = parts[0] - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return (era * 146_097 + doe - 719_468) * 86_400
    }

    /// The lines that start "HH:MM:SS ", in file order. Others (a message's later lines) are skipped.
    static func lines(_ text: String, dayStart: Int) -> [Line] {
        let colon = UInt8(ascii: ":"), zero = UInt8(ascii: "0"), space = UInt8(ascii: " ")
        let longest = launchMarkers.map(\.utf8.count).max() ?? 0
        var out: [Line] = []
        for raw in text.utf8.split(separator: UInt8(ascii: "\n")) {
            let b = Array(raw.prefix(9 + longest))
            guard b.count >= 8, b[2] == colon, b[5] == colon, b.count == 8 || b[8] == space else { continue }
            let digits = [0, 1, 3, 4, 6, 7].map { Int(b[$0]) - Int(zero) }
            guard digits.allSatisfy((0...9).contains) else { continue }
            let h = digits[0] * 10 + digits[1], m = digits[2] * 10 + digits[3], s = digits[4] * 10 + digits[5]
            guard h < 24, m < 60, s < 60 else { continue }
            let message = b.count > 9 ? String(decoding: b[9...], as: UTF8.self) : ""
            out.append(Line(local: dayStart + h * 3600 + m * 60 + s, launch: launchMarkers.contains { message.hasPrefix($0) }))
        }
        return out
    }

    // MARK: Process segments and their offsets

    struct Segment {
        let range: Range<Int>
        /// Starts with a new process. Otherwise it's a process already running: the file's first lines, or the
        /// local time jumping within one (summer time).
        let launch: Bool
    }

    /// A file's lines split where a process starts, and where the local time goes back or jumps forward
    /// (`forwardJump`): only there can the offset change.
    static func segments(_ lines: [Line]) -> [Segment] {
        var starts: [(index: Int, launch: Bool)] = [(0, lines.first?.launch ?? false)]
        for i in lines.indices.dropFirst() {
            let jump = lines[i].local - lines[i - 1].local
            if jump < -slack || jump > forwardJump { starts.append((i, false)) }
            guard lines[i].launch else { continue }
            // The process's first lines can come just before its launch line, at the same time.
            var j = i
            while j > starts[starts.count - 1].index, lines[j - 1].local <= lines[i].local, lines[i].local - lines[j - 1].local <= launchLead {
                j -= 1
            }
            if j == starts[starts.count - 1].index { starts[starts.count - 1].launch = true } else { starts.append((j, true)) }
        }
        return starts.indices.map { k in
            Segment(range: starts[k].index..<(k + 1 < starts.count ? starts[k + 1].index : lines.count), launch: starts[k].launch)
        }
    }

    /// Each segment's offset: the last one's is `end`; before it, the fewest changes, at process starts if they can
    /// be, and each as late as the lines allow (the fewest segments off `carried`). Offsets come from `carried`,
    /// `end` and the files of nearby days. Nil when nothing fits.
    static func assign(_ segments: [Segment], _ lines: [Line], end: Int?, carried: Int?, neighbours: [Int]) -> [Int]? {
        var candidates: [Int] = []
        for o in [carried, end].compactMap({ $0 }) + neighbours.sorted() where !candidates.contains(o) { candidates.append(o) }
        guard !segments.isEmpty, !candidates.isEmpty else { return nil }
        let n = segments.count, k = candidates.count
        // A change at a process start costs 1; inside a process (summer time), 100. Then, as a tie-break, each
        // segment off `carried` costs 1, so changes come as late as they can.
        func change(_ i: Int, from a: Int?, to b: Int) -> Int {
            guard let a, a != b else { return 0 }
            return segments[i].launch ? 10_000 : 1_000_000
        }
        func off(_ o: Int) -> Int { carried.map { $0 == o ? 0 : 1 } ?? 0 }
        func allowed(_ i: Int, _ c: Int) -> Bool { i < n - 1 || end == nil || candidates[c] == end }
        var cost = [[Int]](repeating: [Int](repeating: .max, count: k), count: n)
        var back = [[Int]](repeating: [Int](repeating: -1, count: k), count: n)
        for c in 0..<k where allowed(0, c) { cost[0][c] = change(0, from: carried, to: candidates[c]) + off(candidates[c]) }
        for i in 1..<n {
            let first = lines[segments[i].range.lowerBound].local, last = lines[segments[i - 1].range.upperBound - 1].local
            for c in 0..<k where allowed(i, c) {
                for p in 0..<k where cost[i - 1][p] != .max {
                    let a = candidates[p], b = candidates[c]
                    // Lines are appended in order, so as instants they never go back.
                    guard first - b >= last - a - slack else { continue }
                    let total = cost[i - 1][p] + change(i, from: a, to: b) + off(b)
                    if total < cost[i][c] { cost[i][c] = total; back[i][c] = p }
                }
            }
        }
        guard var c = (0..<k).filter({ cost[n - 1][$0] != .max }).min(by: { cost[n - 1][$0] < cost[n - 1][$1] }) else { return nil }
        var out = [Int](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            out[i] = candidates[c]
            c = back[i][c]
        }
        return out
    }

    // MARK: The timeline

    /// Instants `from`...`to` (inclusive) in one offset, or not known (nil).
    struct Span {
        let from: Int
        let to: Int
        let offset: Int?
    }

    /// A segment's lines as instants, split where they fall silent for longer than `maxSilence`.
    static func spans(_ lines: ArraySlice<Line>, offset: Int) -> [Span] {
        var out: [Span] = []
        var from: Int?, to = 0
        for line in lines {
            let t = line.local - offset
            if let f = from, t - to > maxSilence {
                out.append(Span(from: f, to: to, offset: offset))
                from = nil
            }
            if from == nil { from = t }
            to = max(to, t)
        }
        if let from { out.append(Span(from: from, to: to, offset: offset)) }
        return out
    }

    /// The offset at each instant from the first span on: one offset where spans agree; unknown where they disagree
    /// or one is unknown; between spans, the offset before carried up to `maxSilence`, unknown across longer gaps.
    static func timeline(_ all: [Span], until: Int?) -> [Change] {
        let spans = all.compactMap { s -> Span? in
            guard let until else { return s }
            return s.from < until ? Span(from: s.from, to: min(s.to, until - 1), offset: s.offset) : nil
        }
        guard !spans.isEmpty else { return [] }
        let points = Set(spans.flatMap { [$0.from, $0.to + 1] }).sorted()
        var out: [Change] = []
        var previous: Int?? = nil  // the last piece's offset, resolved (nil inside: unknown)
        for (a, b) in zip(points, points.dropFirst()) {
            let covering = spans.filter { $0.from <= a && $0.to + 1 >= b }
            var offset: Int?
            if covering.isEmpty {
                // A silence: the offset before it holds while it's short.
                offset = b - a <= maxSilence ? (previous ?? nil) : nil
            } else {
                let offsets = Set(covering.map(\.offset))
                offset = offsets.count == 1 ? offsets.first! : nil
            }
            if out.isEmpty || out[out.count - 1].offset != offset { out.append(Change(since: a, offset: offset)) }
            previous = .some(offset)
        }
        // Up to `until`, likewise.
        if let until, let end = points.last, until - end > maxSilence, out.last?.offset != nil {
            out.append(Change(since: end, offset: nil))
        }
        return out
    }
}

/// The one-time rewrite (`zoneRedo1`) of the samples Health has with a wrong zone: until it kept a zone history,
/// the app stamped each sample with the phone's zone when it was written, so data written again after a change of
/// zone carried the new one.
///
/// What Health has is the truth, not the outbox: the outbox can hold rows Health no longer has, still marked
/// written (a night's clear deleted them when a later version of the night started elsewhere). Rewriting those
/// would put deleted, overlapping sleep stages back. So the plan starts from the app's own samples in Health, and
/// only replaces those, in place.
public enum ZoneRedo {
    /// How far back: the outbox keeps written rows 30 days, beats 14; nights restaged by `nightsRedo6` reach 14.
    public static let days = 16

    /// One of the app's own samples as Health has it.
    public struct HealthSample: Equatable {
        public let kind: PlannedSample.Kind
        /// HKMetadataKeySyncIdentifier; nil when it has none.
        public let syncId: String?
        public let start: Int
        public let end: Int
        public let value: Double
        /// HKMetadataKeySyncVersion.
        public let version: Int?
        /// HKMetadataKeyTimeZone; nil when it has none.
        public let zone: String?

        public init(kind: PlannedSample.Kind, syncId: String?, start: Int, end: Int, value: Double, version: Int?, zone: String?) {
            self.kind = kind; self.syncId = syncId; self.start = start; self.end = end; self.value = value
            self.version = version; self.zone = zone
        }
    }

    /// An outbox row to store again: its zone set, its sync version above both the outbox's and Health's, unwritten.
    public struct Rewrite: Equatable {
        public let row: Outbox.Row
        /// The sync version the row had when it was read; it's only rewritten if it still has it.
        public let storedVersion: Int
        /// The sample Health has; nil for a lost night's row, which it hasn't.
        public let health: HealthSample?

        public init(row: Outbox.Row, storedVersion: Int, health: HealthSample?) {
            self.row = row; self.storedVersion = storedVersion; self.health = health
        }
    }

    public struct Plan {
        public var rewrites: [Rewrite] = []
        /// Stamped with the history's zone already (or one with the same offset): left as they are.
        public var right: [HealthSample] = []
        /// Wrongly stamped, but with no outbox row of the same sync identifier, kind, start and end: left as they
        /// are, since nothing in the outbox says what to write.
        public var noRow: [HealthSample] = []
        /// Without a sync identifier: nothing can replace them in place.
        public var noSyncId: [HealthSample] = []
        /// Outbox rows in the window that Health doesn't have, and that aren't a lost night's: never touched.
        public var notInHealth: [Outbox.Row] = []
        /// Nights Health lost whose rows the outbox still has, written: written again (`lostNights`).
        public var restored: [Restore] = []

        /// Every row to store again: the rewrites, then the lost nights'.
        public var all: [Rewrite] { rewrites + restored.flatMap(\.rewrites) }
    }

    /// A night Health lost (a night's clear deleted it in the race fixed on 14 Nov 2026), written again from the outbox.
    public struct Restore: Equatable {
        /// From its first sleep row's start to its last one's end.
        public let start: Int
        public let end: Int
        /// Its sleep, resting-heart-rate and breathing rows, each in the history's zone, one sync version up.
        public let rewrites: [Rewrite]

        public func count(_ kind: PlannedSample.Kind) -> Int { rewrites.filter { $0.row.sample.kind == kind }.count }
    }

    /// The plan for Health's samples starting in the last `days` days. A sample is rewritten only when its zone
    /// isn't the history's at its start (a missing one included) and the outbox has its row: same sync identifier,
    /// kind, start and end. The row keeps its data, data version and metadata, gets the history's zone, and goes
    /// out one sync version above both what the outbox and Health have, so Health replaces the sample in place.
    ///
    /// `written` are the sync identifiers of the outbox rows Health has been given (`lostNights` uses them). `health`
    /// should reach back a day before the window, so a night at its start sees what Health has around it.
    public static func plan(health: [HealthSample], outbox: [String: Outbox.Row], written: Set<String> = [], history: ZoneHistory,
                            now: Int) -> Plan {
        let from = now - days * 86_400
        var plan = Plan()
        // One sample per sync identifier in Health; if there were two, the newer.
        var byId: [String: HealthSample] = [:]
        for h in health where h.start >= from {
            guard let id = h.syncId else { plan.noSyncId.append(h); continue }
            if let other = byId[id], (other.version ?? 0) >= (h.version ?? 0) { continue }
            byId[id] = h
        }
        for h in byId.values.sorted(by: { ($0.start, $0.syncId ?? "") < ($1.start, $1.syncId ?? "") }) {
            let expected = history.zone(at: h.start)
            if sameZone(h.zone, expected, from: h.start, to: h.end) { plan.right.append(h); continue }
            guard let id = h.syncId, let row = outbox[id], row.sample.kind == h.kind, row.sample.start == h.start, row.sample.end == h.end else {
                plan.noRow.append(h)
                continue
            }
            plan.rewrites.append(Rewrite(row: Outbox.Row(sample: row.sample.with(zone: expected),
                                                         syncVersion: max(row.syncVersion, h.version ?? 0) + 1),
                                         storedVersion: row.syncVersion, health: h))
        }
        plan.restored = lostNights(health: health, outbox: outbox, written: written, history: history, from: from)
        let restoring = Set(plan.restored.flatMap { $0.rewrites.map(\.row.sample.syncId) })
        plan.notInHealth = outbox.values.filter { $0.sample.start >= from && byId[$0.sample.syncId] == nil && !restoring.contains($0.sample.syncId) }
            .sorted { ($0.sample.start, $0.sample.syncId) < ($1.sample.start, $1.sample.syncId) }
        return plan
    }

    /// Spans less than two hours apart, merged: a night's samples.
    public static func nights(_ spans: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
        var out: [(start: Int, end: Int)] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start - last.end < 7200 { out[out.count - 1].end = max(last.end, s.end) } else { out.append(s) }
        }
        return out
    }

    /// Nights Health lost that the outbox still has, to write again. A night qualifies only when all of these hold:
    /// - its sleep rows (the outbox's, less than two hours apart) start in the window, Health has been given all
    ///   of them, and they all have one data version, the highest of any outbox sleep row overlapping the night;
    /// - Health has none of the app's sleep, resting-heart-rate or breathing samples within two hours of it.
    ///
    /// Then its sleep rows, and the resting-heart-rate and breathing rows within it that Health was given, are
    /// written again in the history's zone, one sync version up. Anything else stays as it is: rows of an earlier
    /// version of a night (a later version replaced them, and its clear deleted them) have another version than the
    /// night beside them, or Health still has samples next to them.
    static func lostNights(health: [HealthSample], outbox: [String: Outbox.Row], written: Set<String>, history: ZoneHistory,
                           from: Int) -> [Restore] {
        let sleep = outbox.values.filter { $0.sample.kind == .sleep }
        let inHealth = health.filter { NightClear.kinds.contains($0.kind) }
        var out: [Restore] = []
        for night in nights(sleep.map { ($0.sample.start, $0.sample.end) }) where night.start >= from {
            let rows = sleep.filter { $0.sample.start >= night.start && $0.sample.start < night.end }
            let overlapping = sleep.filter { $0.sample.start < night.end && $0.sample.end > night.start }
            guard let version = rows.first?.sample.version, rows.allSatisfy({ $0.sample.version == version }),
                  overlapping.allSatisfy({ $0.sample.version <= version }),
                  rows.allSatisfy({ written.contains($0.sample.syncId) }),
                  !inHealth.contains(where: { $0.start < night.end + 7200 && $0.end > night.start - 7200 }) else { continue }
            let others = outbox.values.filter {
                [.restingHR, .respiratoryRate].contains($0.sample.kind) && $0.sample.start >= night.start && $0.sample.end <= night.end
                    && written.contains($0.sample.syncId)
            }
            let rewrites = (rows + others).sorted { ($0.sample.start, $0.sample.syncId) < ($1.sample.start, $1.sample.syncId) }.map { r in
                Rewrite(row: Outbox.Row(sample: r.sample.with(zone: history.zone(at: r.sample.start)), syncVersion: r.syncVersion + 1),
                        storedVersion: r.syncVersion, health: nil)
            }
            out.append(Restore(start: night.start, end: night.end, rewrites: rewrites))
        }
        return out
    }

    /// The same zone for a sample: the same identifier, or both with the same offset at its start and end (a
    /// sample written live in the phone's named zone, where the history has that offset as a fixed zone).
    public static func sameZone(_ a: String?, _ b: String?, from: Int, to: Int) -> Bool {
        if a == b { return true }
        guard let a = a.flatMap(TimeZone.init(identifier:)), let b = b.flatMap(TimeZone.init(identifier:)) else { return false }
        return [from, max(from, to - 1)].allSatisfy { t in
            let d = Date(timeIntervalSince1970: TimeInterval(t))
            return a.secondsFromGMT(for: d) == b.secondsFromGMT(for: d)
        }
    }
}
