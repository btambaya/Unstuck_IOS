// Guided-tour XCUITest — drives the ESSENTIAL tour end-to-end against the
// network-free demo boot (UITEST_SEED + UITEST_TOUR arms a fresh 'eligible'
// state). Verifies the load-bearing claims:
//  • the tour lives in its own always-on-top window — the panel stays visible
//    and tappable over tab content AND over the sheets steps present
//    (TaskEditor on first-action, Settings→Notifications);
//  • ROUND-2 lockdown — while running, a tap outside the panel + spotlight is
//    SWALLOWED (does nothing); ROUND-3 cutout policy — the ring itself is
//    display-only on ordinary steps (the spotlighted Start-Next hero can't
//    mint a session) and passes through ONLY on the assistant/reentry steps
//    (the launcher opens its sheet);
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
    private func expectStep(_ title: String, shot: String, timeout: TimeInterval = 12) {
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: timeout),
                      "expected tour step '\(title)'")
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

        expectStep("Today narrows it down", shot: "02-today")
        // ROUND-2 LOCKDOWN: a tap outside the panel + spotlight is swallowed.
        // The Today header's avatar normally opens the Settings sheet — while
        // the tour runs it must do NOTHING.
        app.buttons["Account and settings"].firstMatch.tap()
        usleep(800_000)
        XCTAssertFalse(app.navigationBars["Settings"].exists,
                       "blocked tap must not open Settings")
        XCTAssertTrue(app.staticTexts["Today narrows it down"].exists,
                      "blocked tap must not disturb the step")
        snap("02a-lockdown-blocked")
        // ROUND-3 CUTOUT POLICY: on this step the ring is DISPLAY-ONLY — the
        // SPOTLIGHTED Start-Next hero itself is swallowed too. Its Focus
        // button mints a real session in normal use; inside the tour the tap
        // must do NOTHING (no session, step undisturbed).
        let heroFocus = app.buttons["Focus"].firstMatch
        XCTAssertTrue(heroFocus.waitForExistence(timeout: 8),
                      "seeded Today should show the Start-Next hero")
        heroFocus.tap()
        usleep(900_000)
        XCTAssertFalse(app.staticTexts["FOCUSING"].exists,
                       "blocked hero tap must not mint a real focus session")
        XCTAssertTrue(app.staticTexts["Today narrows it down"].exists,
                      "blocked hero tap must not disturb the step")
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
        // launcher opens the real bubble sheet.
        expectStep("Ask Unstuck to handle it", shot: "04-assistant")
        app.buttons["Assistant"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Feedback"].firstMatch.waitForExistence(timeout: 8),
                      "the spotlighted launcher must open the bubble sheet")
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
        XCTAssertTrue(app.staticTexts["Capture"].firstMatch.exists, "demo capture hint (ringed)")
        tapPrimary()
        expectStep("Interruption, then re-entry", shot: "07-reentry")
        XCTAssertFalse(app.staticTexts["FOCUSING"].exists,
                       "leaving the focus steps removes the demo — no session was minted")
        tapPrimary()
        // Settings sheet opens on the Notifications section — panel above it,
        // sheet interactive (panel-only claim while it's up).
        expectStep("You set how present it is", shot: "08-notifications")
        XCTAssertTrue(app.staticTexts["Calm"].firstMatch.waitForExistence(timeout: 8),
                      "settings should be open on the Notifications section")
        tapPrimary()
        expectStep("You’re ready to begin", shot: "09-finish")
        tapPrimary("Begin")

        // Tour done — panel gone, app back on Today, nothing presented, and
        // no focus session anywhere.
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 8))
        usleep(800_000)
        XCTAssertFalse(app.staticTexts["You’re ready to begin"].exists)
        XCTAssertFalse(app.staticTexts["FOCUSING"].exists, "demo never minted a session")
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

        // Focus the Ask field (tour window becomes key) and type.
        app.buttons["Ask a question"].firstMatch.tap()
        let askField = app.textFields.firstMatch
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
        // SwiftUI's vertical-axis TextField is backed by a text view; match
        // whichever element the runtime exposes.
        let nameView = app.textViews.firstMatch
        let nameField = nameView.waitForExistence(timeout: 3) ? nameView : app.textFields.firstMatch
        XCTAssertTrue(nameField.exists, "expected the new-task name input")
        nameField.tap()
        nameField.typeText("Buy stamps")
        let typed = (nameField.value as? String) ?? ""
        XCTAssertTrue(typed.contains("Buy stamps"),
                      "app window must be key — typing lands in the app's own field")
        snap("keywindow-01-app-typing-works")
    }
}
