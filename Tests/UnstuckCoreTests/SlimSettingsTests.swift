// Slim Settings (PLAN.md, approved 2026-09-24): the link aliases, the Text
// size merge, the plain copy and the Calls block's one-line collapse.

import XCTest
@testable import UnstuckCore

final class SlimSettingsTests: XCTestCase {

    // MARK: links (PLAN.md §4 "Deep links")

    func testEveryPlanAliasLandsWhereThePlanSays() {
        let table: [(String, SettingsDestination)] = [
            ("notifications", .notifications), ("notification", .notifications), ("calls", .notifications),
            ("assistant", .assistant), ("ai", .assistant), ("memory", .assistant), ("knows", .assistant),
            ("interface", .appearance), ("appearance", .appearance), ("accessibility", .appearance), ("theme", .appearance),
            ("people", .people), ("connections", .people), ("circle", .people),
            ("backup", .account), ("export", .account), ("account", .account),
            ("feedback", .feedback),
            ("focus", .focus), ("sound", .focus),
            ("areas", .areas), ("tags", .areas), ("areas & tags", .areas), ("areas-and-tags", .areas),
        ]
        for (raw, want) in table {
            XCTAssertEqual(SettingsDestination.from(section: raw), want, raw)
        }
    }

    func testAliasesIgnoreCaseAndSpaces() {
        // The web's section ids are capitalised (`?section=People`) and the
        // tour steps name them that way; old iOS links were lower-case.
        XCTAssertEqual(SettingsDestination.from(section: "People"), .people)
        XCTAssertEqual(SettingsDestination.from(section: "  NOTIFICATIONS "), .notifications)
        XCTAssertEqual(SettingsDestination.from(section: "Interface"), .appearance)
        XCTAssertEqual(SettingsDestination.from(section: "Areas & Tags"), .areas)
        XCTAssertEqual(SettingsDestination.from(section: "Notifications & calls"), .notifications)
        XCTAssertEqual(SettingsDestination.from(section: "Assistant & privacy"), .assistant)
    }

    /// The web's alias table (lib/settings-sections.ts) lands in the same place
    /// here — only `sound` differs on purpose (the Focus screen on iOS).
    func testTheWebsAliasesMeanTheSameHere() {
        let web: [(String, SettingsDestination)] = [
            ("sync", .account), ("profile", .account), ("password", .account), ("delete", .account),
            ("calls from unstuck", .notifications), ("reminder", .notifications),
            ("notifications and calls", .notifications),
            ("ai assistant", .assistant), ("ai data sharing", .assistant), ("what unstuck remembers", .assistant),
            ("assistant and privacy", .assistant),
            ("sharing", .people), ("people you share with", .people),
            ("a11y", .appearance), ("text size", .appearance),
            ("send feedback", .feedback),
            ("areas+tags", .areas), ("area", .areas), ("tag", .areas),
        ]
        for (raw, want) in web {
            XCTAssertEqual(SettingsDestination.from(section: raw), want, raw)
        }
        XCTAssertEqual(SettingsDestination.from(section: "Notifications   &  calls"), .notifications,
                       "runs of spaces fold like the web's")
    }

    func testNothingOrUnknownIsTheHubNeverADeadEnd() {
        XCTAssertEqual(SettingsDestination.from(section: nil), .hub)
        XCTAssertEqual(SettingsDestination.from(section: ""), .hub)
        XCTAssertEqual(SettingsDestination.from(section: "insights"), .hub)
        XCTAssertEqual(SettingsDestination.from(section: "garbage"), .hub)
    }

    func testTheBareServerLinkOpensTheHub() {
        // The server sends the bare `unstuck://settings` on purpose (invites,
        // shares) — People is one tap from the hub.
        XCTAssertEqual(SettingsDestination.from(link: "unstuck://settings"), .hub)
        XCTAssertEqual(SettingsDestination.from(link: "unstuck://settings?section=People"), .people)
        XCTAssertEqual(SettingsDestination.from(link: "unstuck://settings?section=Areas%20%26%20tags"), .areas)
        XCTAssertEqual(SettingsDestination.from(link: "unstuck://settings?section=calls"), .notifications)
        XCTAssertEqual(SettingsDestination.from(link: "unstuck://settings?other=1"), .hub)
    }

