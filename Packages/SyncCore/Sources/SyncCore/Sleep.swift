import Foundation

/// One minute of the strap's R18 records, summarised.
public struct MinuteSummary: Equatable {
    public let minute: Int
    public let records: Int
    /// Records with a heart rate (strap on the wrist).
    public let worn: Int
    public let meanHR: Double?
    /// Mean gravity-removed acceleration, g.
    public let motion: Double?
    /// Records whose band state was "sleep".
    public let sleepFlag: Int
    public let skinTempC: Double?

    public init(minute: Int, records: Int, worn: Int, meanHR: Double?, motion: Double?, sleepFlag: Int, skinTempC: Double?) {
        self.minute = minute; self.records = records; self.worn = worn; self.meanHR = meanHR
        self.motion = motion; self.sleepFlag = sleepFlag; self.skinTempC = skinTempC
    }

    public static func summarise(_ points: [MotionPoint]) -> [MinuteSummary] {
        let byMinute = Dictionary(grouping: points) { $0.ts - $0.ts % 60 }
        return byMinute.keys.sorted().map { minute in
            let ps = byMinute[minute]!
            let worn = ps.filter { $0.bpm > 0 }
            let motions = ps.compactMap(\.motion)
            let skins = worn.compactMap(\.skinTempC)
            return MinuteSummary(minute: minute, records: ps.count, worn: worn.count,
                                 meanHR: worn.isEmpty ? nil : Double(worn.reduce(0) { $0 + $1.bpm }) / Double(worn.count),
                                 motion: motions.isEmpty ? nil : motions.reduce(0, +) / Double(motions.count),
                                 sleepFlag: ps.filter { $0.bandState == 2 }.count,
                                 skinTempC: skins.isEmpty ? nil : skins.reduce(0, +) / Double(skins.count))
        }
    }
}

/// Main-sleep detection from movement and heart rate, plus the per-night samples that hang off it:
/// sleep intervals, resting heart rate and breathing rate.
///
/// A minute is "rest" when the strap is worn and either still (mean gravity-removed acceleration at or
/// below `stillMotion`) or flagged asleep by the band itself. Rest minutes separated by no more than
/// `maxWake` minutes (with the band's flag; `maxQuietWake` lying in bed) or `maxBridge` (stillness alone) of
/// anything else form a block; a block of at least `minSession` minutes whose median heart rate is below the
/// rest of the period's is a night. Thresholds are first guesses, to be checked against real nights.
public enum Sleep {
    public static let stillMotion = 0.02
    /// Without the band's flag, still minutes this far apart are one block: sitting still while awake is
    /// common, so stillness can't bridge more.
    public static let maxBridge = 10
    /// With the band's flag, a night runs across wake-ups of up to this many minutes, which become its
    /// awakenings. Split at 10 minutes, each part was judged alone and the shorter one dropped under
    /// `minSession`: 1 h 44 before a 26-minute wake-up on one night, and 2 h 03 after an 18-minute one on
    /// another.
    public static let maxWake = 60
    /// Up to this many minutes also join when the gap looks like lying in bed: the strap worn for at least half
    /// of it, and its median heart rate within `quietHR` bpm of the sleeping heart rate either side. On one
    /// night the band's flag was off for 82 minutes, most of them in bed at the heart rate asleep, so the 93
    /// minutes flagged after it were a block of their own, under `minSession`, and 2 h 12 of sleep never
    /// reached Health. Back up and about (a waking heart rate), a later doze is still its own block.
    public static let maxQuietWake = 120
    public static let quietHR = 10.0
    /// The band flags sleep 14–17 minutes after your last movement (10 of 11 onsets over eight nights;
    /// once 5 minutes) and doesn't backdate it; it flags waking within a minute or two. So a night starts
    /// this much before its first flagged minute, awake, and the stage model judges when you fell asleep.
    public static let bandLag = 15
    public static let minAwake = 3
    public static let minSession = 180
    /// Minutes of data needed after a night's end before it's written, so it's really over. Without the
    /// band's flag, rest past `maxBridge` minutes starts a new block, so the end can't move; with it, back
    /// asleep within `maxWake` (or `maxQuietWake`), the night grows and is written again. (It was 30, which with downloads every
    /// 15 minutes wrote the night 30-45 minutes after waking.) The strap banks a record every second, worn
    /// or not, so a strap taken off at wake still provides it.
    public static let settle = maxBridge + 2
    /// Sooner than `settle`: `upMinutes` awake after the night, `upMoving` of them moving (mean motion at
    /// least `movingMotion`), mean you're up. Lying awake in bed waits for `settle`. If you're back asleep
    /// within `maxWake` minutes after all (up briefly in the night), the night grows and is written again.
    public static let upMinutes = 5
    public static let upMoving = 3
    public static let movingMotion = 0.05

