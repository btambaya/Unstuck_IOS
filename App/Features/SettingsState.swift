// Device-local user preferences (theme / text size / focus options /
// background noise / the AI switch), UserDefaults-backed and never synced —
// the iOS mirror of Android's SettingsStore + SettingsState. Held as a single shared instance on
// AppModel (`model.settings`) so the whole app observes one source of
// truth; every property writes straight back to UserDefaults so the value
// survives relaunch.
//
// Notification LEVEL + reminder lead deliberately live in NotificationPrefs
// (already wired to the scheduler) — this store only carries the scalars iOS
// can act on locally.
//
// Slim Settings (PLAN.md, 2026-09-24): Accent, High contrast, the in-app
// Reduce motion, "Hide right rail" and the three sounds (start chime, overrun
// bell, completion — nothing ever played them) are gone. Their stored values
// are NOT wiped; they are simply never read again. Density + Larger type
// merged into one Text size (read once from the old keys, then its own key).

import SwiftUI
import UnstuckCore
import UnstuckDesign

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

/// The stored background-noise value (the old Ambient setting's raw values,
/// kept so older builds read it). iOS generates one procedural brown bed
/// (AmbientAudio): the Focus screen's speaker button is the setting now —
/// on stores `.brown`; a stored `pink` (the same loop) reads as on.
enum AmbientSound: String, CaseIterable, Sendable {
    case off, brown, pink
    var isOn: Bool { self != .off }
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

    // MARK: Appearance

    var theme: ThemePref = .system {
        didSet { if !loading { d.set(theme.rawValue, forKey: "unstuck.theme") } }
    }

    /// Settings → Appearance → Text size (Smaller / Default / Larger), applied
    /// at the app root as DynamicTypeSize steps (`TextSizePref.typeStepShift`).
    var textSize: TextSizePref = .standard {
        didSet { if !loading { d.set(textSize.rawValue, forKey: Self.textSizeKey) } }
    }
    nonisolated static let textSizeKey = "unstuck.textSize"

    /// The AI kill-switch the published privacy policy promises (§21: "Settings
    /// → Assistant & privacy → AI Assistant. Turn it off entirely"). Default ON;
    /// when OFF there is no launcher, no panel, no voice, open-assistant deep
    /// links are ignored, and a call that arrives is declined (CallCoordinator).
    /// Device-local, never synced.
    var assistantEnabled: Bool = true {
        didSet { if !loading { d.set(assistantEnabled, forKey: Self.assistantEnabledKey) } }
    }
    nonisolated static let assistantEnabledKey = "unstuck.assistantEnabled"

    /// Read before AppModel is up (a killed-state VoIP launch): ON unless the
    /// user turned it off.
    nonisolated static func storedAssistantEnabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: assistantEnabledKey) == nil ? true : d.bool(forKey: assistantEnabledKey)
    }

    // MARK: Focus

    /// The estimate a new task starts with (minutes). The New Task sheet
    /// remembers the last one picked here (same key, so the assistant's
    /// set_focus_defaults still sets it). Android: 25.
    var focusDefaultMin: Int = 25 {
        didSet { if !loading { d.set(focusDefaultMin, forKey: "unstuck.focusDefaultMin") } }
    }

    /// Focus ⋯ Options → "Check in when I run over" (minutes); 0 = Never. Android: 5.
    var focusOverrunMin: Int = 5 {
        didSet { if !loading { d.set(focusOverrunMin, forKey: "unstuck.focusOverrunMin") } }
    }

    /// Focus ⋯ Options → "Ask before I leave a session" (also "Don't ask
    /// again" on that question). Android: true.
    var focusSoftExit: Bool = true {
        didSet { if !loading { d.set(focusSoftExit, forKey: "unstuck.focusSoftExit") } }
    }

    /// Focus ⋯ Options → "Ask why I'm pausing" (also "Don't ask again" on
    /// that question); off pauses silently.
    var focusPauseReasons: Bool = true {
        didSet { if !loading { d.set(focusPauseReasons, forKey: "unstuck.focusPauseReasons") } }
    }

    /// Treatment a fresh focus session starts in. Android: AMBIENT.
    var defaultTreatment: FocusTreatment = .ambient {
        didSet { if !loading { d.set(defaultTreatment.rawValue, forKey: "unstuck.defaultTreatment") } }
    }

    /// Hands-Free Focus Copilot — spoken progress alerts during a focus block
    /// (HALFWAY / T-5 / AT_TIME / OVERRUN, gated by the notification level).
    /// 100% on-device TTS, zero LLM. Default ON (speak-only). Focus ⋯ Options →
    /// "Talk me through the session".
    var focusSpokenCoach: Bool = true {
        didSet { if !loading { d.set(focusSpokenCoach, forKey: "unstuck.focusSpokenCoach") } }
    }

    /// Hands-free VOICE replies — after a question prompt, open a short
    /// on-device mic window so you can say "add ten" / "stop" / "keep going"
    /// without touching the screen. Requires the spoken coach. Default OFF
    /// (the mic is opt-in). Focus ⋯ Options, under the coach.
    var focusVoiceReplies: Bool = false {
        didSet { if !loading { d.set(focusVoiceReplies, forKey: "unstuck.focusVoiceReplies") } }
    }

    // MARK: Background noise

    /// The Focus screen's speaker button — it IS the setting and remembers
    /// on/off (`.brown` on, `.off` off; a stored `pink` reads as on).
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
        // Text size: its own key once chosen; until then, the old Density /
        // Larger type values (never wiped) decide it.
        if let stored = d.string(forKey: Self.textSizeKey), let pref = TextSizePref(rawValue: stored) {
            textSize = pref
        } else {
            textSize = TextSizePref.migrated(density: d.string(forKey: "unstuck.density"),
                                             largerType: d.bool(forKey: "unstuck.largerType"))
        }
        // ON unless the user explicitly turned the assistant off.
        assistantEnabled = Self.storedAssistantEnabled(d)
        focusDefaultMin = d.object(forKey: "unstuck.focusDefaultMin") == nil ? 25 : d.integer(forKey: "unstuck.focusDefaultMin")
        focusOverrunMin = d.object(forKey: "unstuck.focusOverrunMin") == nil ? 5 : d.integer(forKey: "unstuck.focusOverrunMin")
        focusSoftExit = d.object(forKey: "unstuck.focusSoftExit") == nil ? true : d.bool(forKey: "unstuck.focusSoftExit")
        focusPauseReasons = d.object(forKey: "unstuck.focusPauseReasons") == nil ? true : d.bool(forKey: "unstuck.focusPauseReasons")
        defaultTreatment = FocusTreatment(rawValue: d.string(forKey: "unstuck.defaultTreatment") ?? "") ?? .ambient
        focusSpokenCoach = d.object(forKey: "unstuck.focusSpokenCoach") == nil ? true : d.bool(forKey: "unstuck.focusSpokenCoach")
        focusVoiceReplies = d.object(forKey: "unstuck.focusVoiceReplies") == nil ? false : d.bool(forKey: "unstuck.focusVoiceReplies")
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
