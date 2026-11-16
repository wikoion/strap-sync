/// The standard Bluetooth Heart Rate Measurement characteristic (0x2A37).
///
/// A WHOOP 5/MG streams this at about 1 Hz without a bond. It sends the RR intervals in milliseconds
/// rather than the 1/1024 s the Bluetooth spec defines (ryanbr/noop Whoop5RR.swift, from 71k frames),
/// so `rrRaw` is used as milliseconds as-is.
public struct HeartRateMeasurement: Equatable {
    public enum Contact: Equatable {
        case unsupported, notDetected, detected
    }

    public let bpm: Int
    public let contact: Contact
    public let rrRaw: [Int]

    public static func parse(_ d: [UInt8]) -> HeartRateMeasurement? {
        guard let flags = d.first else { return nil }
        var i = 1
        let bpm: Int
        if flags & 0x01 != 0 {
            guard d.count >= i + 2 else { return nil }
            bpm = Int(d.u16(at: i)); i += 2
        } else {
            guard d.count >= i + 1 else { return nil }
            bpm = Int(d[i]); i += 1
        }
        let contact: Contact = flags & 0x04 == 0 ? .unsupported : (flags & 0x02 == 0 ? .notDetected : .detected)
        if flags & 0x08 != 0 { i += 2 }  // energy expended
        var rr: [Int] = []
        if flags & 0x10 != 0 {
            while i + 1 < d.count {
                let v = Int(d.u16(at: i))
                if v > 0 { rr.append(v) }
                i += 2
            }
        }
        return HeartRateMeasurement(bpm: bpm, contact: contact, rrRaw: rr)
    }

    /// Whether this reading should be kept: the strap is on the wrist and the value is plausible.
    public var isUsable: Bool {
        contact != .notDetected && (25...250).contains(bpm)
    }
}
