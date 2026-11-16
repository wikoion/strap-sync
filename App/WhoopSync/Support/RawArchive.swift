import Foundation

/// Every intact frame from the strap's WHOOP channels, appended to hourly files in Documents/raw
/// (`yyyy-MM-ddTHH.bin`, UTC) as `[length u16 LE][frame]`. It's the material for decoding more of
/// the protocol later (the SpO2 byte's calibration, the raw optical records), so nothing the strap
/// sends is lost once acknowledged. Kept for 7 days. `scripts/install-app.sh --pull-raw` copies it off.
final class RawArchive {
    static let shared = RawArchive()

    private let queue = DispatchQueue(label: "WhoopSync.raw")
    private var handle: FileHandle?
    private var hour = ""
    private let name: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH"
        return f
    }()

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("raw")
    }

    func append(_ frame: [UInt8]) {
        guard frame.count <= Int(UInt16.max) else { return }
        let now = Date()
        queue.async { [self] in
            let h = name.string(from: now)
            if h != hour || handle == nil {
                try? handle?.close()
                handle = nil
                hour = h
                let fm = FileManager.default
                try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                let url = Self.directory.appendingPathComponent("\(h).bin")
                if !fm.fileExists(atPath: url.path) {
                    fm.createFile(atPath: url.path, contents: nil,
                                  attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                    prune()
                }
                handle = try? FileHandle(forWritingTo: url)
                handle?.seekToEndOfFile()
            }
            var record = Data([UInt8(frame.count & 0xFF), UInt8(frame.count >> 8)])
            record.append(contentsOf: frame)
            handle?.write(record)
        }
    }

    private func prune() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        for url in (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
