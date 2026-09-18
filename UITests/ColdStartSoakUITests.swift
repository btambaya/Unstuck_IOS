// Cold-start-to-first-frame against the HEAVY account (UITEST_SEED_HEAVY),
// with the normal demo seed as the control.
//
// The heavy boot writes a persistent sqlite file, so the FIRST launch pays the
// seeding cost and every launch after it is a true cold start against ~800
// tasks / 4000 cal_blocks / 1500 sessions / 300 captures / 40 lists. Both the
// seeding hook and this test are DEBUG-only scaffolding; nothing here ships.
//
// Prints `PERF-BOOT| …` lines (ms).

import XCTest

final class ColdStartSoakUITests: XCTestCase {

    private func makeApp(heavy: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
        if heavy { app.launchEnvironment["UITEST_SEED_HEAVY"] = "1" }
        return app
    }

    /// launch() → the Today tab exists (the bottom nav is the first-frame signal).
    @discardableResult
    private func timeBoot(_ app: XCUIApplication, label: String) -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        app.launch()
        let launched = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let nav = app.buttons["Today"].firstMatch
        XCTAssertTrue(nav.waitForExistence(timeout: 60), "\(label): never reached Today")
        let toToday = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print(String(format: "PERF-BOOT| %@ | launch()=%8.1fms  first-frame(Today nav visible)=%8.1fms",
                     label, launched, toToday))
        return toToday
    }

    private func report(_ label: String, _ ms: [Double]) {
        let s = ms.sorted()
        print(String(format: "PERF-BOOT| %@ | runs=%d min=%8.1fms med=%8.1fms max=%8.1fms",
                     label, s.count, s.first ?? 0, s[s.count / 2], s.last ?? 0))
    }

    func testColdStartLightSeed() {
        let app = makeApp(heavy: false)
        var ms: [Double] = []
        for i in 0..<5 {
            ms.append(timeBoot(app, label: "light seed run \(i)"))
            app.terminate()
        }
        report("CONTROL: light demo seed, cold start → Today", ms)
    }

    func testColdStartHeavySeed() {
        let app = makeApp(heavy: true)
        // Launch 1 pays the one-time seed write (and may reuse an already-seeded
        // file from a previous run — reported, not averaged).
        _ = timeBoot(app, label: "heavy seed run 0 (may include the one-time seed write)")
        app.terminate()

        var ms: [Double] = []
        for i in 1..<6 {
            ms.append(timeBoot(app, label: "heavy run \(i)"))
            app.terminate()
        }
        report("HEAVY: 800 tasks / 4000 blocks, cold start → Today", ms)
    }

    /// The OS-reported app-launch metric over the LIGHT demo store (control).
    func testLightLaunchMetric() {
        let app = makeApp(heavy: false)
        app.launch()
        app.terminate()
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
            app.terminate()
        }
    }

    /// The OS-reported app-launch metric over the heavy store.
    func testHeavyLaunchMetric() {
        let app = makeApp(heavy: true)
        app.launch()           // make sure the store is already seeded
        app.terminate()
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
            app.terminate()
        }
    }
}
