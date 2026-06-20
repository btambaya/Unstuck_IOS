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
