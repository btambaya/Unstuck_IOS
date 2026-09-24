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
    }
}

// Colour sweep screenshots (2026-09-24, Ahmad: every ON switch is coral; no
// indigo accent anywhere — links/inline actions ink, chips the ink/bg pair,
// the voice orb coral). Walks every screen the sweep touched, in light and
// dark, against the network-free demo boot; the auth screen is shot from a
// boot WITHOUT the seed (signed out). Not a behaviour test; a failure means
// a screen it claims to have shot didn't render.
//
//   xcodebuild test … -only-testing:UnstuckUITests/ColourShots \
//     TEST_RUNNER_COLOUR_SHOTS_DIR=/path/to/out
//
// Output dir: the COLOUR_SHOTS_DIR env var, else /tmp/unstuck-colour-shots.
final class ColourShots: XCTestCase {
    private var app: XCUIApplication!
    private lazy var outDir: URL = {
        let env = ProcessInfo.processInfo.environment["COLOUR_SHOTS_DIR"]
        return URL(fileURLWithPath: env?.isEmpty == false ? env! : "/tmp/unstuck-colour-shots")
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

    private func setMode(_ mode: String) {
        XCUIDevice.shared.appearance = mode == "dark" ? .dark : .light
        usleep(1_500_000)
    }

    private func tapNav(_ label: String) {
        let b = app.buttons[label].firstMatch
        expect(b, "bottom nav '\(label)' is missing")
        b.tap(); usleep(800_000)
    }

    private func back() { app.navigationBars.buttons.firstMatch.tap(); usleep(700_000) }

    private func row(_ id: String) -> XCUIElement { app.descendants(matching: .any)["settings-row-\(id)"].firstMatch }

    /// The first element of `q` a tap would actually reach.
    private func hittable(_ q: XCUIElementQuery, timeout: TimeInterval = 4) -> XCUIElement? {
        _ = q.firstMatch.waitForExistence(timeout: timeout)
        return q.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
    }

    /// Pull a sheet (no Done button) down by its grabber area.
    private func dismissSheet(_ title: String) {
        for _ in 0..<3 where app.navigationBars[title].exists {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
            top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            usleep(1_000_000)
        }
        XCTAssertFalse(app.navigationBars[title].exists, "the \(title) sheet did not close")
    }

    /// Share of `e`'s on-screen pixels within `tol` (per channel) of `rgb`.
    /// `rightmost` narrows it to that many points at the element's trailing
    /// edge (a labelled switch's frame is the whole row; the track is at the end).
    private func share(of e: XCUIElement, near rgb: (Int, Int, Int), tol: Int = 26,
                       rightmost: CGFloat? = nil) -> Double {
        guard e.exists, let cg = XCUIScreen.main.screenshot().image.cgImage else { return 0 }
        let scale = CGFloat(cg.width) / app.frame.width
        var f = e.frame
        if let r = rightmost, f.width > r { f = CGRect(x: f.maxX - r, y: f.minY, width: r, height: f.height) }
        let rect = CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let crop = cg.cropping(to: rect), crop.width > 0, crop.height > 0 else { return 0 }
        let (w, h) = (crop.width, crop.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hits = 0
        for i in stride(from: 0, to: px.count, by: 4)
        where abs(Int(px[i]) - rgb.0) <= tol && abs(Int(px[i + 1]) - rgb.1) <= tol && abs(Int(px[i + 2]) - rgb.2) <= tol {
            hits += 1
        }
        return Double(hits) / Double(w * h)
    }

    /// An ON switch paints its track the brand coral #E89077 (Ahmad,
    /// 2026-09-24) — not the old indigo.
    private func assertCoralSwitch(_ sw: XCUIElement, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sw.exists, "\(what): switch missing", file: file, line: line)
        XCTAssertEqual(sw.value as? String, "1", "\(what): expected ON", file: file, line: line)
        let coral = share(of: sw, near: (0xE8, 0x90, 0x77), rightmost: 96)
        XCTAssertGreaterThan(coral, 0.05, "\(what): the ON track is not coral (\(coral))", file: file, line: line)
    }

    /// Every screen the sweep touched, in the current appearance.
    private func walk(_ mode: String) {
        tapNav("Today")
        save("\(mode)-01-today")

        // Tasks: bucket pills, row tag chips, the tag-filter banner, Later.
        tapNav("Tasks")
        expect(app.staticTexts["Your tasks"].firstMatch, "the Tasks tab did not switch")
        save("\(mode)-02-tasks")
        let tagChip = app.buttons["#deep-work"].firstMatch
        if tagChip.waitForExistence(timeout: 4) {
            tagChip.tap(); usleep(700_000)
            save("\(mode)-03-tasks-tag-filter")
            let banner = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Filtering by tag'")).firstMatch
            if banner.waitForExistence(timeout: 3) { banner.tap(); usleep(600_000) }
        } else {
            XCTFail("no #deep-work tag chip on the Tasks rows")
        }
        // The task editor: tag chips + recurrence chips.
        // The Tasks row (a Button) — not Today's same-named row kept alive
        // behind the tab.
        if let proposal = hittable(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Draft the Q3 proposal'"))) {
            proposal.tap(); usleep(1_000_000)
            save("\(mode)-04-task-editor")
            app.swipeUp(); usleep(600_000)
            save("\(mode)-05-task-editor-tags")
            let done = app.navigationBars.buttons["Done"].firstMatch
            if done.exists { done.tap() } else { app.swipeDown(velocity: .fast) }
            usleep(900_000)
        } else {
            XCTFail("the seeded proposal row is missing on Tasks")
        }
        let later = app.buttons["Later"].firstMatch
        expect(later, "the Later bucket pill is missing")
        later.tap(); usleep(700_000)
        save("\(mode)-06-tasks-later")
        app.buttons["All"].firstMatch.tap(); usleep(500_000)

        // Calendar: the week rollup + the month heat map and its legend.
        tapNav("Calendar")
        let week = app.buttons["Week"].firstMatch
        expect(week, "the Calendar Week segment is missing")
        week.tap(); usleep(800_000)
        save("\(mode)-07-calendar-week")
        app.buttons["Month"].firstMatch.tap(); usleep(800_000)
        save("\(mode)-08-calendar-month")
        app.buttons["Day"].firstMatch.tap(); usleep(500_000)

        // Insights: the eyebrow + the charts.
        tapNav("Today")
        let pill = app.buttons["week-pill"].firstMatch
        expect(pill, "the Today week pill is missing")
        pill.tap()
        expect(app.navigationBars["Insights"], "the week pill did not open Insights")
        save("\(mode)-09-insights")
        app.swipeUp(); app.swipeUp(); usleep(600_000)
        save("\(mode)-10-insights-charts")
        // Deep dive: "Captures by kind" + "How fast you come back".
        app.swipeDown(); app.swipeDown(); usleep(600_000)
        let deep = app.buttons["Deep dive"].firstMatch
        if deep.waitForExistence(timeout: 3) {
            deep.tap(); usleep(1_000_000)
            for i in 0..<5 { app.swipeUp(); usleep(500_000); save("\(mode)-11-insights-deep-\(i)") }
            app.swipeDown(); app.swipeDown(); app.swipeDown(); usleep(500_000)
            app.buttons["Report"].firstMatch.tap(); usleep(700_000)
        } else {
            XCTFail("Insights has no Deep dive segment")
        }
        dismissSheet("Insights")

        // Captures: "Promote →".
        let captures = app.buttons["Captures"].firstMatch
        expect(captures, "the Today Captures button is missing")
        captures.tap()
        expect(app.navigationBars["Captures"], "Captures did not open")
        save("\(mode)-12-captures")
        app.navigationBars["Captures"].buttons["Done"].firstMatch.tap(); usleep(900_000)

        // Settings: the switches.
        app.buttons["Account and settings"].firstMatch.tap()
        expect(row("notifications"), "Settings did not open")
        save("\(mode)-13-settings-hub")
        row("notifications").tap()
        expect(app.staticTexts["How Unstuck reaches you."].firstMatch, "Notifications & calls did not open")
        app.swipeUp(); usleep(600_000)
        save("\(mode)-14-settings-calls-switches")
        assertCoralSwitch(app.switches["settings-calls-switch"].firstMatch, "\(mode) Let Unstuck call this phone")
        app.swipeUp(); usleep(600_000)
        save("\(mode)-15-settings-calls-switches-2")
        back()
        row("assistant").tap()
        expect(app.staticTexts["What the AI can see."].firstMatch, "Assistant & privacy did not open")
        save("\(mode)-16-settings-assistant-switches")
        assertCoralSwitch(app.switches["settings-ai-data-sharing"].firstMatch, "\(mode) AI data sharing")
        back()
        row("people").tap()
        expect(app.staticTexts["People you share with."].firstMatch, "People did not open")
        save("\(mode)-17-settings-people")
        back()
        app.buttons["Done"].firstMatch.tap(); usleep(900_000)

        // Talk: the orb + "Noisy room? Hold to talk".
        app.buttons["Assistant"].firstMatch.tap()
        let talk = app.buttons["Talk"].firstMatch
        expect(talk, "the Talk button is missing")
        talk.tap()
        expect(app.descendants(matching: .any)["talk-hold-to-talk"].firstMatch, "Talk has no hold-to-talk switch")
        usleep(1_200_000)
        save("\(mode)-18-talk")
        let hold = app.switches["talk-hold-to-talk"].firstMatch
        if hold.exists {
            hold.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap(); usleep(1_000_000)
            save("\(mode)-19-talk-hold-on")
            assertCoralSwitch(hold, "\(mode) Noisy room? Hold to talk")
            hold.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap(); usleep(600_000)
        } else {
            XCTFail("the hold-to-talk switch is not a switch")
        }
        let close = app.buttons["Close voice mode"].firstMatch
        if close.exists { close.tap(); usleep(900_000) }
        if app.buttons["Close voice mode"].exists { app.buttons["Close voice mode"].firstMatch.tap(); usleep(900_000) }
        // The assistant sheet the Talk button sat in.
        for _ in 0..<3 where app.buttons["Talk"].firstMatch.exists {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
            top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            usleep(1_000_000)
        }
    }

    func testColourSweepLightAndDark() throws {
        launchToToday()
        walk("light")
        setMode("dark")
        walk("dark")
    }

    /// Focus ⋯ Options — the focus switches.
    func testColourFocusOptions() throws {
        app.launchEnvironment["UITEST_FOCUS"] = "1"
        launchToToday()
        for mode in ["light", "dark"] {
            setMode(mode)
            let options = app.buttons["focus-options"].firstMatch
            expect(options, "the Focus screen has no ⋯ Options button", timeout: 12)
            options.tap()
            expect(app.staticTexts["Check in when I run over"].firstMatch, "Focus options did not open")
            save("\(mode)-20-focus-options")
            assertCoralSwitch(app.switches.matching(NSPredicate(format: "value == '1'")).firstMatch, "\(mode) Focus options")
            app.navigationBars["Focus options"].buttons["Done"].firstMatch.tap(); usleep(900_000)
        }
    }

    /// The tour: welcome card + a spotlit step (progress dots, ring).
    func testColourTour() throws {
        app.launchEnvironment["UITEST_TOUR"] = "1"
        app.launch()
        for mode in ["light", "dark"] {
            setMode(mode)
            if mode == "light" {
                expect(app.staticTexts["Welcome to Unstuck"].firstMatch, "the tour welcome never showed", timeout: 20)
                save("\(mode)-21-tour-welcome")
                app.staticTexts["Essential tour"].firstMatch.tap()
                expect(app.staticTexts["This is Unstuck"].firstMatch, "the first tour step never showed", timeout: 12)
                usleep(900_000)
                app.buttons["Continue"].firstMatch.tap(); usleep(1_800_000)
            } else {
                usleep(900_000)
            }
            save("\(mode)-22-tour-step")
        }
    }

    /// Signed out (no seed): the auth screen's eyebrow + links.
    func testColourAuth() throws {
        app.launchEnvironment["UITEST_SEED"] = nil
        app.launch()
        let google = app.buttons["Continue with Google"].firstMatch
        expect(google, "the signed-out boot did not reach the auth screen", timeout: 20)
        for mode in ["light", "dark"] {
            setMode(mode)
            save("\(mode)-23-auth")
        }
    }
}
