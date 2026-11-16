public struct HRPoint: Equatable {
    public let ts: Int
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

/// One beat-to-beat interval. `idx` orders intervals that share a second, and makes re-delivered
/// history dedupe on (ts, idx).
public struct RRPoint: Equatable {
    public let ts: Int
    public let idx: Int
    public let ms: Int
    public init(ts: Int, idx: Int, ms: Int) { self.ts = ts; self.idx = idx; self.ms = ms }
}

/// The per-second fields used for steps, sleep and temperature, from every plausible R18 record
/// (worn or not: off-wrist seconds matter for sleep).
public struct MotionPoint: Equatable {
    public let ts: Int
    public let bpm: Int
    public let stepCounter: Int
    public let stepSoftware: Bool
    public let bandState: Int
    public let motion: Double?
    public let skinTempC: Double?
    public let spo2Raw: Int
    /// The strap's gravity vector in g, for wrist rotation (R18Record.gravity).
    public let gravity: SIMD3<Double>?

    public init(ts: Int, bpm: Int, stepCounter: Int, stepSoftware: Bool, bandState: Int, motion: Double?,
                skinTempC: Double?, spo2Raw: Int = 0, gravity: SIMD3<Double>? = nil) {
        self.ts = ts; self.bpm = bpm; self.stepCounter = stepCounter; self.stepSoftware = stepSoftware
        self.bandState = bandState; self.motion = motion; self.skinTempC = skinTempC; self.spo2Raw = spo2Raw
        self.gravity = gravity
    }

    init(_ r: R18Record) {
        self.init(ts: r.ts, bpm: r.bpm, stepCounter: r.stepCounter, stepSoftware: r.stepSoftware,
                  bandState: r.bandState, motion: r.motion, skinTempC: r.skinTempC, spo2Raw: r.spo2Raw, gravity: r.gravity)
    }
}

/// A history record of a layout the app doesn't decode, kept whole for later study (R20 multi-channel optical,
/// R21 IMU...).
public struct BankedRecord: Equatable {
    public let layout: Int
    public let ts: Int
    public let frame: [UInt8]
    public init(layout: Int, ts: Int, frame: [UInt8]) { self.layout = layout; self.ts = ts; self.frame = frame }
}

/// The records between two history ends: save these, then acknowledge `endBlock`.
public struct HistoryChunk: Equatable {
    public var hr: [HRPoint] = []
    public var rr: [RRPoint] = []
    public var motion: [MotionPoint] = []
    /// R26 optical seconds: the strap's 25 Hz optical bursts (PPG), kept as they are.
    public var optical: [R26Record] = []
    /// Dated records of other layouts, kept whole.
    public var banked: [BankedRecord] = []
    public var endBlock: [UInt8] = []
    /// R18 records seen, including off-wrist and out-of-range ones.
    public var records = 0
    /// Records of layouts other than R18 (R26 included), by layout.
    public var otherRecords = 0
    public var otherLayouts: [UInt8: Int] = [:]
    /// R18 records dated outside the plausible window (a strap clock that wasn't set yet).
    public var implausible = 0

    /// The strap's flash cursor, the first word of the end block. 0xFFFFFFFF means nothing banked.
    public var trimCursor: UInt32? {
        endBlock.count == 8 ? endBlock.u32(at: 0) : nil
    }
}

/// Follows one history download: START, records, END (acknowledge), ..., COMPLETE.
public final class HistorySession {
    public enum Output: Equatable {
        case none
        case chunk(HistoryChunk)
        case complete
    }

    public private(set) var isOpen = false
    private var chunk = HistoryChunk()
    private let now: () -> Int

    /// Records older than this, or more than a day ahead, are a clock problem, not history.
    public static let maxAgeSeconds = 30 * 86_400

    public init(now: @escaping () -> Int) {
        self.now = now
    }

    /// Called when SEND_HISTORICAL_DATA goes out. Records arriving before an explicit START still count.
    public func begin() {
        isOpen = true
        chunk = HistoryChunk()
    }

    public func abandon() {
        isOpen = false
        chunk = HistoryChunk()
    }

    private func plausible(_ ts: Int) -> Bool {
        let t = now()
        return ts >= t - Self.maxAgeSeconds && ts <= t + 86_400
    }

    public func feed(_ message: Whoop5Message) -> Output {
        guard isOpen else { return .none }
        switch message {
        case .historyStart:
            chunk = HistoryChunk()
        case .record(let r):
            chunk.records += 1
            guard plausible(r.ts) else {
                chunk.implausible += 1
                return .none
            }
            chunk.motion.append(MotionPoint(r))
            if (25...250).contains(r.bpm) {
                chunk.hr.append(HRPoint(ts: r.ts, bpm: r.bpm))
                for (i, ms) in r.rrMs.enumerated() {
                    chunk.rr.append(RRPoint(ts: r.ts, idx: i, ms: ms))
                }
            }
        case .optical(let r):
            chunk.otherRecords += 1
            chunk.otherLayouts[26, default: 0] += 1
            if plausible(r.ts) { chunk.optical.append(r) }
        case .otherRecord(let layout, let ts, let frame):
            chunk.otherRecords += 1
            chunk.otherLayouts[layout, default: 0] += 1
            if let ts, plausible(ts) { chunk.banked.append(BankedRecord(layout: Int(layout), ts: ts, frame: frame)) }
        case .historyEnd(_, let endBlock):
            var done = chunk
            done.endBlock = endBlock
            chunk = HistoryChunk()
            return .chunk(done)
        case .historyComplete:
            isOpen = false
            chunk = HistoryChunk()
            return .complete
        default:
            break
        }
        return .none
    }
}

extension HistoryChunk {
    /// The R26 and other banked records in one file of the app's raw frame archive (`[length u16 LE][frame]`
    /// repeated). Everything else in it, R18 included, is left out: that is already stored.
    public static func archived(_ bytes: [UInt8]) -> HistoryChunk {
        var c = HistoryChunk()
        var i = 0
        while i + 2 <= bytes.count {
            let n = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
            guard i + n <= bytes.count else { break }
            let f = Array(bytes[i..<(i + n)])
            i += n
            switch Whoop5Message.parse(f) {
            case .optical(let r)?:
                c.optical.append(r)
            case .otherRecord(let layout, let ts?, let frame)?:
                c.banked.append(BankedRecord(layout: Int(layout), ts: ts, frame: frame))
            default:
                break
            }
        }
        return c
    }
}
