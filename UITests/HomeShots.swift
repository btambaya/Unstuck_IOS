// Home + interview-in-thread screenshots — runs against the network-free demo
// boot (UITEST_SEED + a canned assistant reply) and writes full-resolution
// PNGs: the Today home in light and dark (one-line greeting, week pill, the
// assistant input pill, the list) and the assistant
// thread showing an interview question with its chips after the first
// message was answered. Not a behaviour test; a failure means a screen it
// claims to have shot didn't render.
//
//   xcodebuild test … -only-testing:UnstuckUITests/HomeShots \
//     TEST_RUNNER_HOME_SHOTS_DIR=/path/to/out
//
// Output dir: the HOME_SHOTS_DIR env var, else /tmp/unstuck-home-shots.

import XCTest

final class HomeShots: XCTestCase {
    private var app: XCUIApplication!
    private lazy var outDir: URL = {
        let env = ProcessInfo.processInfo.environment["HOME_SHOTS_DIR"]
        return URL(fileURLWithPath: env?.isEmpty == false ? env! : "/tmp/unstuck-home-shots")
    }()

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
        app.launchEnvironment["UITEST_ASSISTANT_CANNED"] = "1"
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

    private func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    private func expect(_ e: XCUIElement, _ why: String, timeout: TimeInterval = 8,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), why, file: file, line: line)
    }

    func testHomeLightDarkAndInterviewThread() throws {
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 15),
                      "the demo boot never reached Today")
        // A fresh container asks for notification permission on first launch;
        // the interruption monitor only fires on interaction, so clear the
        // system alert explicitly before shooting the home.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap(); usleep(800_000) }
        let pill = app.buttons["home-ask-pill"].firstMatch
        expect(pill, "the assistant input pill is missing under the week pill")
        expect(app.buttons["week-pill"].firstMatch, "the week pill is missing")
        usleep(1_200_000)
        save("01-home-light")

        XCUIDevice.shared.appearance = .dark
        usleep(1_500_000)
        save("02-home-dark")
        XCUIDevice.shared.appearance = .light
        usleep(900_000)

        // The pill opens the assistant with focus in ITS composer; the first
        // message is answered (canned) BEFORE the interview's first question
        // appears with its chips.
        pill.tap()
        let field = app.textFields["assistant-input"]
        expect(field, "the assistant sheet's composer did not open", timeout: 10)
        usleep(700_000)
        if !field.isHittable { field.tap() }
        field.typeText("Hi — can you help me plan?")
        let send = app.buttons["Send"].firstMatch
        expect(send, "the assistant Send button is missing")
        send.tap()
        let question = app.staticTexts["When’s your head clearest?"].firstMatch
        expect(question, "the interview's first question never appeared after the reply", timeout: 15)
        expect(app.buttons["Morning"].firstMatch, "the question's chips are missing")
        expect(app.buttons["Skip this question"].firstMatch, "the question's Skip is missing")
        usleep(1_000_000)
        save("03-assistant-interview")
    }
}

// Calendar → Day → tap a task block: the Edit-block sheet's Mark done / Start
// focus / Open task (Ahmad, 2026-09-24: "Can't complete a task from
// calendar"). Demo boot + UITEST_CALENDAR (a daily "Take vitamins" series with
// an occurrence at the current hour). Shoots the sheet on a plain task (open,
// then done after its own Mark done), on the occurrence (open, then done), and
// the two follow-ups (Open task → the editor, Start focus → Focus).
//
//   xcodebuild test … -only-testing:UnstuckUITests/CalendarBlockSheetShots \
//     TEST_RUNNER_CALBLOCK_SHOTS_DIR=/path/to/out

final class CalendarBlockSheetShots: XCTestCase {
    private var app: XCUIApplication!
    private lazy var outDir: URL = {
        let env = ProcessInfo.processInfo.environment["CALBLOCK_SHOTS_DIR"]
        return URL(fileURLWithPath: env?.isEmpty == false ? env! : "/tmp/unstuck-calblock-shots")
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
        app.launchEnvironment["UITEST_CALENDAR"] = "1"
        XCUIDevice.shared.appearance = .light
        app.launch()
    }

    private func save(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    private var toggle: XCUIElement { app.buttons["cal-block-toggle-done"].firstMatch }

    /// Tap a block on the Day grid by its name and wait for its sheet.
    private func openBlock(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let block = app.staticTexts[name].firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 8), "no \(name) block on the Day grid", file: file, line: line)
        block.tap()
        XCTAssertTrue(app.buttons["cal-block-open"].firstMatch.waitForExistence(timeout: 6),
                      "the Edit-block sheet for \(name) has no Open task", file: file, line: line)
        usleep(900_000)
    }

    private func closeSheet() {
        app.navigationBars.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["cal-block-open"].firstMatch.waitForNonExistence(timeout: 6))
        usleep(500_000)
    }

    func testMarkDoneFocusAndOpenFromTheCalendarBlockSheet() throws {
        // A fresh container asks for notification permission first.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap(); usleep(800_000) }
        XCTAssertTrue(app.buttons["Day"].firstMatch.waitForExistence(timeout: 15), "the demo boot never reached Calendar")
        usleep(1_000_000)

        // Plain task, open → Mark done.
        openBlock("Reply to Sarah")
        XCTAssertEqual(toggle.label, "Mark done")
        XCTAssertTrue(app.buttons["cal-block-focus"].exists)
        save("01-plain-open")
        toggle.tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 6), "Mark done closes the sheet")
        usleep(900_000)
        save("02-grid-after-mark-done")

        // Reopened: the same block now offers the undo.
        openBlock("Reply to Sarah")
        XCTAssertEqual(toggle.label, "Mark not done")
        save("03-plain-done")
        closeSheet()

        // One day of a repeating series.
        openBlock("Take vitamins")
        XCTAssertEqual(toggle.label, "Mark done")
        save("04-occurrence-open")
        toggle.tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 6))
        usleep(900_000)
        openBlock("Take vitamins")
        XCTAssertEqual(toggle.label, "Mark not done", "only this day is done — and it can be undone")
        save("05-occurrence-done")
        XCUIDevice.shared.appearance = .dark
        usleep(1_200_000)
        save("06-occurrence-done-dark")
        XCUIDevice.shared.appearance = .light
        usleep(900_000)
        closeSheet()

        // Open task → the task editor on that task.
        openBlock("Draft the Q3 proposal")
        app.buttons["cal-block-open"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Share task"].firstMatch.waitForExistence(timeout: 8), "Open task opens the editor")
        usleep(900_000)
        save("07-open-task-editor")
        app.navigationBars.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Share task"].firstMatch.waitForNonExistence(timeout: 6))
        usleep(700_000)

        // Start focus → the Focus screen.
        openBlock("Draft the Q3 proposal")
        app.buttons["cal-block-focus"].firstMatch.tap()
        XCTAssertTrue(app.buttons["cal-block-focus"].firstMatch.waitForNonExistence(timeout: 6))
        XCTAssertTrue(app.buttons["Capture"].firstMatch.waitForExistence(timeout: 8), "Start focus opens Focus")
        usleep(1_200_000)
        save("08-start-focus")
    }
}
