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
        XCTAssertTrue(s.focusCollapseRail)
        XCTAssertTrue(s.soundStartChime)
        XCTAssertTrue(s.soundOverrunBell)
    }

    func testFalseDefaultingBoolsDefaultFalseWhenUnset() {
        let s = SettingsState(defaults: freshDefaults())
        s.load()
        XCTAssertFalse(s.reduceMotion)
        XCTAssertFalse(s.largerType)
        XCTAssertFalse(s.highContrast)
        XCTAssertFalse(s.soundCompletion)
    }

    func testStoredFalseOverridesTrueDefault() {
        let d = freshDefaults()
        d.set(false, forKey: "unstuck.focusSoftExit")   // user turned it OFF
        d.set(false, forKey: "unstuck.soundStartChime")
        let s = SettingsState(defaults: d)
        s.load()
        XCTAssertFalse(s.focusSoftExit, "an explicitly-stored false must survive")
        XCTAssertFalse(s.soundStartChime)
        // An unset true-default bool is unaffected.
        XCTAssertTrue(s.focusPauseReasons)
    }

    func testStoredTrueOverridesFalseDefault() {
        let d = freshDefaults()
        d.set(true, forKey: "unstuck.reduceMotion")
        let s = SettingsState(defaults: d)
        s.load()
        XCTAssertTrue(s.reduceMotion)
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
        d.set("garbage", forKey: "unstuck.density")   // unrecognised → default
        let s = SettingsState(defaults: d)
        s.load()
        XCTAssertEqual(s.theme, .dark)
        XCTAssertEqual(s.density, .regular, "an unrecognised raw value falls back to the default")
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
