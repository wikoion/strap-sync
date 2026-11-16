import XCTest
@testable import SyncCore

/// A night asleep 00:00–10:00, downloaded in the morning in one long backlog.
final class SleepDownloadTests: XCTestCase {
    let evening = 1_793_217_600  // 21:00 UTC

    func minutes(_ from: Int, _ to: Int, hr: Double, motion: Double, sleepFlag: Int) -> [MinuteSummary] {
        (from..<to).map {
            MinuteSummary(minute: evening + $0 * 60, records: 60, worn: 60, meanHR: hr, motion: motion,
                          sleepFlag: sleepFlag, skinTempC: 33)
        }
    }

    var night: [MinuteSummary] {
        minutes(0, 180, hr: 75, motion: 0.2, sleepFlag: 0)           // 21:00–00:00 up
            + minutes(180, 780, hr: 55, motion: 0.01, sleepFlag: 60)  // 00:00–10:00 asleep, band flag on
            + minutes(780, 840, hr: 78, motion: 0.3, sleepFlag: 0)    // 10:00–11:00 up
    }

    /// A night's edges: still from 23:52 and until 10:32, but the band flag only 00:11–10:14.
    func testTheBandFlagDefinesTheNightWhenPresent() {
        let real = minutes(0, 172, hr: 80, motion: 0.2, sleepFlag: 0)      // up until 23:52
            + minutes(172, 191, hr: 62, motion: 0.006, sleepFlag: 0)       // 23:52–00:11 still, awake
            + minutes(191, 794, hr: 55, motion: 0.008, sleepFlag: 60)      // 00:11–10:14 band asleep
            + minutes(794, 812, hr: 55, motion: 0.007, sleepFlag: 0)       // 10:14–10:32 lying still
            + minutes(812, 900, hr: 80, motion: 0.3, sleepFlag: 0)         // up
        let n = Sleep.nights(real, dataUntil: evening + 900 * 60, now: evening + 900 * 60)
        // The night opens `bandLag` minutes before the flag, awake, for the stage model to judge.
        XCTAssertEqual(n.map(\.start), [evening + 176 * 60])
        XCTAssertEqual(n.first?.fellAsleep, evening + 191 * 60)
        XCTAssertEqual(n.first?.intervals.first, Sleep.Interval(start: evening + 176 * 60, end: evening + 191 * 60, asleep: false))
        XCTAssertEqual(n.map(\.end), [evening + 794 * 60])
        XCTAssertEqual(n.first?.asleepSeconds, 603 * 60)
        XCTAssertEqual(n.first?.awakenings, 0)
    }

    func testStillnessIsTheFallbackWithoutTheBandFlag() {
        let noFlag = minutes(0, 180, hr: 75, motion: 0.2, sleepFlag: 0)
            + minutes(180, 780, hr: 55, motion: 0.01, sleepFlag: 0)
            + minutes(780, 840, hr: 78, motion: 0.3, sleepFlag: 0)
        XCTAssertEqual(Sleep.nights(noFlag, dataUntil: evening + 840 * 60, now: 0).map(\.start), [evening + 180 * 60])
    }

    func testAHalfDownloadedNightIsNotWritten() {
        // At 10:35 the download had reached 03:30: the night must wait, however late it is.
        let partial = Array(night.prefix(390))
        let now = evening + 815 * 60
        XCTAssertEqual(Sleep.nights(partial, dataUntil: evening + 390 * 60, now: now), [])
    }

    func testTheWholeNightOnceDownloaded() {
        let nights = Sleep.nights(night, dataUntil: evening + 840 * 60, now: evening + 840 * 60)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].start, evening + 165 * 60)
        XCTAssertEqual(nights[0].fellAsleep, evening + 180 * 60)
        XCTAssertEqual(nights[0].end, evening + 780 * 60)
        XCTAssertEqual(nights[0].asleepSeconds, 600 * 60)
    }

    func testARecomputedNightReplacesTheEarlierOne() {
        // What a mid-download pass wrote (00:00–03:00) versus the full night: same sync identifier,
        // higher version, so Health replaces it.
        let early = Sleep.Night(start: evening + 180 * 60, end: evening + 360 * 60,
                                intervals: [.init(start: evening + 180 * 60, end: evening + 360 * 60, asleep: true)])
        let full = Sleep.nights(night, dataUntil: evening + 840 * 60, now: evening + 840 * 60)[0]
        let before = Sleep.samples(for: early, minutes: night, rr: []).filter { $0.kind != .respiratoryRate }
        let after = Sleep.samples(for: full, minutes: night, rr: []).filter { $0.kind != .respiratoryRate }
        for kind in [PlannedSample.Kind.sleep, .restingHR] {
            // For sleep, the asleep sample: the full night also opens with the awake lead-in.
            func pick(_ s: [PlannedSample]) -> PlannedSample { s.first { $0.kind == kind && ($0.kind != .sleep || $0.value == 1) }! }
            let a = pick(before), b = pick(after)
            XCTAssertEqual(a.syncId, b.syncId, "\(kind)")
            XCTAssertGreaterThan(b.version, a.version, "\(kind)")
        }
    }
}