    func testOnlyTheFiveScreensArePushedInsideSettings() {
        XCTAssertEqual(SettingsDestination.allCases.filter(\.isSettingsScreen),
                       [.account, .notifications, .assistant, .people, .appearance])
        // The ids are the web's, so a link means the same everywhere.
        XCTAssertEqual(SettingsDestination.notifications.rawValue, "Notifications")
        XCTAssertEqual(SettingsDestination.assistant.rawValue, "Assistant")
        XCTAssertEqual(SettingsDestination.appearance.rawValue, "Appearance")
    }

    // MARK: text size (Decision 1: Density + Larger type merge)

    func testTextSizeMigratesFromTheOldControls() {
        XCTAssertEqual(TextSizePref.migrated(density: nil, largerType: false), .standard)
        XCTAssertEqual(TextSizePref.migrated(density: "regular", largerType: false), .standard)
        XCTAssertEqual(TextSizePref.migrated(density: "compact", largerType: false), .smaller)
        XCTAssertEqual(TextSizePref.migrated(density: "comfy", largerType: false), .larger)
        // Larger type was the bigger of the two: it wins over Density.
        XCTAssertEqual(TextSizePref.migrated(density: "compact", largerType: true), .larger)
        XCTAssertEqual(TextSizePref.migrated(density: "garbage", largerType: false), .standard)
    }

    func testTextSizeStepsAndLabels() {
        XCTAssertEqual(TextSizePref.allCases.map(\.label), ["Smaller", "Default", "Larger"])
        XCTAssertEqual(TextSizePref.allCases.map(\.typeStepShift), [-1, 0, 2])
        XCTAssertEqual(TextSizePref.standard.rawValue, "default")
        XCTAssertEqual(TextSizePref(rawValue: "larger"), .larger)
    }

    // MARK: plain copy

    func testLevelLinesArePlainAndOnlyCoachPromisesTheSecondNudge() {
        XCTAssertEqual(NotificationLevel.calm.plainLine, "Only the reminders you set, and a recap.")
        XCTAssertEqual(NotificationLevel.balanced.plainLine,
                       "Also a nudge when a task should start, a check-in if you've paused a while, and a morning summary.")
        XCTAssertEqual(NotificationLevel.coach.plainLine, "Also a second nudge if you haven't started 10 minutes in.")
        XCTAssertTrue(NotificationLevel.coachPaceNote.contains("focus coach"))
    }

    func testFactCategoriesHavePlainNames() {
        XCTAssertEqual(ProfileFactCategory.allCases.map(\.plainLabel), ["About me", "Routine", "Limits", "Likes", "Other"])
    }

    func testRoutinesUseTheirNewNamesEverywhere() {
        XCTAssertEqual(RitualKey.allCases.map(routineName),
                       ["Morning plan", "Evening wind-down", "Friday look-back", "Sunday plan-ahead"])
        XCTAssertEqual(RITUAL_LABELS.map(\.label), RitualKey.allCases.map(routineName))
    }

    // MARK: background noise (the speaker button)

    func testBackgroundNoiseReadsBrownAndPinkAsOn() {
        XCTAssertTrue(backgroundNoiseIsOn(storedAmbient: "brown"))
        XCTAssertTrue(backgroundNoiseIsOn(storedAmbient: "pink"))
        XCTAssertFalse(backgroundNoiseIsOn(storedAmbient: "off"))
        XCTAssertFalse(backgroundNoiseIsOn(storedAmbient: nil))
    }

    // MARK: the Calls block

    func testCallsCollapseToOneLineWithoutTheAssistantOrAISharing() {
        XCTAssertEqual(CallsBlockState.resolve(assistantOn: false, aiSharingOn: true, phoneSwitchOn: true), .needsAssistant)
        XCTAssertEqual(CallsBlockState.resolve(assistantOn: true, aiSharingOn: false, phoneSwitchOn: true), .needsAssistant)
        XCTAssertEqual(CallsBlockState.resolve(assistantOn: true, aiSharingOn: true, phoneSwitchOn: false), .off)
        XCTAssertEqual(CallsBlockState.resolve(assistantOn: true, aiSharingOn: true, phoneSwitchOn: true), .on)
        XCTAssertEqual(CallsBlockState.needsLine(assistantOn: false, aiSharingOn: false),
                       "Calls need the Assistant and AI data sharing.")
        XCTAssertTrue(CallsBlockState.needsLine(assistantOn: false, aiSharingOn: true).contains("the Assistant"))
        XCTAssertTrue(CallsBlockState.needsLine(assistantOn: true, aiSharingOn: false).contains("AI data sharing"))
    }
}
