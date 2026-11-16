import Foundation

/// A custom HealthKit metadata value. HealthKit takes NSNumber, NSString and NSDate; this is the same without
/// Foundation's types, so planning stays testable here and the outbox can store it.
public enum MetadataValue: Equatable {
    case number(Double)
    case text(String)
    /// Unix seconds, written as an NSDate.
    case date(Int)
}

/// Strap Sync's own metadata on samples it already writes to Apple Health, for what Health has no type for:
/// skin temperature and ECG recordings on heart rate, RMSSD on HRV (docs/SHARING.md, "Through Apple Health"). Any
/// app the user lets read heart rate or HRV gets them, whoever signed it; the keychain share needs the same team.
///
/// The keys never start with HK, which is Apple's.
public enum HealthMetadata {
    /// °C, the interval's mean wrist skin temperature.
    public static let skinTemperature = "StrapSyncSkinTemperature"
    /// The interval's start.
    public static let skinTemperatureStart = "StrapSyncSkinTemperatureStart"
    /// The interval's length, 600.
    public static let skinTemperatureSeconds = "StrapSyncSkinTemperatureSeconds"
    /// ms, from the same 5-minute window as the HRV sample's SDNN.
    public static let rmssd = "StrapSyncRMSSD"

    /// An ECG recording: base64 of its waveform, the keychain `ecg` item's `samples` (filtered, uncalibrated),
    /// each a signed 16-bit little-endian integer. About 11 KB for 41 s.
    public static let ecg = "StrapSyncECG"
    /// The recording's start: its first waveform record.
    public static let ecgStart = "StrapSyncECGStart"
    /// Hz, estimated from the recording, as the keychain item's `sampleRateHz`. Left out when there's none.
    public static let ecgSampleRate = "StrapSyncECGSampleRate"
    /// bpm, as the keychain item's `heartRate`. Left out when there's none.
    public static let ecgHeartRate = "StrapSyncECGHeartRate"

    static let ecgKeys = [ecg, ecgStart, ecgSampleRate, ecgHeartRate]

    /// An ECG recording, as a heart-rate sample carries it.
    public struct Recording: Equatable {
        public let start: Int
        public let end: Int
        public let sampleRateHz: Double?
        public let heartRate: Int?
        public let samples: [Int]

        public init(start: Int, end: Int, sampleRateHz: Double?, heartRate: Int?, samples: [Int]) {
            self.start = start; self.end = end; self.sampleRateHz = sampleRateHz; self.heartRate = heartRate
            self.samples = samples
        }
    }

    /// The sync identifier of a recording's own heart-rate sample ([withEcgs]).
    public static func carrierId(_ start: Int) -> String { "whoopsync:ecg:\(start)" }

    /// An HRV sample's metadata: its window's RMSSD, when it has one.
    public static func rmssd(_ ms: Double?) -> [String: MetadataValue] {
        ms.map { [rmssd: .number($0)] } ?? [:]
    }

    /// Heart-rate samples with their skin temperature: each one whose minute lies in an interval with a value
    /// carries that interval, so up to ten carry the same one. The rest, and other kinds, are left as they are:
    /// a freshly planned sample has no metadata, and one read back from the outbox for the backfill keeps what it
    /// has when its minutes are no longer stored. (An interval never loses its value: minutes only gain records.)
    public static func withSkinTemperature(_ samples: [PlannedSample], _ intervals: [SkinTemperature.Interval]) -> [PlannedSample] {
        let byStart = Dictionary(intervals.map { ($0.start, $0) }) { _, last in last }
        return samples.map { s in
            guard s.kind == .heartRate, let i = byStart[s.start - s.start % SkinTemperature.intervalSeconds] else { return s }
            var m = s.metadata
            m[skinTemperature] = .number(i.celsius)
            m[skinTemperatureStart] = .date(i.start)
            m[skinTemperatureSeconds] = .number(Double(SkinTemperature.intervalSeconds))
            return s.with(metadata: m)
        }
    }

    /// Heart-rate samples with ECG recordings, so every recording reaches Health:
    /// - The sample of the minute a recording started in carries it (the latest, if two start in one minute).
    /// - When that minute has none, the recording gets a heart-rate sample of its own, from its start to its end at
    ///   its own heart rate, under [carrierId]: the MG's heart rate stays 0 during an ECG, so its minute often has
    ///   no sample. Once it has one (`carried`, or among `samples` when they're read back from the outbox) it keeps
    ///   it, so a minute's sample arriving later doesn't carry the recording a second time.
    /// - A recording with neither a minute's sample nor a heart rate yet waits: its hour is planned again when it
    ///   gets one.
    ///
    /// Its own sample's version stays 1: its heart rate is in its metadata too, so a new one rewrites it
    /// ([Outbox.merge]). Other samples, and other kinds, are left as they are, as for skin temperature.
    public static func withEcgs(_ samples: [PlannedSample], _ recordings: [Recording], carried: Set<Int> = []) -> [PlannedSample] {
        var out = samples
        var minutes: [Int: Int] = [:], own: [String: Int] = [:]  // where each minute's and each carrier's sample is
        for (i, s) in out.enumerated() where s.kind == .heartRate {
            if s.syncId.hasPrefix("whoopsync:ecg:") { own[s.syncId] = i } else { minutes[s.start] = i }
        }
        for r in recordings.sorted(by: { $0.start > $1.start }) {
            let id = carrierId(r.start)
            if !carried.contains(r.start), own[id] == nil, let i = minutes.removeValue(forKey: r.start - r.start % 60) {
                out[i] = attaching(r, to: out[i])
            } else if let bpm = r.heartRate {
                let sample = PlannedSample(kind: .heartRate, syncId: id, start: r.start, end: max(r.end, r.start + 1),
                                           value: Double(bpm), version: 1, metadata: own[id].map { out[$0].metadata } ?? [:])
                if let i = own[id] { out[i] = attaching(r, to: sample) } else { out.append(attaching(r, to: sample)) }
            }
        }
        return out
    }

