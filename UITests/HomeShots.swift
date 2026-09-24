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

// Slim Settings screenshots (2026-09-24) — the hub and every screen it pushes,
// in light and dark, plus the controls that moved OUT of Settings onto the
// screens they change (Focus ⋯ Options, the Tasks "Edit" pill's Areas & tags
// sheet, Talk's "Noisy room? Hold to talk", the share screen's "Manage
// people") and the one-line Calls block without the AI OK. Not a behaviour
// test; a failure means a screen it claims to have shot didn't render.
//
//   xcodebuild test … -only-testing:UnstuckUITests/SettingsShots \
//     TEST_RUNNER_SETTINGS_SHOTS_DIR=/path/to/out
//
// Output dir: the SETTINGS_SHOTS_DIR env var, else /tmp/unstuck-settings-shots.
final class SettingsShots: XCTestCase {
    private var app: XCUIApplication!
    private lazy var outDir: URL = {
        let env = ProcessInfo.processInfo.environment["SETTINGS_SHOTS_DIR"]
        return URL(fileURLWithPath: env?.isEmpty == false ? env! : "/tmp/unstuck-settings-shots")
    }()

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
        addUIInterruptionMonitor(withDescription: "system-alert") { alert in
            for label in ["Allow", "Don’t Allow", "OK", "Continue"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        XCUIDevice.shared.appearance = .light
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
    }

    private func save(_ name: String) {
        usleep(700_000)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    private func expect(_ e: XCUIElement, _ why: String, timeout: TimeInterval = 8,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), why, file: file, line: line)
    }

