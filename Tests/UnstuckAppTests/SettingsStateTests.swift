// App-layer unit tests for SettingsState.load() — specifically the nil-sentinel
// hydration for the TRUE-defaulting bools (object(forKey:) == nil ? default :
// bool(forKey:)). A plain `bool(forKey:)` returns false for a missing key, which
// would silently flip these true-by-default toggles off on first launch; the
// sentinel check preserves the Android-parity default until the user sets one.
//
// Each test injects a throwaway, pre-seeded UserDefaults suite so it never
// touches the device defaults and stays independent of order.

import XCTest
import UnstuckCore
@testable import Unstuck

@MainActor
final class SettingsStateTests: XCTestCase {
    /// A fresh, empty, in-memory-ish suite (a uniquely-named volatile domain).
    private func freshDefaults() -> UserDefaults {
        let name = "test.settings.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testTrueDefaultingBoolsDefaultTrueWhenUnset() {
        let s = SettingsState(defaults: freshDefaults())
        s.load()
        // These must stay TRUE on a first launch (no stored value).
        XCTAssertTrue(s.focusSoftExit)
        XCTAssertTrue(s.focusPauseReasons)
        XCTAssertTrue(s.focusSpokenCoach)
        XCTAssertTrue(s.assistantEnabled)
    }

    func testFalseDefaultingValuesDefaultOffWhenUnset() {
        let s = SettingsState(defaults: freshDefaults())
        s.load()
        XCTAssertFalse(s.focusVoiceReplies)
        XCTAssertEqual(s.ambient, .off)
        XCTAssertFalse(s.ambient.isOn)
        XCTAssertEqual(s.textSize, .standard)
    }

    func testStoredFalseOverridesTrueDefault() {
        let d = freshDefaults()
        d.set(false, forKey: "unstuck.focusSoftExit")   // user turned it OFF
        d.set(false, forKey: "unstuck.focusSpokenCoach")
        let s = SettingsState(defaults: d)
        s.load()
        XCTAssertFalse(s.focusSoftExit, "an explicitly-stored false must survive")
        XCTAssertFalse(s.focusSpokenCoach)
        // An unset true-default bool is unaffected.
        XCTAssertTrue(s.focusPauseReasons)
    }

    func testStoredTrueOverridesFalseDefault() {
        let d = freshDefaults()
        d.set(true, forKey: "unstuck.focusVoiceReplies")
        let s = SettingsState(defaults: d)
        s.load()
        XCTAssertTrue(s.focusVoiceReplies)
    }

    // MARK: slim settings (2026-09-24)

    /// Density + Larger type merged into Text size: a device that set them
    /// keeps its size on the first read, before Text size has its own key.
    func testTextSizeIsReadFromTheOldControlsUntilChosen() {
        let comfy = freshDefaults()
        comfy.set("comfy", forKey: "unstuck.density")
        XCTAssertEqual(SettingsState.loaded(defaults: comfy).textSize, .larger)

        let compact = freshDefaults()
        compact.set("compact", forKey: "unstuck.density")
        XCTAssertEqual(SettingsState.loaded(defaults: compact).textSize, .smaller)

        let larger = freshDefaults()
        larger.set("compact", forKey: "unstuck.density")
        larger.set(true, forKey: "unstuck.largerType")
        XCTAssertEqual(SettingsState.loaded(defaults: larger).textSize, .larger, "Larger type wins")

        // Once chosen, its own key wins over the old ones — which stay.
        let s = SettingsState.loaded(defaults: comfy)
        s.textSize = .smaller
        XCTAssertEqual(comfy.string(forKey: SettingsState.textSizeKey), "smaller")
        XCTAssertEqual(SettingsState.loaded(defaults: comfy).textSize, .smaller)
        XCTAssertEqual(comfy.string(forKey: "unstuck.density"), "comfy", "the old value is never wiped")
    }

    func testAnUnrecognisedTextSizeFallsBackToTheOldControlsThenDefault() {
        let d = freshDefaults()
        d.set("huge", forKey: SettingsState.textSizeKey)
        XCTAssertEqual(SettingsState.loaded(defaults: d).textSize, .standard)
        XCTAssertEqual(TextSizePref.standard.typeStepShift, 0)
    }

    /// Accent, High contrast, the in-app Reduce motion, Hide rail and the
    /// three sounds are gone: stored values are NOT wiped, just never read —
    /// and loading or changing anything else never touches them.
    func testRemovedControlsAreNeitherReadNorWiped() {
        let d = freshDefaults()
        let removed: [String: Any] = [
            "unstuck.accent": "rose", "unstuck.highContrast": true, "unstuck.reduceMotion": true,
            "unstuck.focusCollapseRail": false, "unstuck.soundStartChime": false,
            "unstuck.soundOverrunBell": false, "unstuck.soundCompletion": true,
        ]
        for (k, v) in removed { d.set(v, forKey: k) }
        let s = SettingsState.loaded(defaults: d)
        s.theme = .dark
        s.textSize = .larger
        s.ambient = .brown
        for (k, v) in removed {
            XCTAssertEqual(d.object(forKey: k) as? NSObject, v as? NSObject, "\(k) must stay as stored")
        }
    }