    public struct Interval: Equatable {
        public let start: Int
        public let end: Int
        public let asleep: Bool
    }

    public struct Night: Equatable {
        public let start: Int
        public let end: Int
        public let intervals: [Interval]

        public var asleepSeconds: Int { intervals.filter(\.asleep).reduce(0) { $0 + $1.end - $1.start } }
        /// Awake intervals after first falling asleep: the lead-in before the band's first flag isn't one.
        public var awakenings: Int { intervals.drop { !$0.asleep }.filter { !$0.asleep }.count }
        /// The first asleep minute, by the band (or stillness).
        public var fellAsleep: Int { intervals.first(where: \.asleep)?.start ?? start }
    }

    static func bandAsleep(_ m: MinuteSummary) -> Bool {
        m.records > 0 && m.sleepFlag * 2 >= m.records
    }

    /// With the band's own sleep flag present, a minute is rest only when the band says asleep: on the
    /// first real night its flag ran 00:11-10:14 (10 h 3 min) against a Fitbit Air's 10 h 5 min, while
    /// stillness also counted the quarter-hour before falling asleep and lying in bed after waking.
    /// Without the flag (firmware that never sets it), rest is a still, worn minute.
    static func isRest(_ m: MinuteSummary, bandMode: Bool) -> Bool {
        guard m.records > 0, m.worn * 2 >= m.records else { return false }
        if bandMode { return bandAsleep(m) }
        guard let motion = m.motion else { return false }
        return motion <= stillMotion
    }

    /// Finished nights in `minutes` (sorted or not). `dataUntil` is the end of the downloaded data.
    ///
    /// Only data decides when a night is over, never the clock: history can arrive hours later, and a
    /// night judged mid-download ended wherever the download had got to (the first real night came
    /// out as 23:52–03:00 of a sleep that ran to 10:00). `now` is kept for callers.
    public static func nights(_ minutes: [MinuteSummary], dataUntil: Int, now: Int) -> [Night] {
        candidates(minutes, dataUntil: dataUntil).filter(\.over).map(\.night)
    }

    /// The night under way: long enough to count, but still asleep at the end of the data, or not yet surely
    /// up. `awake` is true once the data runs past its end.
    public static func open(_ minutes: [MinuteSummary], dataUntil: Int) -> (night: Night, awake: Bool)? {
        guard let last = candidates(minutes, dataUntil: dataUntil).last, !last.over else { return nil }
        return (last.night, dataUntil > last.night.end)
    }

    /// The night under way as far as it has got, from whole minutes only: the newest minute is still filling and
    /// could yet turn out awake, so a night written from this only ever grows. Nil with no night under way.
    public static func soFar(_ minutes: [MinuteSummary]) -> Night? {
        let sorted = minutes.sorted { $0.minute < $1.minute }
        guard let newest = sorted.last?.minute else { return nil }
        guard let last = candidates(Array(sorted.dropLast()), dataUntil: newest).last, !last.over else { return nil }
        return last.night
    }

