/// On-demand ECG on the WHOOP MG: commands, the filtered waveform record (R17), and a recorder.
///
/// From ryanbr/noop docs/PROTOCOL_ECG.md and #891 (hardware-confirmed on MGs):
/// - Commands take revision 1 first.
/// - Start is `124 = 2` (`124 = 1` is stop).
/// - Live filtered output is gated separately by 139.
/// - A filtered record is packet type 43 (live) or 47 (saved), layout 17, exactly 240 bytes: a
///   13-byte status block, then up to 100 signed i16 LE samples.
///
/// Amplitude is uncalibrated and the sample rate isn't a published constant, so the recorder
/// estimates the rate from arrival times. The status bytes are kept raw where their meaning is
/// unresolved: no rhythm classification is implied.
public enum Ecg {
    public enum Wrist: UInt8, CaseIterable {
        case right = 1
        case left = 2

        public var name: String { self == .left ? "left" : "right" }
    }

    public enum Command: UInt8 {
        case selectWrist = 123
        case generation = 124
        case liveFiltered = 139
    }

    /// Select the wrist, turn on live filtered output, then start generation.
    public static func startSequence(wrist: Wrist) -> [(cmd: Command, payload: [UInt8])] {
        [(.selectWrist, [1, wrist.rawValue]), (.liveFiltered, [1, 1]), (.generation, [1, 2])]
    }

    /// Stop generation, then turn the live output back off.
    public static let stopSequence: [(cmd: Command, payload: [UInt8])] = [(.generation, [1, 1]), (.liveFiltered, [1, 0])]

    /// WHOOP's recording takes about 30 s of clean signal; the strap's progress byte counts it to 100.
    public static let lengthSeconds = 30

    /// Seconds of clean signal still needed at `progress`.
    public static func secondsLeft(progress: Int) -> Int {
        let p = min(max(progress, 0), 100)
        return (lengthSeconds * (100 - p) + 99) / 100
    }

    /// Bytes 21–33 of an ECG record.
    public struct Status: Equatable {
        /// 0–3 observed; meaning unresolved.
        public let quality: Int
        /// Byte 22 bit 3.
        public let present: Bool
        /// Byte 23. No established meaning: never a rhythm result.
        public let classifier: Int
        /// 0–100, percentage-like; 100 is where the strap considers the recording done.
        public let progress: Int
        /// Byte 27, bpm-like. 0 when not yet available.
        public let heartRate: Int
        /// Bytes 29–30, HRV-related, units unresolved. 0xFFFF (seen on a real MG) or 0 when not available.
        public let hrvRaw: Int

        /// 0 none, 1 weak or settling; 2 and 3 seen once the signal is clean.
        public var signalGood: Bool { quality >= 2 }
    }

    public struct FilteredRecord: Equatable {
        public let status: Status
        public let samples: [Int]
    }

    /// Decodes a validated frame if it's a filtered ECG record (R17), or returns nil.
    public static func filtered(_ f: [UInt8]) -> FilteredRecord? {
        guard f.count == 240, f[8] == 43 || f[8] == 47, f[9] == 17 else { return nil }
        let count = Int(f.u16(at: 32))
        guard count <= 100 else { return nil }  // an anomaly: never truncate silently
        let samples = (0..<count).map { Int(Int16(bitPattern: f.u16(at: 34 + 2 * $0))) }
        let status = Status(quality: Int(f[21]), present: f[22] & 0x08 != 0, classifier: Int(f[23]),
                            progress: Int(f[25]), heartRate: Int(f[27]), hrvRaw: Int(f.u16(at: 29)))
        return FilteredRecord(status: status, samples: samples)
    }
}

/// Collects one recording's filtered records.
public final class EcgRecorder {
    public private(set) var samples: [Int] = []
    public private(set) var records = 0
    public private(set) var first: Double?
    public private(set) var last: Double?
    public private(set) var status: Ecg.Status?
    public private(set) var heartRate: Int?
    public private(set) var hrvRaw: Int?
    /// When progress first reached 100.
    public private(set) var completedAt: Double?
    public private(set) var maxProgress = 0
    /// Whether the strap has reported finger contact at any point.
    public private(set) var hadContact = false
    /// Since when contact has been missing, after it had been there.
    public private(set) var contactLostSince: Double?
    private var firstCount = 0

