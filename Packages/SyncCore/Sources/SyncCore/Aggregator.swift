import Foundation

/// Where a beat came from. History is the strap's own record, so it wins over a live reading of
/// the same minute.
public enum Source: Int {
    case live = 1
    case history = 2

    var tier: Int { self == .history ? 1 : 0 }
}

public struct PlannedSample: Equatable {
    public enum Kind: Int, CaseIterable {
        case heartRate = 1
        case hrv = 2
        case steps = 3
        case restingHR = 4
        case respiratoryRate = 5
        /// A sleep interval; `value` is the HKCategoryValueSleepAnalysis raw value.
        case sleep = 6
        /// Oxygen saturation, `value` in percent.
        case spo2 = 7
    }

    public let kind: Kind
    /// HKMetadataKeySyncIdentifier, e.g. one per minute (HR, steps), hour (HRV, breathing) or night.
    public let syncId: String
    public let start: Int
    public let end: Int
    /// bpm, ms (HRV), steps, breaths/min, or the sleep category value.
    public let value: Double
    /// HKMetadataKeySyncVersion. Health only replaces a sample when the version goes up, so this grows
    /// with the data behind it: history beats live, and more readings beat fewer. A sample whose metadata
    /// changes while its data doesn't goes out with a higher version than this ([Outbox.merge]).
    public let version: Int
    /// Strap Sync's own HealthKit metadata ([HealthMetadata]): skin temperature and ECGs on heart rate, RMSSD on HRV.
    public let metadata: [String: MetadataValue]
    /// HKMetadataKeyTimeZone: the zone the phone was in at `start` ([ZoneHistory]), a TimeZone identifier. The
    /// outbox fills it in when it stores the sample and keeps it through rewrites; nil when it isn't known, and the
    /// sample then goes to Health without a zone.
    public let zone: String?

    public init(kind: Kind, syncId: String, start: Int, end: Int, value: Double, version: Int,
                metadata: [String: MetadataValue] = [:], zone: String? = nil) {
        self.kind = kind; self.syncId = syncId; self.start = start; self.end = end
        self.value = value; self.version = version; self.metadata = metadata; self.zone = zone
    }

    /// The same sample with other metadata.
    public func with(metadata: [String: MetadataValue]) -> PlannedSample {
        PlannedSample(kind: kind, syncId: syncId, start: start, end: end, value: value, version: version, metadata: metadata,
                      zone: zone)
    }

    /// The same sample in another zone.
    public func with(zone: String?) -> PlannedSample {
        PlannedSample(kind: kind, syncId: syncId, start: start, end: end, value: value, version: version, metadata: metadata,
                      zone: zone)
    }
}

/// Turns stored beats into Health samples. Pure; the app feeds it one clock hour at a time.
public enum Aggregator {
    public static let minReadingsPerMinute = 10
    public static let windowSeconds = 300
    /// A 5-minute HRV window needs at least this much clean beat time.
    public static let minWindowBeatMs = 240_000
    /// A window is steady when its minutes' mean heart rates stay within this many bpm. A step or drift inside
    /// it (waking briefly, rolling over, a high heart rate settling) inflates SDNN without saying anything about
    /// recovery: a 10 bpm step inside one window gave an SDNN about twice its RMSSD.
    public static let steadyRangeBpm = 5.0
    /// A minute counts towards steadiness with this many clean beats; a window needs four such minutes.
    static let steadyMinuteBeats = 20
    static let steadyMinutes = 4
    /// Added to every HRV sample's version, so Health replaces what the earlier SDNN wrote. 1: steady windows and
    /// detrended SDNN (8 Nov 2026).
    public static let hrvAlgorithm = 1_000_000