    private func launchToToday() {
        app.launch()
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 15),
                      "the demo boot never reached Today")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap(); usleep(800_000) }
    }

    /// A confirmation dialog's cancel button — on iOS 26 it may only be
    /// "tap outside".
    private func cancelDialog(_ label: String) {
        let b = app.buttons[label].firstMatch
        if b.exists && b.isHittable { b.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).tap()
        }
        usleep(900_000)
    }

    private func row(_ id: String) -> XCUIElement { app.descendants(matching: .any)["settings-row-\(id)"].firstMatch }

    private func back() {
        app.navigationBars.buttons.firstMatch.tap(); usleep(700_000)
    }

    /// Every Settings screen, in the current appearance.
    private func shootSettings(_ mode: String) {
        let avatar = app.buttons["Account and settings"].firstMatch
        expect(avatar, "the Today header avatar is missing")
        avatar.tap()
        expect(row("account"), "Settings did not open")
        save("\(mode)-01-hub")

        row("account").tap()
        expect(app.staticTexts["Your account."].firstMatch, "Account did not open")
        save("\(mode)-02-account")
        back()

        row("notifications").tap()
        expect(app.staticTexts["How Unstuck reaches you."].firstMatch, "Notifications & calls did not open")
        save("\(mode)-03-notifications-top")
        app.swipeUp(); usleep(500_000)
        save("\(mode)-04-notifications-calls")
        app.swipeUp(); usleep(500_000)
        save("\(mode)-05-notifications-bottom")
        back()

        row("assistant").tap()
        expect(app.staticTexts["What the AI can see."].firstMatch, "Assistant & privacy did not open")
        save("\(mode)-06-assistant")
        let remembers = app.descendants(matching: .any)["settings-remembers"].firstMatch
        expect(remembers, "What Unstuck remembers row is missing")
        remembers.tap()
        expect(app.staticTexts["What Unstuck remembers."].firstMatch, "What Unstuck remembers did not open")
        save("\(mode)-07-remembers")
        back()
        back()

        row("people").tap()
        expect(app.staticTexts["People you share with."].firstMatch, "People did not open")
        save("\(mode)-08-people")
        back()

        row("appearance").tap()
        expect(app.staticTexts["How it looks."].firstMatch, "Appearance did not open")
        save("\(mode)-09-appearance")
        back()

        row("feedback").tap()
        usleep(1_200_000)
        save("\(mode)-10-feedback")
        app.swipeDown(velocity: .fast); usleep(900_000)
        if !row("account").isHittable { app.swipeDown(velocity: .fast); usleep(900_000) }

        app.buttons["Done"].firstMatch.tap(); usleep(900_000)
    }

    func testSettingsLightAndDark() throws {
        launchToToday()
        shootSettings("light")
        XCUIDevice.shared.appearance = .dark
        usleep(1_500_000)
        shootSettings("dark")

        // Talk: "Noisy room? Hold to talk" moved here from Settings.
        app.buttons["Assistant"].firstMatch.tap()
        let talk = app.buttons["Talk"].firstMatch
        expect(talk, "the Talk button is missing")
        talk.tap()
        expect(app.descendants(matching: .any)["talk-hold-to-talk"].firstMatch, "Talk has no hold-to-talk switch")
        save("dark-11-talk")
    }

    func testMovedControlsAndCallsWithoutTheAIOK() throws {
        app.launchEnvironment["UITEST_AI_CONSENT"] = "0"
        app.launchEnvironment["UITEST_FOCUS"] = "1"
        launchToToday()
        // Focus ⋯ Options — the focus settings that used to live in Settings.
        let options = app.buttons["focus-options"].firstMatch
        expect(options, "the Focus screen has no ⋯ Options button", timeout: 12)
        save("moved-01-focus")
        options.tap()
        expect(app.staticTexts["Check in when I run over"].firstMatch, "Focus options did not open")
        save("moved-02-focus-options")
        // The sheet's own Done — the Focus screen has a "Done" (finish) too.
        app.navigationBars["Focus options"].buttons["Done"].firstMatch.tap(); usleep(900_000)
        XCTAssertFalse(app.staticTexts["Check in when I run over"].firstMatch.exists, "Focus options did not close")

        // "Ask before I leave" offers "don't ask again" on the question itself.
        app.buttons["← Out"].firstMatch.tap(); usleep(900_000)
        expect(app.buttons["Leave and don't ask again"].firstMatch, "the leave question has no don't-ask-again")
        save("moved-03-leave-confirm")
        cancelDialog("Stay")
        app.buttons["Pause"].firstMatch.tap(); usleep(900_000)
        expect(app.buttons["Don't ask again"].firstMatch, "the pause question has no don't-ask-again")
        save("moved-04-pause-reasons")
        cancelDialog("Just pause")
        app.buttons["← Out"].firstMatch.tap(); usleep(1_200_000)
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 6), "leaving Focus did not return to the app")

        // Tasks → "Edit" → Areas & tags.
        app.buttons["Tasks"].firstMatch.tap(); usleep(900_000)
        let edit = app.buttons["tasks-edit-areas"].firstMatch
        expect(edit, "Tasks has no Edit pill on the area row")
        save("moved-05-tasks-edit-pill")
        edit.tap()
        expect(app.staticTexts["The parts of your life."].firstMatch, "the Areas & tags sheet did not open")
        save("moved-06-areas-tags")
        app.swipeUp(); usleep(600_000)
        save("moved-07-areas-tags-tags")
        app.navigationBars.buttons["Done"].firstMatch.tap(); usleep(900_000)

        // A list's Share screen → "Manage people" → People.
        app.buttons["Collections"].firstMatch.tap(); usleep(900_000)
        let groceries = app.staticTexts["Groceries"].firstMatch
        expect(groceries, "the seeded Groceries list is missing")
        groceries.press(forDuration: 1.2)
        let share = app.buttons["Share…"].firstMatch
        expect(share, "the list card has no Share…")
        share.tap()
        let manage = app.buttons["share-manage-people"].firstMatch
        expect(manage, "the share screen has no Manage people link")
        save("moved-08-share-manage-people")
        manage.tap()
        expect(app.staticTexts["People you share with."].firstMatch, "Manage people did not open People")
        save("moved-09-share-people")
        app.navigationBars.buttons.firstMatch.tap(); usleep(600_000)
        app.buttons["Done"].firstMatch.tap(); usleep(900_000)

        // Notifications & calls without the AI OK: the Calls block is one line.
        app.buttons["Today"].firstMatch.tap(); usleep(900_000)
        app.buttons["Account and settings"].firstMatch.tap()
        expect(row("notifications"), "Settings did not open")
        row("notifications").tap()
        expect(app.staticTexts["How Unstuck reaches you."].firstMatch, "Notifications & calls did not open")
        app.swipeUp(); usleep(600_000)
        expect(app.buttons["settings-calls-turn-on"].firstMatch, "the one-line Calls block is missing")
        save("moved-10-calls-need-ai")
        back()
        row("assistant").tap()
        expect(app.staticTexts["What the AI can see."].firstMatch, "Assistant & privacy did not open")
        save("moved-11-assistant-sharing-off")

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

    /// The two follow-ups on one DAY of a repeating series: Open task lands on
    /// that day's occurrence (the editor offers "Skip today", which only an
    /// occurrence has), Start focus runs Focus on it.
    func testOpenAndFocusOnAnOccurrenceFromTheCalendarBlockSheet() throws {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap(); usleep(800_000) }
        XCTAssertTrue(app.buttons["Day"].firstMatch.waitForExistence(timeout: 15), "the demo boot never reached Calendar")
        usleep(1_000_000)

        openBlock("Take vitamins")
        app.buttons["cal-block-open"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Skip today"].firstMatch.waitForExistence(timeout: 8),
                      "Open task on a day of a series opens THAT day (occurrence editor)")
        usleep(900_000)
        save("09-occurrence-open-task")
        app.navigationBars.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Skip today"].firstMatch.waitForNonExistence(timeout: 6))
        usleep(700_000)

        openBlock("Take vitamins")
        app.buttons["cal-block-focus"].firstMatch.tap()
        XCTAssertTrue(app.buttons["cal-block-focus"].firstMatch.waitForNonExistence(timeout: 6))
        XCTAssertTrue(app.buttons["Capture"].firstMatch.waitForExistence(timeout: 8), "Start focus opens Focus")
        usleep(1_200_000)
        save("10-occurrence-start-focus")
    }
}
