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
        XCTAssertTrue(b.waitForExistence(timeout: 6), "the Calendar's 'Next day' control is missing")
        b.tap()
    }

    private func openAssistant() {
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 30), "never reached the app")
        let bubble = app.buttons["Assistant"].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "assistant launcher missing")
        bubble.tap()
    }

    /// Close the sheet the way a person does: drag it down BY ITS HEADER.
    /// A swipe from the middle of the screen lands in the thread, which a live
    /// turn pins to the bottom — it only scrolls the thread back up and the
    /// sheet never moves. That is how this file used to "exit" nothing: the
    /// Today tab bar still EXISTS behind a sheet, so the next check passed and
    /// the walk then tapped through the sheet (the Calendar tab's spot is the
    /// sheet's input bar).
    private func exitSheet() {
        let header = app.staticTexts["ASK UNSTUCK TO HANDLE IT"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the assistant sheet's header is missing")
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.textFields["assistant-input"].waitForNonExistence(timeout: 5),
                      "the assistant sheet did not close")
    }

    private func send(_ text: String) {
        // By IDENTIFIER — Today's gateway composer is a TextField too and sits
        // behind this sheet, so `textFields.firstMatch` picks the wrong one.
        let field = app.textFields["assistant-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "assistant input missing")
        field.tap()
        field.typeText(text)
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "assistant Send button missing")
        send.tap()
    }

    /// The whole bulk turn with the sheet open the entire time.
    func testBulkCalendarTurnWithTheSheetOpen() throws {
        openAssistant()
        snap("00-assistant-open")
        send("put 50 things on tomorrow")
        // The turn runs three rounds; give it room, then look at the receipts.
        usleep(6_000_000)
        snap("01-after-bulk-turn")
        XCTAssertTrue(app.buttons["Today"].firstMatch.exists || app.textFields["assistant-input"].exists,
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
        exitSheet()
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
        // Day / Week / Month are BUTTONS with an explicit accessibilityLabel —
        // these were written as `staticTexts`, which match nothing, so the
        // week + month relayout (the whole point of the walk) never ran.
        for mode in ["Week", "Month", "Day"] {
            let seg = app.buttons[mode].firstMatch
            XCTAssertTrue(seg.waitForExistence(timeout: 5), "the Calendar '\(mode)' segment is missing")
            seg.tap(); usleep(1_500_000)
            if mode != "Day" { snap(mode == "Week" ? "13-calendar-week" : "14-calendar-month") }
            app.swipeUp(); usleep(400_000); app.swipeDown(); usleep(400_000)
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
        exitSheet(); usleep(600_000)
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
