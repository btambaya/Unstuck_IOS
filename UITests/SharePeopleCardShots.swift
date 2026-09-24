// Share screen · People card — the visual verification tour behind the
// 2026-09-17 rebuild (one collapsed card, shared-first, "Show N more", the
// accent-free monogram). Not a behaviour test: every step asserts that the
// screen it claims to have shot actually rendered, and writes a PNG per
// configuration to SHARE_SHOTS_DIR (pass as TEST_RUNNER_SHARE_SHOTS_DIR to
// xcodebuild; default /tmp/unstuck-share-shots) under a per-device folder.
// SHARE_SHOTS_ONLY (comma-separated config names) re-shoots a subset.
//
// The matrix from the spec — 0 / 1 / 4 / 7 / 20 people with 0 / 2 / 6 of
// them shared, hand-over with and without a holder, light + dark, indigo +
// forest, default + AX XXXL, collapsed / expanded / searching / busy / menu —
// runs from ONE test on ONE simulator: the roster is UITEST_SHARE_PEOPLE
// (App/UITestSupport.swift), theme + accent are UserDefaults launch
// arguments (`-unstuck.theme dark -unstuck.accent forest`) and the text size
// is -UIPreferredContentSizeCategoryName.
//
// Since build 59 (2026-09-17) the card lists ONLY the people who already have
// the item; everyone else sits behind one "Choose someone, N people" row that
// opens a searchable picker ("Search people", rows "Share with <name>"). The
// collapse / "Show N more" / inline Find field are gone, so the busy + search
// configurations go through that picker.

import XCTest

final class SharePeopleCardShots: XCTestCase {
    private struct Config {
        var name: String
        var people: String            // "<count>,<shared>[,<handed>]"
        var handOver = false
        var dark = false
        var accent = "indigo"
        var ax = false
        var expand = false
        var query: String? = nil
        var slowTap = false           // tap the first "Share" row, shoot mid-write
        var openMenu = false          // open the first shared row's picker
    }

    private static let matrix: [Config] = [
        Config(name: "00-empty", people: "0,0"),
        Config(name: "01-one", people: "1,0"),
        Config(name: "03-three-1shared", people: "3,1"),
        Config(name: "04-four", people: "4,0"),
        Config(name: "07-seven", people: "7,0"),
        Config(name: "07-seven-2shared", people: "7,2"),
        Config(name: "07-seven-2shared-expanded", people: "7,2", expand: false),
        Config(name: "07-seven-6shared", people: "7,6"),
        Config(name: "07-seven-2shared-1handed", people: "7,2,1"),
        Config(name: "07-seven-2shared-menu", people: "7,2", openMenu: true),
        Config(name: "07-seven-busy", people: "7,0", slowTap: true),
        Config(name: "20-twenty-2shared", people: "20,2"),
        Config(name: "20-twenty-2shared-expanded", people: "20,2", expand: false),
        Config(name: "20-twenty-2shared-search-ma", people: "20,2", expand: false, query: "ma"),
        Config(name: "20-twenty-2shared-search-none", people: "20,2", expand: false, query: "zzz"),
        Config(name: "20-twenty-10shared", people: "20,10"),
        Config(name: "handover-07-noholder", people: "7,0", handOver: true),
        Config(name: "handover-07-holder", people: "7,3,1", handOver: true),
        Config(name: "dark-07-2shared", people: "7,2", dark: true),
        Config(name: "dark-07-2shared-expanded", people: "7,2", dark: true, expand: false),
        Config(name: "forest-07-2shared", people: "7,2", accent: "forest"),
        Config(name: "dark-forest-07-2shared", people: "7,2", dark: true, accent: "forest"),
        Config(name: "ax-07-2shared", people: "7,2", ax: true),
        Config(name: "ax-07-2shared-expanded", people: "7,2", ax: true, expand: false),
        Config(name: "ax-dark-handover-07-holder", people: "7,3,1", handOver: true, dark: true, ax: true),
    ]

