// Device-local "Calls from Unstuck" preferences (UserDefaults): the master
// on/off switch (Android's `enabled` — applied ON RECEIPT: a call that lands
// while off ends as `declined` quietly + a notification, like the outside-
// hours path), the allowed hours the phone applies on receipt (outside → the
// call ends as `declined` silently + a notification), and the default lead
// for task-anchored calls. The SERVER window is 06:00–23:00 (request_call
// refuses outside it); this client window is the user's own, narrower guard.
//
// The three PROACTIVE calls (morning plan / evening wrap-up / check-in after a
// block) are ACCOUNT-wide: `notification_preferences.call_*` (migration 072)
// through PreferencesClient — cached here as the device copy, with a
// `pendingProactivePush` flag so an offline toggle is re-pushed on the next
// hydrate instead of pulled over (the NotificationPrefs pattern).

import Foundation
import UnstuckSync

enum CallSettings {
    static let enabledKey = "unstuck.calls.enabled"
    static let windowStartKey = "unstuck.calls.windowStart"
    static let windowEndKey = "unstuck.calls.windowEnd"
    static let defaultLeadKey = "unstuck.calls.defaultLead"
    static let proactiveKey = "unstuck.calls.proactive"
    static let pendingProactivePushKey = "unstuck.calls.proactive.pendingPush"
    static let voipNudgeDismissedKey = "unstuck.calls.voipNudgeDismissed"

    /// Every key the sign-out scrub removes (AppModel.scrubDeviceLocalUserContent).
    static let userContentKeys = [enabledKey, windowStartKey, windowEndKey, defaultLeadKey,
                                  proactiveKey, pendingProactivePushKey, voipNudgeDismissedKey]

    static let defaultWindowStart = "08:00"
    static let defaultWindowEnd = "21:00"
    static let leadOptions = [5, 10, 15, 30]
    static let defaultLead = 15

    /// The server's booking window (HH:MM, inclusive both ends).
    static let serverWindowStart = "06:00"
    static let serverWindowEnd = "23:00"

    /// The store. Swappable so the persistence tests run on a throwaway suite
    /// (written once from a test's setUp on the main thread — never mutated
    /// concurrently in production).
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// Master switch (default ON — a booked call rings unless they turned
    /// calls off on THIS phone). A missing key is "on": `bool(forKey:)` would
    /// silently read false on a first launch.
    static var enabled: Bool {
        get { defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    static var windowStart: String {
        get { valid(defaults.string(forKey: windowStartKey)) ?? defaultWindowStart }
        set { defaults.set(newValue, forKey: windowStartKey) }
    }
    static var windowEnd: String {
        get { valid(defaults.string(forKey: windowEndKey)) ?? defaultWindowEnd }
        set { defaults.set(newValue, forKey: windowEndKey) }
    }
    static var defaultLeadMin: Int {
        get {
            let v = defaults.integer(forKey: defaultLeadKey)
            return v > 0 ? v : defaultLead
        }
        set { defaults.set(newValue, forKey: defaultLeadKey) }
    }

    // MARK: proactive calls (server-backed; this is the device cache)

    /// The cached proactive toggles + times; `.defaults` (all off) until the
    /// server row has been read or the user toggled one here.
    static var proactive: CallProactivePrefs {
        get {
            guard let data = defaults.data(forKey: proactiveKey),
                  let p = try? JSONDecoder().decode(CallProactivePrefs.self, from: data) else { return .defaults }
            return p
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: proactiveKey) }
        }
    }

    /// True while a toggle made on this device hasn't reached
    /// `notification_preferences` yet — the hydrate pull re-pushes it rather
    /// than pulling the server's older value over it.
    static var pendingProactivePush: Bool {
        get { defaults.bool(forKey: pendingProactivePushKey) }
        set {
            if newValue { defaults.set(true, forKey: pendingProactivePushKey) }
            else { defaults.removeObject(forKey: pendingProactivePushKey) }
        }
    }

    // MARK: the VoIP nudge

    /// The one-time "Calls need Voice-over-IP registration — retry" note was
    /// acted on (retry tapped) on this install.
    static var voipNudgeDismissed: Bool {
        get { defaults.bool(forKey: voipNudgeDismissedKey) }
        set {
            if newValue { defaults.set(true, forKey: voipNudgeDismissedKey) }
            else { defaults.removeObject(forKey: voipNudgeDismissedKey) }
        }
    }

    // MARK: windows

    /// Is `date` inside the user's window? Start inclusive, end exclusive;
    /// start == end → always allowed; start > end → an overnight window
    /// (e.g. 22:00–02:00).
    static func isWithinWindow(_ date: Date, start: String = windowStart, end: String = windowEnd,
                               calendar: Calendar = .current) -> Bool {
        guard let s = minutesOfDay(start), let e = minutesOfDay(end) else { return true }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let t = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if s == e { return true }
        if s < e { return t >= s && t < e }
        return t >= s || t < e
    }

    /// Server booking window check (inclusive 06:00 … 23:00).
    static func isWithinServerWindow(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let s = minutesOfDay(serverWindowStart), let e = minutesOfDay(serverWindowEnd) else { return true }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let t = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return t >= s && t <= e
    }

    static func minutesOfDay(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
        return p[0] * 60 + p[1]
    }

    static func hhmm(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "14:05" → "2:05pm", "09:00" → "9am", "12:30" → "12:30pm", "00:15" →
    /// "12:15am" — a time the way people say it (the after-block opening).
    /// Anything that isn't HH:MM comes back as given.
    static func spokenTime(_ hhmm: String) -> String {
        guard let m = minutesOfDay(hhmm) else { return hhmm }
        let h24 = m / 60, min = m % 60
        let suffix = h24 < 12 ? "am" : "pm"
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        return min == 0 ? "\(h12)\(suffix)" : String(format: "%d:%02d%@", h12, min, suffix)
    }

    private static func valid(_ s: String?) -> String? {
        guard let s, minutesOfDay(s) != nil else { return nil }
        return s
    }
}

/// The one-time nudge for a phone whose PushKit registration never produced a
/// VoIP token: shown in Settings › Calls when, 10 s after a signed-in launch,
/// there is still no token, until the user taps retry (or a token lands).
/// Pure — the registry and Settings supply the facts.
enum VoipRegistrationNudge {
    static let graceSeconds: TimeInterval = 10

    static func shouldShow(tokenPresent: Bool, signedIn: Bool, secondsSinceStart: TimeInterval?,
                           dismissed: Bool) -> Bool {
        guard !tokenPresent, signedIn, !dismissed, let s = secondsSinceStart else { return false }
        return s >= graceSeconds
    }
}