    public init() {}

    public func add(_ r: Ecg.FilteredRecord, at t: Double) {
        if first == nil {
            first = t
            firstCount = r.samples.count
        }
        last = t
        records += 1
        samples += r.samples
        status = r.status
        if r.status.heartRate > 0 { heartRate = r.status.heartRate }
        if r.status.hrvRaw > 0 && r.status.hrvRaw < 0xFFFF { hrvRaw = r.status.hrvRaw }
        if r.status.progress >= 100, completedAt == nil { completedAt = t }
        maxProgress = max(maxProgress, r.status.progress)
        if r.status.present {
            hadContact = true
            contactLostSince = nil
        } else if hadContact, contactLostSince == nil {
            contactLostSince = t
        }
    }

    /// Samples after the first record over the time they took to arrive: an estimate, not a device constant.
    public var sampleRateHz: Double? {
        guard let first, let last, last - first >= 2 else { return nil }
        return Double(samples.count - firstCount) / (last - first)
    }
}

/// Heart rate from the ECG trace itself, for when the strap leaves its heart-rate byte at 0 (seen on
/// a real MG throughout a complete recording).
///
/// A polarity-free QRS detector: squared slope, smoothed over 120 ms. A beat is a local peak above 40%
/// of the largest smoothed value within ±1 s: a local threshold, because movement spikes in a real
/// trace would hide the beats around them from a global one. Peaks closer than 400 ms are merged, so a
/// T wave isn't counted as a second beat.
/// Heart rate is 60 over the median beat interval, reported only with enough, mostly regular beats.
/// On the first complete recording from a real MG this found 38 beats in 36 s at about 63 bpm.
public enum EcgBeats {
    public static func heartRate(_ samples: [Int], rateHz: Double) -> Int? {
        let n = samples.count
        guard rateHz >= 50, n >= Int(rateHz * 5) else { return nil }
        let x = samples.map(Double.init)
        var energy = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let slope = x[i + 1] - x[i - 1]
            energy[i] = slope * slope
        }
        let width = max(1, Int(rateHz * 0.12))
        var smooth = [Double](repeating: 0, count: n)
        var running = 0.0
        for i in 0..<n {
            running += energy[i]
            if i >= width { running -= energy[i - width] }
            smooth[i] = running / Double(width)
        }

        let half = Int(rateHz)
        let refractory = Int(rateHz * 0.4)
        var peaks: [Int] = []
        for i in 1..<(n - 1) where smooth[i] > 0 && smooth[i] >= smooth[i - 1] && smooth[i] >= smooth[i + 1] {
            let local = smooth[max(0, i - half)..<min(n, i + half)].max() ?? 0
            guard smooth[i] > 0.4 * local else { continue }
            if let last = peaks.last, i - last < refractory {
                if smooth[i] > smooth[last] { peaks[peaks.count - 1] = i }
            } else {
                peaks.append(i)
            }
        }
        guard peaks.count >= 6 else { return nil }
        let intervals = zip(peaks.dropFirst(), peaks).map { Double($0 - $1) / rateHz }.sorted()
        let median = intervals[intervals.count / 2]
        // Mostly regular: at least 60% of intervals within 20% of the median.
        let regular = intervals.filter { abs($0 - median) <= 0.2 * median }.count
        guard Double(regular) >= 0.6 * Double(intervals.count) else { return nil }
        let bpm = Int((60 / median).rounded())
        return (30...150).contains(bpm) ? bpm : nil
    }

    /// Which heart rate an ECG gets: the strap's own value, else the trace's if it agrees with the
    /// optical heart rate measured at the same time (within 15 %), else the optical one.
    public static func choose(strap: Int?, trace: Int?, optical: Int?) -> (bpm: Int, source: String)? {
        if let strap, strap > 0 { return (strap, "strap") }
        if let trace, optical.map({ abs(Double(trace - $0)) <= 0.15 * Double($0) }) ?? true { return (trace, "ecg") }
        return optical.map { ($0, "optical") }
    }
}