    /// The nights one pass writes, oldest first. `doneUntil` and `lastStart` are the end and start of the last
    /// night written. A finished night is written once, and again if it has grown since.
    ///
    /// `soFar` is the night under way (`soFar(_:)`), given only while Health can be written. It's written when an
    /// earlier, shorter version of the same night was: awake for `settle` minutes in the small hours, a night is
    /// written as over, and it's only over again once you're up for the day. Until then what was written is known
    /// to be short, and on one night it's what reached Health when the phone was unlocked in the morning: 3 h 33
    /// of a night of 9 h 14, for the eight minutes until the whole one replaced it. A night not yet written still
    /// waits until it's over.
    public static func due(finished: [Night], soFar: Night?, doneUntil: Int, lastStart: Int?) -> [Night] {
        var out = finished.filter { $0.start >= doneUntil || ($0.start == lastStart && $0.end > doneUntil) }
        if let soFar, soFar.start == lastStart, soFar.end > doneUntil,
           !finished.contains(where: { $0.start < soFar.end && soFar.start < $0.end }) {
            out.append(soFar)
        }
        return out
    }

    /// True once the data after `end` shows you up: `upMinutes` of it, `upMoving` minutes moving. Every minute
    /// after a night's end is awake, or it'd have been part of the night.
    static func isUp(after end: Int, _ sorted: [MinuteSummary], dataUntil: Int) -> Bool {
        guard dataUntil - end >= upMinutes * 60 else { return false }
        let moving = sorted.filter { $0.minute >= end && $0.minute < dataUntil && ($0.motion ?? 0) >= movingMotion }
        return moving.count >= upMoving
    }

    /// Blocks long enough to be a night, each with whether it's over.
    static func candidates(_ minutes: [MinuteSummary], dataUntil: Int) -> [(night: Night, over: Bool)] {
        let sorted = minutes.sorted { $0.minute < $1.minute }
        let bandMode = sorted.contains(where: bandAsleep)
        let rest = sorted.filter { isRest($0, bandMode: bandMode) }.map(\.minute)
        guard !rest.isEmpty else { return [] }

        // Blocks of rest minutes with gaps of at most maxWake (band) or maxBridge (stillness) minutes.
        let bridge = bandMode ? maxWake : maxBridge
        let lead = bandMode ? bandLag * 60 : 0
        var blocks: [[Int]] = [[rest[0]]]
        for m in rest.dropFirst() {
            if m - blocks[blocks.count - 1].last! <= (bridge + 1) * 60 {
                blocks[blocks.count - 1].append(m)
            } else {
                blocks.append([m])
            }
        }
        if bandMode { blocks = joinQuiet(blocks, sorted) }

        return blocks.compactMap { block -> (night: Night, over: Bool)? in
            let start = block.first! - lead, end = block.last! + 60
            guard (end - block.first!) / 60 >= minSession else { return nil }
            // Rest from the first minute given began before it, so its start is unknown. A night sliding
            // out of a caller's look-back window would otherwise come back a minute shorter each pass.
            guard start > sorted[0].minute else { return nil }
            // Over once there's settled data after it, or sooner when that data shows you up and about.
            let over = end + settle * 60 <= dataUntil || isUp(after: end, sorted, dataUntil: dataUntil)
            // Sleeping heart rate sits below the waking heart rate around it.
            let inside = sorted.filter { $0.minute >= start && $0.minute < end }.compactMap(\.meanHR)
            let outside = sorted.filter { ($0.minute < start || $0.minute >= end) && $0.worn > 0 }.compactMap(\.meanHR)
            if outside.count >= 60, let a = median(inside), let b = median(outside), a >= b { return nil }

            var intervals: [Interval] = lead > 0 ? [Interval(start: start, end: block[0], asleep: false)] : []
            var runStart = block[0]
            var previous = block[0]
            for m in block.dropFirst() {
                let gap = (m - previous) / 60 - 1
                if gap >= minAwake {
                    intervals.append(Interval(start: runStart, end: previous + 60, asleep: true))
                    intervals.append(Interval(start: previous + 60, end: m, asleep: false))
                    runStart = m
                }
                previous = m
            }
            intervals.append(Interval(start: runStart, end: previous + 60, asleep: true))
            return (Night(start: start, end: end, intervals: intervals), over)
        }
    }

