import XCTest
@testable import SyncCore

/// Waking in the night, by the band's flag. Before `maxWake`, a night like these lost part of its sleep: the
/// band's blocks were split at 10 minutes awake and the shorter one dropped.
final class WakeUpTests: XCTestCase {
    let evening = 1_793_829_600  // 22:00 UTC

    func minutes(_ from: Int, _ to: Int, hr: Double, motion: Double, flag: Bool) -> [MinuteSummary] {
        (from..<to).map {
            MinuteSummary(minute: evening + $0 * 60, records: 60, worn: 60, meanHR: hr, motion: motion,
                          sleepFlag: flag ? 60 : 0, skinTempC: 33)
        }
    }

    func at(_ m: Int) -> Int { evening + m * 60 }

    /// Still from 00:27, flagged 01:03-02:47, 26 minutes awake, flagged 03:13-09:00.
    var wakeUpNight: [MinuteSummary] {
        minutes(0, 147, hr: 75, motion: 0.2, flag: false)                  // up until 00:27
            + minutes(147, 183, hr: 58, motion: 0.008, flag: false)        // still, not yet flagged
            + minutes(183, 287, hr: 55, motion: 0.007, flag: true)         // 01:03-02:47
            + minutes(287, 290, hr: 74, motion: 0.16, flag: false)         // a turn
            + minutes(290, 313, hr: 52, motion: 0.007, flag: false)        // still again, not yet flagged
            + minutes(313, 660, hr: 52, motion: 0.007, flag: true)         // 03:13-09:00
            + minutes(660, 720, hr: 85, motion: 0.3, flag: false)          // up
    }

