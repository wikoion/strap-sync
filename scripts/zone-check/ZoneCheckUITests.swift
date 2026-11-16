import XCTest

/// Launches the app's zone check (App/WhoopSync/Support/ZoneCheck.swift), allows Health access when it asks, and
/// fails unless the check passes.
final class ZoneCheckUITests: XCTestCase {
    func testZoneRedoAgainstHealth() {
        let app = XCUIApplication()
        app.launchArguments = ["-zoneCheck", "YES"]
        app.launch()
        let result = app.staticTexts["zoneCheckResult"]
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            for label in ["Turn On All", "Turn On All Categories"] {
                if app.buttons[label].exists { app.buttons[label].tap() } else if app.staticTexts[label].exists { app.staticTexts[label].tap() }
            }
            let allow = app.navigationBars.buttons["Allow"]
            if allow.exists, allow.isEnabled { allow.tap() }
            if result.exists, result.label.hasPrefix("PASS") || result.label.hasPrefix("FAIL") { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        for line in result.label.split(separator: "\n") { print("ZONECHECK \(line)") }
        XCTAssertTrue(result.label.hasPrefix("PASS"), result.label)
    }
}
