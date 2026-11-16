#if DEBUG
import Foundation
import SyncCore

/// Made-up data for screenshots in the Simulator, which has no Bluetooth: launch a Debug build there with
/// `-demo YES`. AppModel plays a paired strap's events over it (`playDemo`): last night with sleep stages,
/// two ECGs and the day's samples for Apple Health. None of it comes from a strap or a person, and it only
/// runs in the Simulator, so a phone's own store is never mixed with it.
enum Demo {
    static var enabled: Bool {
        #if targetEnvironment(simulator)
        return UserDefaults.standard.bool(forKey: "demo")
        #else
        return false
        #endif
    }

    static let strapId = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    /// A firmware version from a public report (ryanbr/noop #2809).
    static let info = DeviceInfo(model: "MG", firmware: "50.42.1.0")

    /// A repeatable wobble in -1...1.
    static func wobble(_ x: Int) -> Double {
        let v = sin(Double(x) * 12.9898) * 43_758.5453
        return (v - v.rounded(.down)) * 2 - 1
    }

    /// Last night, 22:59 to 07:02 in five sleep cycles, and the day since.
    struct Day {
        let night: Sleep.Night
        let stages: StagedNight
        let samples: [PlannedSample]
        let ecgs: [EcgRecording]

        /// Stage and minutes from the night's start, which is `Sleep.bandLag` before the band's first sleep flag.
        static let script: [(SleepStage, Int)] = [
            (.wake, 11), (.light, 16), (.deep, 42), (.light, 12), (.rem, 10),
            (.light, 24), (.deep, 28), (.light, 14), (.wake, 3), (.light, 10), (.rem, 22),
            (.light, 36), (.deep, 14), (.light, 18), (.rem, 28), (.wake, 4),
            (.light, 40), (.deep, 6), (.light, 16), (.rem, 34),
            (.light, 30), (.wake, 2), (.light, 16), (.rem, 30), (.light, 17),
        ]

