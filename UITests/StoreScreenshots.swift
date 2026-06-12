// App Store screenshot tour — runs against the network-free demo boot
// (UITEST_SEED) on a 6.9" simulator and writes full-resolution PNGs to
// /tmp/unstuck-shots/ for the caption compositor + upload to App Store
// Connect. Not a behavior test; failures only matter if a screen didn't
// render.

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

    private func tapNav(_ label: String) {
        let b = app.buttons[label].firstMatch
        if b.waitForExistence(timeout: 8) { b.tap() }
        usleep(900_000)
    }

    func testStoreTour() throws {
        _ = app.buttons["Today"].firstMatch.waitForExistence(timeout: 15)
        usleep(1_200_000)
        save("01-today")

        // Focus session, then end it via soft-exit "End for now" (a Button,
        // not a staticText) — the recap card's "JUST NOW" label confirms we
        // landed back on Today before shooting.
        if app.staticTexts["Focus"].firstMatch.waitForExistence(timeout: 4) {
            app.staticTexts["Focus"].firstMatch.tap()
            usleep(1_500_000)
            save("02-focus")
            let end = app.buttons["End for now"].exists
                ? app.buttons["End for now"].firstMatch
                : app.staticTexts["End for now"].firstMatch
            if end.waitForExistence(timeout: 3) {
                end.tap()
                if app.staticTexts["JUST NOW"].firstMatch.waitForExistence(timeout: 8) {
                    usleep(800_000)
                    save("03-recap")
                }
            }
        }

        tapNav("Tasks")
        // "Upcoming" filter pill only exists on the Tasks screen — proves the
        // tab actually switched before shooting.
        if app.staticTexts["Upcoming"].firstMatch.waitForExistence(timeout: 4) {
            usleep(400_000)
            save("04-tasks")
        } else {
            tapNav("Tasks")
            _ = app.staticTexts["Upcoming"].firstMatch.waitForExistence(timeout: 4)
            usleep(400_000)
            save("04-tasks")
        }

        tapNav("Calendar")
        usleep(900_000)
        save("05-calendar")

        tapNav("Collections")
        usleep(600_000)
        if app.staticTexts["Groceries"].firstMatch.waitForExistence(timeout: 4) {
            app.staticTexts["Groceries"].firstMatch.tap(); usleep(900_000)
        }
        save("06-collections")

        // Capture Inbox (tray icon on the Today header)
        tapNav("Today")
        let inbox = app.buttons["Inbox"].firstMatch
        if inbox.waitForExistence(timeout: 4) {
            inbox.tap(); usleep(1_000_000)
            save("07-inbox")
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap(); usleep(700_000) }
        }

        // Insights via the Today header "This week" pill (week-pill id)
        let pill = app.buttons["week-pill"].firstMatch
        if pill.waitForExistence(timeout: 4) {
            pill.tap(); usleep(1_500_000)
            save("08-insights")
        }
    }
}
