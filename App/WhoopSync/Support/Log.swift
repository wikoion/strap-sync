import Foundation

/// The app's log: the last 500 lines for the Log screen, and every line appended to
/// Documents/logs/<day>.log so it survives restarts and can be pulled off the phone.
/// Call from the main thread.
final class Log: ObservableObject {
    static let shared = Log()

    @Published private(set) var lines: [String] = []

    private let fileQueue = DispatchQueue(label: "WhoopSync.log")
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("logs")
    }

    func callAsFunction(_ message: String) {
        let now = Date()
        let line = "\(stamp.string(from: now)) \(message)"
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        let url = Self.directory.appendingPathComponent("\(day.string(from: now)).log")
        fileQueue.async {
            let data = Data((line + "\n").utf8)
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    var text: String { lines.joined(separator: "\n") }
}

let log = Log.shared
