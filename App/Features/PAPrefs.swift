// Personal-assistant prefs — WHICH recurring PA moments run (`RitualPrefs`)
// and which moment ids the user has dismissed. Same UserDefaults keys + JSON
// shapes as the web's localStorage (`unstuck-pa-rituals` = RitualPrefs JSON,
// `unstuck-pa-dismissed` = [String]), so the two platforms stay describable
// in one vocabulary.
//
// The RITUAL toggles are account-wide: `user_preferences.pa_rituals`
// (migration 053) is the source of truth — the local key is a cache that
// wins until the first hydrate, after which the server wins; every toggle
// here fires `onRitualsChanged` (AppModel pushes it up), and a push that
// fails is flagged pending so the next hydrate re-pushes instead of pulling
// the server's older value over it. Moment DISMISSALS stay DEVICE-LOCAL by
// design: "not now" on the phone must not hide the card on the laptop.
// Per-user state: every key must be wiped by
// `AppModel.scrubDeviceLocalUserContent()` on sign-out (`PAPrefsStore.scrub()`)
// — leaving them across a sign-out on a shared device leaks one person's
// setup to the next.

import Foundation
import Observation
import UnstuckCore

/// Static get/set over UserDefaults — the storage layer. Pure I/O, no state.
enum PAPrefsStore {
    static let ritualsKey = "unstuck-pa-rituals"
    static let dismissedKey = "unstuck-pa-dismissed"
    /// Set while a ritual toggle made here hasn't reached `pa_rituals` yet.
    static let pendingPushKey = "unstuck-pa-rituals-pending-push"
    /// Every key this store owns — the sign-out wipe removes all of them.
    static let allKeys = [ritualsKey, dismissedKey, pendingPushKey]
    /// The web keeps the newest 200 dismissals (gateway-card.tsx).
    static let maxDismissed = 200

    /// The stored value is the JSON text (like the web's localStorage string);
    /// a `Data` blob written by an earlier build is read the same way.
    private static func json(_ key: String, _ defaults: UserDefaults) -> Data? {
        switch defaults.object(forKey: key) {
        case let s as String: return s.data(using: .utf8)
        case let d as Data: return d
        default: return nil
        }
    }

    // MARK: rituals

    static func getRitualPrefs(_ defaults: UserDefaults = .standard) -> RitualPrefs {
        guard let data = json(ritualsKey, defaults) else { return RitualPrefs.defaults }
        // `{ ...DEFAULTS, ...JSON.parse(raw) }` — RitualPrefs' decoder fills missing keys.
        return (try? JSONDecoder().decode(RitualPrefs.self, from: data)) ?? RitualPrefs.defaults
    }

    static func setRitualPrefs(_ prefs: RitualPrefs, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(prefs), let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: ritualsKey)
    }

    /// The `set_ritual` tool's entry point: a ritual NAME from the model
    /// ("morning" | "evening" | "friday" | "sunday"). Returns false for an
    /// unknown name so the executor can answer with the contract's error.
    @discardableResult
    static func setRitual(_ name: String, on: Bool, _ defaults: UserDefaults = .standard) -> Bool {
        guard let key = RitualKey(rawValue: name) else { return false }
        var prefs = getRitualPrefs(defaults)
        prefs[key] = on
        setRitualPrefs(prefs, defaults)
        return true
    }

    static func isPendingPush(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pendingPushKey)
    }

    static func setPendingPush(_ pending: Bool, _ defaults: UserDefaults = .standard) {
        if pending { defaults.set(true, forKey: pendingPushKey) } else { defaults.removeObject(forKey: pendingPushKey) }
    }

    // MARK: dismissed moment ids

    static func getDismissed(_ defaults: UserDefaults = .standard) -> [String] {
        guard let data = json(dismissedKey, defaults),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    static func setDismissed(_ ids: [String], _ defaults: UserDefaults = .standard) {
        let capped = Array(ids.suffix(maxDismissed))
        guard let data = try? JSONEncoder().encode(capped), let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: dismissedKey)
    }

    /// Sign-out wipe: remove BOTH keys so the next account starts on defaults.
    static func scrub(_ defaults: UserDefaults = .standard) {
        for key in allKeys { defaults.removeObject(forKey: key) }
    }
}

/// Observable wrapper for the surfaces (gateway card, Settings, interview):
/// one shared instance on AppModel so every reader sees one source of truth;
/// every mutation writes straight back to UserDefaults.
@MainActor
@Observable
final class PAPrefs {
    /// `@ObservationIgnored` so reads of UserDefaults don't register as
    /// observable dependencies; it's an immutable dependency, not state.
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var rituals: RitualPrefs
    private(set) var dismissed: [String]
    /// Fired after every USER change to the rituals (not after a server
    /// apply) — AppModel wires it to the `pa_rituals` push.
    @ObservationIgnored var onRitualsChanged: ((RitualPrefs) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rituals = PAPrefsStore.getRitualPrefs(defaults)
        self.dismissed = PAPrefsStore.getDismissed(defaults)
    }

    func setRitual(_ key: RitualKey, on: Bool) {
        rituals[key] = on
        PAPrefsStore.setRitualPrefs(rituals, defaults)
        onRitualsChanged?(rituals)
    }

    func setRituals(_ prefs: RitualPrefs) {
        rituals = prefs
        PAPrefsStore.setRitualPrefs(prefs, defaults)
        onRitualsChanged?(rituals)
    }

    /// The account's rituals as the server has them (hydrate): replace the
    /// cache without firing the push, and clear any pending-push flag — the
    /// server is the truth from here on.
    func applyServerRituals(_ prefs: RitualPrefs) {
        rituals = prefs
        PAPrefsStore.setRitualPrefs(prefs, defaults)
        PAPrefsStore.setPendingPush(false, defaults)
    }

    var isPendingPush: Bool { PAPrefsStore.isPendingPush(defaults) }
    func setPendingPush(_ pending: Bool) { PAPrefsStore.setPendingPush(pending, defaults) }

    /// Record a moment dismissal (idempotent; keeps the newest 200).
    func dismiss(_ momentId: String) {
        guard !dismissed.contains(momentId) else { return }
        dismissed = Array((dismissed + [momentId]).suffix(PAPrefsStore.maxDismissed))
        PAPrefsStore.setDismissed(dismissed, defaults)
    }

    func isDismissed(_ momentId: String) -> Bool { dismissed.contains(momentId) }

    /// The `MomentState.isDismissed` closure over a snapshot of the current list.
    var dismissalCheck: @Sendable (String) -> Bool {
        let ids = Set(dismissed)
        return { ids.contains($0) }
    }

    /// Re-read from UserDefaults (after a sign-out scrub or an external write).
    func reload() {
        rituals = PAPrefsStore.getRitualPrefs(defaults)
        dismissed = PAPrefsStore.getDismissed(defaults)
    }

    /// Sign-out: wipe the keys and fall back to defaults in memory.
    func scrub() {
        PAPrefsStore.scrub(defaults)
        reload()
    }
}
