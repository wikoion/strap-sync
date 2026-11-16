import XCTest
@testable import SyncCore

/// A night that began before the minutes a caller passes in can't be judged: on 31 Oct the app's 48-h
/// look-back window slid across the 28->29 night, and each pass found it a minute shorter and rewrote it.
final class NightWindowTests: XCTestCase {
    /// 2 h awake, 8 h asleep by the band's flag, 2 h awake, from t0.
    func day(_ t0: Int) -> [MinuteSummary] {
        (0..<720).map { i in
            let asleep = (120..<600).contains(i)
            return MinuteSummary(minute: t0 + i * 60, records: 60, worn: 60, meanHR: asleep ? 52 : 70, motion: 0.01,
                                 sleepFlag: asleep ? 60 : 0, skinTempC: 33)
        }
    }

    func testWholeNightIsFound() {
        let t0 = 1_793_200_000 - 1_793_200_000 % 60
        let nights = Sleep.nights(day(t0), dataUntil: t0 + 720 * 60, now: t0 + 720 * 60)
        XCTAssertEqual(nights.map(\.start), [t0 + 105 * 60])     // `bandLag` before the flag
        XCTAssertEqual(nights.map(\.end), [t0 + 600 * 60])
    }

    func testNightCutByTheWindowIsSkipped() {
        let t0 = 1_793_200_000 - 1_793_200_000 % 60
        // The window starting where the night does (`bandLag` before the flag), at the flag, a minute
        // after, an hour after.
        for cut in [105, 120, 121, 180] {
            let window = Array(day(t0).dropFirst(cut))
            XCTAssertEqual(Sleep.nights(window, dataUntil: t0 + 720 * 60, now: t0 + 720 * 60), [], "window from minute \(cut)")
        }
    }
}
