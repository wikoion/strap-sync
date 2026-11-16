import Foundation
import Security
import SyncCore

/// One stored ECG, as recorded and as shared (docs/SHARING.md, `ecg.<start>`).
struct EcgRecording: Equatable, Identifiable {
    let start: Int
    let end: Int
    let wrist: String
    let heartRate: Int?
    let hrvRaw: Int?
    let progress: Int
    let quality: Int
    let classifier: Int
    let sampleRateHz: Double?
    let samples: [Int]
    /// "strap", "ecg" (counted from the trace) or "optical" (wrist heart rate during the recording).
    var heartRateSource: String? = nil

    var id: Int { start }
    var account: String { "ecg.\(start)" }
    /// As a heart-rate sample carries it in Health (docs/SHARING.md, "Through Apple Health").
    var forHealth: HealthMetadata.Recording {
        HealthMetadata.Recording(start: start, end: end, sampleRateHz: sampleRateHz, heartRate: heartRate, samples: samples)
    }
}

/// The keychain group Strap Sync shares with Health Dashboard (docs/SHARING.md). Strap Sync is the only
/// writer: it keeps 7 days of skin temperature, hourly HRV and ECGs there.
enum SharedKeychain {
    static let service = "whoop-sync"
    static let retentionSeconds = 7 * 86_400

    /// `$(AppIdentifierPrefix)com.richarddraycott.healthshare`, resolved at build time into Info.plist.
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String }

    private static func base(_ account: String? = nil) -> [String: Any]? {
        guard let group else { return nil }
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: group,
            kSecAttrService as String: service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    @discardableResult
    static func write(_ account: String, _ data: Data) -> OSStatus {
        guard let query = base(account) else { return errSecMissingEntitlement }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        return status
    }

    static func delete(_ account: String) {
        guard let query = base(account) else { return }
        SecItemDelete(query as CFDictionary)
    }

    static func accounts() -> [String] {
        guard var query = base() else { return [] }
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: Payloads

    /// 10-minute means over worn minutes for the last 7 days, intervals with 5+ minutes only: the intervals the
    /// heart-rate samples in Health carry too (`SkinTemperature`).
    static func skinSamples(minutes: [MinuteSummary], now: Int) -> [(start: Int, celsius: Double)] {
        SkinTemperature.intervals(minutes.filter { $0.minute >= now - retentionSeconds }).map { ($0.start, $0.celsius) }
    }

    /// `skin-temperature`.
    static func skinTemperature(_ samples: [(start: Int, celsius: Double)], device: String, now: Int) -> Data? {
        let body: [String: Any] = [
            "version": 1, "updated": now, "device": device, "intervalSeconds": SkinTemperature.intervalSeconds,
            "samples": samples.map { [$0.start, $0.celsius] as [Any] },
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// `hrv`: each hour's window as `[start, end, rmssd or null, sdnn]`, oldest first.
    static func hrv(_ hours: [Aggregator.HourlyHRV], device: String, now: Int) -> Data? {
        let body: [String: Any] = [
            "version": 1, "updated": now, "device": device, "windowSeconds": Aggregator.windowSeconds,
            "samples": hours.map { [$0.start, $0.start + Aggregator.windowSeconds, $0.rmssd ?? NSNull(), $0.sdnn] as [Any] },
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// `ecg.<start>`.
    static func ecg(_ e: EcgRecording, device: String) -> Data? {
        var body: [String: Any] = [
            "version": 1, "id": e.account, "device": device, "start": e.start, "end": e.end, "wrist": e.wrist,
            "progress": e.progress, "quality": e.quality, "classifier": e.classifier, "amplitudeUnit": "raw",
            "samples": e.samples,
        ]
        body["heartRate"] = e.heartRate ?? NSNull()
        body["heartRateSource"] = e.heartRateSource ?? NSNull()
        body["hrvRaw"] = e.hrvRaw ?? NSNull()
        body["sampleRateHz"] = e.sampleRateHz.map { ($0 * 10).rounded() / 10 } ?? NSNull()
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
