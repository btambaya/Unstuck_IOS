// The user-visible half of the crash trail: after a session that faulted, the
// feedback composer (Settings → Account → Send feedback) must OFFER the
// report — visibly, toggleable, on by default. That is what turns the next
// "it crashed" one-liner into something with a stack in it.
//
// XCUITest cannot survive the app faulting underneath it, so the CAPTURE half
// (signal handler, exception handler, next-launch pickup) is verified outside
// XCUITest, by launching with UITEST_FORCE_CRASH and reading the trail out of
// the app container:
//
//   SIMCTL_CHILD_UITEST_SEED=1 SIMCTL_CHILD_UITEST_FORCE_CRASH=signal \
//     xcrun simctl launch --terminate-running-process <device> io.unstucknow.app
//   cat "$(xcrun simctl get_app_container <device> io.unstucknow.app data)"\
//       "/Library/Application Support/diagnostics/breadcrumbs.log"
//
// This test covers the other half: a clean run must not offer anything.

import XCTest

final class CrashReportAttachUITests: XCTestCase {

    func testACleanSessionOffersNoCrashReport() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 30), "app never came up")
        usleep(1_200_000)
        app.buttons["Account and settings"].firstMatch.tap()
        usleep(1_200_000)

        // By IDENTIFIER: Settings is a sheet over Today, so a bare label query
        // can resolve to something behind it.
        let account = app.buttons["settings-row-Account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), "Settings never opened")
        account.tap()
        XCTAssertTrue(app.staticTexts["Your account."].firstMatch.waitForExistence(timeout: 8),
                      "Settings → Account never opened")

        let feedback = app.staticTexts["Send feedback"].firstMatch
        for _ in 0..<12 where !feedback.exists || !feedback.isHittable {
            app.swipeUp(); usleep(300_000)
        }
        XCTAssertTrue(feedback.waitForExistence(timeout: 10), "Account → Send feedback missing")
        XCTAssertTrue(feedback.isHittable, "Account → Send feedback never scrolled into reach")
        feedback.tap()
        usleep(1_000_000)

        XCTAssertTrue(app.buttons["Send"].firstMatch.waitForExistence(timeout: 10), "composer never opened")
        XCTAssertFalse(app.switches["Attach the last crash report"].firstMatch.exists,
                       "a clean run must not offer a crash report")
    }
}