    private let outDir: URL = {
        let env = ProcessInfo.processInfo.environment
        let base = env["SHARE_SHOTS_DIR"] ?? "/tmp/unstuck-share-shots"
        let device = (env["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
        return URL(fileURLWithPath: base).appendingPathComponent(device)
    }()

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        addUIInterruptionMonitor(withDescription: "system-alert") { alert in
            for label in ["Allow", "Don’t Allow", "OK", "Continue"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
    }

    private func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    private func expect(_ e: XCUIElement, _ why: String, timeout: TimeInterval = 8,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), why, file: file, line: line)
    }

    private func launch(_ c: Config) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED"] = "1"
        app.launchEnvironment["UITEST_SHARE_PEOPLE"] = c.people
        if c.slowTap { app.launchEnvironment["UITEST_SHARE_SLOW"] = "1" }
        app.launchArguments += ["-unstuck.theme", c.dark ? "dark" : "light", "-unstuck.accent", c.accent]
        if c.ax {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    /// Today → Tasks → the first seeded task's editor → Share (or ⋯ → Hand
    /// over to…). Returns false (after asserting) when a step is missing, so
    /// the matrix carries on with the next configuration instead of aborting
    /// on the first fatal `tap()`.
    private func openShare(_ app: XCUIApplication, _ c: Config) -> Bool {
        let today = app.buttons["Today"].firstMatch
        expect(today, "[\(c.name)] the demo boot never reached Today", timeout: 20)
        guard today.exists else { return false }
        usleep(600_000)
        let tasks = app.buttons["Tasks"].firstMatch
        expect(tasks, "[\(c.name)] bottom nav 'Tasks' is missing")
        guard tasks.exists else { return false }
        tasks.tap(); usleep(700_000)
        // The row's inline "#tag" chip has a 44pt hit frame that covers the
        // name's centre — tap the row near its trailing edge (the estimate).
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Draft the Q3 proposal'")).firstMatch
        expect(row, "[\(c.name)] the seeded task row is missing")
        guard row.exists else { return false }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap(); usleep(800_000)
        if c.handOver {
            let more = app.buttons["More actions"].firstMatch
            expect(more, "[\(c.name)] the editor's ⋯ menu is missing")
            guard more.exists else { return false }
            more.tap(); usleep(500_000)
            let hand = app.buttons["Hand over to…"].firstMatch
            expect(hand, "[\(c.name)] 'Hand over to…' is missing from the menu")
            guard hand.exists else { return false }
            hand.tap()
            let bar = app.navigationBars["Hand over"].firstMatch
            expect(bar, "[\(c.name)] the Hand-over sheet did not open")
            guard bar.exists else { return false }
        } else {
            let share = app.buttons["Share task"].firstMatch
            expect(share, "[\(c.name)] the editor's Share button is missing")
            guard share.exists else { return false }
            share.tap()
            let bar = app.navigationBars["Share"].firstMatch
            expect(bar, "[\(c.name)] the Share sheet did not open")
            guard bar.exists else { return false }
        }
        usleep(900_000)
        return true
    }

    /// Open the "Choose someone" picker — the only way to the people who
    /// don't have the item yet.
    private func openPicker(_ app: XCUIApplication, _ c: Config) -> Bool {
        let choose = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Choose someone'")).firstMatch
        expect(choose, "[\(c.name)] no 'Choose someone' row on the People card")
        guard choose.exists else { return false }
        choose.tap(); usleep(800_000)
        return true
    }

    func testPeopleCardMatrix() throws {
        // SHARE_SHOTS_ONLY="07-seven,ax-07-2shared" (TEST_RUNNER_-prefixed for
        // xcodebuild) re-shoots a subset after a targeted fix.
        let only = (ProcessInfo.processInfo.environment["SHARE_SHOTS_ONLY"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for c in Self.matrix where only.isEmpty || only.contains(c.name) {
            let app = launch(c)
            guard openShare(app, c) else { save("\(c.name)-FAILED"); app.terminate(); continue }
            if c.expand {
                let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show ' AND label ENDSWITH ' more people'")).firstMatch
                expect(more, "[\(c.name)] no 'Show N more people' disclosure")
                if more.exists { more.tap(); usleep(600_000) }
                expect(app.buttons["Show fewer people"].firstMatch, "[\(c.name)] the disclosure did not flip to Show fewer")
            }
            if let q = c.query, openPicker(app, c) {
                let field = app.searchFields["Search people"].firstMatch
                expect(field, "[\(c.name)] the picker's search field is missing")
                if field.exists { field.tap(); usleep(300_000); field.typeText(q); usleep(600_000) }
            }
            if c.slowTap, openPicker(app, c) {
                let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Share with '")).firstMatch
                expect(first, "[\(c.name)] no unshared person in the picker to tap")
                // The pick closes the picker; the write is held 1.5s
                // (UITEST_SHARE_SLOW), so this still shoots it mid-write.
                if first.exists { first.tap(); usleep(700_000) }
            }
            if c.openMenu {
                let shared = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Change access'")).firstMatch
                expect(shared, "[\(c.name)] no shared row to open")
                if shared.exists { shared.tap(); usleep(700_000) }
                expect(app.buttons["Remove"].firstMatch, "[\(c.name)] the access menu did not open")
            }
            if c.ax {
                // At accessibility sizes the header fills the first screen —
                // bring the People eyebrow to the top so the rows are in frame.
                // Its label counts who HAS the item ("People, 2"), not the roster.
                let eyebrow = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                                   c.handOver ? "Hand over to," : "People,")).firstMatch
                for _ in 0..<5 where !(eyebrow.exists && eyebrow.frame.minY < 260) {
                    app.swipeUp(); usleep(500_000)
                }
            }
            save(c.name)
            app.terminate()
        }
    }

    // MARK: New task → "Share with…" (the one row + the pre-create picker)

    /// New task → More options: the ONE "Share with…" row with nothing picked,
    /// the pre-create Share screen it opens, two people picked at different
    /// grades (Maya · Can edit, Zubair · Can view) with Someone new + Invite
    /// with a link below, and the row's summary afterwards —
    /// light + dark. PNGs go to SHARE_ROW_SHOTS_DIR (TEST_RUNNER_-prefixed for
    /// xcodebuild; default /tmp/unstuck-share-row-shots). Each step asserts the
    /// screen it shoots actually rendered.
    func testNewTaskShareRowShots() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["SHARE_ROW_SHOTS_DIR"] ?? "/tmp/unstuck-share-row-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func shot(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        }
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let app = launch(Config(name: "share-row-\(theme)", people: "7,0", dark: dark))
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.buttons["Allow"].firstMatch
            if allow.waitForExistence(timeout: 4) { allow.tap(); usleep(600_000) }

            let newTask = app.buttons["New task"].firstMatch
            expect(newTask, "[\(theme)] the demo boot never showed the + (New task)", timeout: 40)
            guard newTask.exists else {
                shot("\(theme)-FAILED-boot"); print("BOOT-TREE \(app.debugDescription)")
                app.terminate(); continue
            }
            newTask.tap()
            expect(app.staticTexts["What's on your mind?"].firstMatch, "[\(theme)] the New task sheet did not open")
            let nameField = app.textFields["new-task-name"]
            if nameField.waitForExistence(timeout: 4) {
                nameField.tap(); nameField.typeText("Plan the team offsite")
            }
            let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'More options'")).firstMatch
            expect(more, "[\(theme)] no 'More options' disclosure")
            guard more.exists else { app.terminate(); continue }
            // Scroll the disclosure clear of the keyboard, open it, and bring
            // the Share row up.
            app.swipeUp(); usleep(500_000)
            more.tap(); usleep(600_000)
            let row = app.buttons["new-task-share-row"].firstMatch
            expect(row, "[\(theme)] the Share with… row is missing under More options")
            guard row.exists else { shot("\(theme)-FAILED"); app.terminate(); continue }
            app.swipeUp(); usleep(600_000)
            XCTAssertEqual(row.label, "Share with", "[\(theme)] the row's VoiceOver label")
            XCTAssertEqual(row.value as? String, "Only you", "[\(theme)] nothing picked reads Only you")
            shot("01-row-nothing-picked-\(theme)")

            row.tap()
            let bar = app.navigationBars["Share"].firstMatch
            expect(bar, "[\(theme)] the row did not open the Share screen")
            guard bar.exists else { shot("\(theme)-FAILED-share"); app.terminate(); continue }
            usleep(900_000)
            shot("02-picker-open-\(theme)")

            // Maya at the default Can edit …
            let choose = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Choose someone'")).firstMatch
            expect(choose, "[\(theme)] no 'Choose someone' row in the pre-create Share screen")
            if choose.exists {
                choose.tap(); usleep(800_000)
                let maya = app.buttons["Share with Maya Chen"].firstMatch
                expect(maya, "[\(theme)] Maya is not in the picker")
                if maya.exists { maya.tap(); usleep(900_000) }
            }
            // … Zubair at Can view.
            let view = app.segmentedControls.buttons["Can view"].firstMatch
            expect(view, "[\(theme)] the Can edit / Can view switch is missing")
            if view.exists { view.tap(); usleep(400_000) }
            if choose.waitForExistence(timeout: 4) {
                choose.tap(); usleep(800_000)
                let zubair = app.buttons["Share with Zubair Kazaure"].firstMatch
                expect(zubair, "[\(theme)] Zubair is not in the picker")
                if zubair.exists { zubair.tap(); usleep(900_000) }
            }
            expect(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Maya Chen, Can edit'")).firstMatch,
                   "[\(theme)] Maya is not shown as picked at Can edit")
            expect(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Zubair Kazaure, Can view'")).firstMatch,
                   "[\(theme)] Zubair is not shown as picked at Can view")
            shot("03-picker-two-picked-\(theme)")
            expect(app.buttons["Invite with a link"].firstMatch, "[\(theme)] pre-create's connect-invite link is missing")
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Share a link'")).firstMatch.exists,
                           "[\(theme)] a task link can't exist before the task")

            app.navigationBars["Share"].buttons["Done"].firstMatch.tap(); usleep(900_000)
            expect(row, "[\(theme)] back on the New task sheet")
            XCTAssertEqual(row.value as? String, "Maya can edit, Zubair can view", "[\(theme)] the row's spoken summary")
            shot("04-row-two-picked-\(theme)")
            app.terminate()
        }
    }
}
