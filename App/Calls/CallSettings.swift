// Device-local "Calls from Unstuck" preferences (UserDefaults): the master
// on/off switch (Android's `enabled` — applied ON RECEIPT: a call that lands
// while off ends as `declined` quietly + a notification, like the outside-
// hours path), the allowed hours the phone applies on receipt (outside → the
// call ends as `declined` silently + a notification), and the default lead
// for task-anchored calls. The SERVER window is 06:00–23:00 (request_call
// refuses outside it); this client window is the user's own guard, and it
// defaults to those same hours.
//
// The three PROACTIVE calls (morning plan / evening wrap-up / check-in after a
// block) are ACCOUNT-wide: `notification_preferences.call_*` (migration 072)
// through PreferencesClient — cached here as the device copy, with a
// `pendingProactivePush` flag so an offline toggle is re-pushed on the next
// hydrate instead of pulled over (the NotificationPrefs pattern).

import Foundation
import UnstuckCore
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

    /// The server's 06:00–23:00, like Android's DEFAULT_HOURS_*: the old
    /// 08:00–21:00 default quietly declined calls the server and the web had
    /// booked for 07:30 or 21:15 (audit 2026-09-22, C12). Only users who
    /// never changed their hours see the difference.
    static let defaultWindowStart = "06:00"
    static let defaultWindowEnd = "23:00"
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
        isWithinWindow(minuteOfDay: minuteOfDay(date, calendar: calendar), start: start, end: end)
    }

    /// The same rule on minutes since midnight (the HH:MM pickers).
    static func isWithinWindow(minuteOfDay t: Int, start: String, end: String) -> Bool {
        guard let s = minutesOfDay(start), let e = minutesOfDay(end) else { return true }
        if s == e { return true }
        if s < e { return t >= s && t < e }
        return t >= s || t < e
    }

    /// The allowed hours as a refusal names them, "08:00–21:00". The end is
    /// exclusive, so refusing the end minute itself read as a contradiction —
    /// "23:00 is outside this iPhone's call hours (06:00–23:00)" on untouched
    /// defaults, where the server and the web take 23:00 — so that one case
    /// also says the last minute that rings (audit 2026-09-22, C12).
    /// `clock`: the user's 12/24-hour clock for a line they READ (Settings,
    /// the task editor — "8:00 AM–9:00 PM"); nil keeps the machine HH:MM the
    /// model's `error:` strings carry.
    static func hoursLabel(start: String, end: String, refusing t: Int, clock: ClockFormat? = nil) -> String {
        let span = clock.map { $0.range(start, end) } ?? "\(start)–\(end)"
        guard let e = minutesOfDay(end), t == e else { return span }
        let last = (e + 24 * 60 - 1) % (24 * 60)
        let lastText = clock?.time(minutes: last) ?? String(format: "%02d:%02d", last / 60, last % 60)
        return "\(span); the latest it rings is \(lastText)"
    }

    // MARK: will it ring here? (audit 2026-09-22, C12)
    //
    // Every booking path used to check only the server window, while the
    // phone applied its switch and hours on receipt — so a call the app had
    // confirmed was declined quietly at ring time, every day for a proactive
    // time outside the hours. These say so where the time is picked.

    /// The minute dispatch_proactive_calls (072) actually books a morning /
    /// evening call picked for minute `t`: its cron runs every 5 minutes and
    /// books at the first tick in [t, t+10) that is also inside 06:00–23:00
    /// (inclusive). nil = no tick qualifies, so the call never happens.
    static func proactiveRingMinute(_ t: Int) -> Int? {
        guard let s = minutesOfDay(serverWindowStart), let e = minutesOfDay(serverWindowEnd) else { return t }
        let first = (t + 4) / 5 * 5
        return [first, first + 5].first { $0 >= s && $0 <= e }
    }

    /// The amber line under a proactive call's time picker, or nil when it
    /// will ring here. Judged at the minute the dispatcher really books it
    /// (proactiveRingMinute) and the minute after — call-dispatch runs every
    /// minute — against this phone's switch and hours.
    /// Times read in the phone's own clock (`clock`; tests pin one).
    static func proactiveTimeWarning(_ hhmm: String, enabled: Bool, start: String, end: String,
                                     clock: ClockFormat = .device) -> String? {
        guard let t = minutesOfDay(hhmm) else { return nil }
        guard let ring = proactiveRingMinute(t) else {
            return "Unstuck only calls between \(clock.time(serverWindowStart)) and \(clock.time(serverWindowEnd)), so a call at \(clock.time(hhmm)) never rings."
        }
        if !enabled {
            return "Calls are off on this iPhone, so this call is declined here — switch them on above."
        }
        if let outside = [ring, ring + 1].first(where: { !isWithinWindow(minuteOfDay: $0, start: start, end: end) }) {
            return "Unstuck rings this call at about \(clock.time(minutes: outside)), outside this iPhone's allowed hours (\(hoursLabel(start: start, end: end, refusing: outside, clock: clock))), so it's declined here — widen the hours above or pick another time."
        }
        return nil
    }

    /// The amber line under "Check in after a block" (it rings at the tick
    /// after a block ends, any time 06:00–23:00), or nil when every such
    /// call rings here. The 23:00 minute itself is left out: the default
    /// hours end there (exclusive), and one edge minute is not worth a
    /// warning on every untouched phone.
    static func afterBlockWarning(enabled: Bool, start: String, end: String, clock: ClockFormat = .device) -> String? {
        if !enabled {
            return "Calls are off on this iPhone, so these check-ins are declined here — switch them on above."
        }
        guard let s = minutesOfDay(serverWindowStart), let e = minutesOfDay(serverWindowEnd) else { return nil }
        if (s..<e).allSatisfy({ isWithinWindow(minuteOfDay: $0, start: start, end: end) }) { return nil }
        return "This iPhone only takes calls \(clock.range(start, end)), so a check-in after a block that ends outside those hours is declined here."
    }

    /// Can a call actually ring on this phone? Calls on here, and a
    /// call_requests row mirrored (any platform, any status) or a proactive
    /// call switched on — the moment to ask for the microphone (audit
    /// 2026-09-22, C13).
    static func expectsCalls(hasCallRows: Bool, enabled: Bool = Self.enabled,
                             proactive: CallProactivePrefs = Self.proactive) -> Bool {
        enabled && (hasCallRows || proactive.morningEnabled || proactive.eveningEnabled || proactive.afterBlockEnabled)
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

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
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
