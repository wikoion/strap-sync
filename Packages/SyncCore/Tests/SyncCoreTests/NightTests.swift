import XCTest
@testable import SyncCore

final class StepsTests: XCTestCase {
    func point(_ ts: Int, _ steps: Int, software: Bool = false) -> MotionPoint {
        MotionPoint(ts: ts, bpm: 70, stepCounter: steps, stepSoftware: software, bandState: 0, motion: 0.1, skinTempC: nil)
    }

    func testDeltasPerMinuteWithWrapAndPrevious() {
        let minute = 1_780_916_100
        let previous = point(minute - 1, 65_530)
        let points = [point(minute, 65_532), point(minute + 1, 65_534), point(minute + 2, 1), point(minute + 61, 5)]
        let out = Steps.perMinute(points, previous: previous)
        // 2 + 2 + 3 in the first minute; the 59 s gap before the last point is skipped.
        XCTAssertEqual(out, [PlannedSample(kind: .steps, syncId: "whoopsync:steps:\(minute)", start: minute,
                                           end: minute + 60, value: 7, version: 3)])
    }

    func testResetsSourceSwitchesAndJumpsAreDropped() {
        let t = 1_780_916_100
        let points = [point(t, 500), point(t + 1, 10), point(t + 2, 12, software: true), point(t + 3, 300, software: true)]
        XCTAssertEqual(Steps.perMinute(points, previous: nil), [])
    }
}

final class RespirationTests: XCTestCase {
    /// Beats with RR modulated by breathing at `breathsPerMinute`, plus deterministic jitter.
    func beats(breathsPerMinute: Double, seconds: Double, depth: Double = 50, jitter: Double = 10) -> [Int] {
        var t = 0.0
        var out: [Int] = []
        var seed: UInt64 = 42
        while t < seconds {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Double(seed >> 33) / Double(1 << 31) - 0.5) * 2 * jitter
            let rr = 1000 + depth * sin(2 * Double.pi * breathsPerMinute / 60 * t) + noise
            out.append(Int(rr))
            t += rr / 1000
        }
        return out
    }

    func testFindsTheBreathingRate() {
        for rate in [9.0, 15.0, 22.0] {
            let r = Respiration.rate(beats(breathsPerMinute: rate, seconds: 300))
            XCTAssertEqual(r?.breathsPerMinute ?? 0, rate, accuracy: 0.6, "\(rate)")
        }
    }

    func testNoiseGivesNothing() {
        XCTAssertNil(Respiration.rate(beats(breathsPerMinute: 15, seconds: 300, depth: 0, jitter: 40)))
    }

    func testTooShortGivesNothing() {
        XCTAssertNil(Respiration.rate(beats(breathsPerMinute: 15, seconds: 40)))
    }
}

final class SleepTests: XCTestCase {
    let evening = 1_780_941_600  // 18:00 UTC

    /// Minutes from `from` to `to` (minutes after `evening`) with the given HR and motion.
    func minutes(_ from: Int, _ to: Int, hr: Double, motion: Double) -> [MinuteSummary] {
        (from..<to).map {
            MinuteSummary(minute: evening + $0 * 60, records: 60, worn: 60, meanHR: hr, motion: motion, sleepFlag: 0, skinTempC: 33)
        }
    }

    /// Up at 18:00, asleep 23:00–07:00 with 5 restless minutes at 03:00, up again until 09:00.
    var day: [MinuteSummary] {
        minutes(0, 300, hr: 78, motion: 0.15)
            + minutes(300, 540, hr: 55, motion: 0.008)
            + minutes(540, 545, hr: 70, motion: 0.2)
            + minutes(545, 780, hr: 52, motion: 0.01)
            + minutes(780, 900, hr: 80, motion: 0.2)
    }

