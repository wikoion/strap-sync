import XCTest
@testable import SyncCore

final class AggregatorTests: XCTestCase {
    let hour = 1_780_912_800  // a whole hour

    func points(_ start: Int, _ count: Int, bpm: Int) -> [HRPoint] {
        (0..<count).map { HRPoint(ts: start + $0, bpm: bpm) }
    }

    func testMinuteNeedsTenReadingsAndMustBeFinished() {
        let live = points(hour, 9, bpm: 60) + points(hour + 60, 30, bpm: 70) + points(hour + 120, 30, bpm: 80)
        let out = Aggregator.heartRateMinutes(live: live, history: [], now: hour + 150)
        XCTAssertEqual(out, [PlannedSample(kind: .heartRate, syncId: "whoopsync:hr:\(hour + 60)", start: hour + 60,
                                           end: hour + 120, value: 70, version: 30)])
    }

    func testHistoryReplacesLiveWithAHigherVersion() {
        let live = points(hour, 60, bpm: 70)
        let history = points(hour, 20, bpm: 64)
        let fromLive = Aggregator.heartRateMinutes(live: live, history: [], now: hour + 3600)[0]
        let fromHistory = Aggregator.heartRateMinutes(live: live, history: history, now: hour + 3600)[0]
        XCTAssertEqual(fromHistory.value, 64)
        XCTAssertGreaterThan(fromHistory.version, fromLive.version)
        XCTAssertEqual(fromHistory.syncId, fromLive.syncId)
    }

    func testMoreReadingsGiveAHigherVersion() {
        let partial = Aggregator.heartRateMinutes(live: [], history: points(hour, 20, bpm: 60), now: hour + 60)[0]
        let full = Aggregator.heartRateMinutes(live: [], history: points(hour, 60, bpm: 60), now: hour + 60)[0]
        XCTAssertGreaterThan(full.version, partial.version)
    }

    /// One beat per second at `ms` (alternating +/- `jitter`) across a 5-minute window.
    func window(_ start: Int, ms: Int, jitter: Int) -> [RRPoint] {
        var out: [RRPoint] = []
        var t = 0
        var i = 0
        while t < 300_000 {
            let v = ms + (i % 2 == 0 ? jitter : -jitter)
            out.append(RRPoint(ts: start + t / 1000, idx: i, ms: v))
            t += v
            i += 1
        }
        return out
    }

