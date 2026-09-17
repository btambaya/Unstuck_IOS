// Home + interview-in-thread screenshots — runs against the network-free demo
// boot (UITEST_SEED + a canned assistant reply) and writes full-resolution
// PNGs: the Today home in light and dark (one-line greeting, week pill, the
// assistant input pill, the Start-Next hero, the list) and the assistant
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
