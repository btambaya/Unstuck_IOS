// Guided-tour XCUITest — drives the ESSENTIAL tour end-to-end against the
// network-free demo boot (UITEST_SEED + UITEST_TOUR arms a fresh 'eligible'
// state). Verifies the load-bearing rendering claim: the tour lives in its
// own always-on-top window, so the panel must stay visible and tappable over
// the tab content AND over the sheets the steps present (TaskEditor on
// first-action, Settings→Notifications on the notifications step).
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
        // One-time welcome (armed by UITEST_TOUR) over Today.
        XCTAssertTrue(app.staticTexts["Welcome to Unstuck"].firstMatch.waitForExistence(timeout: 20))
        snap("00-welcome")
        app.staticTexts["Essential tour"].firstMatch.tap()

        expectStep("This is Unstuck", shot: "01-welcome-step")
        tapPrimary()
        expectStep("Today narrows it down", shot: "02-today")
        // Ask-a-question with the keyboard UP: keyboard avoidance must not
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
        XCTAssertTrue(app.staticTexts["Today narrows it down"].exists,
                      "panel must stay expanded (title visible) with the keyboard up")
        snap("02b-ask-keyboard")
        app.buttons["Send question"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'focus time you realistically have'"))
            .firstMatch.waitForExistence(timeout: 10),
            "expected the canned usable-time answer")
        app.buttons["Close question"].firstMatch.tap()
        tapPrimary()
        // Opens a real task's detail sheet — the panel must render above it.
        expectStep("The first physical action", shot: "03-first-action")
        tapPrimary()
        // The assistant step's primary opens the bubble; Skip advances without
        // opening it (keeps the walk deterministic).
        expectStep("Ask Unstuck to handle it", shot: "04-assistant")
        tapPrimary("Skip")
        // Focus + capture ring the Today hero's Focus affordance — the tour
        // must NEVER start a session (no "Out" pill / focus screen).
        expectStep("Focus, and the Ring", shot: "05-focus")
        XCTAssertFalse(app.staticTexts["FOCUSING"].exists, "tour must never mint a focus session")
        tapPrimary()
        expectStep("Capture without leaving", shot: "06-capture")
        tapPrimary()
        expectStep("Interruption, then re-entry", shot: "07-reentry")
        tapPrimary()
        // Settings sheet opens on the Notifications section — panel above it.
        expectStep("You set how present it is", shot: "08-notifications")
        XCTAssertTrue(app.staticTexts["Calm"].firstMatch.waitForExistence(timeout: 8),
                      "settings should be open on the Notifications section")
        tapPrimary()
        expectStep("You’re ready to begin", shot: "09-finish")
        tapPrimary("Begin")

        // Tour done — panel gone, app back on Today, nothing presented.
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 8))
        usleep(800_000)
        XCTAssertFalse(app.staticTexts["You’re ready to begin"].exists)
        snap("10-done")
    }
}
