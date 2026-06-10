// XCUITest screenshot walk of the whole app against the network-free demo boot
// (UITEST_SEED). Drives the custom bottom nav + opens key sub-screens, and
// attaches a screenshot of each for visual review.

import XCTest

final class AppSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
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

    private func tapNav(_ label: String) {
        let b = app.buttons[label].firstMatch
        if b.waitForExistence(timeout: 8) { b.tap() }
        usleep(700_000)
    }

    func testMainScreens() throws {
        _ = app.buttons["Today"].firstMatch.waitForExistence(timeout: 15)
        usleep(800_000)
        snap("01-today")
        tapNav("Tasks");      snap("02-tasks")
        tapNav("Calendar");   snap("03-calendar-day")
        if app.staticTexts["Week"].firstMatch.waitForExistence(timeout: 3) { app.staticTexts["Week"].firstMatch.tap(); usleep(700_000); snap("04-calendar-week") }
        if app.staticTexts["Month"].firstMatch.exists { app.staticTexts["Month"].firstMatch.tap(); usleep(700_000); snap("05-calendar-month") }
        tapNav("Collections"); snap("06-collections")
        if app.staticTexts["Groceries"].firstMatch.waitForExistence(timeout: 4) {
            app.staticTexts["Groceries"].firstMatch.tap(); usleep(800_000); snap("07-collection-detail")
        }
    }

    func testFocus() throws {
        _ = app.buttons["Today"].firstMatch.waitForExistence(timeout: 15)
        usleep(600_000)
        if app.staticTexts["Focus"].firstMatch.waitForExistence(timeout: 4) {
            app.staticTexts["Focus"].firstMatch.tap(); usleep(1_200_000); snap("11-focus")
        }
    }

    /// The in-app Assistant bubble → chat sheet with the voice affordances
    /// (dictate mic + read-aloud toggle), and Feedback still reachable. The
    /// realtime "Talk" button only appears when VOICE_PROXY_URL is configured
    /// (not in the demo boot), so we don't assert it here.
    func testAssistantBubble() throws {
        _ = app.buttons["Today"].firstMatch.waitForExistence(timeout: 15)
        usleep(600_000)
        let bubble = app.buttons["Assistant"].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 6), "assistant bubble missing")
        bubble.tap(); usleep(900_000); snap("12-assistant-chat")
        XCTAssertTrue(app.buttons["Dictate"].firstMatch.waitForExistence(timeout: 4), "dictation mic missing")
        XCTAssertTrue(app.buttons["Read replies aloud"].firstMatch.exists, "read-aloud toggle missing")
        // Feedback surface still reachable via the toggle.
        let feedback = app.buttons["Feedback"].firstMatch
        if feedback.waitForExistence(timeout: 3) { feedback.tap(); usleep(600_000); snap("13-feedback") }
    }

    /// The new Settings depth: the hub links into the Focus + Account sub-screens.
    func testSettingsSubScreens() throws {
        _ = app.buttons["Today"].firstMatch.waitForExistence(timeout: 15)
        usleep(600_000)
        let avatar = app.buttons["U"].firstMatch
        guard avatar.waitForExistence(timeout: 4) else { return }
        avatar.tap(); usleep(800_000)
        if app.staticTexts["Focus"].firstMatch.waitForExistence(timeout: 3) {
            app.staticTexts["Focus"].firstMatch.tap(); usleep(700_000); snap("14-settings-focus")
            if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap(); usleep(500_000) }
        }
        if app.staticTexts["Account"].firstMatch.waitForExistence(timeout: 3) {
            app.staticTexts["Account"].firstMatch.tap(); usleep(700_000); snap("15-settings-account")
        }
    }

    func testSettingsAndInsights() throws {
        _ = app.buttons["Today"].firstMatch.waitForExistence(timeout: 15)
        usleep(600_000)
        let avatar = app.buttons["U"].firstMatch
        if avatar.waitForExistence(timeout: 4) {
            avatar.tap(); usleep(900_000); snap("08-settings")
            let ins = app.staticTexts["Insights"].firstMatch
            if ins.waitForExistence(timeout: 3) {
                ins.tap(); usleep(900_000); snap("09-insights")
                if app.staticTexts["Deep dive"].firstMatch.waitForExistence(timeout: 2) { app.staticTexts["Deep dive"].firstMatch.tap(); usleep(700_000); snap("10-insights-deep") }
            }
        }
    }
}
