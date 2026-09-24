// ClockFormat — THE one formatter for every clock time the user sees.
//
// Ahmad, 2026-09-24: "On the calendar we need to be consistent — either 12
// hour or 24h, not both." His iPhone is set to 24-hour, yet Today said
// "THURSDAY · 2:02 PM" while the rest of the app showed 14:02 — every screen
// hard-coded its own format ("h:mm a", "%02d:%02d", a hand-rolled "2pm"…).
//
// The rule, app-wide: a clock time the user SEES follows the device's own
// 12/24-hour preference (Settings › General › Date & Time › 24-Hour Time,
// and the region's default). Every display site goes through this type:
//
//   24-hour  "14:30" · whole hours in tight spots "14:00" (never "14")
//   12-hour  "2:30 PM" · whole hours in tight spots "2 PM" (the locale's
//            AM/PM symbols)
//   ranges   "14:00–15:30" / "2:00–3:30 PM" / "11:30 AM–12:30 PM" (en dash)
//
// NOT for machine formats: HH:MM in tool arguments / results the model reads,
// storage, API payloads, Google sync, logs — those stay "HH:mm" exactly as
// they were. The formatter itself is pure (the mode is passed in, so tests
// pin both); `ClockFormat.device` is the thin accessor that supplies the
// phone's mode.

import Foundation

public struct ClockFormat: Sendable, Hashable {
    /// 12-hour (AM/PM) or 24-hour.
    public enum Cycle: String, Sendable, Hashable {
        case h12
        case h24
    }

    public var cycle: Cycle
    /// The locale's AM / PM markers ("AM"/"PM" in en_US, "am"/"pm" in en_GB).
    public var amSymbol: String
    public var pmSymbol: String

    public init(cycle: Cycle, amSymbol: String = "AM", pmSymbol: String = "PM") {
        self.cycle = cycle
        self.amSymbol = amSymbol
        self.pmSymbol = pmSymbol
    }

    /// 24-hour: "14:30".
    public static let h24 = ClockFormat(cycle: .h24)
    /// 12-hour with the en_US markers: "2:30 PM".
    public static let h12 = ClockFormat(cycle: .h12)

    public var is24Hour: Bool { cycle == .h24 }

    // MARK: - detection

    /// The hour cycle a localized hour pattern implies — the pattern
    /// `DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale:)`
    /// returns ("h a" → 12h, "HH" → 24h, "H時" → 24h). A day-period field
    /// (`a`, `b`, `B`) or a 12-hour hour field (`h`, `K`) means 12-hour.
    /// Quoted literals are ignored: fr_CA's "HH 'h'" is 24-hour, and hi_IN's
    /// "B h" (a flexible day period, no `a`) is 12-hour.
    public static func cycle(forHourPattern pattern: String) -> Cycle {
        var inQuote = false
        for ch in pattern {
            if ch == "'" { inQuote.toggle(); continue }
            if inQuote { continue }
            if ch == "a" || ch == "b" || ch == "B" || ch == "h" || ch == "K" { return .h12 }
        }
        return .h24
    }

    /// The clock `locale` asks for: its hour cycle (a 24-Hour Time override
    /// rides in the locale — "en_US@hours=h23") plus its AM/PM symbols.
    public static func forLocale(_ locale: Locale) -> ClockFormat {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "HH"
        let f = DateFormatter()
        f.locale = locale
        let am = f.amSymbol.flatMap { $0.isEmpty ? nil : $0 } ?? "AM"
        let pm = f.pmSymbol.flatMap { $0.isEmpty ? nil : $0 } ?? "PM"
        return ClockFormat(cycle: cycle(forHourPattern: pattern), amSymbol: am, pmSymbol: pm)
    }

    /// The phone's own clock — what every display site uses. Cached (a
    /// template lookup per row would add up on a long list) and dropped when
    /// the system locale changes, or when the app calls `refreshDevice()`
    /// on returning to the foreground.
    public static var device: ClockFormat { DeviceClock.shared.current() }

    /// Forget the cached device clock so the next read picks up a changed
    /// 12/24-hour setting. The app calls it on every return to the foreground.
    public static func refreshDevice() { DeviceClock.shared.invalidate() }

    // MARK: - formatting

    /// "14:30" / "2:30 PM". Out-of-range input wraps onto the 24-hour day.
    public func time(hour: Int, minute: Int) -> String {
        time(minutes: hour * 60 + minute)
    }

    /// A time given as minutes since midnight (wraps: 1440 → midnight).
    public func time(minutes: Int) -> String {
        let (h, m) = Self.split(minutes)
        switch cycle {
        case .h24: return "\(Self.pad2(h)):\(Self.pad2(m))"
        case .h12: return "\(Self.hour12(h)):\(Self.pad2(m)) \(marker(h))"
        }
    }