    func testHRVPicksTheCalmestWindow() {
        let busy = window(hour, ms: 600, jitter: 10)        // 100 bpm
        let calm = window(hour + 900, ms: 1000, jitter: 50)  // 60 bpm, SDNN 50
        let out = Aggregator.hourlyHRV(live: busy + calm, history: [], now: hour + 3600)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].syncId, "whoopsync:hrv:\(hour)")
        XCTAssertEqual(out[0].start, hour + 900)
        XCTAssertEqual(out[0].end, hour + 1200)
        XCTAssertEqual(out[0].value, 50, accuracy: 0.5)
    }

    func testHRVWaitsForTheHourToFinish() {
        XCTAssertEqual(Aggregator.hourlyHRV(live: window(hour, ms: 1000, jitter: 50), history: [], now: hour + 3599), [])
    }

    func testSparseWindowDoesNotQualify() {
        let sparse = window(hour, ms: 1000, jitter: 50).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        XCTAssertEqual(Aggregator.hourlyHRV(live: sparse, history: [], now: hour + 3600), [])
    }

    func testEctopicBeatsAreFiltered() {
        XCTAssertEqual(Aggregator.cleanIntervals([1000, 1010, 500, 990, 2500, 1500, 1005]), [1000, 1010, 990, 1005])
    }

    func testHourlyWindowHasSdnnAndRmssd() {
        // Alternating ±50 ms: SDNN 50, and each successive difference is 100 ms, so RMSSD 100.
        let out = Aggregator.hourlyWindows(live: window(hour, ms: 1000, jitter: 50), history: [], now: hour + 3600)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].sdnn, 50, accuracy: 0.5)
        XCTAssertEqual(out[0].rmssd!, 100, accuracy: 0.5)
        // The Health sample is the same window's SDNN.
        let health = Aggregator.hourlyHRV(live: window(hour, ms: 1000, jitter: 50), history: [], now: hour + 3600)[0]
        XCTAssertEqual(health.value, out[0].sdnn)
        XCTAssertEqual(health.version, out[0].version)
    }

    func testSuccessiveDifferencesSkipRejectedBeatsAndGaps() {
        let pts = [1000, 1010, 500, 990, 1000, 1005].enumerated().map { RRPoint(ts: hour + $0.offset, idx: 0, ms: $0.element) }
        // 1010-1000; 500 is rejected, so 990 has no pair; then 1000-990 and 1005-1000.
        XCTAssertEqual(Aggregator.successiveDifferences(pts), [10, 10, 5])
        // A record missing between two beats a second apart: no pair across it.
        let gap = [RRPoint(ts: hour, idx: 0, ms: 1000), RRPoint(ts: hour + 2, idx: 0, ms: 1000), RRPoint(ts: hour + 3, idx: 0, ms: 1020)]
        XCTAssertEqual(Aggregator.successiveDifferences(gap), [20])
    }

    func testRmssdNeedsEnoughPairs() {
        // A spurious 200 ms detection after every beat: the beats still cover over 4 minutes, so SDNN qualifies,
        // but no two kept beats are neighbours, so there's no RMSSD.
        var pts: [RRPoint] = []
        var t = 0
        var i = 0
        while t < 300_000 {
            let v = i % 2 == 1 ? 200 : 1000 + (i % 4 == 0 ? 40 : -40)
            pts.append(RRPoint(ts: hour + t / 1000, idx: i, ms: v))
            t += v
            i += 1
        }
        let w = Aggregator.qualifyingWindows(pts)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].sdnn, 40, accuracy: 0.5)
        XCTAssertNil(w[0].rmssd)
    }

    func testHistoryHRVBeatsLive() {
        let live = Aggregator.hourlyHRV(live: window(hour, ms: 1000, jitter: 50), history: [], now: hour + 3600)[0]
        let hist = Aggregator.hourlyHRV(live: window(hour, ms: 1000, jitter: 50),
                                        history: window(hour + 300, ms: 900, jitter: 30), now: hour + 3600)[0]
        XCTAssertEqual(hist.start, hour + 300)
        XCTAssertGreaterThan(hist.version, live.version)
    }

    // MARK: Steady windows and detrended SDNN (8 Nov 2026)

    /// A window whose heart rate drops [drop] bpm for its last fifth, as when a raised heart rate settles.
    func stepWindow(_ start: Int, ms: Int, jitter: Int, drop: Double) -> [RRPoint] {
        let slow = Int((60_000 / (60_000 / Double(ms) - drop)).rounded())
        var out: [RRPoint] = []
        var t = 0
        var i = 0
        while t < 300_000 {
            let v = (t < 240_000 ? ms : slow) + (i % 2 == 0 ? jitter : -jitter)
            out.append(RRPoint(ts: start + t / 1000, idx: i, ms: v))
            t += v
            i += 1
        }
        return out
    }

    func testDetrendMatchesScipy() {
        // Golden values from scipy (sparse solve of (I + 500²D₂ᵀD₂) z = x), research venv, 8 Nov 2026.
        let x = (0..<300).map { i -> Double in
            let d = Double(i)
            return 1000 + 40 * sin(d * 0.9) + 25 * sin(d * 0.05) + 2 * d + 30 * Double((i * 37) % 17 - 8) / 8
        }
        let r = Detrend.smoothnessPriors(x)
        let mean = r.reduce(0, +) / Double(r.count)
        let sd = (r.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(r.count)).squareRoot()
        XCTAssertEqual(sd, 35.0308919647654, accuracy: 1e-6)
        XCTAssertEqual(r[0], -49.05909596793333, accuracy: 1e-6)
        XCTAssertEqual(r[150], 17.75167992110164, accuracy: 1e-6)
        XCTAssertEqual(r[299], -25.95295871611097, accuracy: 1e-6)
        let five = Detrend.smoothnessPriors([1000, 1010, 990, 1020, 980])
        for (a, b) in zip(five, [-5.999971228295976, 6.999988377337672, -10.00002801714379, 22.999975588190523, -13.999964806616049]) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    func testSteadyWindowSdnnBarelyChanges() {
        // Alternating ±50 ms around a steady 60 bpm: nothing slow to remove, so SDNN stays 50.
        let w = Aggregator.qualifyingWindows(window(hour, ms: 1000, jitter: 50))
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].steady)
        XCTAssertEqual(w[0].sdnn, 50, accuracy: 0.5)
    }

    func testAStepInHeartRateIsNotHrv() {
        let step = stepWindow(hour, ms: 833, jitter: 20, drop: 10)
        // The SD of the raw intervals counts the step: well over the 20 ms of beat-to-beat change.
        let raw = Aggregator.cleanIntervals(step.map(\.ms)).map(Double.init)
        let mean = raw.reduce(0, +) / Double(raw.count)
        let rawSD = (raw.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(raw.count)).squareRoot()
        XCTAssertGreaterThan(rawSD, 50)
        let w = Aggregator.qualifyingWindows(step)
        XCTAssertEqual(w.count, 1)
        XCTAssertFalse(w[0].steady)
        XCTAssertLessThan(w[0].sdnn, rawSD * 0.6)
        // With a steady window in the hour, the step's window isn't used, though its mean heart rate is lower.
        let steady = window(hour + 600, ms: 800, jitter: 20)
        let out = Aggregator.hourlyWindows(live: step + steady, history: [], now: hour + 3600)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, hour + 600)
        XCTAssertEqual(out[0].sdnn, 20, accuracy: 0.5)
    }

    func testNoSteadyWindowFallsBackToTheCalmest() {
        let a = stepWindow(hour, ms: 833, jitter: 20, drop: 10)
        let b = stepWindow(hour + 600, ms: 750, jitter: 20, drop: 10)
        let out = Aggregator.hourlyWindows(live: a + b, history: [], now: hour + 3600)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, hour)
    }

    func testTooFewMinutesToJudgeIsNotSteady() {
        // A beat every 3.5 s: over 4 minutes of beat time, but no minute with 20 clean beats.
        let pts = (0..<86).map { RRPoint(ts: hour + $0 * 3 + $0 / 2, idx: 0, ms: 3_000) }
        XCTAssertFalse(Aggregator.isSteady(pts))
    }

    func testNewSdnnReplacesTheOldInHealth() {
        // Samples written before 8 Nov had versions under 200,000 (tier × 100,000 + beats).
        let s = Aggregator.hourlyHRV(live: [], history: window(hour, ms: 1000, jitter: 50), now: hour + 3600)[0]
        XCTAssertGreaterThan(s.version, 199_999)
    }
}