    func testAWakeUpInTheNightKeepsBothParts() {
        let n = Sleep.nights(wakeUpNight, dataUntil: at(720), now: at(720))
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n.first?.start, at(168))           // 00:48, `bandLag` before the flag
        XCTAssertEqual(n.first?.fellAsleep, at(183))
        XCTAssertEqual(n.first?.end, at(660))
        XCTAssertEqual(n.first?.intervals, [
            Sleep.Interval(start: at(168), end: at(183), asleep: false),
            Sleep.Interval(start: at(183), end: at(287), asleep: true),
            Sleep.Interval(start: at(287), end: at(313), asleep: false),
            Sleep.Interval(start: at(313), end: at(660), asleep: true),
        ])
        XCTAssertEqual(n.first?.awakenings, 1)
        XCTAssertEqual(n.first?.asleepSeconds, (104 + 347) * 60)
    }

    func testTheFirstPartAloneIsNotANight() {
        // At 03:05 there's 1 h 44 of flagged sleep: neither a night to write nor one under way.
        let soFar = Array(wakeUpNight.prefix(305))
        XCTAssertEqual(Sleep.nights(soFar, dataUntil: at(305), now: 0), [])
        XCTAssertNil(Sleep.open(soFar, dataUntil: at(305)))
        // By 05:00 it is under way, asleep since the first flag.
        let open = Sleep.open(Array(wakeUpNight.prefix(420)), dataUntil: at(420))
        XCTAssertEqual(open?.night.fellAsleep, at(183))
        XCTAssertEqual(open?.awake, false)
    }

    /// Flagged 00:20-06:10, up 3 minutes, still 15, flagged again 06:28-08:31.
    var morningTripNight: [MinuteSummary] {
        minutes(0, 125, hr: 75, motion: 0.2, flag: false)
            + minutes(125, 140, hr: 60, motion: 0.008, flag: false)
            + minutes(140, 490, hr: 54, motion: 0.007, flag: true)         // 00:20-06:10
            + minutes(490, 493, hr: 72, motion: 0.1, flag: false)          // up
            + minutes(493, 508, hr: 55, motion: 0.007, flag: false)        // back in bed
            + minutes(508, 631, hr: 52, motion: 0.007, flag: true)         // 06:28-08:31
            + minutes(631, 720, hr: 85, motion: 0.3, flag: false)
    }

    func testBackAsleepAfterTheMorningTripGrowsTheNight() {
        // At 06:15 it looks like the morning, so the night so far is written...
        let early = Sleep.nights(Array(morningTripNight.prefix(495)), dataUntil: at(495), now: 0)
        XCTAssertEqual(early.map(\.start), [at(125)])
        XCTAssertEqual(early.map(\.end), [at(490)])
        // ...back asleep 18 minutes later, it's the same night (same start, so the app rewrites it), longer.
        let whole = Sleep.nights(morningTripNight, dataUntil: at(720), now: at(720))
        XCTAssertEqual(whole.map(\.start), [at(125)])
        XCTAssertEqual(whole.map(\.end), [at(631)])
        XCTAssertEqual(whole.first?.awakenings, 1)
        XCTAssertEqual(whole.first?.asleepSeconds, (350 + 123) * 60)
    }

    /// Two 3-hour blocks `gap` minutes apart, with 2 hours up either side.
    func split(gap: Int) -> (minutes: [MinuteSummary], end: Int) {
        let b = 120 + 180 + gap
        let ms = minutes(0, 120, hr: 80, motion: 0.2, flag: false)
            + minutes(120, 300, hr: 54, motion: 0.007, flag: true)
            + minutes(300, b, hr: 70, motion: 0.1, flag: false)
            + minutes(b, b + 180, hr: 54, motion: 0.007, flag: true)
            + minutes(b + 180, b + 300, hr: 80, motion: 0.2, flag: false)
        return (ms, at(b + 300))
    }

    func testAnHourAwakeIsStillTheSameNight() {
        let (ms, end) = split(gap: Sleep.maxWake)
        XCTAssertEqual(Sleep.nights(ms, dataUntil: end, now: end).count, 1)
        let (ms2, end2) = split(gap: Sleep.maxWake + 1)
        XCTAssertEqual(Sleep.nights(ms2, dataUntil: end2, now: end2).map(\.fellAsleep), [at(120), at(300 + Sleep.maxWake + 1)])
    }

    /// Flagged 23:38-04:34, up for 15 minutes, then lying in bed 82 minutes in all at a sleeping heart
    /// rate, flagged again 05:56-07:29.
    var quietGapNight: [MinuteSummary] {
        minutes(0, 83, hr: 64, motion: 0.04, flag: false)                  // reading in bed
            + minutes(83, 98, hr: 58, motion: 0.015, flag: false)          // still, not yet flagged
            + minutes(98, 394, hr: 55, motion: 0.008, flag: true)          // 23:38-04:34
            + minutes(394, 409, hr: 86, motion: 0.05, flag: false)         // up
            + minutes(409, 476, hr: 55, motion: 0.018, flag: false)        // back in bed
            + minutes(476, 569, hr: 55, motion: 0.015, flag: true)         // 05:56-07:29
            + minutes(569, 660, hr: 75, motion: 0.2, flag: false)          // up
    }

    func testLyingInBedForAnHourAndAHalfIsStillTheSameNight() {
        // Written at 04:50, once up...
        let early = Sleep.nights(Array(quietGapNight.prefix(410)), dataUntil: at(410), now: 0)
        XCTAssertEqual(early.map(\.start), [at(83)])
        XCTAssertEqual(early.map(\.end), [at(394)])
        // ...and the same night, longer, after the second part: before, those 93 minutes were dropped.
        let whole = Sleep.nights(quietGapNight, dataUntil: at(660), now: at(660))
        XCTAssertEqual(whole.map(\.start), [at(83)])
        XCTAssertEqual(whole.map(\.end), [at(569)])
        XCTAssertEqual(whole.first?.awakenings, 1)
        XCTAssertEqual(whole.first?.asleepSeconds, (296 + 93) * 60)
    }

    func testAQuietGapJoinsOnlyUpToTwoHours() {
        func quiet(_ gap: Int) -> [MinuteSummary] {
            let b = 120 + 180 + gap
            return minutes(0, 120, hr: 80, motion: 0.2, flag: false) + minutes(120, 300, hr: 54, motion: 0.007, flag: true)
                + minutes(300, b, hr: 60, motion: 0.02, flag: false) + minutes(b, b + 90, hr: 54, motion: 0.007, flag: true)
                + minutes(b + 90, b + 210, hr: 80, motion: 0.2, flag: false)
        }
        let ms = quiet(Sleep.maxQuietWake)
        XCTAssertEqual(Sleep.nights(ms, dataUntil: at(510 + Sleep.maxQuietWake), now: 0).map(\.end),
                       [at(300 + Sleep.maxQuietWake + 90)])
        // A minute more and the second part is its own block, too short to be a night.
        let ms2 = quiet(Sleep.maxQuietWake + 1)
        XCTAssertEqual(Sleep.nights(ms2, dataUntil: at(511 + Sleep.maxQuietWake), now: 0).map(\.end), [at(300)])
    }

    func testADozeAfterGettingUpIsNotTheNight() {
        // Up and about at a waking heart rate for 90 minutes, then 90 minutes flagged: not joined.
        let ms = minutes(0, 120, hr: 80, motion: 0.2, flag: false) + minutes(120, 600, hr: 54, motion: 0.007, flag: true)
            + minutes(600, 690, hr: 78, motion: 0.15, flag: false) + minutes(690, 780, hr: 56, motion: 0.007, flag: true)
            + minutes(780, 900, hr: 80, motion: 0.2, flag: false)
        XCTAssertEqual(Sleep.nights(ms, dataUntil: at(900), now: 0).map(\.end), [at(600)])
    }

    func testAGapWithTheStrapOffIsNotJoined() {
        // The strap off (no heart rate) for most of a 90-minute gap.
        let off = (300..<390).map {
            MinuteSummary(minute: evening + $0 * 60, records: 60, worn: $0 < 330 ? 60 : 0, meanHR: $0 < 330 ? 56 : nil,
                          motion: 0.01, sleepFlag: 0, skinTempC: nil)
        }
        let ms = minutes(0, 120, hr: 80, motion: 0.2, flag: false) + minutes(120, 300, hr: 54, motion: 0.007, flag: true)
            + off + minutes(390, 480, hr: 54, motion: 0.007, flag: true) + minutes(480, 600, hr: 80, motion: 0.2, flag: false)
        XCTAssertEqual(Sleep.nights(ms, dataUntil: at(600), now: 0).map(\.end), [at(300)])
    }

    func testStillnessAloneStillSplitsAtTenMinutes() {
        // Without the band's flag, the night's edges and bridges are unchanged.
        let ms = (minutes(0, 120, hr: 80, motion: 0.2, flag: false) + minutes(120, 330, hr: 54, motion: 0.007, flag: false)
            + minutes(330, 350, hr: 70, motion: 0.1, flag: false) + minutes(350, 560, hr: 54, motion: 0.007, flag: false)
            + minutes(560, 700, hr: 80, motion: 0.2, flag: false))
        let n = Sleep.nights(ms, dataUntil: at(700), now: at(700))
        XCTAssertEqual(n.map(\.start), [at(120), at(350)])
    }

    /// Flagged 22:41-02:13, a turn, the flag off for 28 minutes lying still, flagged again 02:41-08:23. The night
    /// Health had 3 h 33 of when the phone was unlocked at 08:19, and the whole of only once up.
    var secondSleepNight: [MinuteSummary] {
        minutes(0, 26, hr: 75, motion: 0.2, flag: false)                   // up until 22:26
            + minutes(26, 41, hr: 58, motion: 0.008, flag: false)          // still, not yet flagged
            + minutes(41, 253, hr: 52, motion: 0.007, flag: true)          // 22:41-02:13
            + minutes(253, 255, hr: 68, motion: 0.1, flag: false)          // a turn
            + minutes(255, 281, hr: 50, motion: 0.007, flag: false)        // still again, not yet flagged
            + minutes(281, 623, hr: 50, motion: 0.007, flag: true)         // 02:41-08:23
            + minutes(623, 660, hr: 85, motion: 0.3, flag: false)          // up
    }

    func testANightWrittenInTheSmallHoursIsWrittenAgainAsFarAsItHasGot() {
        let start = at(26)
        // 02:27, twelve minutes after the flag went off: the night is written as over.
        let small = Array(secondSleepNight.prefix(267))
        let early = Sleep.nights(small, dataUntil: at(267), now: 0)
        XCTAssertEqual(early.map(\.start), [start])
        XCTAssertEqual(early.map(\.end), [at(253)])
        XCTAssertNil(Sleep.soFar(small))
        XCTAssertEqual(Sleep.due(finished: early, soFar: nil, doneUntil: 0, lastStart: nil), early)
        // 08:19, asleep again since 02:41: no finished night, and the one written is six hours short.
        let morning = Array(secondSleepNight.prefix(619))
        XCTAssertEqual(Sleep.nights(morning, dataUntil: at(619), now: 0), [])
        let soFar = Sleep.soFar(morning)
        XCTAssertEqual(soFar?.start, start)
        XCTAssertEqual(soFar?.end, at(618))
        XCTAssertEqual(soFar?.asleepSeconds, (212 + 337) * 60)
        // The phone locked, Health can't be written and nothing is staged; unlocked, the night so far is, once.
        XCTAssertEqual(Sleep.due(finished: [], soFar: nil, doneUntil: at(253), lastStart: start), [])
        XCTAssertEqual(Sleep.due(finished: [], soFar: soFar, doneUntil: at(253), lastStart: start), [soFar!])
        XCTAssertEqual(Sleep.due(finished: [], soFar: soFar, doneUntil: at(618), lastStart: start), [])
        // Up at 08:23: the whole night replaces it.
        let whole = Sleep.nights(secondSleepNight, dataUntil: at(660), now: 0)
        XCTAssertEqual(whole.map(\.end), [at(623)])
        XCTAssertEqual(Sleep.due(finished: whole, soFar: nil, doneUntil: at(618), lastStart: start), whole)
    }

    func testTheNightSoFarLeavesOutTheMinuteStillFilling() {
        // 20 s of the newest minute have arrived, asleep; the other 40 could yet be awake.
        var ms = Array(secondSleepNight.prefix(400))
        ms[399] = MinuteSummary(minute: at(399), records: 20, worn: 20, meanHR: 50, motion: 0.007, sleepFlag: 20, skinTempC: 33)
        XCTAssertEqual(Sleep.open(ms, dataUntil: at(400))?.night.end, at(400))
        XCTAssertEqual(Sleep.soFar(ms)?.end, at(399))
    }

    func testThereIsNoNightSoFarOnceItsOverOrBeforeItsLongEnough() {
        XCTAssertNil(Sleep.soFar(secondSleepNight))                      // up since 08:23
        XCTAssertNil(Sleep.soFar(Array(secondSleepNight.prefix(200))))   // 2 h 39 flagged
        XCTAssertNil(Sleep.soFar([]))
    }

    func testANightNotYetWrittenWaitsUntilItsOver() {
        // No version of it to replace: the last night written was the one before.
        let soFar = Sleep.soFar(Array(secondSleepNight.prefix(619)))
        XCTAssertNotNil(soFar)
        XCTAssertEqual(Sleep.due(finished: [], soFar: soFar, doneUntil: at(-840), lastStart: at(-1320)), [])
        XCTAssertEqual(Sleep.due(finished: [], soFar: soFar, doneUntil: 0, lastStart: nil), [])
    }

    func testTheWholeNightIsntWrittenTwice() {
        // Unlocked at 08:26, awake since 08:23 but not yet surely up: the night so far already runs to its end,
        // so the finished night is the one written, and isn't written again.
        let soFar = Sleep.soFar(Array(secondSleepNight.prefix(626)))
        let whole = Sleep.nights(secondSleepNight, dataUntil: at(660), now: 0)
        XCTAssertEqual(whole, [soFar].compactMap { $0 })
        XCTAssertEqual(whole.count, 1)
        XCTAssertEqual(Sleep.due(finished: whole, soFar: nil, doneUntil: at(623), lastStart: at(26)), [])
    }

    func testAFinishedNightIsWrittenRatherThanTheSameNightSoFar() {
        // The newest minute tips the night over; without it, it's still under way. The finished one is written.
        let whole = Sleep.nights(secondSleepNight, dataUntil: at(660), now: 0)
        let soFar = Sleep.soFar(Array(secondSleepNight.prefix(619)))
        XCTAssertEqual(Sleep.due(finished: whole, soFar: soFar, doneUntil: at(253), lastStart: at(26)), whole)
    }
}
