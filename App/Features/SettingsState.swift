// Device-local user preferences (theme / focus / sound / accessibility),
// UserDefaults-backed and never synced — the iOS mirror of Android's
// SettingsStore + SettingsState. Held as a single shared instance on
// AppModel (`model.settings`) so the whole app observes one source of
// truth; every property writes straight back to UserDefaults so the value
// survives relaunch.
//
// Notification LEVEL + reminder lead deliberately live in NotificationPrefs
// (already wired to the scheduler) — this store only carries the scalars iOS
// can act on locally.

import SwiftUI
import UnstuckCore

// `ThemePref` (system/light/dark) is the UnstuckCore enum (mirrors Android's
// ThemePref); we only add the SwiftUI override seam here.
extension ThemePref {
    /// The SwiftUI override applied at the app root. `nil` = follow system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Ambient sound bed for the focus "ambient" treatment. iOS generates brown
/// noise procedurally (AmbientAudio); `pink` reuses the same bed (we expose
/// the choice for Android parity, but both map to the one available loop).
enum AmbientSound: String, CaseIterable, Sendable {
    case off, brown, pink
}

@MainActor
@Observable
final class SettingsState {
    /// `@ObservationIgnored` so reads of UserDefaults don't register as
    /// observable dependencies; it's an immutable dependency, not state.
    @ObservationIgnored private let d: UserDefaults

    /// `loading` suppresses the persisting `didSet` while `load()` overlays
    /// the saved values onto the stored-property defaults — otherwise the
    /// hydrate would redundantly write every key straight back.
    @ObservationIgnored private var loading = false

    init(defaults: UserDefaults = .standard) { self.d = defaults }

    // MARK: Interface

    var theme: ThemePref = .system {
        didSet { if !loading { d.set(theme.rawValue, forKey: "unstuck.theme") } }
    }

    // MARK: Accessibility

    var reduceMotion: Bool = false {
        didSet { if !loading { d.set(reduceMotion, forKey: "unstuck.reduceMotion") } }
    }

    // MARK: Focus

    /// Default focus length / new-task estimate (minutes). Android: 25.
    var focusDefaultMin: Int = 25 {
        didSet { if !loading { d.set(focusDefaultMin, forKey: "unstuck.focusDefaultMin") } }
    }

    /// Soft overrun grace (minutes); 0 = Never. Android: 5.
    var focusOverrunMin: Int = 5 {
        didSet { if !loading { d.set(focusOverrunMin, forKey: "unstuck.focusOverrunMin") } }
    }

    /// When on, leaving focus via "← Out" records the session instead of
    /// discarding it. Android: true.
    var focusSoftExit: Bool = true {
        didSet { if !loading { d.set(focusSoftExit, forKey: "unstuck.focusSoftExit") } }
    }

    /// When on, Pause asks "Why are you pausing?"; off pauses silently.
    var focusPauseReasons: Bool = true {
        didSet { if !loading { d.set(focusPauseReasons, forKey: "unstuck.focusPauseReasons") } }
    }

    /// Treatment a fresh focus session starts in. Android: AMBIENT.
    var defaultTreatment: FocusTreatment = .ambient {
        didSet { if !loading { d.set(defaultTreatment.rawValue, forKey: "unstuck.defaultTreatment") } }
    }

    // MARK: Sound

    var soundStartChime: Bool = true {
        didSet { if !loading { d.set(soundStartChime, forKey: "unstuck.soundStartChime") } }
    }
    var soundOverrunBell: Bool = true {
        didSet { if !loading { d.set(soundOverrunBell, forKey: "unstuck.soundOverrunBell") } }
    }
    var soundCompletion: Bool = false {
        didSet { if !loading { d.set(soundCompletion, forKey: "unstuck.soundCompletion") } }
    }
    var ambient: AmbientSound = .off {
        didSet { if !loading { d.set(ambient.rawValue, forKey: "unstuck.ambient") } }
    }

    // MARK: load

    /// Hydrate from UserDefaults with Android-parity defaults. Reading the
    /// stored values in `init` would fire the `didSet` observers, so we load
    /// after the stored-property defaults are set, then overwrite in place.
    func load() {
        loading = true
        defer { loading = false }
        theme = ThemePref(rawValue: d.string(forKey: "unstuck.theme") ?? "") ?? .system
        reduceMotion = d.bool(forKey: "unstuck.reduceMotion")   // default false
        focusDefaultMin = d.object(forKey: "unstuck.focusDefaultMin") == nil ? 25 : d.integer(forKey: "unstuck.focusDefaultMin")
        focusOverrunMin = d.object(forKey: "unstuck.focusOverrunMin") == nil ? 5 : d.integer(forKey: "unstuck.focusOverrunMin")
        focusSoftExit = d.object(forKey: "unstuck.focusSoftExit") == nil ? true : d.bool(forKey: "unstuck.focusSoftExit")
        focusPauseReasons = d.object(forKey: "unstuck.focusPauseReasons") == nil ? true : d.bool(forKey: "unstuck.focusPauseReasons")
        defaultTreatment = FocusTreatment(rawValue: d.string(forKey: "unstuck.defaultTreatment") ?? "") ?? .ambient
        soundStartChime = d.object(forKey: "unstuck.soundStartChime") == nil ? true : d.bool(forKey: "unstuck.soundStartChime")
        soundOverrunBell = d.object(forKey: "unstuck.soundOverrunBell") == nil ? true : d.bool(forKey: "unstuck.soundOverrunBell")
        soundCompletion = d.bool(forKey: "unstuck.soundCompletion")   // default false
        ambient = AmbientSound(rawValue: d.string(forKey: "unstuck.ambient") ?? "") ?? .off
    }
}

extension SettingsState {
    /// A self-loading instance — the stored-property initialisers below are
    /// just the Android-parity defaults; `load()` then overlays any saved
    /// values. Kept as a convenience so AppModel can `SettingsState.loaded()`.
    static func loaded(defaults: UserDefaults = .standard) -> SettingsState {
        let s = SettingsState(defaults: defaults)
        s.load()
        return s
    }
}
