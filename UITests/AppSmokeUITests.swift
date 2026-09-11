// XCUITest screenshot walk of the whole app against the network-free demo boot
// (UITEST_SEED). Drives the custom bottom nav + opens key sub-screens, and
// attaches a screenshot of each for visual review.
//
// Every step ASSERTS. These used to be written as `if element.exists { … }`,
// which turned a missing screen into a silent pass — the suite reported green
// while `testSettingsSubScreens` had not opened Settings in months. A smoke
// test that cannot fail is worse than no smoke test.
//
// One rule worth remembering here: Settings is a SHEET over Today, so its rows
// share ONE accessibility tree with the Today screen behind them and bare
// labels collide ("Focus" is both a Settings row and the Start-Next hero's
// button). Address rows by identifier — `settings-row-<label>`.

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

    /// Wait for the app to finish its demo boot (the bottom nav is the signal).
    private func launchToToday(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 15),
                      "the demo boot never reached Today", file: file, line: line)
        usleep(700_000)
    }

    private func tapNav(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let b = app.buttons[label].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 8), "bottom nav '\(label)' is missing",
                      file: file, line: line)
        b.tap()
        usleep(700_000)
    }

    private func expect(_ e: XCUIElement, _ why: String,
                        timeout: TimeInterval = 6,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), why, file: file, line: line)
    }

    /// Scroll `e` into reach. Today's Start-Next hero renders UNDER the AI
    /// gateway card, so on a fresh launch its Focus button lands in the bottom
    /// ~100pt that the FLOATING bottom nav covers — and XCUITest still calls
    /// elements under that nav `isHittable`, so tapping one silently hits the
    /// nav instead (that is how `testFocus` used to "pass" while starting no
    /// session). Require the element to clear the nav, not merely to exist.
    @discardableResult
    private func scrollIntoReach(_ e: XCUIElement, swipes: Int = 8) -> Bool {
        let clearOfFloatingNav = { e.exists && e.isHittable && e.frame.maxY < self.app.frame.height - 110 }
        for _ in 0..<swipes {
            if clearOfFloatingNav() { return true }
            app.swipeUp(); usleep(500_000)
        }
        return clearOfFloatingNav()
    }

    func testMainScreens() throws {
        launchToToday()
        snap("01-today")

        tapNav("Tasks")
        expect(app.staticTexts["Your tasks"].firstMatch, "the Tasks tab did not switch")
        snap("02-tasks")

        tapNav("Calendar")
        // Day / Week / Month are Buttons carrying an explicit accessibilityLabel.
        expect(app.buttons["Day"].firstMatch, "the Calendar tab did not switch")
        snap("03-calendar-day")
        let week = app.buttons["Week"].firstMatch
        XCTAssertTrue(week.exists, "the Calendar Week segment is missing")
        week.tap(); usleep(700_000); snap("04-calendar-week")
        let month = app.buttons["Month"].firstMatch
        XCTAssertTrue(month.exists, "the Calendar Month segment is missing")
        month.tap(); usleep(700_000); snap("05-calendar-month")

        tapNav("Collections")
        // "Groceries" is seeded by DemoSeed — its presence proves both that the
        // tab switched and that the store hydrated.
        let groceries = app.staticTexts["Groceries"].firstMatch
        expect(groceries, "the Collections tab did not switch (no seeded list)")
        snap("06-collections")
        groceries.tap(); usleep(800_000)
        expect(app.staticTexts["Milk"].firstMatch, "the collection detail did not open")
        snap("07-collection-detail")
    }

    /// Today's primary CTA: the Start-Next hero's Focus button really starts a
    /// session. (It renders below the AI gateway card, so this also pins the
    /// fact that it is reachable at all — by scrolling.)
    func testFocus() throws {
        launchToToday()
        let heroFocus = app.buttons["Focus"].firstMatch
        expect(heroFocus, "the seeded Today should show the Start-Next hero")
        XCTAssertTrue(scrollIntoReach(heroFocus),
                      "the Start-Next hero's Focus button never became reachable on Today")
        heroFocus.tap()
        XCTAssertTrue(app.staticTexts["FOCUSING"].firstMatch.waitForExistence(timeout: 8),
                      "tapping the hero's Focus did not start a session")
        usleep(700_000)
        snap("11-focus")
    }

    /// Tapping "Talk" must actually PRESENT the voice screen. Ahmad, 2026-09-09:
    /// the button was there and tapping it did nothing — the full-screen cover
    /// was attached to a view inside the sheet and never came up. In the demo
    /// boot there is no access token, so the screen opens on its "sign in" note;
    /// that it opens AT ALL is the thing under test.
    func testTalkOpensTheVoiceScreen() throws {
        launchToToday()
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
        launchToToday()
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
        launchToToday()
        let avatar = app.buttons["Account and settings"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 6), "the Today header avatar is missing")
        avatar.tap(); usleep(800_000)

        let focusRow = app.buttons["settings-row-Focus"].firstMatch
        expect(focusRow, "Settings hub is missing the Focus row")
        focusRow.tap()
        expect(app.staticTexts["How focus mode behaves."].firstMatch, "Settings → Focus did not open")
        snap("14-settings-focus")
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.exists, "no back button out of Settings → Focus")
        back.tap(); usleep(600_000)

        let accountRow = app.buttons["settings-row-Account"].firstMatch
        expect(accountRow, "Settings hub is missing the Account row")
        accountRow.tap()
        expect(app.staticTexts["Your account."].firstMatch, "Settings → Account did not open")
        snap("15-settings-account")
    }

    func testSettingsAndInsights() throws {
        launchToToday()
        let avatar = app.buttons["Account and settings"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 6), "the Today header avatar is missing")
        avatar.tap(); usleep(900_000)
        expect(app.buttons["settings-row-Account"].firstMatch, "Settings did not open")
        snap("08-settings")

        let insights = app.buttons["settings-row-Insights"].firstMatch
        expect(insights, "Settings hub is missing the Insights row")
        XCTAssertTrue(scrollIntoReach(insights), "the Insights row never became reachable")
        insights.tap()
        expect(app.navigationBars["Insights"], "Settings → Insights did not open")
        usleep(700_000); snap("09-insights")
    }
}
