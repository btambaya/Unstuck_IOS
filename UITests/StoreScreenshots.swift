// App Store screenshot tour — runs against the network-free demo boot
// (UITEST_SEED) on a 6.9" simulator and writes full-resolution PNGs to
// /tmp/unstuck-shots/ for the caption compositor + upload to App Store
// Connect. Not a behavior test; a failure here means a screen it claims to
// have shot didn't render — which is exactly the thing worth failing on,
// since the alternative is shipping a missing or wrong marketing screenshot.
//
// It used to be written as `if element.exists { … save() }` throughout, so a
// screen that stopped rendering just dropped out of the set in silence. Two
// had: the focus + recap shots (Today's then-hero moved under the floating nav
// once the AI gateway card landed above it) and the Tasks shot keyed off an
// "Upcoming" pill that no longer exists.
//
// Focus is entered from a Today ROW's context menu (long-press → "Focus"):
// the Start-Next hero and its Focus button are gone from the home
// (2026-09-18); rows and the task editor are where Focus starts now.

import XCTest

final class StoreScreenshots: XCTestCase {
    private var app: XCUIApplication!
    private let outDir = URL(fileURLWithPath: "/tmp/unstuck-shots")

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
        app.launch()
    }

    private func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    private func tapNav(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let b = app.buttons[label].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 8), "bottom nav '\(label)' is missing",
                      file: file, line: line)
        b.tap()
        usleep(900_000)
    }

    private func expect(_ e: XCUIElement, _ why: String, timeout: TimeInterval = 6,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), why, file: file, line: line)
    }

    /// Scroll `e` clear of the FLOATING bottom nav, which overlays the last
    /// ~110pt of the screen. XCUITest reports elements under it as hittable, so
    /// checking `isHittable` alone taps the nav instead.
    @discardableResult
    private func scrollIntoReach(_ e: XCUIElement, swipes: Int = 8) -> Bool {
        let clear = { e.exists && e.isHittable && e.frame.maxY < self.app.frame.height - 110 }
        for _ in 0..<swipes {
            if clear() { return true }
            app.swipeUp(); usleep(500_000)
        }
        return clear()
    }

    func testStoreTour() throws {
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 15),
                      "the demo boot never reached Today")
        usleep(1_200_000)
        save("01-today")

        // Focus session from a Today row (long-press → context menu → Focus;
        // the seeded proposal task carries a first physical action, so the
        // focus screen shows a real first step), then end it via soft-exit
        // "End for now" (a Button, not a staticText) — the recap card's
        // "JUST NOW" label confirms we landed back on Today before shooting.
        let row = app.staticTexts["Draft the Q3 proposal"].firstMatch
        expect(row, "the seeded 'Draft the Q3 proposal' row is missing from Today — no focus screenshot")
        XCTAssertTrue(scrollIntoReach(row), "the proposal row never cleared the bottom nav")
        row.press(forDuration: 1.2)
        let focus = app.buttons["Focus"].firstMatch
        expect(focus, "the row's context menu has no Focus action")
        focus.tap()
        expect(app.staticTexts["FOCUSING"].firstMatch, "the focus screen did not open")
        usleep(1_200_000)
        save("02-focus")
        let end = app.buttons["End for now"].firstMatch
        expect(end, "the focus screen has no 'End for now'")
        end.tap()
        // Ending a session puts up the "How did that land?" reflection sheet
        // BEFORE Today comes back. The old version of this walk shot right
        // here and filed the result as "03-recap" — it was a picture of the
        // reflection sheet, and every later step then ran against a screen
        // with a sheet over it. Dismiss it, then shoot the real recap card.
        expect(app.staticTexts["How did that land?"].firstMatch, "no reflection sheet after ending focus")
        let skip = app.buttons["Skip"].firstMatch
        expect(skip, "the reflection sheet has no way out")
        skip.tap()
        let recap = app.staticTexts["JUST NOW"].firstMatch
        expect(recap, "no session recap on Today after ending focus", timeout: 8)
        // `exists` is not enough — Today renders behind a sheet, and that is
        // exactly how this walk used to shoot the wrong screen.
        XCTAssertTrue(recap.isHittable, "the recap card is on Today but something is still over it")
        usleep(800_000)
        save("03-recap")

        tapNav("Tasks")
        expect(app.staticTexts["Your tasks"].firstMatch, "the Tasks tab did not switch")
        usleep(400_000)
        save("04-tasks")

        tapNav("Calendar")
        expect(app.buttons["Day"].firstMatch, "the Calendar tab did not switch")
        usleep(900_000)
        save("05-calendar")

        tapNav("Collections")
        let groceries = app.staticTexts["Groceries"].firstMatch
        expect(groceries, "the seeded 'Groceries' list is missing")
        groceries.tap(); usleep(900_000)
        expect(app.staticTexts["Milk"].firstMatch, "the collection detail did not open")
        // The detail auto-focuses its add-item field on open (rapid entry), so
        // the software keyboard covers the lower half of the screen. Open the
        // title's inline rename and submit it unchanged: that path clears the
        // focus state explicitly. (A flick on the short list doesn't start a
        // scroll, so scroll-dismiss can't be relied on.) The store shot is the
        // list, not the keyboard.
        if app.keyboards.count > 0 {
            app.staticTexts["Groceries"].firstMatch.tap(); usleep(500_000)
            app.typeText("\n"); usleep(800_000)
            XCTAssertEqual(app.keyboards.count, 0, "the keyboard is still covering the collection")
        }
        save("06-collections")

        // Captures (tray icon on the Today header)
        tapNav("Today")
        let inbox = app.buttons["Captures"].firstMatch
        expect(inbox, "the Today header's Captures button is missing")
        inbox.tap(); usleep(1_000_000)
        expect(app.navigationBars["Captures"], "the Captures screen did not open")
        save("07-inbox")
        let done = app.buttons["Done"].firstMatch
        expect(done, "no way out of the Captures sheet")
        done.tap(); usleep(700_000)

        // Insights via the Today header "This week" pill (week-pill id)
        let pill = app.buttons["week-pill"].firstMatch
        expect(pill, "the Today header's week pill is missing")
        pill.tap()
        expect(app.navigationBars["Insights"], "Insights did not open", timeout: 8)
        usleep(1_500_000)
        save("08-insights")
    }
}
