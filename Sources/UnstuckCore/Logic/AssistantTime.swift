// Assistant time cognisance — the local-clock helpers the executor and the
// context builder reason from. Port of the time section of
// lib/assistant/tools.ts (`localNowHM`, `freeWindowsToday`, `rejectPastTime`,
// `rejectPastDate`, and the `upcoming` map `buildAssistantContext` hands the
// model). Pure: the caller passes today's date + the wall clock.
//
// Dates are LOCAL 'YYYY-MM-DD' strings and times LOCAL 'HH:MM' — never
// ISO-8601 UTC for a date-only value (a UTC midnight reads back as the
// previous day west of Greenwich). Day arithmetic goes through
// `Calendar.current` (DST-safe), matching the web's `setDate()`.

import Foundation

// MARK: - Local-date plumbing shared by the assistant modules

/// 'YYYY-MM-DD' helpers with the web's `parseIso` / `fmtIso` / `addDaysIso` /
/// `mondayOf` semantics (tools.ts, patterns.ts, moments.ts).
public enum LocalDate {
    /// Local midnight for 'YYYY-MM-DD' — `new Date(y, m - 1, d)`, never
    /// `new Date(string)` (UTC). Unparseable input → the epoch (like the web's
    /// NaN date, which no comparison ever matches).
    public static func parse(_ iso: String) -> Date {
        let parts = iso.split(separator: "-").map { Int($0) }
        guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2] else {
            return Date(timeIntervalSince1970: 0)
        }
        return Time.civil(y, m, d)
    }

    /// Field-by-field 'YYYY-MM-DD' in the local calendar (never toISOString).
    public static func format(_ d: Date) -> String { Clock.dateISO(d) }

    /// `iso` advanced by `n` whole days (DST-safe).
    public static func addDays(_ iso: String, _ n: Int) -> String {
        format(Time.addDays(parse(iso), n))
    }

    /// Monday of the week containing `iso`.
    public static func mondayOf(_ iso: String) -> String {
        let d = parse(iso)
        return format(Time.addDays(d, -((Time.dayOfWeekJS(d) + 6) % 7)))
    }

    /// JS `getDay()` of a 'YYYY-MM-DD' date: 0=Sun … 6=Sat.
    public static func dayOfWeek(_ iso: String) -> Int { Time.dayOfWeekJS(parse(iso)) }

    /// Whole days from `fromIso` to `toIso` (local midnights; DST-rounded).
    public static func daysUntil(_ fromIso: String, _ toIso: String) -> Int {
        Time.wholeDaysBetween(parse(toIso), parse(fromIso))
    }

    /// Local calendar date of an ISO timestamp, or nil when unparseable —
    /// the web's `dateOfStamp`. A timestamp without a zone designator is
    /// parsed as LOCAL time (like JS `new Date('2026-08-23T18:00:00')`).
    public static func dateOfStamp(_ stamp: String?) -> String? {
        guard let stamp, !stamp.isEmpty, let d = LocalTime.parseTimestamp(stamp) else { return nil }
        return format(d)
    }
}

/// Timestamp parsing that mirrors JS `new Date(string)` for the two shapes
/// the app stores: a full ISO-8601 instant (with `Z` / offset) and a
/// zone-less local wall-clock stamp ('2026-08-23T18:00:00', optionally with
/// fractional seconds).
public enum LocalTime {
    private static let LOCAL_FORMATS = ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"]

