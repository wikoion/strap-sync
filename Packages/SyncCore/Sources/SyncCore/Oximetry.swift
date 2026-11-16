/// SpO2 from the strap's own readings (R18 byte 82).
///
/// While asleep the MG measures in ~30 s runs roughly every 20 minutes. Within a run the byte
/// alternates between readings (70–100) and status sentinels, so a run is the in-band readings with no
/// gap over 60 s. The first five readings of each run are an optical lock-on ramp: they read low and,
/// unlike later lows, cause no heart-rate response, so they're dropped (ryanbr/noop #1099).
///
/// Evidence says this byte measures oxygen; whether 97 means 97 hasn't been checked against a
/// reference oximeter yet.
public enum Oximetry {
    public static let runGap = 60
    public static let ramp = 5
    public static let minReadings = 5

    public struct Run: Equatable {
        /// First in-band reading, ramp included: stable as the run fills in, so it keys the sample.
        public let start: Int
        public let end: Int
        /// Readings after the ramp.
        public let values: [Int]

        public var median: Double {
            let s = values.sorted()
            return s.count % 2 == 1 ? Double(s[s.count / 2]) : Double(s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
    }

    public static func isReading(_ raw: Int) -> Bool { (70...100).contains(raw) }

    public static func runs(_ points: [(ts: Int, raw: Int)]) -> [Run] {
        let readings = points.filter { isReading($0.raw) }.sorted { $0.ts < $1.ts }
        var groups: [[(ts: Int, raw: Int)]] = []
        for p in readings {
            if let last = groups.last?.last, p.ts - last.ts <= runGap {
                groups[groups.count - 1].append(p)
            } else {
                groups.append([p])
            }
        }
        return groups.compactMap { g in
            let kept = g.dropFirst(ramp)
            guard kept.count >= minReadings else { return nil }
            return Run(start: g[0].ts, end: g[g.count - 1].ts + 1, values: kept.map(\.raw))
        }
    }

    /// One oxygen-saturation sample per run: the median of its post-ramp readings, in percent.
    public static func samples(_ runs: [Run]) -> [PlannedSample] {
        runs.map {
            PlannedSample(kind: .spo2, syncId: "whoopsync:spo2:\($0.start)", start: $0.start, end: $0.end,
                          value: $0.median, version: $0.values.count)
        }
    }
}
