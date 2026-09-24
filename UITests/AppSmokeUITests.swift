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
// labels collide ("Focus" was both a Settings row and the since-removed
// Start-Next hero's button). Address rows by their FIXED identifiers —
// `settings-row-account`, `-notifications`, `-assistant`, `-people`,
// `-appearance`, `-feedback`, `-tour` (slim settings, 2026-09-24).

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

    /// Scroll `e` into reach. Today's lower rows land in the bottom ~100pt
    /// that the FLOATING bottom nav covers — and XCUITest still calls elements
    /// under that nav `isHittable`, so tapping one silently hits the nav
    /// instead (that is how `testFocus` used to "pass" while starting no
    /// session, back when the hero's Focus button sat there). Require the
    /// element to clear the nav, not merely to exist.
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
        // An item row is ONE combined button since build 84 (tap strikes it
        // out, swipes/hold do the rest), so "Milk" is a Button's label now —
        // there is no separate StaticText to find.
        expect(app.buttons["Milk"].firstMatch, "the collection detail did not open")
        snap("07-collection-detail")
    }

    /// Focus from a Today row: long-press a seeded row, pick "Focus" in its
    /// context menu, and a real session starts. (The Start-Next hero and its
    /// Focus button are gone from the home — 2026-09-18 — so the row's menu
    /// and the task editor's Focus button are the home's ways into Focus.)
    func testFocus() throws {
        launchToToday()
        let row = app.staticTexts["Draft the Q3 proposal"].firstMatch
        expect(row, "the seeded Today should list 'Draft the Q3 proposal'")
        XCTAssertTrue(scrollIntoReach(row), "the proposal row never became reachable on Today")
        // No hero on the home any more: nothing labelled Focus before the menu.
        XCTAssertFalse(app.buttons["Focus"].firstMatch.exists,
                       "Today must not carry a Focus button outside a row's context menu")
        row.press(forDuration: 1.2)
        let focus = app.buttons["Focus"].firstMatch
        expect(focus, "the row's context menu has no Focus action")
        focus.tap()
        XCTAssertTrue(app.staticTexts["FOCUSING"].firstMatch.waitForExistence(timeout: 8),
                      "the row's Focus action did not start a session")
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
    /// Settings → "Send feedback".
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
                       "feedback moved to Settings → Send feedback")
    }

    /// The slim hub (2026-09-24): an Account card, four screens, two one-tap
    /// actions and the Terms · Privacy · version footer — and each screen is a
    /// PUSHED sub-screen (the tour's scoped lockdown needs that).
    func testSettingsSubScreens() throws {
        launchToToday()
        let avatar = app.buttons["Account and settings"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 6), "the Today header avatar is missing")
        avatar.tap(); usleep(800_000)

        for id in ["account", "notifications", "assistant", "people", "appearance", "feedback", "tour"] {
            expect(app.descendants(matching: .any)["settings-row-\(id)"].firstMatch, "Settings hub is missing the \(id) row")
        }
        XCTAssertTrue(app.buttons["settings-terms"].firstMatch.exists, "Terms must stay one tap from the hub")
        XCTAssertTrue(app.buttons["settings-privacy"].firstMatch.exists, "Privacy must stay one tap from the hub")
        // Gone from the hub: Focus, Sound, Accessibility, Interface, Insights,
        // Backup, Areas & tags, Calls from Unstuck.
        for gone in ["Focus", "Sound", "Accessibility", "Interface", "Insights", "Backup", "Areas & tags"] {
            XCTAssertFalse(app.buttons["settings-row-\(gone)"].exists, "\(gone) must not be a hub row any more")
        }
        snap("08-settings")

        app.buttons["settings-row-appearance"].firstMatch.tap()
        expect(app.staticTexts["How it looks."].firstMatch, "Settings → Appearance did not open")
        XCTAssertTrue(app.buttons["Text size: Larger"].firstMatch.exists, "Appearance → Text size is missing")
        XCTAssertFalse(app.staticTexts["Accent"].exists, "Accent is gone")
        snap("14-settings-appearance")
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.exists, "no back button out of Settings → Appearance")
        back.tap(); usleep(600_000)

        app.buttons["settings-row-notifications"].firstMatch.tap()
        expect(app.staticTexts["How Unstuck reaches you."].firstMatch, "Settings → Notifications & calls did not open")
        XCTAssertTrue(app.staticTexts["Calm"].firstMatch.exists, "the level picker is missing")
        snap("16-settings-notifications")
        app.navigationBars.buttons.firstMatch.tap(); usleep(600_000)

        app.buttons["settings-row-assistant"].firstMatch.tap()
        expect(app.staticTexts["What the AI can see."].firstMatch, "Settings → Assistant & privacy did not open")
        XCTAssertTrue(app.switches["settings-ai-data-sharing"].firstMatch.exists, "the AI data sharing consent row must stay")
        snap("17-settings-assistant")
        app.navigationBars.buttons.firstMatch.tap(); usleep(600_000)

        let accountRow = app.descendants(matching: .any)["settings-row-account"].firstMatch
        expect(accountRow, "Settings hub is missing the Account card")
        accountRow.tap()
        expect(app.staticTexts["Your account."].firstMatch, "Settings → Account did not open")
        let delete = app.staticTexts["Delete my account"].firstMatch
        for _ in 0..<6 where !delete.exists { app.swipeUp(); usleep(300_000) }
        XCTAssertTrue(delete.exists, "Delete my account must stay reachable (App Store 5.1.1(v))")
        snap("15-settings-account")
    }

    /// Insights left the Settings hub (slim settings): Today's week pill is
    /// its one-tap way in.
    func testSettingsAndInsights() throws {
        launchToToday()
        let pill = app.buttons["week-pill"].firstMatch
        expect(pill, "the Today week pill is missing")
        pill.tap()
        expect(app.navigationBars["Insights"], "the week pill did not open Insights")
        usleep(700_000); snap("09-insights")
    }

    /// The bottom-bar + creates the thing you're LOOKING AT (2026-09-18):
    /// New task on Today/Tasks/Calendar, New collection on the Collections
    /// grid, and — inside a collection — the cursor in that collection's ONE
    /// inline add field (no second add UI). The button itself never changes;
    /// its accessibility label is how the surface-sensitivity is asserted here.
    func testFabCreatesWhatYoureLookingAt() throws {
        launchToToday()
        XCTAssertTrue(app.buttons["New task"].firstMatch.waitForExistence(timeout: 6),
                      "the + on Today must still be New task (the tour's first-action fallback anchor)")
        tapNav("Tasks")
        XCTAssertTrue(app.buttons["New task"].firstMatch.exists, "the + on Tasks must still be New task")
        tapNav("Calendar")
        XCTAssertTrue(app.buttons["New task"].firstMatch.exists, "the + on Calendar must still be New task")

        // Collections grid → New collection, and it opens the real sheet.
        tapNav("Collections")
        let newCollection = app.buttons["New collection"].firstMatch
        expect(newCollection, "the + on the Collections grid should offer New collection")
        XCTAssertFalse(app.buttons["New task"].firstMatch.exists,
                       "the + must not still be New task on the Collections grid")
        newCollection.tap()
        expect(app.staticTexts["NEW COLLECTION"].firstMatch, "the + did not open the New-collection sheet")
        snap("16-fab-new-collection")
        app.buttons["Cancel"].firstMatch.tap(); usleep(700_000)

        // Inside a collection → the inline add field.
        let groceries = app.staticTexts["Groceries"].firstMatch
        expect(groceries, "the seeded Groceries list is missing")
        groceries.tap(); usleep(800_000)
        // The detail ALREADY auto-focuses its add field on open, so clear that
        // focus first — otherwise this test would pass even if the + did
        // nothing at all. Opening the title's inline rename and submitting it
        // unchanged is the path that drops the focus (same trick
        // StoreScreenshots uses; a flick on a short list won't scroll-dismiss).
        if app.keyboards.count > 0 {
            app.staticTexts["Groceries"].firstMatch.tap(); usleep(500_000)
            app.typeText("\n"); usleep(900_000)
            XCTAssertEqual(app.keyboards.count, 0, "could not clear the add field's focus")
        }

        let addToThis = app.buttons["Add to this collection"].firstMatch
        expect(addToThis, "inside a collection the + should add to THAT collection")
        addToThis.tap(); usleep(900_000)
        // No second add UI: no sheet came up, just the field that was already there.
        XCTAssertFalse(app.staticTexts["What's on your mind?"].firstMatch.exists,
                       "the + inside a collection must not open the New-task sheet")
        XCTAssertFalse(app.staticTexts["NEW COLLECTION"].firstMatch.exists,
                       "the + inside a collection must not open the New-collection sheet")
        XCTAssertTrue(app.keyboards.count > 0,
                      "the + should have put the cursor back in the add field")
        snap("17-fab-add-to-collection")
        // …and it is THAT field the cursor is in: typing lands in it. (Only the
        // typing, not a submit — the demo boot has no SyncCoordinator, so
        // AppModel.mutateCollectionItem no-ops and a committed item would never
        // appear. Nothing to do with the +.)
        let addField = app.textFields
            .matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Add to this collection'")).firstMatch
        expect(addField, "the collection's inline add field is missing")
        app.typeText("Olive oil"); usleep(500_000)
        XCTAssertTrue(((addField.value as? String) ?? "").contains("Olive oil"),
                      "the + should leave the cursor in the add field, ready to type")

        // Back out to the grid and the + goes back to New collection — a stale
        // "add to that collection" after the pop would be the bug.
        app.navigationBars.buttons.firstMatch.tap(); usleep(900_000)
        XCTAssertTrue(app.buttons["New collection"].firstMatch.waitForExistence(timeout: 6),
                      "popping back to the grid must retract the open-collection marker")
        XCTAssertFalse(app.buttons["Add to this collection"].firstMatch.exists,
                       "the + still points at a collection that is no longer on screen")

        // …and so does leaving the tab entirely.
        tapNav("Today")
        XCTAssertTrue(app.buttons["New task"].firstMatch.waitForExistence(timeout: 6),
                      "the + must be New task again back on Today")

        // The walk that used to be able to strand the marker: leave the tab
        // STRAIGHT FROM an open collection — tap Today in the bottom nav with
        // no back tap — then come back to the grid. The retraction used to hang
        // entirely on the detail's onDisappear; miss it and the + went on
        // offering "add to that collection" over a grid.
        tapNav("Collections")
        expect(app.staticTexts["Groceries"].firstMatch, "the seeded Groceries list is missing")
        app.staticTexts["Groceries"].firstMatch.tap(); usleep(800_000)
        expect(app.buttons["Add to this collection"].firstMatch, "the collection detail did not open")
        tapNav("Today")                    // no back tap — straight out of the tab
        tapNav("Collections")
        XCTAssertTrue(app.buttons["New collection"].firstMatch.waitForExistence(timeout: 6),
                      "back on the Collections grid the + must offer New collection")
        XCTAssertFalse(app.buttons["Add to this collection"].firstMatch.exists,
                       "the + survived a tab switch still aimed at a collection that isn't on screen")
    }
}