    func testFindsTheNightAndTheAwakening() {
        let nights = Sleep.nights(day, dataUntil: evening + 900 * 60, now: evening + 900 * 60)
        XCTAssertEqual(nights.count, 1)
        let n = nights[0]
        XCTAssertEqual(n.start, evening + 300 * 60)
        XCTAssertEqual(n.end, evening + 780 * 60)
        XCTAssertEqual(n.intervals, [
            Sleep.Interval(start: evening + 300 * 60, end: evening + 540 * 60, asleep: true),
            Sleep.Interval(start: evening + 540 * 60, end: evening + 545 * 60, asleep: false),
            Sleep.Interval(start: evening + 545 * 60, end: evening + 780 * 60, asleep: true),
        ])
    }

    func testWaitsUntilTheNightIsOver() {
        // Lying awake in bed (not still enough to be rest, not moving about) for ten minutes: not over yet.
        let inBed = Array(day.prefix(780)) + minutes(780, 900, hr: 70, motion: 0.03)
        func nights(after m: Int) -> [Int] {
            Sleep.nights(Array(inBed.prefix(m)), dataUntil: evening + m * 60, now: evening + m * 60).map(\.end)
        }
        XCTAssertEqual(nights(after: 790), [])
        XCTAssertEqual(Sleep.open(Array(inBed.prefix(790)), dataUntil: evening + 790 * 60)?.awake, true)
        // Twelve minutes: rest now would start a new block, so the night's end is fixed and it's written.
        XCTAssertEqual(nights(after: 792), [evening + 780 * 60])
    }

    func testUpAndAboutEndsTheNightSooner() {
        // `day` has you moving about from 07:00: five minutes of that is enough.
        XCTAssertEqual(Sleep.nights(Array(day.prefix(784)), dataUntil: evening + 784 * 60, now: 0), [])
        XCTAssertEqual(Sleep.nights(Array(day.prefix(785)), dataUntil: evening + 785 * 60, now: 0).map(\.end), [evening + 780 * 60])
        // Still asleep at the end of the data: the night is open, not over.
        let asleep = Array(day.prefix(700))
        XCTAssertEqual(Sleep.nights(asleep, dataUntil: evening + 700 * 60, now: 0), [])
        let open = Sleep.open(asleep, dataUntil: evening + 700 * 60)
        XCTAssertEqual(open?.night.start, evening + 300 * 60)
        XCTAssertEqual(open?.awake, false)
    }

    func testBackAsleepAfterGettingUpGrowsTheNight() {
        // Up at 03:00 for six minutes, walking, then asleep again until 07:00.
        let trip = minutes(0, 300, hr: 78, motion: 0.15) + minutes(300, 480, hr: 55, motion: 0.008)
            + minutes(480, 486, hr: 75, motion: 0.2) + minutes(486, 780, hr: 52, motion: 0.01) + minutes(780, 900, hr: 80, motion: 0.2)
        // Five minutes into the trip it looks like the morning, so the night so far is written...
        XCTAssertEqual(Sleep.nights(Array(trip.prefix(485)), dataUntil: evening + 485 * 60, now: 0).map(\.end), [evening + 480 * 60])
        // ...and once you're back asleep it's the same night, longer, with the trip as an awakening.
        let whole = Sleep.nights(trip, dataUntil: evening + 900 * 60, now: 0)
        XCTAssertEqual(whole.map(\.start), [evening + 300 * 60])
        XCTAssertEqual(whole.map(\.end), [evening + 780 * 60])
        XCTAssertEqual(whole.first?.awakenings, 1)
    }

    func testSittingStillWithAWakingHeartRateIsNotSleep() {
        let sofa = minutes(0, 120, hr: 70, motion: 0.15) + minutes(120, 360, hr: 72, motion: 0.01) + minutes(360, 480, hr: 70, motion: 0.15)
        XCTAssertEqual(Sleep.nights(sofa, dataUntil: evening + 480 * 60, now: evening + 480 * 60), [])
    }