    private static func attaching(_ r: Recording, to s: PlannedSample) -> PlannedSample {
        var m = s.metadata
        for key in ecgKeys { m[key] = nil }  // a recording without a rate or heart rate leaves those out
        m[ecg] = .text(waveform(r.samples))
        m[ecgStart] = .date(r.start)
        if let rate = r.sampleRateHz { m[ecgSampleRate] = .number((rate * 10).rounded() / 10) }
        if let bpm = r.heartRate { m[ecgHeartRate] = .number(Double(bpm)) }
        return s.with(metadata: m)
    }

    /// Base64 of the samples as signed 16-bit little-endian integers, the strap's own sample format.
    public static func waveform(_ samples: [Int]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(samples.count * 2)
        for v in samples {
            let u = UInt16(bitPattern: Int16(clamping: v))
            bytes += [UInt8(u & 0xFF), UInt8(u >> 8)]
        }
        return Data(bytes).base64EncodedString()
    }

    /// [waveform] read back, as a reader would.
    public static func samples(fromWaveform text: String) -> [Int]? {
        guard let data = Data(base64Encoded: text), data.count % 2 == 0 else { return nil }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 2).map { Int(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) }
    }

    /// The one-time backfill (`metadataRedo1`): the heart-rate samples already planned, with the stored ECGs (and
    /// their own samples, where their minute has none) and the stored minutes' skin temperature, and the stored hours'
    /// HRV with their RMSSD. Their data versions are unchanged, so [Outbox.merge] rewrites just the ones that gain
    /// metadata.
    public static func backfill(heartRate: [PlannedSample], minutes: [MinuteSummary], ecgs: [Recording],
                                hrv: [Aggregator.HourlyHRV]) -> [PlannedSample] {
        withSkinTemperature(withEcgs(heartRate, ecgs), SkinTemperature.intervals(minutes)) + Aggregator.hrvSamples(hrv)
    }

    // MARK: Stored in the outbox

    /// JSON with sorted keys, or nil for none, for the outbox's `meta` column.
    public static func encode(_ metadata: [String: MetadataValue]) -> String? {
        guard !metadata.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]  // base64 is full of slashes
        return (try? encoder.encode(metadata)).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func decode(_ text: String?) -> [String: MetadataValue] {
        guard let text else { return [:] }
        return (try? JSONDecoder().decode([String: MetadataValue].self, from: Data(text.utf8))) ?? [:]
    }
}

extension MetadataValue: Codable {
    private enum CodingKeys: String, CodingKey { case n, s, t }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try c.decodeIfPresent(Double.self, forKey: .n) {
            self = .number(n)
        } else if let s = try c.decodeIfPresent(String.self, forKey: .s) {
            self = .text(s)
        } else {
            self = .date(try c.decode(Int.self, forKey: .t))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let n): try c.encode(n, forKey: .n)
        case .text(let s): try c.encode(s, forKey: .s)
        case .date(let t): try c.encode(t, forKey: .t)
        }
    }
}

/// Wrist skin temperature in 10-minute intervals: the mean over an interval's worn minutes, when at least 5 were
/// worn. The keychain's `skin-temperature` item and the heart-rate samples in Health carry the same intervals.
public enum SkinTemperature {
    public static let intervalSeconds = 600
    public static let minWornMinutes = 5

    public struct Interval: Equatable {
        public let start: Int
        /// °C, to 0.01.
        public let celsius: Double

        public init(start: Int, celsius: Double) {
            self.start = start; self.celsius = celsius
        }
    }

    /// Clock-aligned intervals with a value, oldest first. Only minutes worn with a reading count.
    public static func intervals(_ minutes: [MinuteSummary]) -> [Interval] {
        let worn = minutes.filter { $0.worn > 0 && $0.skinTempC != nil }
        let buckets = Dictionary(grouping: worn) { $0.minute - $0.minute % intervalSeconds }
        return buckets.keys.sorted().compactMap { start in
            let ms = buckets[start]!
            guard ms.count >= minWornMinutes else { return nil }
            let mean = ms.compactMap(\.skinTempC).reduce(0, +) / Double(ms.count)
            return Interval(start: start, celsius: (mean * 100).rounded() / 100)
        }
    }
}