    /// Joins neighbouring blocks across a gap of up to `maxQuietWake` minutes spent lying in bed (see there).
    static func joinQuiet(_ blocks: [[Int]], _ sorted: [MinuteSummary]) -> [[Int]] {
        let hr = Dictionary(sorted.compactMap { m in m.meanHR.map { (m.minute, $0) } }) { a, _ in a }
        var out = [blocks[0]]
        for b in blocks.dropFirst() {
            let a = out[out.count - 1]
            let gap = (b[0] - a.last!) / 60 - 1
            let inGap = stride(from: a.last! + 60, to: b[0], by: 60).compactMap { hr[$0] }
            if gap <= maxQuietWake, inGap.count * 2 >= gap, let g = median(inGap),
               let asleep = median((a + b).compactMap { hr[$0] }), g <= asleep + quietHR {
                out[out.count - 1] += b
            } else {
                out.append(b)
            }
        }
        return out
    }

    /// The Health samples for one night: its intervals, resting heart rate, and hourly breathing rate.
    public static func samples(for night: Night, minutes: [MinuteSummary], rr: [RRPoint]) -> [PlannedSample] {
        // Versions grow with the data behind each sample, so a night recomputed with more of it
        // replaces what was written before under the same sync identifier.
        var out = night.intervals.map {
            PlannedSample(kind: .sleep, syncId: "whoopsync:sleep:\($0.start)", start: $0.start, end: $0.end,
                          value: $0.asleep ? 1 : 2, version: ($0.end - $0.start) / 60)  // asleepUnspecified, awake
        }
        let asleep = night.intervals.filter(\.asleep)
        func isAsleep(_ t: Int) -> Bool { asleep.contains { t >= $0.start && t < $0.end } }

        // Resting heart rate: the lowest 30-minute mean while asleep, needing 25 minutes with a reading.
        let hrByMinute = Dictionary(uniqueKeysWithValues: minutes.compactMap { m in
            m.meanHR.map { (m.minute, $0) }
        }.filter { isAsleep($0.0) })
        var lowest: (start: Int, mean: Double)?
        for start in hrByMinute.keys.sorted() {
            let window = (0..<30).compactMap { hrByMinute[start + $0 * 60] }
            guard window.count >= 25 else { continue }
            let mean = window.reduce(0, +) / Double(window.count)
            if lowest == nil || mean < lowest!.mean { lowest = (start, mean) }
        }
        if let lowest {
            // Keyed by the (UTC) day of waking, so a night recomputed with a different start still replaces it.
            out.append(PlannedSample(kind: .restingHR, syncId: "whoopsync:rhr:\(night.end / 86_400)", start: lowest.start,
                                     end: lowest.start + 1800, value: (lowest.mean * 10).rounded() / 10,
                                     version: night.asleepSeconds / 60))
        }

        // Breathing rate: 5-minute windows fully asleep with enough beats, median per clock hour.
        let byWindow = Dictionary(grouping: rr.filter { isAsleep($0.ts) }) { $0.ts - $0.ts % 300 }
        var ratesByHour: [Int: [Double]] = [:]
        for (start, points) in byWindow where isAsleep(start) && isAsleep(start + 299) {
            let beats = Aggregator.cleanIntervals(points.sorted { ($0.ts, $0.idx) < ($1.ts, $1.idx) }.map(\.ms))
            guard beats.reduce(0, +) >= 255_000, let r = Respiration.rate(beats) else { continue }
            ratesByHour[start - start % 3600, default: []].append(r.breathsPerMinute)
        }
        for hour in ratesByHour.keys.sorted() {
            guard let rate = median(ratesByHour[hour]!) else { continue }
            out.append(PlannedSample(kind: .respiratoryRate, syncId: "whoopsync:resp:\(hour)",
                                     start: max(hour, night.start), end: min(hour + 3600, night.end),
                                     value: (rate * 10).rounded() / 10, version: ratesByHour[hour]!.count))
        }
        return out
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
