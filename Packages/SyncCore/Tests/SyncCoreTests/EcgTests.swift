import XCTest
@testable import SyncCore

final class EcgTests: XCTestCase {
    /// A 240-byte filtered ECG record laid out as PROTOCOL_ECG.md describes, with valid CRCs.
    static func r17(type: UInt8 = 43, samples: [Int16], progress: UInt8 = 40, quality: UInt8 = 3, present: Bool = true,
                    heartRate: UInt8 = 61, hrvRaw: UInt16 = 0, count: Int? = nil) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 240)
        f[0] = 0xAA; f[1] = 0x01
        f[2] = UInt8((240 - 8) & 0xFF); f[3] = UInt8((240 - 8) >> 8)
        f[4] = 0x01; f[5] = 0x00
        let h = Checksum.crc16Modbus(f[0..<6])
        f[6] = UInt8(h & 0xFF); f[7] = UInt8(h >> 8)
        f[8] = type; f[9] = 17
        f[21] = quality; f[22] = present ? 0x0A : 0x02; f[23] = 7; f[25] = progress; f[27] = heartRate
        f[29] = UInt8(hrvRaw & 0xFF); f[30] = UInt8(hrvRaw >> 8)
        let n = count ?? samples.count
        f[32] = UInt8(n & 0xFF); f[33] = UInt8(n >> 8)
        for (i, s) in samples.enumerated() {
            let u = UInt16(bitPattern: s)
            f[34 + 2 * i] = UInt8(u & 0xFF); f[35 + 2 * i] = UInt8(u >> 8)
        }
        let c = Checksum.crc32(f[8..<236])
        for k in 0..<4 { f[236 + k] = UInt8((c >> UInt32(8 * k)) & 0xFF) }
        return f
    }

    func testFilteredRecord() {
        let f = Self.r17(samples: [100, -250, 32767, -32768, 0], progress: 55, hrvRaw: 0x0123)
        XCTAssertTrue(Frame.isValid(f))
        let r = Ecg.filtered(f)
        XCTAssertEqual(r?.samples, [100, -250, 32767, -32768, 0])
        XCTAssertEqual(r?.status, Ecg.Status(quality: 3, present: true, classifier: 7, progress: 55, heartRate: 61, hrvRaw: 0x0123))
    }

    func testOnlyDeclaredSamplesAreRead() {
        // 100 slots are always there; only the declared count is data, and the alignment word never is.
        XCTAssertEqual(Ecg.filtered(Self.r17(samples: [1, 2, 3], count: 2))?.samples, [1, 2])
        XCTAssertEqual(Ecg.filtered(Self.r17(samples: Array(repeating: 5, count: 100)))?.samples.count, 100)
    }

    func testOverCapacityCountAndOtherShapesAreRejected() {
        XCTAssertNil(Ecg.filtered(Self.r17(samples: [1], count: 101)))
        var r16 = Self.r17(samples: [1])
        r16[9] = 16
        XCTAssertNil(Ecg.filtered(r16))
        XCTAssertNil(Ecg.filtered(Array(Self.r17(samples: [1]).prefix(124))))
    }

    func testCommandsMatchTheHardwareConfirmedArguments() {
        let start = Ecg.startSequence(wrist: .left).map { [$0.cmd.rawValue] + $0.payload }
        XCTAssertEqual(start, [[123, 1, 2], [139, 1, 1], [124, 1, 2]])
        XCTAssertEqual(Ecg.stopSequence.map { [$0.cmd.rawValue] + $0.payload }, [[124, 1, 1], [139, 1, 0]])
        XCTAssertEqual(Array(Frame.command(124, seq: 9, payload: [1, 2])[8..<13]), [35, 9, 124, 1, 2])
    }

    func testRecorderEstimatesRateAndKeepsTheLastValues() {
        let rec = EcgRecorder()
        for i in 0..<41 {
            let progress = UInt8(min(100, i * 3))
            let r = Ecg.filtered(Self.r17(samples: Array(repeating: Int16(i), count: 100), progress: progress,
                                         heartRate: i < 5 ? 0 : 62, hrvRaw: i > 35 ? 44 : 0))!
            rec.add(r, at: 1000 + Double(i))   // 100 samples a second
        }
        XCTAssertEqual(rec.samples.count, 4100)
        XCTAssertEqual(rec.sampleRateHz ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(rec.heartRate, 62)
        XCTAssertEqual(rec.hrvRaw, 44)
        XCTAssertEqual(rec.completedAt, 1034)
    }
}

