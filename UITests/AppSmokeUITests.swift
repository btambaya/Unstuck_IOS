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
// Start-Next hero's button). Address rows by identifier — `settings-row-<label>`.

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

/// Ahmad, 2026-09-24 (build 97): in a collection taller than the screen,
/// editing a row near the bottom left the row under the keyboard, the list
/// would not bring it into view, and the bottom nav (Today · Tasks · + ·
/// Calendar · Collections) rode up and sat ON TOP of the keyboard.
///
/// The contract, checked with the software keyboard really on screen:
///   • the edited row / the add field sits fully above the keyboard, and is
///     not under the nav either;
///   • the bottom nav is not drawn above the keyboard while typing;
///   • the list still scrolls with the keyboard up;
///   • once the keyboard goes, the nav is back at the bottom of the screen.
///
/// Runs on the network-free demo boot with UITEST_LONG_LIST (a 12-item "Sync
/// up" list). Screenshots go to LISTKBD_SHOTS_DIR (export it to xcodebuild as
/// TEST_RUNNER_LISTKBD_SHOTS_DIR) named with LISTKBD_SHOT_PREFIX ("before" /
/// "after"); they are attached to the result either way.
///
/// Simulator note: a simulator with a hardware keyboard attached keeps the
/// software keyboard OFF screen for a focused field (the element exists, at
/// y > screen height) until XCUITest types into it — so every state below
/// types a no-op (a space + delete) before it is measured, which is what a
/// phone with no hardware keyboard shows the moment the field takes focus.
final class CollectionKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment
    private var prefix: String { env["LISTKBD_SHOT_PREFIX"].flatMap { $0.isEmpty ? nil : $0 } ?? "shot" }
    private var outDir: URL? {
        guard let d = env["LISTKBD_SHOTS_DIR"], !d.isEmpty else { return nil }
        let url = URL(fileURLWithPath: d)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let lastItem = "Beta invite list"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
        app.launchEnvironment["UITEST_LONG_LIST"] = "1"
        addUIInterruptionMonitor(withDescription: "system-alert") { alert in
            for label in ["Allow", "Don’t Allow", "OK", "Continue"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        XCUIDevice.shared.appearance = .light
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let outDir { try? s.pngRepresentation.write(to: outDir.appendingPathComponent("\(name).png")) }
    }

    private func dumpTree(_ name: String) {
        guard let outDir else { return }
        try? app.debugDescription.write(to: outDir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    /// The bottom nav, found by one of its tab buttons.
    private var nav: XCUIElement { app.buttons["Calendar"].firstMatch }
    private var keyboard: XCUIElement { app.keyboards.firstMatch }
    private var addField: XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Add to this collection'")).firstMatch
    }
    /// Some field has keyboard focus (the keyboard element exists — on or off screen).
    private var hasFocus: Bool { app.keyboards.count > 0 }
    /// The software keyboard is actually up on screen.
    private var keyboardOnScreen: Bool { keyboard.exists && keyboard.frame.minY < app.frame.height - 40 }

    /// The row being edited: its text field if exposed on its own, else the
    /// row element that carries the text.
    private func edited(_ body: String) -> XCUIElement {
        let tf = app.textFields.matching(NSPredicate(format: "value == %@", body)).firstMatch
        if tf.exists { return tf }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", body, body)).firstMatch
    }

    private func rect(_ r: CGRect) -> String { String(format: "y %.0f…%.0f", r.minY, r.maxY) }

    private func waitUntil(_ timeout: TimeInterval = 6, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { usleep(700_000); return true }   // + the slide animation
            usleep(200_000)
        }
        return cond()
    }

    /// Bring the software keyboard on screen for the focused field without
    /// changing its text (see the simulator note above).
    private func raiseKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntil { self.hasFocus }, "no field has focus", file: file, line: line)
        app.typeText(" "); app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(waitUntil { self.keyboardOnScreen }, "the software keyboard never came on screen", file: file, line: line)
    }

    /// Log where the keyboard, the nav and `field` are, and assert the
    /// contract: `field` wholly above the keyboard (and above the nav if the
    /// nav is somehow drawn there), and no nav above the keyboard.
    @discardableResult
    private func measure(_ tag: String, _ field: XCUIElement,
                         file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        let screen = app.frame.height
        let kb = keyboardOnScreen ? keyboard.frame : .null
        let kbTop = kb.isNull ? screen : kb.minY
        let navShown = nav.exists && nav.isHittable
        let navRect = navShown ? nav.frame : .null
        let navAboveKeyboard = !kb.isNull && navShown && navRect.maxY <= kbTop + 1
        let f = field.exists ? field.frame : .null
        let limit = navAboveKeyboard ? min(kbTop, navRect.minY) : kbTop
        let fieldClear = !f.isNull && f.maxY <= limit + 0.5 && f.minY >= 0
        print("LISTKBD [\(tag)] screen=\(Int(screen)) keyboard=\(kb.isNull ? "none" : rect(kb)) "
              + "nav=\(navShown ? rect(navRect) : "hidden") navAboveKeyboard=\(navAboveKeyboard) "
              + "field=\(f.isNull ? "missing" : rect(f)) fieldClear=\(fieldClear)")
        XCTAssertFalse(kb.isNull, "[\(tag)] the software keyboard is not on screen", file: file, line: line)
        XCTAssertTrue(fieldClear, "[\(tag)] the field (\(f.isNull ? "missing" : rect(f))) is not wholly visible above the keyboard top \(Int(kbTop))\(navAboveKeyboard ? " and the nav top \(Int(navRect.minY))" : "")", file: file, line: line)
        XCTAssertFalse(navAboveKeyboard, "[\(tag)] the bottom nav (\(rect(navRect))) sits on top of the keyboard (\(rect(kb)))", file: file, line: line)
        return f
    }

    /// Drop keyboard focus the way the smoke test does: open the title's inline
    /// rename and submit it unchanged.
    private func dropFocus(file: StaticString = #filePath, line: UInt = #line) {
        guard hasFocus else { return }
        app.staticTexts["Sync up"].firstMatch.tap(); usleep(500_000)
        app.typeText("\n")
        XCTAssertTrue(waitUntil { !self.hasFocus }, "could not drop the keyboard", file: file, line: line)
    }

    /// Scroll until `row` is on screen and clear of the (keyboard-less) nav.
    private func scrollIntoReach(_ row: XCUIElement) -> Bool {
        for _ in 0..<8 {
            let navTop = nav.exists ? nav.frame.minY : app.frame.height
            if row.exists, row.isHittable, row.frame.maxY < navTop - 4 { return true }
            app.swipeUp(); usleep(600_000)
        }
        return row.exists && row.isHittable
    }

    /// Hold the last row to edit it, keyboard up, and measure.
    @discardableResult
    private func editLastItem(_ tag: String) -> CGRect {
        dropFocus()
        let row = app.buttons[lastItem].firstMatch
        XCTAssertTrue(scrollIntoReach(row), "the last row never came into reach")
        row.press(forDuration: 0.8)
        raiseKeyboard()
        usleep(500_000)
        return measure(tag, edited(lastItem))
    }

    func testEditAndAddAtTheBottomStayAboveTheKeyboard() throws {
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 15), "the demo boot never reached Today")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap(); usleep(800_000) }

        app.buttons["Collections"].firstMatch.tap(); usleep(700_000)
        let list = app.staticTexts["Sync up"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 8), "the long seeded list is missing")
        list.tap()
        XCTAssertTrue(app.buttons["Review TestFlight feedback"].firstMatch.waitForExistence(timeout: 8),
                      "the collection detail did not open")

        // 0 · The detail focuses its add field on open — with the keyboard up
        // that field is the bottom of a long list.
        raiseKeyboard()
        measure("open-add-focused", addField)
        shot("\(prefix)-open")

        // 1 · Hold the LAST row to edit it (the reported case).
        let first = editLastItem("edit-last")
        shot(prefix)
        dumpTree("\(prefix)-edit-tree")

        // The list must still scroll with the keyboard up: a flick up moves the
        // row up (or it is already as high as the content allows), and a flick
        // down brings it back into view — never lost under the keyboard.
        app.swipeUp(); usleep(800_000)
        let up = measure("edit-last-swiped-up", edited(lastItem))
        print("LISTKBD [edit-last-swiped-up] moved \(Int(first.minY - up.minY))pt")
        shot("\(prefix)-edit-scrolled")
        app.swipeDown(); usleep(800_000)
        print("LISTKBD [edit-last-swiped-down] field=\(rect(edited(lastItem).frame))")

        // Done editing → the keyboard goes and the nav is back at the bottom.
        app.typeText("\n")
        XCTAssertTrue(waitUntil { !self.hasFocus }, "submitting the edit did not dismiss the keyboard")
        XCTAssertTrue(nav.waitForExistence(timeout: 4) && nav.isHittable, "the bottom nav did not come back after the edit")
        XCTAssertGreaterThan(nav.frame.maxY, app.frame.height - 120, "the bottom nav is not back at the bottom of the screen")
        print("LISTKBD [after-edit] nav=\(rect(nav.frame))")
        shot("\(prefix)-edit-done")

        // 2 · Add a new item at the bottom: the + puts the cursor in the add field.
        app.buttons["Add to this collection"].firstMatch.tap()
        XCTAssertTrue(waitUntil { self.hasFocus }, "the + did not focus the add field")
        app.typeText("Book the venue")
        XCTAssertTrue(waitUntil { self.keyboardOnScreen }, "the software keyboard never came on screen")
        measure("add-bottom", addField)
        shot("\(prefix)-add")

        // 3 · Dark: the same two states.
        XCUIDevice.shared.appearance = .dark
        usleep(1_500_000)
        measure("add-bottom-dark", addField)
        shot("\(prefix)-dark-add")
        editLastItem("edit-last-dark")
        shot("\(prefix)-dark")
    }
}
