// Device-local notification preferences (spec 10 §1.11/§1.12, mirror of
// the Android SettingsStore scalars): the NotificationLevel, the global
// "remind me N min before" lead, and the per-task reminder override.
// Device-local and never synced — reminders fire from on-device
// notifications; only the level-derived booleans are mirrored to
// notification_preferences (AppModel.setNotificationLevel).

import Foundation
import UnstuckCore

enum NotificationPrefs {
    private static let levelKey = "unstuck.notificationLevel"
    private static let leadKey = "unstuck.reminderLeadMin"
    private static let overridePrefix = "reminder.override."

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

    /// Remove per-user device-local content on sign-out so a different
    /// account on this device starts clean (spec 10 §1.8/§1.11; Android
    /// SettingsStore.clearUserContent).
    static func clearUserContent() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(overridePrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
