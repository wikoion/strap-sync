/// WHOOP 5/MG "format 1" frames, the envelope every command, reply and history record travels in.
///
/// ```
/// [0]     0xAA start byte
/// [1]     0x01 format
/// [2..3]  declared length (u16 LE) = frame length - 8
/// [4..5]  header bytes (00 01 on requests)
/// [6..7]  CRC16-Modbus over bytes 0..5
/// [8]     packet type
/// [9]     sequence
/// [10...] packet-specific bytes, zero-padded so [8..<end-4] is a multiple of 4
/// [end-4] CRC32 over [8..<end-4]
/// ```
///
/// Layout from the public WHOOP 5 protocol notes (b-nnett/goose, ryanbr/noop docs/PROTOCOL_TRANSPORT.md).
public enum Frame {
    public static let minimumLength = 16
    public static let maximumLength = 8192

    /// A command frame (packet type 35) for the strap's command characteristic.
    public static func command(_ cmd: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [35, seq, cmd] + payload
        while body.count % 4 != 0 { body.append(0) }
        var frame: [UInt8] = [0xAA, 0x01]
        frame.appendLE(UInt16(body.count + 4))
        frame += [0x00, 0x01]
        frame.appendLE(Checksum.crc16Modbus(frame[0..<6]))
        frame += body
        frame.appendLE(Checksum.crc32(body))
        return frame
    }

    /// True when `frame` is exactly one intact format-1 frame: declared length, header CRC and body CRC.
    public static func isValid(_ frame: [UInt8]) -> Bool {
        guard frame.count >= minimumLength, frame[0] == 0xAA, frame[1] == 0x01,
              Int(frame.u16(at: 2)) + 8 == frame.count,
              Checksum.crc16Modbus(frame[0..<6]) == frame.u16(at: 6)
        else { return false }
        return Checksum.crc32(frame[8..<(frame.count - 4)]) == frame.u32(at: frame.count - 4)
    }
}

/// Joins BLE notification fragments into whole frames. One per notify characteristic.
///
/// A start byte only counts when the header CRC over its own length field checks out, so a stray 0xAA
/// inside a payload can't desync the stream.
public final class Reassembler {
    private var buf: [UInt8] = []
    public private(set) var droppedBytes = 0

    public init() {}

    public func feed(_ fragment: [UInt8]) -> [[UInt8]] {
        buf += fragment
        var out: [[UInt8]] = []
        while true {
            guard let sof = buf.firstIndex(of: 0xAA) else {
                droppedBytes += buf.count
                buf.removeAll()
                break
            }
            if sof > 0 {
                droppedBytes += sof
                buf.removeFirst(sof)
            }
            guard buf.count >= 8 else { break }
            let total = Int(buf.u16(at: 2)) + 8
            guard buf[1] == 0x01, Checksum.crc16Modbus(buf[0..<6]) == buf.u16(at: 6),
                  (Frame.minimumLength...Frame.maximumLength).contains(total)
            else {
                droppedBytes += 1
                buf.removeFirst()
                continue
            }
            guard buf.count >= total else { break }
            out.append(Array(buf[0..<total]))
            buf.removeFirst(total)
        }
        return out
    }

    public func reset() { buf.removeAll() }
}
