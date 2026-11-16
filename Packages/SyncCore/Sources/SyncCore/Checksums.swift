/// The two checksums in a WHOOP 5/MG frame.
public enum Checksum {
    /// CRC16-Modbus (reflected, polynomial 0xA001, initial 0xFFFF). Guards the 6-byte frame header.
    public static func crc16Modbus<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    /// Standard zlib CRC-32 (reflected, polynomial 0xEDB88320). Guards the frame body.
    public static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }
}

extension Array where Element == UInt8 {
    func u16(at i: Int) -> UInt16 {
        UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8(v >> 8))
    }

    mutating func appendLE(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
}