    /// The speaker button IS the background-noise setting: on stores brown
    /// (old builds read it), and a stored pink — the same loop — reads as on.
    func testBackgroundNoiseReadsPinkAsOnAndStoresBrown() {
        let d = freshDefaults()
        d.set("pink", forKey: "unstuck.ambient")
        let s = SettingsState.loaded(defaults: d)
        XCTAssertTrue(s.ambient.isOn)
        s.ambient = .off
        XCTAssertEqual(d.string(forKey: "unstuck.ambient"), "off")
        s.ambient = .brown
        XCTAssertEqual(d.string(forKey: "unstuck.ambient"), "brown")
    }

    /// Read before AppModel exists (a killed-state VoIP launch).
    func testTheStoredAssistantSwitchIsReadableWithoutAModel() {
        let d = freshDefaults()
        XCTAssertTrue(SettingsState.storedAssistantEnabled(d), "on unless turned off")
        d.set(false, forKey: SettingsState.assistantEnabledKey)
        XCTAssertFalse(SettingsState.storedAssistantEnabled(d))
    }

    /// The AI kill-switch (privacy policy §21). ON unless the user turned it
    /// off; an explicit OFF must survive relaunch — the whole point of the
    /// promise is that it stays off.
    func testAssistantKillSwitchDefaultsOnAndPersistsOff() {
        XCTAssertTrue(SettingsState.loaded(defaults: freshDefaults()).assistantEnabled)

        let d = freshDefaults()
        let s = SettingsState(defaults: d)
        s.load()
        s.assistantEnabled = false
        XCTAssertFalse(d.bool(forKey: "unstuck.assistantEnabled"), "the choice must be written through")

        let reloaded = SettingsState(defaults: d)
        reloaded.load()
        XCTAssertFalse(reloaded.assistantEnabled, "a disabled assistant must stay disabled after relaunch")
    }

    func testIntScalarsDefaultToAndroidParityWhenUnset() {
        let s = SettingsState(defaults: freshDefaults())
        s.load()
        XCTAssertEqual(s.focusDefaultMin, 25)
        XCTAssertEqual(s.focusOverrunMin, 5)
    }

    func testStoredZeroIntSurvives() {
        // 0 is a meaningful value (overrun "Never"); a plain integer(forKey:)
        // returns 0 for a missing key too — the sentinel check is what lets us
        // tell "unset → default 5" apart from "explicitly 0".
        let d = freshDefaults()
        d.set(0, forKey: "unstuck.focusOverrunMin")
        let s = SettingsState(defaults: d)
        s.load()
        XCTAssertEqual(s.focusOverrunMin, 0)
    }

    func testEnumScalarsHydrateAndFallBack() {
        let d = freshDefaults()
        d.set("dark", forKey: "unstuck.theme")
        d.set("garbage", forKey: "unstuck.ambient")   // unrecognised → default
        let s = SettingsState(defaults: d)
        s.load()
        XCTAssertEqual(s.theme, .dark)
        XCTAssertEqual(s.ambient, .off, "an unrecognised raw value falls back to the default")
    }

    func testLoadDoesNotWriteBackDefaults() {
        // load() suppresses the persisting didSet, so hydrating defaults must NOT
        // create keys in the suite (it would defeat the unset-vs-explicit sentinel).
        let d = freshDefaults()
        let s = SettingsState(defaults: d)
        s.load()
        XCTAssertNil(d.object(forKey: "unstuck.focusSoftExit"),
                     "loading a default value must not persist it")
        XCTAssertNil(d.object(forKey: "unstuck.theme"))
        XCTAssertNil(d.object(forKey: SettingsState.textSizeKey), "a migrated Text size isn't written until chosen")
    }

    func testSettingAValueAfterLoadPersists() {
        // The persisting didSet fires for real user changes (loading == false).
        let d = freshDefaults()
        let s = SettingsState(defaults: d)
        s.load()
        s.focusSoftExit = false
        XCTAssertEqual(d.object(forKey: "unstuck.focusSoftExit") as? Bool, false)
    }
}

// MARK: - Sign out with edits still queued (audit 2026-09-22, C36)

@MainActor
final class SignOutWarningTests: XCTestCase {
    /// The Sign out row signs out at once only when nothing is waiting;
    /// otherwise it first says where the queued edits go.
    func testTheSignOutRowWarnsOnlyWhenEditsAreStillQueued() throws {
        XCTAssertNil(AppModel.unsyncedSignOutWarning(pending: 0))
        let one = try XCTUnwrap(AppModel.unsyncedSignOutWarning(pending: 1))
        XCTAssertTrue(one.hasPrefix("1 change hasn’t reached the server yet."), one)
        let three = try XCTUnwrap(AppModel.unsyncedSignOutWarning(pending: 3))
        XCTAssertTrue(three.hasPrefix("3 changes haven’t reached the server yet."), three)
        XCTAssertTrue(three.contains("sync the next time you sign in here"), three)
    }

