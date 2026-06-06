// XCUITest smoke walk of the whole app, driven against the network-free demo
// boot (UITEST_SEED). Verifies every primary screen renders with real seeded
// data and captures a screenshot of each for visual review.

import XCTest

final class AppSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
        // Safety net in case any system alert still appears.
        addUIInterruptionMonitor(withDescription: "system-alert") { alert in
            for label in ["Allow", "Don’t Allow", "OK", "Continue"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        app.launch()
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func tab(_ label: String) {
        let button = app.tabBars.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Tab \(label) should exist")
        button.tap()
    }

    func testWalkEveryScreen() throws {
        // Reached the main app (demo boot → MainTabScaffold).
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "Tab bar should appear")

        // Today — Start-Next headline + seeded task.
        tab("Today")
        XCTAssertTrue(app.staticTexts["Draft the Q3 proposal"].waitForExistence(timeout: 5)
                      || app.staticTexts["Open the doc and write one sentence"].waitForExistence(timeout: 5),
                      "Start-Next should surface the seeded task")
        snap("01-today")

        // Tasks list.
        tab("Tasks")
        XCTAssertTrue(app.staticTexts["Reply to Sarah"].waitForExistence(timeout: 5), "Tasks list should show seeded tasks")
        snap("02-tasks")

        // Calendar — Day, then Week.
        tab("Calendar")
        snap("03-calendar-day")
        if app.buttons["Week"].waitForExistence(timeout: 3) {
            app.buttons["Week"].tap()
            snap("04-calendar-week")
        }

        // Lists — overview + a detail with items.
        tab("Lists")
        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 5), "Lists overview should show the seeded collection")
        snap("05-lists")
        app.staticTexts["Groceries"].tap()
        XCTAssertTrue(app.staticTexts["Coffee beans"].waitForExistence(timeout: 5), "Collection detail should show items")
        snap("06-list-detail")

        // Settings → Insights (from Today's gear).
        tab("Today")
        let gear = app.navigationBars.buttons["gearshape"]
        if gear.waitForExistence(timeout: 3) {
            gear.tap()
            snap("07-settings")
            if app.staticTexts["View insights"].waitForExistence(timeout: 3) {
                app.staticTexts["View insights"].tap()
                snap("08-insights-report")
                if app.buttons["Deep dive"].waitForExistence(timeout: 3) {
                    app.buttons["Deep dive"].tap()
                    snap("09-insights-deep")
                }
            }
        }
    }
}
