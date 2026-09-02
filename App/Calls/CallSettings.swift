// Device-local "Calls from Unstuck" preferences (UserDefaults): the allowed
// hours the phone applies ON RECEIPT (outside → the call ends as `declined`
// silently + a notification), and the default lead for task-anchored calls.
// The SERVER window is 06:00–23:00 (request_call refuses outside it); this
// client window is the user's own, narrower guard.

import Foundation

enum CallSettings {
    static let windowStartKey = "unstuck.calls.windowStart"
    static let windowEndKey = "unstuck.calls.windowEnd"
    static let defaultLeadKey = "unstuck.calls.defaultLead"

    static let defaultWindowStart = "08:00"
    static let defaultWindowEnd = "21:00"
    static let leadOptions = [5, 10, 15, 30]
    static let defaultLead = 15

    /// The server's booking window (HH:MM, inclusive both ends).
    static let serverWindowStart = "06:00"
    static let serverWindowEnd = "23:00"

    static var defaults: UserDefaults { .standard }

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

    private static func valid(_ s: String?) -> String? {
        guard let s, minutesOfDay(s) != nil else { return nil }
        return s
    }
}