    /// Quarantined ops are parked and restored with their attempts, so no
    /// sign-in ever syncs them: the row must not promise it for those.
    func testChangesTheServerRefusedAreNeverPromisedASync() throws {
        let stuckOnly = try XCTUnwrap(AppModel.unsyncedSignOutWarning(pending: 1, quarantined: 1))
        XCTAssertFalse(stuckOnly.contains("sync the next time you sign in"), stuckOnly)
        XCTAssertTrue(stuckOnly.hasPrefix("1 change the server couldn’t accept stays on this iPhone only"), stuckOnly)

        let mixed = try XCTUnwrap(AppModel.unsyncedSignOutWarning(pending: 4, quarantined: 2))
        XCTAssertTrue(mixed.hasPrefix("2 changes haven’t reached the server yet."), mixed)
        XCTAssertTrue(mixed.contains("sync the next time you sign in here"), mixed)
        XCTAssertTrue(mixed.contains("2 changes the server couldn’t accept stay on this iPhone only"), mixed)
    }
}

// MARK: - where a Settings link lands (slim settings, 2026-09-24)

/// Every entry point that names a Settings section — `unstuck://settings`
/// links (server, old builds), the assistant's open_screen, the web's
/// capitalised `?section=` ids — lands on the slim structure: old names are
/// aliases, the bare link stays the hub, areas/tags open the Tasks sheet.
@MainActor
final class SettingsLinkRoutingTests: XCTestCase {
    private var model: AppModel!

    override func setUp() {
        super.setUp()
        model = AppModel()
        model.startUITestMode()
    }

    private func land(_ link: String) -> AppRouter.Sheet? {
        model.router.dismissAllPresentations()
        model.router.pendingDeepLink = nil
        model.routeDeepLink(link)
        return model.router.activeSheet
    }

    func testTheBareLinkStaysTheHub() {
        // The server sends it on purpose (invites, shares): People is one tap.
        XCTAssertEqual(land("unstuck://settings"), .settings(section: nil))
    }

    func testOldAndNewSectionNamesLandOnTheSlimScreens() {
        let table: [(String, String?)] = [
            ("Notifications", "Notifications"), ("calls", "Notifications"), ("Calls", "Notifications"),
            ("Interface", "Appearance"), ("accessibility", "Appearance"), ("Appearance", "Appearance"),
            ("memory", "Assistant"), ("AI", "Assistant"), ("Assistant", "Assistant"),
            ("People", "People"), ("circle", "People"),
            ("Backup", "Account"), ("export", "Account"), ("Account", "Account"),
            ("feedback", "Feedback"),
            ("focus", nil), ("Sound", nil),   // nothing running → the hub
            ("insights", nil), ("nonsense", nil),
        ]
        for (section, want) in table {
            XCTAssertEqual(land("unstuck://settings?section=\(section)"), .settings(section: want), section)
        }
    }

    func testAreasAndTagsOpenTheTasksSheet() {
        for section in ["areas", "Areas", "tags", "Areas%20%26%20tags"] {
            model.router.select(.today)
            XCTAssertEqual(land("unstuck://settings?section=\(section)"), .areasTags, section)
            XCTAssertEqual(model.router.tab, .tasks, section)
        }
    }

    func testTheAssistantsOpenScreenTargets() {
        model.router.dismissAllPresentations()
        XCTAssertTrue(model.openScreen("settings"))
        XCTAssertEqual(model.router.activeSheet, .settings(section: nil))
        model.router.dismissAllPresentations(); model.router.pendingDeepLink = nil
        XCTAssertTrue(model.openScreen("notifications"))
        XCTAssertEqual(model.router.activeSheet, .settings(section: "Notifications"))
        model.router.dismissAllPresentations(); model.router.pendingDeepLink = nil
        XCTAssertTrue(model.openScreen("people"))
        XCTAssertEqual(model.router.activeSheet, .settings(section: "People"))
        model.router.dismissAllPresentations(); model.router.pendingDeepLink = nil
        XCTAssertTrue(model.openScreen("areas"))
        XCTAssertEqual(model.router.activeSheet, .areasTags)
        XCTAssertEqual(model.router.tab, .tasks)
    }

    func testALinkArrivingOverAnOpenSheetIsDeferredThenLands() {
        model.router.present(.inbox)
        model.routeDeepLink("unstuck://settings?section=Interface")
        XCTAssertEqual(model.router.pendingDeepLink, "unstuck://settings?section=Interface",
                       "dismiss first, then present — two sheets on one host no-op")
        model.flushPendingDeepLink()
        XCTAssertEqual(model.router.activeSheet, .settings(section: "Appearance"))
    }
}