    func testRestingHeartRateAndBreathing() {
        let night = Sleep.nights(day, dataUntil: evening + 900 * 60, now: evening + 900 * 60)[0]
        // Calm beats for one fully asleep hour, 01:00–02:00, breathing at 14/min.
        let hour = evening + 420 * 60
        var rr: [RRPoint] = []
        var t = 0.0
        var i = 0
        while t < 3600 {
            let ms = 1000 + 50 * sin(2 * Double.pi * 14 / 60 * t)
            rr.append(RRPoint(ts: hour + Int(t), idx: i, ms: Int(ms)))
            t += ms / 1000
            i += 1
        }
        let out = Sleep.samples(for: night, minutes: day, rr: rr)
        XCTAssertEqual(out.filter { $0.kind == .sleep }.count, 3)
        let rhr = out.first { $0.kind == .restingHR }
        XCTAssertEqual(rhr?.value, 52)
        let resp = out.filter { $0.kind == .respiratoryRate }
        XCTAssertEqual(resp.count, 1)
        XCTAssertEqual(resp.first?.value ?? 0, 14, accuracy: 0.6)
        XCTAssertEqual(resp.first?.start, hour)
    }

    func testMinuteSummary() {
        let points = [
            MotionPoint(ts: 120, bpm: 60, stepCounter: 0, stepSoftware: false, bandState: 2, motion: 0.01, skinTempC: 33),
            MotionPoint(ts: 150, bpm: 0, stepCounter: 0, stepSoftware: false, bandState: 0, motion: 0.03, skinTempC: 22),
            MotionPoint(ts: 181, bpm: 70, stepCounter: 0, stepSoftware: false, bandState: 0, motion: nil, skinTempC: nil),
        ]
        XCTAssertEqual(MinuteSummary.summarise(points), [
            MinuteSummary(minute: 120, records: 2, worn: 1, meanHR: 60, motion: 0.02, sleepFlag: 1, skinTempC: 33),
            MinuteSummary(minute: 180, records: 1, worn: 1, meanHR: 70, motion: nil, sleepFlag: 0, skinTempC: nil),
        ])
    }
}

final class OximetryTests: XCTestCase {
    /// A made-up run shaped like the MG's, one reading a second: a five-reading lock-on ramp, then steady
    /// readings (min 97, median 98).
    let run = [86, 89, 92, 94, 96] + Array(repeating: 97, count: 6) + Array(repeating: 98, count: 13)
        + Array(repeating: 99, count: 6)

    func testRampDroppedAndSentinelsBridged() {
        var points: [(ts: Int, raw: Int)] = []
        for (i, v) in run.enumerated() {
            points.append((1000 + 2 * i, v))
            points.append((1001 + 2 * i, i % 3 == 0 ? 0xA0 : 32))  // sentinels and codes in between
        }
        let runs = Oximetry.runs(points)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].start, 1000)
        XCTAssertEqual(runs[0].values.count, 25)
        XCTAssertEqual(runs[0].values.min(), 97)
        XCTAssertEqual(runs[0].median, 98)
        XCTAssertEqual(Oximetry.samples(runs), [PlannedSample(kind: .spo2, syncId: "whoopsync:spo2:1000", start: 1000,
                                                              end: 1059, value: 98, version: 25)])
    }

    func testRunsSplitOnAMinuteGapAndShortRunsDropped() {
        let first = run.enumerated().map { (ts: 1000 + $0.offset, raw: $0.element) }
        let second = run.enumerated().map { (ts: 2200 + $0.offset, raw: $0.element) }
        let blip = (0..<8).map { (ts: 4000 + $0, raw: 95) }
        XCTAssertEqual(Oximetry.runs(first + second + blip).map(\.start), [1000, 2200])
    }

    func testCapturedDaytimeFrameHasNoReading() {
        guard case .record(let r)? = Whoop5Message.parse(Captured.r18) else { return XCTFail() }
        XCTAssertEqual(r.spo2Raw, 0)
        var f = Captured.r18
        f[82] = 96
        guard case .record(let r2)? = Whoop5Message.parse(f) else { return XCTFail() }
        XCTAssertEqual(r2.spo2Raw, 96)
    }
}
