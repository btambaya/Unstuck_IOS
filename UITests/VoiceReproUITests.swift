// Manual end-to-end harness for realtime voice ("Talk"). Unlike the rest of
// UITests it runs the REAL app against the REAL backend and the REAL voice
// proxy: it signs in, opens Talk, and watches the screen until the assistant
// is speaking. That is the only way to tell the three failure classes apart —
// a dead transport, a dead mic, or a precondition that dead-ends the screen
// before either (the 2026-09-11 bug: `voiceAccessToken` was nil, so Talk showed
// "Please sign in to use voice." while the app was plainly signed in).
//
// It SKIPS unless credentials are passed in, so no password lives in the repo
// and it never runs (or burns realtime-model quota) by accident:
//
//   xcodebuild test -project Unstuck.xcodeproj -scheme Unstuck \
//     -destination 'platform=iOS Simulator,name=iPhone 17' \
//     -only-testing:UnstuckUITests/VoiceReproUITests \
//     VOICE_REPRO_EMAIL=you@example.com VOICE_REPRO_PASSWORD=…
//
// (`xcodebuild` does not forward environment variables to a UI-test runner, so
// from the CLI inject them into the .xctestrun that `build-for-testing` emits —
// its `UnstuckUITests` → `TestingEnvironmentVariables` dictionary — and run it
// with `test-without-building`. In Xcode, the scheme's Test environment works.)
//
// Grant the microphone once first, or the permission alert stalls the run at
// "Connecting…" with nobody to tap Allow:
//   xcrun simctl privacy booted grant microphone io.unstucknow.app
//
// Pair it with `xcrun simctl spawn booted log stream --level debug --predicate
// 'subsystem == "io.unstucknow.app"'` to see the voice + Supabase lifecycle.
//
// NOTE: a DEBUG simulator build is unsigned (project.yml sets
// CODE_SIGNING_ALLOWED=NO), so it has no `application-identifier` entitlement
// and EVERY keychain call returns −34018. The Supabase session therefore never
// persists in the simulator: this test has to sign in on each run, and the app
// is signed out again on the next launch. That is a simulator artifact, not a
// product bug — but it is exactly why voice must not depend on a keychain read.

import XCTest

final class VoiceReproUITests: XCTestCase {
    private var app: XCUIApplication!

    private var credentials: (email: String, password: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let e = env["VOICE_REPRO_EMAIL"], !e.isEmpty,
              let p = env["VOICE_REPRO_PASSWORD"], !p.isEmpty else { return nil }
        return (e, p)
    }

    override func setUpWithError() throws {
        try XCTSkipIf(credentials == nil,
                      "set VOICE_REPRO_EMAIL / VOICE_REPRO_PASSWORD to run the live voice harness")
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The one label the voice screen shows for its current state — the whole
    /// diagnosis in one string ("Connecting…" forever, an error note, or the
    /// listening → thinking → speaking progression we want).
    /// One snapshot of every label on screen. Taken in a SINGLE query: the
    /// voice orb animates forever once the session is live, and each separate
    /// element query pays another "wait for the app to idle" against it.
    private func screenLabels() -> [String] {
        var labels: [String] = []
        for e in app.staticTexts.allElementsBoundByIndex.prefix(6) { labels.append(e.label) }
        return labels
    }

    func testTalkReachesALiveConversation() throws {
        let creds = try XCTUnwrap(credentials)

        // --- sign in (skipped when a session survived from a previous run) ---
        let email = app.textFields["Email"].firstMatch
        if email.waitForExistence(timeout: 25) {
            email.tap(); email.typeText(creds.email)
            let pw = app.secureTextFields["Password"].firstMatch
            pw.tap(); pw.typeText(creds.password)
            app.buttons["Sign in"].firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 60),
                      "never reached the signed-in app")
        usleep(3_000_000)
        snap("01-signed-in")

        // --- Assistant sheet → Talk ---
        app.buttons["Assistant"].firstMatch.tap()
        let talk = app.buttons["Talk"].firstMatch
        XCTAssertTrue(talk.waitForExistence(timeout: 10),
                      "the Talk button is missing — voice is unconfigured in this build")
        talk.tap()
        XCTAssertTrue(app.buttons["Close voice mode"].firstMatch.waitForExistence(timeout: 10),
                      "tapping Talk did not present the voice screen")
        // --- the session must actually come alive ---
        let live: Set<String> = ["Listening…", "Speaking…", "Thinking…", "Hold the button to talk"]
        var reached: Set<String> = []
        for i in 0..<8 {
            let labels = screenLabels()
            print("VOICE-SCREEN[\(i)] \(labels)")
            reached.formUnion(labels)
            if !reached.isDisjoint(with: live) { break }
            snap("02-voice-\(i)")
            usleep(2_500_000)
        }
        snap("03-voice-final")
        XCTAssertFalse(reached.contains("Please sign in to use voice."),
                       "the app is signed in but voice could not get an access token")
        XCTAssertFalse(reached.contains("Voice isn't set up yet."),
                       "VOICE_PROXY_HOST / VOICE_PROXY_URL is missing from this build")
        XCTAssertFalse(reached.isDisjoint(with: live),
                       "voice never reached a live session; screen showed: \(reached.sorted())")
    }
}