    /// One heart-rate sample per finished minute with enough readings.
    public static func heartRateMinutes(live: [HRPoint], history: [HRPoint], now: Int) -> [PlannedSample] {
        let liveByMinute = Dictionary(grouping: live) { $0.ts - $0.ts % 60 }
        let historyByMinute = Dictionary(grouping: history) { $0.ts - $0.ts % 60 }
        let minutes = Set(liveByMinute.keys).union(historyByMinute.keys).filter { $0 + 60 <= now }
        return minutes.sorted().compactMap { minute in
            let h = historyByMinute[minute] ?? [], l = liveByMinute[minute] ?? []
            let chosen: (points: [HRPoint], source: Source)
            if h.count >= minReadingsPerMinute {
                chosen = (h, .history)
            } else if l.count >= minReadingsPerMinute {
                chosen = (l, .live)
            } else {
                return nil
            }
            let mean = Double(chosen.points.reduce(0) { $0 + $1.bpm }) / Double(chosen.points.count)
            guard (25...230).contains(mean) else { return nil }
            return PlannedSample(kind: .heartRate, syncId: "whoopsync:hr:\(minute)", start: minute, end: minute + 60,
                                 value: (mean * 10).rounded() / 10,
                                 version: chosen.source.tier * 100_000 + chosen.points.count)
        }
    }

    /// One finished clock hour's HRV: the steady qualifying 5-minute window with the lowest mean heart rate (any
    /// qualifying window when none is steady), as both SDNN and RMSSD. SDNN goes to Health (it has no RMSSD type);
    /// both are shared with Health Dashboard (docs/SHARING.md, `hrv`).
    public struct HourlyHRV: Equatable {
        public let hour: Int
        public let start: Int
        public let sdnn: Double
        /// nil when under half the window's beats have a clean neighbour to pair with.
        public let rmssd: Double?
        /// As the Health sample's: a newer algorithm beats an older one, history beats live, and more beats beat fewer.
        public let version: Int

        public init(hour: Int, start: Int, sdnn: Double, rmssd: Double?, version: Int) {
            self.hour = hour; self.start = start; self.sdnn = sdnn; self.rmssd = rmssd; self.version = version
        }
    }

    /// At most one window per finished clock hour. History is used when any of its windows qualify, live otherwise.
    public static func hourlyWindows(live: [RRPoint], history: [RRPoint], now: Int) -> [HourlyHRV] {
        let liveByHour = Dictionary(grouping: live) { $0.ts - $0.ts % 3600 }
        let historyByHour = Dictionary(grouping: history) { $0.ts - $0.ts % 3600 }
        let hours = Set(liveByHour.keys).union(historyByHour.keys).filter { $0 + 3600 <= now }
        return hours.sorted().compactMap { hour in
            for (points, source) in [(historyByHour[hour] ?? [], Source.history), (liveByHour[hour] ?? [], .live)] {
                let windows = qualifyingWindows(points)
                let steady = windows.filter(\.steady)
                guard let best = (steady.isEmpty ? windows : steady).min(by: { $0.meanHR < $1.meanHR }) else { continue }
                let beats = windows.reduce(0) { $0 + $1.beats }
                return HourlyHRV(hour: hour, start: best.start, sdnn: (best.sdnn * 10).rounded() / 10,
                                 rmssd: best.rmssd.map { ($0 * 10).rounded() / 10 },
                                 version: hrvAlgorithm + source.tier * 100_000 + beats)
            }
            return nil
        }
    }

    /// At most one HRV (SDNN) sample per finished clock hour, from [hourlyWindows].
    public static func hourlyHRV(live: [RRPoint], history: [RRPoint], now: Int) -> [PlannedSample] {
        hrvSamples(hourlyWindows(live: live, history: history, now: now))
    }

    /// Each hour's HRV (SDNN) sample, carrying the same window's RMSSD when it has one: Health has no RMSSD type,
    /// and this way an app reading Health gets it too (docs/SHARING.md, "Through Apple Health").
    public static func hrvSamples(_ hours: [HourlyHRV]) -> [PlannedSample] {
        hours.map {
            PlannedSample(kind: .hrv, syncId: "whoopsync:hrv:\($0.hour)", start: $0.start, end: $0.start + windowSeconds,
                          value: $0.sdnn, version: $0.version, metadata: HealthMetadata.rmssd($0.rmssd))
        }
    }

