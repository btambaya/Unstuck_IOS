// App Store screenshot tour — runs against the network-free demo boot
// (UITEST_SEED) on a 6.9" simulator and writes full-resolution PNGs to
// /tmp/unstuck-shots/ for upload to App Store Connect. Not a test of
// behavior; failures only matter insofar as a screen didn't render.

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

        // Focus session (the product's core moment), then end it via the
        // soft-exit "End for now" — landing back on Today with the recap card.
        if app.staticTexts["Focus"].firstMatch.waitForExistence(timeout: 4) {
            app.staticTexts["Focus"].firstMatch.tap()
            usleep(1_500_000)
            save("02-focus")
            let end = app.staticTexts["End for now"].firstMatch
            if end.waitForExistence(timeout: 3) { end.tap(); usleep(1_200_000) }
            if app.buttons["Today"].firstMatch.waitForExistence(timeout: 6) {
                usleep(600_000)
                save("03-recap")
            }
        }

        tapNav("Tasks")
        save("04-tasks")

        tapNav("Calendar")
        usleep(600_000)
        if app.staticTexts["Week"].firstMatch.waitForExistence(timeout: 3) {
            app.staticTexts["Week"].firstMatch.tap(); usleep(900_000)
        }
        save("05-calendar")

        tapNav("Collections")
        usleep(600_000)
        if app.staticTexts["Groceries"].firstMatch.waitForExistence(timeout: 4) {
            app.staticTexts["Groceries"].firstMatch.tap(); usleep(900_000)
        }
        save("06-collections")

        // Insights via the Today header "This week" pill
        tapNav("Today")
        let pill = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'this week'")).firstMatch
        if pill.waitForExistence(timeout: 4) {
            pill.tap(); usleep(1_200_000)
            save("07-insights")
        }
    }
}
