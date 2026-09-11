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

    /// Tapping "Talk" must actually PRESENT the voice screen. Ahmad, 2026-09-09:
    /// the button was there and tapping it did nothing — the full-screen cover
    /// was attached to a view inside the sheet and never came up. In the demo
    /// boot there is no access token, so the screen opens on its "sign in" note;
    /// that it opens AT ALL is the thing under test.
    func testTalkOpensTheVoiceScreen() throws {
        _ = app.buttons["Today"].firstMatch.waitForExistence(timeout: 15)
        usleep(600_000)
        app.buttons["Assistant"].firstMatch.tap()
        let talk = app.buttons["Talk"].firstMatch
        XCTAssertTrue(talk.waitForExistence(timeout: 6), "the Talk button is missing — voice is unconfigured in this build")
        talk.tap()
        XCTAssertTrue(app.buttons["Close voice mode"].firstMatch.waitForExistence(timeout: 6),
                      "tapping Talk did not present the voice screen")
    }

    /// The ✦ launcher → the Assistant panel: the suggestion card it opens on,
    /// the dictation mic, and the ⋯ options menu (which now carries read-aloud
    /// + Clear conversation). Feedback is NO longer here — it moved to
    /// Settings → Account → "Send feedback".
    func testAssistantPanel() throws {
        _ = app.buttons["Today"].firstMatch.waitForExistence(timeout: 15)
        usleep(600_000)
        let launcher = app.buttons["Assistant"].firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 6), "assistant launcher missing")
        launcher.tap(); usleep(900_000); snap("12-assistant-panel")
        XCTAssertTrue(app.buttons["Dictate"].firstMatch.waitForExistence(timeout: 4), "dictation mic missing")
        XCTAssertTrue(app.staticTexts["ASK UNSTUCK TO HANDLE IT"].firstMatch.exists,
                      "the assistant panel header is missing")
        // The redesigned panel leads with the suggestion card, not a bare input.
        XCTAssertTrue(app.staticTexts["What can I take off your plate?"].firstMatch.exists
                        || app.staticTexts["GETTING STARTED"].firstMatch.exists,
                      "the panel must open on the suggestion card")
        // Feedback must NOT live inside the assistant panel any more.
        XCTAssertFalse(app.buttons["Feedback"].firstMatch.exists,
                       "feedback moved to Settings → Account")
    }

    /// The new Settings depth: the hub links into the Focus + Account sub-screens.
    func testSettingsSubScreens() throws {
        _ = app.buttons["Today"].firstMatch.waitForExistence(timeout: 15)
        usleep(600_000)
        let avatar = app.buttons["Account and settings"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 6), "the Today header avatar is missing")
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
        let avatar = app.buttons["Account and settings"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 6), "the Today header avatar is missing")
        if true {
            avatar.tap(); usleep(900_000); snap("08-settings")
            let ins = app.staticTexts["Insights"].firstMatch
            if ins.waitForExistence(timeout: 3) {
                ins.tap(); usleep(900_000); snap("09-insights")
                if app.staticTexts["Deep dive"].firstMatch.waitForExistence(timeout: 2) { app.staticTexts["Deep dive"].firstMatch.tap(); usleep(700_000); snap("10-insights-deep") }
            }
        }
    }
}
