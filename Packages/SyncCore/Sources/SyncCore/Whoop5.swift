/// WHOOP 5.0 / MG Bluetooth facts and message decoding.
///
/// UUIDs, command numbers and byte offsets come from the public reverse-engineering in b-nnett/goose
/// and ryanbr/noop (docs/PROTOCOL_WHOOP5.md, PROTOCOL_TRANSPORT.md, PROTOCOL_SENSORS.md). Only the
/// parts this app needs are decoded: command replies, history metadata and R18 summary records.
public enum Whoop5 {
    public static let service = "FD4B0001-CCE1-4033-93CE-002D5875F58A"
    public static let commandChar = "FD4B0002-CCE1-4033-93CE-002D5875F58A"
    public static let notifyChars = [
        "FD4B0003-CCE1-4033-93CE-002D5875F58A",
        "FD4B0004-CCE1-4033-93CE-002D5875F58A",
        "FD4B0005-CCE1-4033-93CE-002D5875F58A",
        "FD4B0007-CCE1-4033-93CE-002D5875F58A",
    ]

    /// Written with response to start the session. Doing so on an unbonded link makes iOS run
    /// "just works" pairing. It is a GET_HELLO (145) frame, revision 1, sequence 1.
    public static let clientHello: [UInt8] = [
        0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71, 0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D,
    ]

    /// The only commands this app sends. Destructive ones (trim, reboot, firmware) are deliberately absent.
    public enum Command: UInt8 {
        case setClock = 10
        case getClock = 11
        case sendHistoricalData = 22
        case historicalDataResult = 23
        case getBatteryLevel = 26
    }

    /// SET_CLOCK body: unix seconds (u32 LE) and four zero bytes. The 8-byte form NOOP has validated on 5/MG.
    public static func setClockPayload(unix: UInt32) -> [UInt8] {
        var p: [UInt8] = []
        p.appendLE(unix)
        return p + [0, 0, 0, 0]
    }

    /// Acknowledges one history chunk: `01` then the chunk's 8-byte end block, exactly as received.
    /// Only send once the chunk's records are saved, because it lets the strap delete them.
    public static func historyAckPayload(endBlock: [UInt8]) -> [UInt8] {
        [0x01] + endBlock
    }
}

/// One second of the strap's R18 biometric summary.
public struct R18Record: Equatable {
    /// Unix seconds, from the strap's clock.
    public let ts: Int
    /// 0 means off-wrist / no reading.
    public let bpm: Int
    /// Beat-to-beat intervals in milliseconds, zeros removed.
    public let rrMs: [Int]
    /// Cumulative step counter (u16, wraps). Unvalidated against the official app's count.
    public var stepCounter: Int = 0
    /// The counter at 57 switches to a software count when this is set; deltas across a switch are meaningless.
    public var stepSoftware = false
    /// Band motion/rest state: 0 wake, 1 still, 2 sleep, 3 up. Only "wake" has been seen in captures so far.
    public var bandState = 0
    /// Gravity-removed acceleration in g: about 0.01 when still.
    public var motion: Double?
    /// Skin temperature in °C (raw/100), when in the plausible 5–45 range.
    public var skinTempC: Double?
    /// Bytes 45/49/53: the strap's gravity vector in g (float32 x, y, z, about 1 g long). Its turns
    /// are wrist rotation, which sleep staging uses for wake. Nil unless finite and 0.1–4 g long.
    public var gravity: SIMD3<Double>?
    /// Byte 82: the strap's own SpO2 reading. 70–100 is a percentage, taken in ~30 s runs while
    /// asleep; values with bit 7 set are status sentinels, small values diagnostic codes, 0 nothing.
    public var spo2Raw = 0

    public init(ts: Int, bpm: Int, rrMs: [Int]) {
        self.ts = ts; self.bpm = bpm; self.rrMs = rrMs
    }
}

/// One second of the strap's R26 optical record: 25 samples of one PPG channel at 25 Hz. The strap
/// stores these in 40-second bursts every 20 minutes, day and night.
///
/// Layout (88 bytes; wearable5.0 `compact_optical_window`, NOOP #2019, checked on our archive): unix
/// time at 15, a u16 at 19, a burst counter at 21, the first sample as a signed i32 at 23, then 24 i16
/// deltas from 27. Sample i+1 is sample i plus delta i. Each pulse sends less light back, so a beat is
/// a dip.
public struct R26Record: Equatable {
    public let ts: Int
    /// The first sample, signed (it goes negative on some straps).
    public let base: Int32
    /// 24 steps between successive samples. The strap clamps them at the i16 limits.
    public let deltas: [Int16]
    /// Byte 19 (u16), meaning unknown; 6225 in our first capture.
    public var aux = 0
    /// Byte 21 (u16): 1 on a burst's first second, counting up through it.
    public var burstCounter = 0
    /// Byte 75 (f32): a motion figure for the second, about 0.006 asleep and 0.07 awake.
    public var motion: Double?
    /// Byte 79 (u16), meaning unknown; it takes a few values that differ asleep and awake.
    public var status = 0
    /// Byte 81, called on-wrist by wearable5.0 but mostly 0 while worn.
    public var onWrist = 0
    /// Byte 82: 1 when the strap accepted the second's signal (every second asleep, a fifth awake).
    public var acceptance = 0

