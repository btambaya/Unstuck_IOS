// Notification preferences (spec 10 §1.11/§1.12, mirror of the Android
// SettingsStore scalars): the NotificationLevel, the global "remind me N
// min before" lead, and the per-task reminder override. Reminders fire from
// on-device notifications, but the LEVEL and the LEAD are account-wide:
// `notification_preferences.notification_level` / `reminder_lead_min` is the
// source of truth (the web reads the same columns), written through on
// every change (AppModel.setNotificationLevel / setReminderLeadMin) and read
// back on every sign-in hydrate (AppModel.pullServerPreferencesIfNeeded).
// The UserDefaults keys are the device cache. A change whose push failed is
// flagged `pendingServerPush` so the next hydrate re-pushes it instead of
// letting the server's older value overwrite it. Per-task overrides stay
// device-local.

import Foundation
import UnstuckCore

enum NotificationPrefs {
    private static let levelKey = "unstuck.notificationLevel"
    private static let leadKey = "unstuck.reminderLeadMin"
    private static let overridePrefix = "reminder.override."
    private static let pendingPushKey = "unstuck.notifPrefs.pendingPush"

    static var defaults: UserDefaults { .standard }

    /// Calm / Balanced / Coach; default Balanced (spec 10 §3.1).
    static var level: NotificationLevel {
        get { NotificationLevel.fromLabel(defaults.string(forKey: levelKey) ?? "") }
        set { defaults.set(newValue.rawValue, forKey: levelKey) }
    }

    /// Global "remind me N min before a scheduled task"; 0 = Off; default 10.
    static var reminderLeadMin: Int {
        get { defaults.object(forKey: leadKey) == nil ? 10 : defaults.integer(forKey: leadKey) }
        set { defaults.set(newValue, forKey: leadKey) }
    }

    /// True while a level / lead change made on this device hasn't reached
    /// `notification_preferences` yet (offline) — the hydrate pull re-pushes
    /// rather than pulling over it.
    static var pendingServerPush: Bool {
        get { defaults.bool(forKey: pendingPushKey) }
        set { if newValue { defaults.set(true, forKey: pendingPushKey) } else { defaults.removeObject(forKey: pendingPushKey) } }
    }

    /// The server's `notification_level` value ("calm" / "balanced" /
    /// "coach", lowercase per migration 030) → the level; nil for null /
    /// unknown so the caller keeps its local value.
    static func level(fromServer raw: String?) -> NotificationLevel? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        return NotificationLevel.allCases.first { $0.rawValue.lowercased() == raw }
    }

    /// Per-task reminder lead override (minutes), or nil to use the global
    /// default. Stored device-locally (`reminder.override.<taskId>`).
    static func reminderOverride(taskId: String) -> Int? {
        let key = overridePrefix + taskId
        return defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }

    static func setReminderOverride(taskId: String, leadMin: Int?) {
        let key = overridePrefix + taskId
        if let leadMin { defaults.set(leadMin, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// All per-task overrides, for the scheduler's planReminders input.
    static func overridesByTask() -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(overridePrefix) {
            if let v = value as? Int { out[String(key.dropFirst(overridePrefix.count))] = v }
        }
        return out
    }

    /// Remove per-user content on sign-out so a different account on this
    /// device starts clean (spec 10 §1.8/§1.11; Android
    /// SettingsStore.clearUserContent): the per-task overrides AND the cached
    /// level + lead — the next account reads its own back from the server.
    static func clearUserContent() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(overridePrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: levelKey)
        defaults.removeObject(forKey: leadKey)
        defaults.removeObject(forKey: pendingPushKey)
    }
}