final class EcgSessionTests: XCTestCase {
    func testUnavailableHrvIsIgnored() {
        // A real MG reports 0xFFFF in bytes 29-30 until the value exists.
        let rec = EcgRecorder()
        rec.add(Ecg.filtered(EcgTests.r17(samples: [1], hrvRaw: 0xFFFF))!, at: 0)
        XCTAssertNil(rec.hrvRaw)
        rec.add(Ecg.filtered(EcgTests.r17(samples: [1], hrvRaw: 52))!, at: 1)
        XCTAssertEqual(rec.hrvRaw, 52)
    }

    func testContactTracking() {
        let rec = EcgRecorder()
        rec.add(Ecg.filtered(EcgTests.r17(samples: [1], present: false))!, at: 0)
        XCTAssertNil(rec.contactLostSince)  // never had contact yet
        rec.add(Ecg.filtered(EcgTests.r17(samples: [1], present: true))!, at: 1)
        rec.add(Ecg.filtered(EcgTests.r17(samples: [1], present: false))!, at: 2)
        rec.add(Ecg.filtered(EcgTests.r17(samples: [1], present: false))!, at: 3)
        XCTAssertEqual(rec.contactLostSince, 2)
        rec.add(Ecg.filtered(EcgTests.r17(samples: [1], present: true))!, at: 4)
        XCTAssertNil(rec.contactLostSince)
        XCTAssertTrue(rec.hadContact)
    }

    func testCountdown() {
        XCTAssertEqual(Ecg.secondsLeft(progress: 0), 30)
        XCTAssertEqual(Ecg.secondsLeft(progress: 50), 15)
        XCTAssertEqual(Ecg.secondsLeft(progress: 99), 1)
        XCTAssertEqual(Ecg.secondsLeft(progress: 100), 0)
        XCTAssertEqual(Ecg.secondsLeft(progress: 140), 0)
    }
}

final class EcgBeatsTests: XCTestCase {
    /// A synthetic 100 Hz ECG: sharp QRS spikes every `interval` s, a T wave, baseline wander and noise.
    func trace(bpm: Double, seconds: Double = 30, inverted: Bool = false) -> [Int] {
        let rate = 100.0, interval = 60 / bpm
        var seed: UInt64 = 7
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            let phase = t.truncatingRemainder(dividingBy: interval)
            let qrs = 4000 * exp(-pow((phase - 0.2) / 0.012, 2))
            let tWave = 900 * exp(-pow((phase - 0.45) / 0.06, 2))
            let wander = 1500 * sin(2 * Double.pi * 0.25 * t)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Double(seed >> 33) / Double(1 << 31) - 0.5) * 300
            let v = qrs + tWave + wander + noise
            return Int(inverted ? -v : v)
        }
    }

    func testHeartRateFromTheTrace() {
        for bpm in [48.0, 72.0, 110.0] {
            XCTAssertEqual(Double(EcgBeats.heartRate(trace(bpm: bpm), rateHz: 100) ?? 0), bpm, accuracy: 2, "\(bpm)")
        }
        XCTAssertEqual(Double(EcgBeats.heartRate(trace(bpm: 66, inverted: true), rateHz: 100) ?? 0), 66, accuracy: 2)
    }

    func testFlatOrTooShortGivesNothing() {
        XCTAssertNil(EcgBeats.heartRate(Array(repeating: 0, count: 3000), rateHz: 100))
        XCTAssertNil(EcgBeats.heartRate(trace(bpm: 70, seconds: 3), rateHz: 100))
    }
}

final class EcgHeartRateChoiceTests: XCTestCase {
    func testChoice() {
        XCTAssertEqual(EcgBeats.choose(strap: 70, trace: 62, optical: 66)?.source, "strap")
        // Attempt 2 on a real MG: trace 63, optical 66 → the trace.
        XCTAssertEqual(EcgBeats.choose(strap: 0, trace: 63, optical: 66).map { "\($0.bpm) \($0.source)" }, "63 ecg")
        // A trace that disagrees with the optical heart rate loses to it.
        XCTAssertEqual(EcgBeats.choose(strap: nil, trace: 107, optical: 90).map { "\($0.bpm) \($0.source)" }, "90 optical")
        XCTAssertEqual(EcgBeats.choose(strap: nil, trace: nil, optical: 90)?.source, "optical")
        XCTAssertEqual(EcgBeats.choose(strap: nil, trace: 64, optical: nil)?.source, "ecg")
        XCTAssertNil(EcgBeats.choose(strap: nil, trace: nil, optical: nil))
    }
}