    public init(ts: Int, base: Int32, deltas: [Int16]) {
        self.ts = ts; self.base = base; self.deltas = deltas
    }

    /// The 25 samples: the base followed by the running sum of the deltas.
    public var samples: [Int] {
        var out = [Int(base)]
        out.reserveCapacity(25)
        for d in deltas { out.append(out.last! + Int(d)) }
        return out
    }

    /// The deltas as 48 little-endian bytes, the way the app stores them.
    public var deltaBytes: [UInt8] {
        deltas.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
    }

    /// Rebuilds the deltas from `deltaBytes`. Nil unless there are exactly 48 bytes.
    public static func deltas(from bytes: [UInt8]) -> [Int16]? {
        guard bytes.count == 48 else { return nil }
        return (0..<24).map { Int16(bitPattern: UInt16(bytes[2 * $0]) | UInt16(bytes[2 * $0 + 1]) << 8) }
    }
}

public enum Whoop5Message: Equatable {
    case commandResponse(cmd: UInt8, originSeq: UInt8, result: UInt8, body: [UInt8])
    case historyStart
    case historyEnd(unix: UInt32, endBlock: [UInt8])
    case historyComplete
    case record(R18Record)
    case optical(R26Record)
    /// A history record with a layout this app doesn't decode (IMU, multi-channel optical, ECG...). The
    /// whole frame is kept so it can be banked and studied later.
    case otherRecord(layout: UInt8, ts: Int?, frame: [UInt8])
    case event(number: UInt8)
    case other(type: UInt8)

    public var isHistory: Bool {
        switch self {
        case .historyStart, .historyEnd, .historyComplete, .record, .optical, .otherRecord: return true
        default: return false
        }
    }

    /// Decodes one frame that has already passed `Frame.isValid`. Returns nil for a short or malformed one.
    public static func parse(_ f: [UInt8]) -> Whoop5Message? {
        guard f.count >= Frame.minimumLength else { return nil }
        switch f[8] {
        case 36, 38:
            // Command response: command 10, originating request sequence 11, result 12, body from 13.
            return .commandResponse(cmd: f[10], originSeq: f[11], result: f[12], body: Array(f[13..<(f.count - 4)]))
        case 49, 56:
            // History metadata: kind at 10 (1 start, 2 end, 3 complete).
            switch f[10] {
            case 1: return .historyStart
            case 3: return .historyComplete
            case 2:
                guard f.count >= 33 else { return nil }
                return .historyEnd(unix: f.u32(at: 11), endBlock: Array(f[21..<29]))
            default: return .other(type: f[8])
            }
        case 47:
            // Historical record: layout at 9. R18 is the 124-byte biometric summary, R26 the 88-byte optical one.
            if f[9] == 26 && f.count == 88 {
                var r = R26Record(ts: Int(f.u32(at: 15)), base: Int32(bitPattern: f.u32(at: 23)),
                                  deltas: (0..<24).map { Int16(bitPattern: f.u16(at: 27 + 2 * $0)) })
                r.aux = Int(f.u16(at: 19))
                r.burstCounter = Int(f.u16(at: 21))
                let motion = Double(Float(bitPattern: f.u32(at: 75)))
                r.motion = motion.isFinite ? motion : nil
                r.status = Int(f.u16(at: 79))
                r.onWrist = Int(f[81])
                r.acceptance = Int(f[82])
                return .optical(r)
            }
            guard f[9] == 18 else {
                return .otherRecord(layout: f[9], ts: f.count >= 19 ? Int(f.u32(at: 15)) : nil, frame: f)
            }
            guard f.count == 124 else { return nil }
            let count = min(Int(f[23]), 4)
            let rr = (0..<count).map { Int(f.u16(at: 24 + 2 * $0)) }.filter { $0 > 0 }
            var r = R18Record(ts: Int(f.u32(at: 15)), bpm: Int(f[22]), rrMs: rr)
            r.stepCounter = Int(f.u16(at: 57))
            r.stepSoftware = f[64] == 0x10
            r.bandState = Int((f[81] >> 4) & 0x03)
            let motion = Double(Float(bitPattern: f.u32(at: 41)))
            r.motion = motion.isFinite && (0...8).contains(motion) ? motion : nil
            let skin = Double(f.u16(at: 73)) / 100
            r.skinTempC = (5...45).contains(skin) ? skin : nil
            let g = SIMD3([45, 49, 53].map { Double(Float(bitPattern: f.u32(at: $0))) })
            let length = (g * g).sum().squareRoot()
            r.gravity = length.isFinite && (0.1...4).contains(length) ? g : nil
            r.spo2Raw = Int(f[82])
            return .record(r)
        case 48:
            return .event(number: f[10])
        default:
            return .other(type: f[8])
        }
    }
}