    /// A stored "HH:MM" (or "H:MM", or "HH:MM:SS") in the user's clock.
    /// Anything that isn't a clock time comes back exactly as given.
    public func time(_ hhmm: String) -> String {
        guard let mins = Self.minutes(hhmm) else { return hhmm }
        return time(minutes: mins)
    }

    /// The wall-clock time of `date` in `calendar`'s zone (the device's by default).
    public func time(_ date: Date, calendar: Calendar = Time.calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return time(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    /// A whole hour in a tight spot (grid gutters, axis ticks): "14:00" / "2 PM".
    public func hourLabel(_ hour: Int) -> String {
        let (h, _) = Self.split(hour * 60)
        switch cycle {
        case .h24: return "\(Self.pad2(h)):00"
        case .h12: return "\(Self.hour12(h)) \(marker(h))"
        }
    }

    /// A time in running prose — a whole hour reads short in 12-hour mode
    /// ("2 PM"), anything else as `time` ("2:30 PM"); 24-hour is always "14:00".
    public func shortTime(minutes: Int) -> String {
        let (h, m) = Self.split(minutes)
        return m == 0 ? hourLabel(h) : time(minutes: minutes)
    }

    /// `shortTime` for a stored "HH:MM"; anything else comes back as given.
    public func shortTime(_ hhmm: String) -> String {
        guard let mins = Self.minutes(hhmm) else { return hhmm }
        return shortTime(minutes: mins)
    }

    /// "14:00–15:30" / "2:00–3:30 PM" / "11:30 AM–12:30 PM". Minutes since
    /// midnight; an end past midnight wraps ("23:00–00:30").
    public func range(startMinutes: Int, endMinutes: Int) -> String {
        switch cycle {
        case .h24:
            return "\(time(minutes: startMinutes))–\(time(minutes: endMinutes))"
        case .h12:
            let (sh, sm) = Self.split(startMinutes)
            let (eh, _) = Self.split(endMinutes)
            if marker(sh) == marker(eh) {
                return "\(Self.hour12(sh)):\(Self.pad2(sm))–\(time(minutes: endMinutes))"
            }
            return "\(time(minutes: startMinutes))–\(time(minutes: endMinutes))"
        }
    }

    /// Two stored "HH:MM" times as a range; either unparseable → joined as given.
    public func range(_ startHHMM: String, _ endHHMM: String) -> String {
        guard let s = Self.minutes(startHHMM), let e = Self.minutes(endHHMM) else {
            return "\(time(startHHMM))–\(time(endHHMM))"
        }
        return range(startMinutes: s, endMinutes: e)
    }

    /// A block's span from its "HH:MM" start and length.
    public func range(start hhmm: String, durationMinutes: Int) -> String {
        guard let s = Self.minutes(hhmm) else { return hhmm }
        return range(startMinutes: s, endMinutes: s + durationMinutes)
    }

    /// The hour starting at `hour`, as a heat-map cell names it:
    /// "14:00–15:00" / "2–3 PM" / "11 AM–12 PM" / "11 PM–12 AM".
    public func hourSpan(_ hour: Int) -> String {
        let (a, _) = Self.split(hour * 60)
        let (b, _) = Self.split(hour * 60 + 60)
        switch cycle {
        case .h24:
            return "\(hourLabel(a))–\(hourLabel(b))"
        case .h12:
            return marker(a) == marker(b)
                ? "\(Self.hour12(a))–\(hourLabel(b))"
                : "\(hourLabel(a))–\(hourLabel(b))"
        }
    }

    // MARK: - helpers

    private func marker(_ hour24: Int) -> String { hour24 < 12 ? amSymbol : pmSymbol }

    /// (hour 0–23, minute 0–59) for minutes since midnight, wrapped onto one day.
    static func split(_ minutes: Int) -> (Int, Int) {
        let m = ((minutes % 1440) + 1440) % 1440
        return (m / 60, m % 60)
    }

    /// 0 → 12, 13 → 1, 12 → 12.
    static func hour12(_ h: Int) -> Int { h % 12 == 0 ? 12 : h % 12 }

    static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// Minutes since midnight for "H:MM" / "HH:MM" / "HH:MM:SS" (hour 0–24,
    /// minute 0–59), else nil.
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...24).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }
}

/// The cached device clock behind `ClockFormat.device`.
private final class DeviceClock: @unchecked Sendable {
    static let shared = DeviceClock()

    private let lock = NSLock()
    private var cached: ClockFormat?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.invalidate() }
    }

    func current() -> ClockFormat {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let fresh = ClockFormat.forLocale(Locale.current)
        cached = fresh
        return fresh
    }

    func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