    /// `Date` for an ISO instant or a zone-less local stamp; nil when neither parses.
    public static func parseTimestamp(_ s: String) -> Date? {
        if let ms = Time.parseMillis(s) { return Date(timeIntervalSince1970: ms / 1000) }
        // Date-only → local midnight (never UTC).
        if s.count == 10, s.split(separator: "-").count == 3 {
            let d = LocalDate.parse(s)
            return d.timeIntervalSince1970 == 0 ? nil : d
        }
        // Built per call (cold path) so the current zone is always honoured
        // and no formatter is shared across threads.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        for fmt in LOCAL_FORMATS {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// Epoch ms for an ISO instant or a zone-less local stamp — `new Date(s).getTime()`.
    public static func parseMillis(_ s: String) -> EpochMillis? {
        parseTimestamp(s).map { $0.timeIntervalSince1970 * 1000 }
    }
}

// MARK: - HH:MM helpers

func hmPad2(_ n: Int) -> String { String(format: "%02d", n) }

/// `hmToMin`: 'HH:MM' → minutes since midnight (a missing/invalid minute reads 0).
func hmToMin(_ hm: String) -> Int {
    let parts = hm.split(separator: ":", omittingEmptySubsequences: false)
    let h = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
    let m = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    return h * 60 + m
}

func minToHM(_ n: Int) -> String { "\(hmPad2(n / 60)):\(hmPad2(n % 60))" }

/// Local wall-clock "HH:MM" of a `Date` — the ONLY time the model should reason from.
public func localNowHM(_ d: Date = Date()) -> String {
    let c = Time.calendar.dateComponents([.hour, .minute], from: d)
    return "\(hmPad2(c.hour ?? 0)):\(hmPad2(c.minute ?? 0))"
}

/// Lower-case weekday names in JS `getDay()` order — the context's `todayWeekday` / `upcoming` keys.
public let ASSISTANT_DAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
/// Capitalised weekday names in JS `getDay()` order — used by the past-date refusal.
public let WEEKDAY_NAMES_CAP = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

private let DAY_END_MIN = 21 * 60

// MARK: - Free windows + past-time / past-date refusals

/// One open stretch of today, 'HH:MM'–'HH:MM'.
public struct FreeWindow: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Free windows for the REST of today (from the next quarter-hour after now
/// until 21:00, minus every live block), ≥20 min, max 4. Deterministic, so
/// "schedule two tasks today" at 15:07 can't be answered with 10:00.
public func freeWindowsToday(blocks: [CalBlock], today: String, nowHM: String) -> [FreeWindow] {
    let start = Int((Double(hmToMin(nowHM) + 5) / 15).rounded(.up)) * 15
    let busy = blocks
        .filter { $0.date == today && !$0.done && !$0.skipped && !$0.startTime.isEmpty }
        .map { b -> (Int, Int) in
            let s = hmToMin(b.startTime)
            return (s, s + (b.durationMinutes == 0 ? 30 : b.durationMinutes))
        }
        .sorted { $0.0 < $1.0 }
    var out: [FreeWindow] = []
    var cursor = start
    for (s, e) in busy {
        if s - cursor >= 20 { out.append(FreeWindow(from: minToHM(cursor), to: minToHM(min(s, DAY_END_MIN)))) }
        cursor = max(cursor, e)
        if cursor >= DAY_END_MIN { break }
    }
    if DAY_END_MIN - cursor >= 20 { out.append(FreeWindow(from: minToHM(cursor), to: minToHM(DAY_END_MIN))) }
    return Array(out.prefix(4))
}

/// A time TODAY that has already passed is refused, with what's actually free —
/// the model was proposing 10:00 at 15:00 (tester, 2026-09-02). nil = fine.
public func rejectPastTime(blocks: [CalBlock], today: String, date: String, startTime: String?, nowHM: String) -> String? {
    guard let startTime, !startTime.isEmpty, date == today else { return nil }
    if hmToMin(startTime) > hmToMin(nowHM) { return nil }
    let free = freeWindowsToday(blocks: blocks, today: today, nowHM: nowHM)
    let freeTxt = free.isEmpty
        ? "nothing usable is left today — offer tomorrow"
        : "free today: " + free.map { "\($0.from)–\($0.to)" }.joined(separator: ", ")
    return "error: \(startTime) today is already past (it's \(nowHM) now). Ask for a later time or another day — \(freeTxt)."
}

private let ISO_DATE_RE = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")

/// A schedule date before today is almost always the model's date math going
/// wrong ("Monday" → last Monday). Refuse with the next occurrence so it can
/// re-call correctly (2026-09-02). nil = fine.
public func rejectPastDate(today: String, date: String, weekdayNames: [String] = WEEKDAY_NAMES_CAP) -> String? {
    let range = NSRange(date.startIndex..<date.endIndex, in: date)
    if ISO_DATE_RE.firstMatch(in: date, range: range) == nil {
        return "error: date must be YYYY-MM-DD (got \"\(date)\")"
    }
    if !isCalendarDate(date) { return impossibleDateError(date) }
    if date >= today { return nil }
    let dow = LocalDate.dayOfWeek(date)
    let todayDow = LocalDate.dayOfWeek(today)
    var ahead = ((dow - todayDow) + 7) % 7
    if ahead == 0 { ahead = 7 }
    let next = LocalDate.addDays(today, ahead)
    let name = weekdayNames[dow]
    return "error: \(date) is in the PAST (today is \(today)). If the user meant the coming \(name), use \(next) — see context.upcoming. Never schedule into the past."
}

/// A 'YYYY-MM-DD' that names a real day. "2026-09-31" or "2027-02-29" pass
/// the pattern, `LocalDate.parse` quietly rolls them into the next month, and
/// the server's `date` columns refuse them — the write was quarantined on
/// this phone while the tool said "ok" (audit 2026-09-22, C28).
public func isCalendarDate(_ s: String) -> Bool {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    guard ISO_DATE_RE.firstMatch(in: s, range: range) != nil else { return false }
    return LocalDate.format(LocalDate.parse(s)) == s
}

private func impossibleDateError(_ date: String) -> String {
    let parts = date.split(separator: "-").compactMap { Int($0) }
    if parts.count == 3, (1...12).contains(parts[1]) {
        let days = Time.daysInMonth(Time.civil(parts[0], parts[1], 1))
        return "error: \(date) is not a real date — \(date.prefix(7)) has \(days) days. Use a day that exists."
    }
    return "error: \(date) is not a real date. Use a day that exists."
}

/// The model's `startTime` as the zero-padded 24-hour 'HH:MM' the server's
/// `cal_blocks_start_time_format` CHECK accepts ("9:00" → "09:00"); nil for
/// anything else ("7:30pm", "0930"). A '9:00' block was refused and
/// quarantined, and sorted after '10:00' here (date + time string order)
/// (audit 2026-09-22, C28).
public func normalizeClockTime(_ raw: String) -> String? {
    let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
          parts.allSatisfy({ $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
          let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
    return "\(hmPad2(h)):\(hmPad2(m))"
}

/// The refusal for a `startTime` that isn't a clock time; nil when absent or fine.
public func rejectBadStartTime(_ raw: String?) -> String? {
    guard let raw, normalizeClockTime(raw) == nil else { return nil }
    return "error: startTime must be 24-hour HH:MM (got \"\(raw)\")."
}

/// The model's `dueAt` as an ISO-8601 instant `tasks.due_at` (timestamptz)
/// takes. An instant with its zone travels as sent; a zone-less stamp is read
/// as LOCAL time (Postgres would read it as UTC, and the deadline moved by the
/// user's offset after the echo) and a bare date as local midnight (how this
/// phone already reads one), both written as a UTC instant. nil for anything
/// else ("Friday 5pm", "2026-09-31T10:00"), which the whole row's upsert
/// failed on — the task was quarantined while the tool said "created" (audit
/// 2026-09-22, C28).
public func normalizeDueAt(_ raw: String) -> String? {
    let s = raw.trimmingCharacters(in: .whitespaces)
    guard s.count >= 10, isCalendarDate(String(s.prefix(10))), let d = LocalTime.parseTimestamp(s) else { return nil }
    if Time.parseMillis(s) != nil { return s }   // zoned: already an instant
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}

/// The refusal for a `dueAt` that isn't a date / time; nil when absent or fine.
public func rejectBadDueAt(_ raw: String?) -> String? {
    guard let raw, normalizeDueAt(raw) == nil else { return nil }
    return "error: dueAt must be an ISO-8601 date-time like 2026-09-25T17:00 (got \"\(raw)\")."
}

// MARK: - Context dates

/// Deterministic date resolution for the model: `tomorrow`, every weekday
/// name → its NEXT date (1–7 days ahead; today's own weekday means next
/// week), and `next_week_monday`. The model must COPY these verbatim.
public func upcomingDates(today: String) -> [String: String] {
    var upcoming: [String: String] = ["tomorrow": LocalDate.addDays(today, 1)]
    let todayDow = LocalDate.dayOfWeek(today)
    for i in 1...7 {
        upcoming[ASSISTANT_DAY_NAMES[(todayDow + i) % 7]] = LocalDate.addDays(today, i)
    }
    upcoming["next_week_monday"] = LocalDate.addDays(LocalDate.mondayOf(today), 7)
    return upcoming
}

/// Lower-case weekday of `today` ('monday'), the context's `todayWeekday`.
public func weekdayName(today: String) -> String {
    ASSISTANT_DAY_NAMES[LocalDate.dayOfWeek(today)]
}

/// The context's `nowNote`: "it is 15:07 on wednesday — times earlier than this today are already gone".
public func nowNote(today: String, nowHM: String) -> String {
    "it is \(nowHM) on \(weekdayName(today: today)) — times earlier than this today are already gone"
}
