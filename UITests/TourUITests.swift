// Guided-tour XCUITest — drives the ESSENTIAL tour end-to-end against the
// network-free demo boot (UITEST_SEED + UITEST_TOUR arms a fresh 'eligible'
// state). Verifies the load-bearing claims:
//  • the tour lives in its own always-on-top window — the panel stays visible
//    and tappable over tab content AND over the sheets steps present
//    (TaskEditor on first-action, Settings→Notifications);
//  • ROUND-2 lockdown — while running, a tap outside the panel + spotlight is
//    SWALLOWED (does nothing); ROUND-3 cutout policy — the ring itself is
//    display-only on ordinary steps (the spotlighted Today list can't open a
//    task) and passes through ONLY on the assistant/reentry steps (the
//    launcher opens its sheet);
//  • ROUND-3 key-window handback — exiting with the Ask keyboard up hands
//    key status back to the app window (its text inputs keep working);
//  • the focus/capture steps render the tour's DEMO focus surface (frozen at
//    18:24 of 40 min) and never mint a real session;
//  • pause → inline confirm → floating "Resume tour" chip (tap = resume at
//    the step, ✕ = gone for good), with full pass-through while paused.
// Screenshots land in /tmp/unstuck-tour-shots/ for visual review.

import XCTest

final class TourUITests: XCTestCase {
    private var app: XCUIApplication!
    private let outDir = URL(fileURLWithPath: "/tmp/unstuck-tour-shots")

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
        app.launchEnvironment["UITEST_TOUR"] = "1"
        addUIInterruptionMonitor(withDescription: "system-alert") { alert in
            for label in ["Allow", "Don’t Allow", "OK", "Continue"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        app.launch()
    }

    private func snap(_ name: String) {
        let png = app.screenshot().pngRepresentation
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    /// Wait for a step's title (rendered by the tour panel in the overlay
    /// window) and screenshot it.
    ///
    /// `body` is the guard the title alone can't give: a COLLAPSED panel still
    /// renders its title, so the 2026-09-18 today/finish regression — the whole
    /// step body hidden on 6.3" phones — looked like a perfectly healthy step
    /// from up here and all three of these tests passed straight through it.
    /// Pass a distinctive fragment of the step's copy and the panel has to have
    /// actually rendered it.
    private func expectStep(_ title: String, shot: String, body: String? = nil,
                            timeout: TimeInterval = 12) {
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: timeout),
                      "expected tour step '\(title)'")
        if let body {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body))
                            .firstMatch.waitForExistence(timeout: 4),
                          "step '\(title)' rendered TITLE-ONLY — its body copy never made it "
                          + "into the panel (expected to find: \(body))")
        }
        usleep(900_000)   // let navigation/sheet animations settle for the shot
        snap(shot)
    }

    private func tapPrimary(_ label: String = "Continue") {
        let b = app.buttons[label].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 8), "expected primary '\(label)'")
        b.tap()
    }

    func testEssentialTourEndToEnd() throws {
        // One-time welcome (armed by UITEST_TOUR) over Today — round-2 copy.
        XCTAssertTrue(app.staticTexts["Welcome to Unstuck"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'about three minutes for the essentials'"))
            .firstMatch.exists, "round-2 welcome intro copy")
        XCTAssertTrue(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Pause anytime'"))
            .firstMatch.exists, "welcome footer names the Settings path")
        snap("00-welcome")
        app.staticTexts["Essential tour"].firstMatch.tap()

        expectStep("This is Unstuck", shot: "01-welcome-step")
        // Ask-a-question with the keyboard UP (on the no-target welcome step,
        // whose panel is never collapsed): keyboard avoidance must not
        // collapse the panel and unmount the focused field (the HIGH-severity
        // focus/keyboard loop). The field has to survive focus + typing, and
        // the canned TOUR_QA answer lands (network-free boot → instant fallback).
        app.buttons["Ask a question"].firstMatch.tap()
        let askField = app.textFields.firstMatch
        XCTAssertTrue(askField.waitForExistence(timeout: 6), "expected the ask input")
        askField.tap()
        askField.typeText("usable time")
        usleep(700_000)   // give a would-be collapse loop time to manifest
        XCTAssertTrue(askField.exists, "ask field must stay mounted while focused")
        XCTAssertTrue(app.staticTexts["This is Unstuck"].exists,
                      "panel must stay expanded (title visible) with the keyboard up")
        snap("01b-ask-keyboard")
        app.buttons["Send question"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'focus time you realistically have'"))
            .firstMatch.waitForExistence(timeout: 10),
            "expected the canned usable-time answer")
        app.buttons["Close question"].firstMatch.tap()
        tapPrimary()

        // The today step is the one the panel-placement regression hit: its ring
        // is the Today list, which leaves only 242pt above it on a 6.3" phone —
        // less than the panel's natural 358. The panel must CAP and scroll, not
        // collapse, so the copy has to be there.
        expectStep("Today narrows it down", shot: "02-today",
                   body: "Today lists only what\u{2019}s planned for today")
        // …and on a capped panel the body is a live scroll view, whose pan
        // recognizer outranks the panel-wide DragGesture. Swiping DOWN over the
        // copy is the documented iOS Escape-equivalent and must still reach the
        // pause confirm on exactly these steps.
        let todayTitle = app.staticTexts["Today narrows it down"].firstMatch.frame
        let overTheCopy = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: todayTitle.midX, dy: todayTitle.maxY + 20))
        overTheCopy.press(forDuration: 0.1,
                          thenDragTo: overTheCopy.withOffset(CGVector(dx: 0, dy: 110)))
        XCTAssertTrue(app.staticTexts["Pause the tour? Your progress is saved."]
            .firstMatch.waitForExistence(timeout: 6),
            "swipe-down over a CAPPED panel's copy must still open the pause confirm")
        app.buttons["Keep going"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Today narrows it down"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Pause the tour? Your progress is saved."].exists)
        // ROUND-2 LOCKDOWN: a tap outside the panel + spotlight is swallowed.
        // ROUND-4 A11Y (build 39) went further — on a step where the touch
        // layer swallows EVERY app point, the app window's elements are hidden
        // outright, so the Today header's avatar is not merely inert, it is
        // UNREACHABLE. That is the stronger guarantee, and it is what we
        // assert: the element cannot be found, so neither a tap nor VoiceOver
        // can reach Settings from under the scrim.
        XCTAssertFalse(app.buttons["Account and settings"].firstMatch.exists,
                       "app content must be unreachable while the tour holds the lock")
        XCTAssertFalse(app.navigationBars["Settings"].exists,
                       "Settings must not be open behind the tour")
        snap("02a-lockdown-blocked")
        // ROUND-3 CUTOUT POLICY: on this step the ring is DISPLAY-ONLY — the
        // SPOTLIGHTED Today list is swallowed like everything else, so its
        // rows (and the header's week pill) are hidden from the a11y tree
        // too. (A row opens a real task in normal use; the end of this test
        // proves it comes back the moment the tour lets go.)
        XCTAssertFalse(app.staticTexts["Draft the Q3 proposal"].firstMatch.exists,
                       "a display-only ring must not leave the ringed rows reachable")
        XCTAssertFalse(app.buttons["week-pill"].firstMatch.exists,
                       "Today's header must be unreachable under the scrim")
        // The touch layer is the half the a11y tree can't speak for, so probe
        // it with a RAW coordinate touch — the tab bar, whose position is
        // fixed and which is unambiguously app content under the scrim.
        // Tapping "Tasks" must do nothing at all: the step stays put, and the
        // end-of-test assertions still find Today (a tap that got through
        // would have left the app on the Tasks tab).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.925)).tap()
        usleep(900_000)
        XCTAssertFalse(app.staticTexts["FOCUSING"].exists,
                       "a swallowed tap must not mint a real focus session")
        XCTAssertTrue(app.staticTexts["Today narrows it down"].exists,
                      "a swallowed tap must not disturb the step")
        snap("02b-cutout-display-only")
        tapPrimary()
        // Opens a real task's detail sheet — the panel must render above it,
        // and the sheet (the step's subject) stays interactive under the
        // panel-only claim.
        expectStep("The first physical action", shot: "03-first-action")
        tapPrimary()
        // ROUND-2 LOCKDOWN, pass-through side — narrowed by the round-3
        // cutout policy to the assistant/reentry steps (cutoutInteractive):
        // HERE the spotlighted element works — tapping the ringed assistant
        // launcher opens the real Assistant panel.
        expectStep("Ask Unstuck to handle it", shot: "04-assistant")
        // The a11y lock is SCOPED to the touch policy: where the ring passes
        // touches through, the ringed control stays in the accessibility tree
        // too — otherwise this step ("the Assistant lives here, bottom-right")
        // is followable by sighted users only. Finding the launcher by label
        // and tapping it is that guarantee.
        app.buttons["Assistant"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["ASK UNSTUCK TO HANDLE IT"].firstMatch.waitForExistence(timeout: 8),
                      "the spotlighted launcher must open the assistant panel")
        snap("04b-assistant-sheet")
        // The panel stays interactive above the sheet; Skip advances (and the
        // step navigation closes the tour-opened sheet).
        tapPrimary("Skip")

        // Focus + capture present the tour's DEMO focus surface — visually a
        // focus session frozen at 18:24 of 40 min, but NO real session exists
        // and the app stays on Today underneath.
        expectStep("Focus, and the Ring", shot: "05-focus")
        XCTAssertTrue(app.staticTexts["FOCUSING"].firstMatch.waitForExistence(timeout: 6),
                      "demo focus surface should render")
        XCTAssertTrue(app.staticTexts["18:24"].firstMatch.exists, "demo timer frozen mid-progress")
        XCTAssertTrue(app.staticTexts["Write the project update"].firstMatch.exists, "demo task title")
        tapPrimary()
        expectStep("Capture without leaving", shot: "06-capture")
        // Round 3: the ringed pill is LIVE on this step — it opens the DEMO
        // capture sheet (typing allowed, nothing stored).
        let capturePill = app.buttons["Capture — opens a demo capture sheet"].firstMatch
        XCTAssertTrue(capturePill.exists, "demo capture pill (ringed, live on this step)")
        capturePill.tap()
        let demoSheet = app.otherElements["Demo capture sheet"].firstMatch
        XCTAssertTrue(demoSheet.waitForExistence(timeout: 4), "pill tap opens the demo capture sheet")
        let field = demoSheet.textFields.firstMatch.exists
            ? demoSheet.textFields.firstMatch : demoSheet.textViews.firstMatch
        field.tap()
        field.typeText("buy washing liquid")
        snap("06b-demo-capture")
        demoSheet.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Captured. In a real session it lands in your Inbox."]
            .firstMatch.waitForExistence(timeout: 4), "save flashes the demo confirmation")
        tapPrimary()
        expectStep("Interruption, then re-entry", shot: "07-reentry")
        XCTAssertFalse(app.staticTexts["FOCUSING"].exists,
                       "leaving the focus steps removes the demo — no session was minted")
        tapPrimary()
        // Settings sheet opens on the Notifications section — panel above it,
        // sheet interactive (panel-only claim while it's up).
        expectStep("You set how present it is", shot: "08-notifications")
        // Same scoping the assistant step relies on: the step-opened Settings
        // section is passed through by the touch layer, so it must stay in the
        // a11y tree — "Calm" being findable is what says a VoiceOver user can
        // actually change the setting this step is about.
        XCTAssertTrue(app.staticTexts["Calm"].firstMatch.waitForExistence(timeout: 8),
                      "settings should be open on the Notifications section")
        tapPrimary()
        expectStep("You’re ready to begin", shot: "09-finish",
                   body: "Pick one real next step")
        tapPrimary("Begin")

        // Tour done — panel gone, app back on Today, nothing presented, and
        // no focus session anywhere.
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 8))
        usleep(800_000)
        XCTAssertFalse(app.staticTexts["You’re ready to begin"].exists)
        XCTAssertFalse(app.staticTexts["FOCUSING"].exists, "demo never minted a session")
        // The lock let go with the tour: Today's rows — the thing step 2
        // ringed, and the elements the lockdown hid — are back in the tree,
        // tab still Today (proof the swallowed tab-bar tap on step 2 really
        // went nowhere).
        XCTAssertTrue(app.staticTexts["Draft the Q3 proposal"].firstMatch.waitForExistence(timeout: 8),
                      "seeded Today shows its rows once the lock lifts")
        XCTAssertTrue(app.buttons["week-pill"].firstMatch.exists, "Today's header is back")
        XCTAssertTrue(app.buttons["Account and settings"].firstMatch.exists,
                      "the whole app window is reachable again")
        snap("10-done")
    }

    func testPauseConfirmAndResumeChip() throws {
        XCTAssertTrue(app.staticTexts["Welcome to Unstuck"].firstMatch.waitForExistence(timeout: 20))
        app.staticTexts["Essential tour"].firstMatch.tap()
        expectStep("This is Unstuck", shot: "pause-00-step1")

        // Pause asks first; "Keep going" stays on the step.
        app.buttons["Pause"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Pause the tour? Your progress is saved."]
            .firstMatch.waitForExistence(timeout: 6), "expected the inline pause confirm")
        XCTAssertTrue(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Settings → Account → Product tour'"))
            .firstMatch.exists, "the confirm names the Settings path")
        snap("pause-01-confirm")
        app.buttons["Keep going"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["This is Unstuck"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Pause the tour? Your progress is saved."].exists)

        // Confirmed pause → tour dismissed, floating "Resume tour" chip docks.
        app.buttons["Pause"].firstMatch.tap()
        let confirm = app.buttons["Confirm pause"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 6))
        confirm.tap()
        let chip = app.buttons["Resume tour"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "resume chip should appear")
        usleep(600_000)
        XCTAssertFalse(app.staticTexts["This is Unstuck"].exists, "panel gone while paused")
        snap("pause-02-chip")

        // While paused everything passes through normally — the app is fully
        // usable (tab switch works) and the chip persists across screens.
        app.buttons["Tasks"].firstMatch.tap()
        usleep(900_000)
        XCTAssertTrue(chip.exists, "chip present across screens")
        snap("pause-03-chip-on-tasks")

        // Chip tap = resume at the SAME step (navigation returns to Today).
        chip.tap()
        XCTAssertTrue(app.staticTexts["This is Unstuck"].firstMatch.waitForExistence(timeout: 8),
                      "chip resumes at the saved step")
        snap("pause-04-resumed")

        // Pause again; the chip ✕ dismisses it for good.
        app.buttons["Pause"].firstMatch.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 6))
        confirm.tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        app.buttons["Dismiss resume tour chip"].firstMatch.tap()
        usleep(600_000)
        XCTAssertFalse(app.buttons["Resume tour"].exists, "✕ removes the chip for good")
        snap("pause-05-chip-dismissed")
    }

    /// ROUND-3 key-window handback: the Ask field makes the TOUR window key
    /// for typing; exiting the tour with the keyboard still up unmounts the
    /// panel before its focus handler can hand key status back. teardown must
    /// restore the APP window as key — otherwise every text input in the app
    /// goes dead (keyboard focus can't land in a non-key window).
    func testExitWithAskKeyboardUpRestoresAppKeyWindow() throws {
        XCTAssertTrue(app.staticTexts["Welcome to Unstuck"].firstMatch.waitForExistence(timeout: 20))
        app.staticTexts["Essential tour"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["This is Unstuck"].firstMatch.waitForExistence(timeout: 12))

        // Focus the Ask field (tour window becomes key) and type. The app
        // window is hidden from accessibility on this step, so the tour's own
        // input is the only text field in the tree — but name it anyway, so
        // this never silently starts typing into Today's gateway composer.
        app.buttons["Ask a question"].firstMatch.tap()
        let askField = app.textFields
            .matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Ask anything'")).firstMatch
        XCTAssertTrue(askField.waitForExistence(timeout: 6), "expected the ask input")
        askField.tap()
        askField.typeText("key window")
        snap("keywindow-00-ask-focused")

        // Exit ✕ with the keyboard still up.
        app.buttons["Exit tour"].firstMatch.tap()
        usleep(900_000)
        XCTAssertFalse(app.staticTexts["This is Unstuck"].exists, "tour gone after exit")

        // The APP window must be key again: its text inputs accept keyboard
        // focus and typing lands. (With the leak, the dead tour window kept
        // key status and typeText below fails to acquire keyboard focus.)
        app.buttons["New task"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["What's on your mind?"].firstMatch.waitForExistence(timeout: 8),
                      "new-task sheet should open after the tour exits")
        // Address the sheet's input by IDENTIFIER. `app.textFields.firstMatch`
        // is wrong here and was the long-standing failure in this test:
        // Today's gateway composer ("Ask me anything — or hand me your whole
        // day…") is also a TextField, it sorts first, and from BEHIND the
        // presented sheet it is of course not hittable — so the tap failed on
        // an element that had nothing to do with the key-window handback.
        let nameField = app.textFields["new-task-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "expected the new-task name input")
        nameField.tap()
        nameField.typeText("Buy stamps")
        let typed = (nameField.value as? String) ?? ""
        XCTAssertTrue(typed.contains("Buy stamps"),
                      "app window must be key — typing lands in the app's own field")
        snap("keywindow-01-app-typing-works")
    }
}
