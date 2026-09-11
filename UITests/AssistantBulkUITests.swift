// Crash repro for the live tester reports (TestFlight 33/34/41): "the ai
// crashed after being asked to add a lot of items to the calendar", "it was
// successful but then the app stopped responding", "crashed after I tried
// exiting the AI".
//
// Drives the REAL app (network-free demo boot) through a scripted bulk
// assistant turn — 25 create_tasks with times + 25 block_time in one turn — so
// the whole stack runs it: the harness on the main actor, the executor's 50
// awaited GRDB writes, 50 receipt rows in the sheet's LazyVStack, the calendar
// relayout over 50 overlapping blocks, the reminder rescheduler and the widget
// snapshot. Then it exits the sheet mid/post-turn and walks the calendar.
//
// The app staying alive IS the assertion.

import XCTest

final class AssistantBulkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
        app.launchEnvironment["UITEST_ASSISTANT_BULK"] = "1"
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

    private func nextDay() {
        let b = app.buttons["Next day"].firstMatch
        if b.waitForExistence(timeout: 6) { b.tap() }
    }

    private func openAssistant() {
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 30), "never reached the app")
        let bubble = app.buttons["Assistant"].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "assistant launcher missing")
        bubble.tap()
    }

    private func send(_ text: String) {
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "assistant input missing")
        field.tap()
        field.typeText(text)
        app.buttons["Send"].firstMatch.tap()
    }

    /// The whole bulk turn with the sheet open the entire time.
    func testBulkCalendarTurnWithTheSheetOpen() throws {
        openAssistant()
        snap("00-assistant-open")
        send("put 50 things on tomorrow")
        // The turn runs three rounds; give it room, then look at the receipts.
        usleep(6_000_000)
        snap("01-after-bulk-turn")
        XCTAssertTrue(app.buttons["Today"].firstMatch.exists || app.textViews.firstMatch.exists,
                      "the app is gone — the bulk turn took it down")
        // Scroll the thread (50+ receipt rows in a LazyVStack).
        app.swipeUp(); app.swipeUp(); app.swipeDown()
        snap("02-thread-scrolled")
    }

    /// "I tried exiting the AI … and then it crashed" — dismiss the sheet WHILE
    /// the turn is still writing, then use the app.
    func testExitingTheSheetMidBulkTurnThenWalkingTheCalendar() throws {
        openAssistant()
        send("put 50 things on tomorrow")
        // Exit immediately — the turn keeps running detached, writing 50 rows
        // into a store the Today/Calendar screens are observing.
        usleep(400_000)
        app.swipeDown(velocity: .fast)
        usleep(300_000)
        app.swipeDown(velocity: .fast)
        snap("10-exited-mid-turn")

        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 15), "the app died on exiting the sheet")
        usleep(4_000_000)
        snap("11-today-after-burst")

        // Walk the calendar over the 50-block day (lane layout worst case).
        // Everything landed on TOMORROW, so step the day forward first.
        app.buttons["Calendar"].firstMatch.tap(); usleep(1_200_000)
        nextDay(); usleep(1_500_000); snap("12-calendar-day-tomorrow")
        app.swipeUp(); usleep(400_000); app.swipeDown(); usleep(400_000)
        snap("12b-calendar-day-scrolled")
        if app.staticTexts["Week"].firstMatch.waitForExistence(timeout: 4) {
            app.staticTexts["Week"].firstMatch.tap(); usleep(1_500_000); snap("13-calendar-week")
            app.swipeUp(); usleep(400_000); app.swipeDown(); usleep(400_000)
        }
        if app.staticTexts["Month"].firstMatch.exists {
            app.staticTexts["Month"].firstMatch.tap(); usleep(1_200_000); snap("14-calendar-month")
        }
        if app.staticTexts["Day"].firstMatch.exists {
            app.staticTexts["Day"].firstMatch.tap(); usleep(1_200_000)
        }
        app.swipeUp(); app.swipeUp(); app.swipeDown()
        snap("15-calendar-scrolled")
        app.buttons["Tasks"].firstMatch.tap(); usleep(1_200_000); snap("16-tasks")
        XCTAssertTrue(app.buttons["Today"].firstMatch.exists, "the app died walking the calendar after the burst")
    }

    /// Reopen the sheet after the burst and send again — the second turn
    /// replays a 50-turn thread AND re-renders every receipt.
    func testReopeningAndSendingAgainAfterTheBurst() throws {
        openAssistant()
        send("put 50 things on tomorrow")
        usleep(6_000_000)
        app.swipeDown(velocity: .fast); usleep(400_000)
        app.swipeDown(velocity: .fast); usleep(600_000)
        openAssistant()
        usleep(800_000)
        snap("20-reopened")
        send("and again")
        usleep(6_000_000)
        snap("21-second-turn")
        XCTAssertTrue(app.buttons["Send"].firstMatch.exists || app.buttons["Today"].firstMatch.exists,
                      "the app died on the second bulk turn")
    }
}