        init?(now: Int) {
            let epochs = Self.script.flatMap { Array(repeating: $0.0, count: $0.1 * 2) }
            // Woke at 07:02 today, or yesterday if that was under an hour ago.
            let today = Date(timeIntervalSince1970: TimeInterval(now))
            guard var woke = Calendar.current.date(bySettingHour: 7, minute: 2, second: 0, of: today) else { return nil }
            if woke > today.addingTimeInterval(-3600) { woke = woke.addingTimeInterval(-86_400) }
            let end = Int(woke.timeIntervalSince1970), start = end - epochs.count * 30
            let firstFlag = start + Sleep.bandLag * 60

            // The strap's minutes from two hours before bed to now, as the band and heart rate would show them.
            var minutes: [MinuteSummary] = []
            var samples: [PlannedSample] = []
            for minute in stride(from: start - 7200, to: now - 60, by: 60) {
                let k = (minute - end) / 60
                let stage = minute >= start && minute < end ? epochs[(minute - start) / 30] : nil
                let walking = [(10, 14), (88, 22), (330, 26), (520, 18)].contains { k >= $0.0 && k < $0.0 + $0.1 }
                let hr: Double
                switch stage {
                case .deep?: hr = 51
                case .light?: hr = 56
                case .rem?: hr = 60
                case .wake?: hr = 65
                case nil: hr = walking ? 104 : 74
                }
                let bpm = (hr + 2 * Demo.wobble(minute / 60)).rounded()
                // Wrist skin runs warmer asleep, under the covers.
                minutes.append(MinuteSummary(minute: minute, records: 60, worn: 60, meanHR: bpm,
                                             motion: stage.map { $0 == .wake ? 0.03 : 0.004 } ?? 0.08,
                                             sleepFlag: minute >= firstFlag && stage != nil && stage != .wake ? 60 : 0,
                                             skinTempC: (stage == nil ? 33.1 : 34.3) + 0.2 * Demo.wobble(minute / 60 + 3)))
                samples.append(PlannedSample(kind: .heartRate, syncId: "whoopsync:hr:\(minute)", start: minute,
                                             end: minute + 60, value: bpm, version: 2))
                let steps = walking ? 96 + 14 * Demo.wobble(minute) : Demo.wobble(minute) > 0.6 ? 25 + 20 * Demo.wobble(minute + 7) : 0
                if stage == nil, minute >= end, steps >= 1 {
                    samples.append(PlannedSample(kind: .steps, syncId: "whoopsync:steps:\(minute)", start: minute,
                                                 end: minute + 60, value: steps.rounded(), version: 1))
                }
            }
            guard let last = minutes.last,
                  let night = Sleep.nights(minutes, dataUntil: last.minute + 60, now: now).last,
                  night.start == start, night.end == end else { return nil }
            self.night = night
            stages = StagedNight(start: start, end: end, stages: epochs)

            // Sleep as stages, resting heart rate from the minutes, and what the strap measures overnight.
            samples += SleepStager.samples(start: start, stages: epochs, version: 1)
            samples += Sleep.samples(for: night, minutes: minutes, rr: []).filter { $0.kind == .restingHR }
            for hour in stride(from: (start - 7200) / 3600 * 3600 + 3600, to: now / 3600 * 3600, by: 3600) {
                let asleep = hour >= start && hour < end
                let sdnn = ((asleep ? 52 : 36) + 7 * Demo.wobble(hour)).rounded()
                samples.append(PlannedSample(kind: .hrv, syncId: "whoopsync:hrv:\(hour)", start: hour + 1200, end: hour + 1500,
                                             value: sdnn, version: Aggregator.hrvAlgorithm + 2,
                                             metadata: HealthMetadata.rmssd(((sdnn * 0.9 + 4 * Demo.wobble(hour + 2)) * 10).rounded() / 10)))
                if hour + 3600 > firstFlag && hour < end {
                    samples.append(PlannedSample(kind: .respiratoryRate, syncId: "whoopsync:resp:\(hour)",
                                                 start: max(hour, start), end: min(hour + 3600, end),
                                                 value: ((14.8 + 0.6 * Demo.wobble(hour + 1)) * 10).rounded() / 10, version: 10))
                }
            }
            for t in stride(from: firstFlag + 600, to: end - 30, by: 1200) {
                samples.append(PlannedSample(kind: .spo2, syncId: "whoopsync:spo2:\(t)", start: t, end: t + 30,
                                             value: (96.2 + 1.4 * Demo.wobble(t)).rounded(), version: 25))
            }
            ecgs = [(end + 40 * 60 + 31, 63), (end - 36 * 3600 + 734, 71)].map { start, bpm in
                EcgRecording(start: start, end: start + 41, wrist: "left", heartRate: bpm, hrvRaw: nil, progress: 100,
                             quality: 3, classifier: 0, sampleRateHz: 98.4,
                             samples: Demo.ecgTrace(seconds: 41, rate: 98.4, bpm: Double(bpm)), heartRateSource: "strap")
            }
            // Skin temperature and ECGs ride on the heart-rate samples, as from a strap.
            self.samples = HealthMetadata.withSkinTemperature(HealthMetadata.withEcgs(samples, ecgs.map(\.forHealth)),
                                                              SkinTemperature.intervals(minutes))
        }
    }

    /// A clean sinus rhythm: P, QRS and T as Gaussian bumps per beat, with breathing in the beat spacing, a
    /// little baseline wander and noise.
    static func ecgTrace(seconds: Double, rate: Double, bpm: Double) -> [Int] {
        let waves: [(at: Double, height: Double, width: Double)] = [
            (-0.20, 0.12, 0.025), (-0.035, -0.12, 0.010), (0, 1, 0.014), (0.035, -0.25, 0.012), (0.27, 0.32, 0.045),
        ]
        var beats: [Double] = []
        var t = 0.3
        while t < seconds + 1 {
            beats.append(t)
            t += 60 / bpm * (1 + 0.04 * sin(2 * .pi * t / 4))
        }
        return (0..<Int(seconds * rate)).map { i in
            let x = Double(i) / rate
            var v = 0.04 * sin(2 * .pi * 0.25 * x)
            for r in beats where abs(x - r) < 0.6 {
                for w in waves { v += w.height * exp(-pow((x - r - w.at) / w.width, 2) / 2) }
            }
            return Int((v * 900 + 10 * wobble(i)).rounded())
        }
    }
}
#endif