    struct Window: Equatable {
        let start: Int
        /// Of the detrended intervals ([Detrend]), so slow changes in heart rate don't count.
        let sdnn: Double
        let rmssd: Double?
        let meanHR: Double
        let beats: Int
        /// Its minutes' mean heart rates are within [steadyRangeBpm].
        let steady: Bool
    }

    static func qualifyingWindows(_ points: [RRPoint]) -> [Window] {
        let byWindow = Dictionary(grouping: points) { $0.ts - $0.ts % windowSeconds }
        return byWindow.keys.sorted().compactMap { start in
            let sorted = byWindow[start]!.sorted { ($0.ts, $0.idx) < ($1.ts, $1.idx) }
            let kept = cleanPoints(sorted)
            let total = kept.reduce(0) { $0 + $1.ms }
            guard total >= minWindowBeatMs else { return nil }
            let mean = Double(total) / Double(kept.count)
            let residual = Detrend.smoothnessPriors(kept.map { Double($0.ms) })
            let residualMean = residual.reduce(0, +) / Double(residual.count)
            let variance = residual.reduce(0.0) { $0 + ($1 - residualMean) * ($1 - residualMean) } / Double(residual.count)
            let diffs = successiveDifferences(sorted)
            let rmssd = diffs.count * 2 < kept.count ? nil
                : (diffs.reduce(0.0) { $0 + Double($1 * $1) } / Double(diffs.count)).squareRoot()
            return Window(start: start, sdnn: variance.squareRoot(), rmssd: rmssd, meanHR: 60_000 / mean, beats: kept.count,
                          steady: isSteady(kept))
        }
    }

    /// The differences between successive intervals, for RMSSD. A pair counts only when both intervals pass
    /// [cleanIntervals]' rules and were next to each other in the recording: a rejected beat in between, or a
    /// gap in the records longer than the interval itself (a beat missing from the data), breaks the pair.
    static func successiveDifferences(_ points: [RRPoint]) -> [Int] {
        var out: [Int] = []
        var lastKept: Int?
        var previous: RRPoint?  // the point just before, when it was kept
        for p in points {
            let kept = (300...2000).contains(p.ms) && lastKept.map { abs(Double(p.ms - $0)) <= 0.2 * Double($0) } ?? true
            guard kept else { previous = nil; continue }
            // A beat lands within ceil(ms / 1000) record-seconds of the one before it.
            if let q = previous, p.ts - q.ts <= (p.ms + 999) / 1000 { out.append(p.ms - q.ms) }
            lastKept = p.ms
            previous = p
        }
        return out
    }

    /// Keeps intervals between 300 and 2000 ms that differ from the previous kept one by at most 20%,
    /// a simple filter for ectopic beats and missed detections.
    static func cleanIntervals(_ ms: [Int]) -> [Int] {
        cleanPoints(ms.map { RRPoint(ts: 0, idx: 0, ms: $0) }).map(\.ms)
    }

    /// [cleanIntervals] keeping each beat's time.
    static func cleanPoints(_ points: [RRPoint]) -> [RRPoint] {
        var out: [RRPoint] = []
        for p in points where (300...2000).contains(p.ms) {
            if let prev = out.last, abs(Double(p.ms - prev.ms)) > 0.2 * Double(prev.ms) { continue }
            out.append(p)
        }
        return out
    }

    /// Whether a window's minutes (by record time) keep their mean heart rates within [steadyRangeBpm]. A window
    /// with under [steadyMinutes] minutes of [steadyMinuteBeats] clean beats can't be judged, so isn't steady.
    static func isSteady(_ kept: [RRPoint]) -> Bool {
        let minutes = Dictionary(grouping: kept) { ($0.ts % windowSeconds) / 60 }.values.filter { $0.count >= steadyMinuteBeats }
        guard minutes.count >= steadyMinutes else { return false }
        let rates = minutes.map { m in 60_000 * Double(m.count) / Double(m.reduce(0) { $0 + $1.ms }) }
        return rates.max()! - rates.min()! <= steadyRangeBpm
    }
}
