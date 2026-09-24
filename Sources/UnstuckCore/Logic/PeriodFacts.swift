// periodFacts — ONE aggregation of "what happened in a span of days", shared
// by the Insights screen (headline, daily rhythm, plan, repeating rhythm,
// wins, trend), the Today week pill and the assistant's `get_period_review`
// (PeriodReview.swift renders it as text). Port of the `collect()` core of
// period-review.ref.mjs (spec: week-review-spec.md §3), extended with the
// per-day, plan, series, wins and area facts the screen draws
// (analytics-audit/opportunities.md §3.1).
//
// Every date is a LOCAL civil 'YYYY-MM-DD' in `Time.calendar`'s zone — never
// `TimeZone.current`, which ignores `NSTimeZone.default` (spec §6) — and every
// timestamp is read with ONE strict grammar (spec §3.1), never the platform's
// lenient parser, so the three apps attribute a stamp to the same day.
//
// Sessions go through the D1 filter first (ANALYTICS-PLAN.md D1): a session
// under a minute is an accidental start and doesn't count; a longer one
// counts for at most max(3×estimate, estimate+60min), and never past 4 h, so a
// timer left running overnight can't swamp every total. Stored rows are
// untouched — this is a display rule.

import Foundation

// MARK: - D1: which focus sessions count, and for how long

/// Sessions shorter than this are accidental starts, not focus (D1).
public let COUNTED_SESSION_MIN_SEC = 60
/// No single session counts for more than this — a forgotten timer (D1).
public let SESSION_CEILING_SEC = 4 * 3600

/// The most one session can count for: max(3×estimate, estimate + 60 min),
/// capped at 4 h; 4 h when the session carries no estimate.
public func sessionCapSec(estimateMin: Int?) -> Int {
    guard let est = estimateMin, est > 0 else { return SESSION_CEILING_SEC }
    return min(max(3 * est, est + 60) * 60, SESSION_CEILING_SEC)
}

/// The seconds a session counts for, or nil when it doesn't count at all.
public func countedSec(_ s: Session) -> Int? {
    let raw = max(0, s.actualSec)
    guard raw >= COUNTED_SESSION_MIN_SEC else { return nil }
    return min(raw, sessionCapSec(estimateMin: s.estimateMin))
}

/// The sessions every focus number is computed from: the ones that count,
/// each with `actualSec` replaced by what it counts for. Used by the Insights
/// charts, the Today pill, `get_insights`, `get_period_review` and the
/// assistant's focus window, so they all agree.
public func countableSessions(_ sessions: [Session]) -> [Session] {
    sessions.compactMap { s in
        guard let sec = countedSec(s) else { return nil }
        var c = s
        c.actualSec = sec
        return c
    }
}

// MARK: - Civil dates ('YYYY-MM-DD'), zone-free day-number arithmetic

enum CivilDay {
    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return isLeap(y) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Day number (days since 1970-01-01) for a REAL date written exactly as
    /// 'YYYY-MM-DD' with a year ≥ 1900 — nil otherwise (never normalises
    /// 2026-02-30 into March, spec §3.1).
    static func parse(_ s: String) -> Int? {
        let b = Array(s.utf8)
        guard b.count == 10, b[4] == 0x2D, b[7] == 0x2D else { return nil }
        var f = [0, 0, 0]
        for (k, r) in [(0, 0..<4), (1, 5..<7), (2, 8..<10)] {
            for i in r {
                guard b[i] >= 0x30, b[i] <= 0x39 else { return nil }
                f[k] = f[k] * 10 + Int(b[i] - 0x30)
            }
        }
        let (y, m, d) = (f[0], f[1], f[2])
        guard y >= 1900, m >= 1, m <= 12, d >= 1, d <= daysInMonth(y, m) else { return nil }
        return Time.daysFromCivil(y, m, d)
    }

    /// (year, month, day) of a day number (Hinnant's `civil_from_days`).
    static func ymd(_ n: Int) -> (Int, Int, Int) {
        let z = n + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    static func format(_ n: Int) -> String {
        let (y, m, d) = ymd(n)
        return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))"
    }

    static func pad(_ v: Int, _ w: Int) -> String {
        let s = String(v)
        return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
    }

    /// Day number of an already-valid date string (the engine only ever calls
    /// this on dates it produced or validated). Unparseable → 0 (1970-01-01).
    static func num(_ s: String) -> Int { parse(s) ?? 0 }

    static func add(_ s: String, _ k: Int) -> String { format(num(s) + k) }
    /// JS `getDay()`: 0 = Sunday … 6 = Saturday (1970-01-01 was a Thursday).
    static func weekday(_ s: String) -> Int { ((num(s) % 7) + 7 + 4) % 7 }
    static func monday(_ s: String) -> String { add(s, -((weekday(s) + 6) % 7)) }
    static func firstOfMonth(_ s: String) -> String { String(s.prefix(8)) + "01" }
    static func daysInMonth(of s: String) -> Int { let (y, m, _) = ymd(num(s)); return daysInMonth(y, m) }
    static func lastOfMonth(_ s: String) -> String { String(s.prefix(8)) + pad(daysInMonth(of: s), 2) }
    static func dayOfMonth(_ s: String) -> Int { ymd(num(s)).2 }
    static func between(_ a: String, _ b: String) -> Int { num(b) - num(a) }
    /// Every date from `a` through `b` inclusive (empty when b < a).
    static func range(_ a: String, _ b: String) -> [String] {
        let lo = num(a), hi = num(b)
        return hi < lo ? [] : (lo...hi).map(format)
    }
}

// MARK: - Timestamps: one strict grammar (spec §3.1)

/// A parsed timestamp: its instant plus its LOCAL day and minute-of-day.
public struct PeriodStamp: Equatable, Sendable {
    public let ms: Int64
    public let day: String
    public let minute: Int
}

public enum PeriodTime {
    /// Epoch ms for `YYYY-MM-DD'T'HH:MM[:SS[.1-9 digits]][Z|±HH|±HHMM|±HH:MM]`,
    /// every field in range with no roll-over (year ≥ 1900). With a zone it is
    /// that instant; without one it is LOCAL wall-clock time in
    /// `Time.calendar` (a DST gap moves forward, an overlap takes the earlier
    /// offset — like JS `new Date(y, m, d, h, mi)`). Anything else — a bare
    /// date, a space for the 'T', lower-case 't'/'z', junk — is nil.
    public static func ms(_ stamp: String?) -> Int64? {
        guard let stamp else { return nil }
        let b = Array(stamp.utf8)
        let n = b.count
        func digit(_ i: Int) -> Int? { i < n && b[i] >= 0x30 && b[i] <= 0x39 ? Int(b[i] - 0x30) : nil }
        func number(_ i: Int, _ len: Int) -> Int? {
            var v = 0
            for k in 0..<len { guard let d = digit(i + k) else { return nil }; v = v * 10 + d }
            return v
        }
        guard n >= 16, let y = number(0, 4), b[4] == 0x2D, let mo = number(5, 2), b[7] == 0x2D,
              let d = number(8, 2), b[10] == 0x54 /* T */, let h = number(11, 2), b[13] == 0x3A,
              let mi = number(14, 2) else { return nil }
        var i = 16
        var sec = 0
        var millis = 0
        if i < n, b[i] == 0x3A {
            guard let s = number(i + 1, 2) else { return nil }
            sec = s
            i += 3
            if i < n, b[i] == 0x2E {
                i += 1
                var digits = 0
                var place = 100
                while let dd = digit(i) {
                    if digits < 3 { millis += dd * place; place /= 10 }   // truncate to ms
                    digits += 1
                    i += 1
                }
                guard digits >= 1, digits <= 9 else { return nil }
            }
        }
        var offsetMin: Int? = nil                 // nil = no zone → local wall clock
        if i < n {
            if b[i] == 0x5A /* Z */ {
                guard i + 1 == n else { return nil }
                offsetMin = 0
            } else if b[i] == 0x2B || b[i] == 0x2D {
                let sign = b[i] == 0x2B ? 1 : -1
                let rest = n - i - 1
                var oh = 0, om = 0
                if rest == 2, let a = number(i + 1, 2) {
                    oh = a
                } else if rest == 4, let a = number(i + 1, 2), let c = number(i + 3, 2) {
                    oh = a; om = c
                } else if rest == 5, let a = number(i + 1, 2), b[i + 3] == 0x3A, let c = number(i + 4, 2) {
                    oh = a; om = c
                } else {
                    return nil
                }
                guard oh <= 23, om <= 59 else { return nil }
                offsetMin = sign * (oh * 60 + om)
            } else {
                return nil
            }
        }
        guard y >= 1900, mo >= 1, mo <= 12, d >= 1, d <= CivilDay.daysInMonth(y, mo),
              h <= 23, mi <= 59, sec <= 59 else { return nil }
        if let off = offsetMin {
            let secs = Int64(Time.daysFromCivil(y, mo, d)) * 86_400 + Int64(h * 3600 + mi * 60 + sec) - Int64(off * 60)
            return secs * 1000 + Int64(millis)
        }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = sec
        guard let date = Time.calendar.date(from: c) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded()) + Int64(millis)
    }

    /// The instant plus its local day + minute, or nil when unparseable.
    public static func parse(_ stamp: String?) -> PeriodStamp? {
        guard let t = ms(stamp) else { return nil }
        return at(t)
    }

    /// Local day + minute-of-day of an instant, in `Time.calendar`'s zone.
    public static func at(_ t: Int64) -> PeriodStamp {
        let date = Date(timeIntervalSince1970: Double(t) / 1000)
        let c = Time.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = Time.daysFromCivil(c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        return PeriodStamp(ms: t, day: CivilDay.format(day), minute: (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// Local 'YYYY-MM-DD' of a stamp (nil when absent / unparseable).
    public static func dayOf(_ stamp: String?) -> String? { parse(stamp)?.day }
}

// MARK: - Text helpers shared with the review (spec §4.1, §3.7)

/// `\t \n \v \f \r SPACE U+00A0` — the spec's whitespace set (never the
/// platform's `trim()`, whose sets differ).
func isReviewSpace(_ u: Unicode.Scalar) -> Bool {
    switch u.value {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0: return true
    default: return false
    }
}

/// Runs of the whitespace set → one space; one leading and one trailing
/// space dropped; empty → "(untitled)"; over 40 code points → 39 + "…".
public func reviewCleanName(_ s: String?) -> String {
    var out = String.UnicodeScalarView()
    var inRun = false
    for u in (s ?? "").unicodeScalars {
        if isReviewSpace(u) {
            if !inRun { out.append(" ") }
            inRun = true
        } else {
            out.append(u)
            inRun = false
        }
    }
    var scalars = Array(out)
    if scalars.first == " " { scalars.removeFirst() }
    if scalars.last == " " { scalars.removeLast() }
    if scalars.isEmpty { return "(untitled)" }
    if scalars.count > 40 { scalars = Array(scalars.prefix(39)) + ["…"] }
    var v = String.UnicodeScalarView()
    v.append(contentsOf: scalars)
    return String(v)
}

/// True when the string holds anything but the whitespace set.
func hasReviewText(_ s: String?) -> Bool {
    guard let s else { return false }
    return s.unicodeScalars.contains { !isReviewSpace($0) }
}

/// UTF-16 code-unit order (JS `<`), never locale collation.
func utf16Less(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

// MARK: - The data a period is computed from (stamps parsed once)

/// The user's own rows, with every timestamp parsed once so a trend (eight
/// windows) doesn't re-parse. `sessions` are already D1-filtered.
public struct PeriodData: Sendable {
    public let tasks: [TaskItem]
    public let blocks: [CalBlock]
    public let sessions: [Session]
    public let captures: [Capture]
    public let reasons: [ReasonLog]
    let byId: [String: TaskItem]
    let taskDone: [PeriodStamp?]
    let taskCreated: [PeriodStamp?]
    let blockDone: [PeriodStamp?]
    let sessionEnd: [PeriodStamp?]
    let captureAt: [PeriodStamp?]
    let reasonAt: [PeriodStamp?]

    public init(tasks: [TaskItem], blocks: [CalBlock], sessions: [Session], captures: [Capture] = [], reasons: [ReasonLog] = []) {
        self.tasks = tasks
        self.blocks = blocks
        let counted = countableSessions(sessions)
        self.sessions = counted
        self.captures = captures
        self.reasons = reasons
        // JS `new Map(tasks.map(...))`: a duplicate id keeps the LAST row.
        self.byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        self.taskDone = tasks.map { PeriodTime.parse($0.completedAt) }
        self.taskCreated = tasks.map { PeriodTime.parse($0.createdAt) }
        self.blockDone = blocks.map { PeriodTime.parse($0.completedAt) }
        self.sessionEnd = counted.map { PeriodTime.parse($0.completedAt) }
        self.captureAt = captures.map { PeriodTime.parse($0.at) }
        self.reasonAt = reasons.map { PeriodTime.parse($0.at) }
    }

    func task(_ id: String?) -> TaskItem? { id.flatMap { byId[$0] } }

    /// The template an occurrence block belongs to, when `b` is one.
    func template(of b: CalBlock) -> TaskItem? {
        guard isTaskBlock(b), let t = task(b.taskId), t.recurrence != nil else { return nil }
        return t
    }

    /// The earliest local day with any recorded activity — a task created, a
    /// task done (its completion; a reopened task's old stamp doesn't count),
    /// a counted session ended — where "All time" starts and stepping back
    /// through past periods stops. Web's rule (lib/period-facts.ts
    /// `firstActivityDay`), the same on all three apps.
    public var earliestDay: String? {
        let done = tasks.indices.map { tasks[$0].done ? taskDone[$0] : nil }
        let days = (taskCreated + done + sessionEnd).compactMap { $0?.day }
        return days.min(by: utf16Less)
    }
}

// MARK: - One window's facts

/// `[from, to]` inclusive local dates; `cut` = the minute-of-day on `to` past
/// which a stamp doesn't count (set while the period includes today, so a
/// comparison stops at the same time of day).
public struct PeriodWindow: Equatable, Sendable {
    public let from: String
    public let to: String
    public let cut: Int?

    public init(from: String, to: String, cut: Int? = nil) {
        self.from = from
        self.to = to
        self.cut = cut
    }

    public func contains(_ s: PeriodStamp?) -> Bool {
        guard let s, !utf16Less(s.day, from), !utf16Less(to, s.day) else { return false }
        return cut == nil || s.day != to || s.minute <= cut!
    }

    public var days: Int { CivilDay.between(from, to) + 1 }
}

public struct DoneTask: Sendable {
    public let task: TaskItem
    public let at: PeriodStamp
}

public struct DoneOccurrence: Sendable {
    public let block: CalBlock
    public let template: TaskItem
    /// The day it counts on: its completion's local day, else the block date.
    public let day: String
}

public struct CountedSession: Sendable {
    public let session: Session
    public let end: PeriodStamp
    public var sec: Int { session.actualSec }
}

public struct PeriodFacts: Sendable {
    public let window: PeriodWindow
    /// Plain (non-repeating) tasks completed in the window.
    public let plainDone: [DoneTask]
    /// Repeating occurrences checked off in the window.
    public let occDone: [DoneOccurrence]
    /// Counted focus sessions that ended in the window (D1-filtered).
    public let sessions: [CountedSession]
    public let focusSec: Int
    public let captures: [Capture]
    public let pauses: [ReasonLog]
    /// Tasks (templates included) created in the window.
    public let created: [TaskItem]

    public var doneCount: Int { plainDone.count + occDone.count }
    public var focusMin: Int { roundedMinutes(focusSec) }
}

/// The review's minutes: floor((sec + 30) / 60) — every focus number on the
/// Insights page, the pill and the assistant rounds the same way.
public func roundedMinutes(_ sec: Int) -> Int { (max(0, sec) + 30) / 60 }

/// `45m` / `2h` / `1h 5m` — the review's `dur`, used on screen too.
public func fmtFocusDur(_ m: Int) -> String {
    if m < 60 { return "\(m)m" }
    return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
}

public func periodFacts(_ data: PeriodData, _ win: PeriodWindow) -> PeriodFacts {
    var plainDone: [DoneTask] = []
    for (i, t) in data.tasks.enumerated() where t.recurrence == nil && t.done {
        if let at = data.taskDone[i], win.contains(at) { plainDone.append(DoneTask(task: t, at: at)) }
    }
    var occDone: [DoneOccurrence] = []
    for (i, b) in data.blocks.enumerated() where b.done && !b.skipped {
        guard let tpl = data.template(of: b) else { continue }
        if let at = data.blockDone[i] {
            if win.contains(at) { occDone.append(DoneOccurrence(block: b, template: tpl, day: at.day)) }
        } else if !utf16Less(b.date, win.from), !utf16Less(win.to, b.date) {
            occDone.append(DoneOccurrence(block: b, template: tpl, day: b.date))
        }
    }
    var sessions: [CountedSession] = []
    for (i, s) in data.sessions.enumerated() {
        if let end = data.sessionEnd[i], win.contains(end) { sessions.append(CountedSession(session: s, end: end)) }
    }
    let captures = data.captures.indices.filter { win.contains(data.captureAt[$0]) }.map { data.captures[$0] }
    let pauses = data.reasons.indices.filter { win.contains(data.reasonAt[$0]) }.map { data.reasons[$0] }
    let created = data.tasks.indices.filter { win.contains(data.taskCreated[$0]) }.map { data.tasks[$0] }
    return PeriodFacts(window: win, plainDone: plainDone, occDone: occDone, sessions: sessions,
                       focusSec: sessions.reduce(0) { $0 + $1.sec },
                       captures: captures, pauses: pauses, created: created)
}

// MARK: - Per day

public struct DayFacts: Equatable, Sendable {
    public let date: String
    public var done: Int
    public var focusSec: Int
    public var sessions: Int
    public var active: Bool { done > 0 || sessions > 0 }
}

/// One entry per date in `[from, to]` (the nominal span, so future days of a
/// "so far" week are there, empty): done by completion day (an occurrence by
/// its completion's day, else its block date), focus + sessions by the day a
/// session ended.
public func dailyFacts(_ f: PeriodFacts, from: String, to: String) -> [DayFacts] {
    var byDay: [String: DayFacts] = [:]
    func bump(_ d: String, _ body: (inout DayFacts) -> Void) {
        var e = byDay[d] ?? DayFacts(date: d, done: 0, focusSec: 0, sessions: 0)
        body(&e)
        byDay[d] = e
    }
    for t in f.plainDone { bump(t.at.day) { $0.done += 1 } }
    for o in f.occDone { bump(o.day) { $0.done += 1 } }
    for s in f.sessions { bump(s.end.day) { $0.focusSec += s.sec; $0.sessions += 1 } }
    return CivilDay.range(from, to).map { byDay[$0] ?? DayFacts(date: $0, done: 0, focusSec: 0, sessions: 0) }
}

/// Days in the window with at least one thing done or one counted session —
/// "Showed up N of M days" (never a streak).
public func showedUpDays(_ f: PeriodFacts) -> Int {
    var days = Set<String>()
    for t in f.plainDone { days.insert(t.at.day) }
    for o in f.occDone { days.insert(o.day) }
    for s in f.sessions { days.insert(s.end.day) }
    return days.count
}

/// The review's busiest day: most done, then most focus, then earliest date.
public func busiestDay(_ f: PeriodFacts) -> DayFacts? {
    dailyFacts(f, from: f.window.from, to: f.window.to).filter(\.active).sorted {
        if $0.done != $1.done { return $0.done > $1.done }
        if $0.focusSec != $1.focusSec { return $0.focusSec > $1.focusSec }
        return utf16Less($0.date, $1.date)
    }.first
}

// MARK: - Plan vs followed through (spec §3.4, current window only)

public struct SlippedTask: Sendable {
    public let task: TaskItem
    /// The latest block date it was planned on inside the judged days.
    public let planDate: String
    public var doneLater: Bool { task.done }
}

public struct SeriesCount: Equatable, Sendable {
    public let id: String
    public let name: String
    public var n: Int
}

public struct PlanFacts: Sendable {
    public let plannedPlain: Int
    public let plainDoneToPlan: Int
    public let occPlanned: Int
    public let occDoneToPlan: Int
    /// Repeating days skipped on purpose in [from, end] (today included).
    public let skipped: Int
    /// Planned plain tasks not done by the end of the period (sorted).
    public let slipped: [SlippedTask]
    /// Repeating days planned on a judged day and not ticked, per series.
    public let missed: [SeriesCount]
    /// Deadlines that passed in the period without an on-time completion.
    public let deadlines: [TaskItem]

    public var planned: Int { plannedPlain + occPlanned }
    public var doneToPlan: Int { plainDoneToPlan + occDoneToPlan }
    public var missedTotal: Int { missed.reduce(0) { $0 + $1.n } }
    public var doneLater: Int { slipped.filter(\.doneLater).count }
    /// Planned items still not done: slipped tasks still open + repeating days
    /// not ticked. The screen calls these "still open", never "missed".
    public var stillOpen: Int { slipped.filter { !$0.doneLater }.count + missedTotal }
    /// Whether the review writes a Plan line with content.
    public var recorded: Bool { planned > 0 || !slipped.isEmpty || !missed.isEmpty || skipped > 0 || !deadlines.isEmpty }
}

/// nil when there is no judged day yet (today alone, or a Monday for this
/// week): today is never judged because it isn't over.
public func planFacts(_ data: PeriodData, from: String, end: String, clipped: Bool, nowMs: Int64) -> PlanFacts? {
    let judgeTo = clipped ? CivilDay.add(end, -1) : end
    guard !utf16Less(judgeTo, from) else { return nil }
    var plannedPlain: [String: String] = [:]       // plain task id → latest block date in the judged days
    var occPlanned = 0, occDoneN = 0, skipped = 0
    var missed: [String: SeriesCount] = [:]
    for b in data.blocks {
        guard isTaskBlock(b), let t = data.task(b.taskId) else { continue }   // orphan → ignored
        if t.recurrence != nil {
            if utf16Less(b.date, from) || utf16Less(end, b.date) { continue }
            if b.skipped { skipped += 1; continue }
            if utf16Less(judgeTo, b.date) { continue }
            occPlanned += 1
            if b.done { occDoneN += 1 } else {
                var g = missed[t.id] ?? SeriesCount(id: t.id, name: reviewCleanName(t.name), n: 0)
                g.n += 1
                missed[t.id] = g
            }
        } else if !utf16Less(b.date, from), !utf16Less(judgeTo, b.date) {
            if let was = plannedPlain[t.id], !utf16Less(was, b.date) { continue }
            plannedPlain[t.id] = b.date
        }
    }
    var plainDoneN = 0
    var slipped: [SlippedTask] = []
    for (id, date) in plannedPlain {
        guard let t = data.task(id) else { continue }
        let doneDay = PeriodTime.parse(t.completedAt)?.day
        if t.done && (doneDay == nil || !utf16Less(end, doneDay!)) { plainDoneN += 1 } else { slipped.append(SlippedTask(task: t, planDate: date)) }
    }
    slipped.sort {
        if $0.planDate != $1.planDate { return utf16Less($0.planDate, $1.planDate) }
        let a = reviewCleanName($0.task.name), b = reviewCleanName($1.task.name)
        if a != b { return utf16Less(a, b) }
        return utf16Less($0.task.id, $1.task.id)
    }
    var deadlines: [(TaskItem, Int64)] = []
    for t in data.tasks where t.recurrence == nil {
        guard let due = PeriodTime.parse(t.dueAt), due.ms < nowMs else { continue }
        if utf16Less(due.day, from) || utf16Less(end, due.day) { continue }
        let doneAt = t.done ? PeriodTime.ms(t.completedAt) : nil
        if let doneAt, doneAt <= due.ms { continue }
        deadlines.append((t, due.ms))
    }
    deadlines.sort { $0.1 != $1.1 ? $0.1 < $1.1 : utf16Less($0.0.id, $1.0.id) }
    let missedSorted = missed.values.sorted {
        if $0.n != $1.n { return $0.n > $1.n }
        if $0.name != $1.name { return utf16Less($0.name, $1.name) }
        return utf16Less($0.id, $1.id)
    }
    return PlanFacts(plannedPlain: plannedPlain.count, plainDoneToPlan: plainDoneN, occPlanned: occPlanned,
                     occDoneToPlan: occDoneN, skipped: skipped, slipped: slipped, missed: missedSorted,
                     deadlines: deadlines.map(\.0))
}

/// Planned items dated `day` (today) not done yet: open occurrences plus
/// distinct plain tasks with a block that day.
public func stillOpenOn(_ data: PeriodData, day: String) -> Int {
    var n = 0
    var openPlain = Set<String>()
    for b in data.blocks where b.date == day && isTaskBlock(b) {
        guard let t = data.task(b.taskId) else { continue }
        if t.recurrence != nil {
            if !b.done && !b.skipped { n += 1 }
        } else if !t.done {
            openPlain.insert(t.id)
        }
    }
    return n + openPlain.count
}

// MARK: - Repeating rhythm (one dot per occurrence; no streaks)

public enum SeriesDotState: String, Sendable {
    /// Ticked off.
    case done
    /// Skipped on purpose (a decision, not a miss).
    case skipped
    /// A past day not ticked — "open", never "missed" on screen.
    case open
    /// Today or later, not ticked yet.
    case upcoming
}

public struct SeriesDot: Equatable, Sendable {
    public let date: String
    public let state: SeriesDotState
}

public struct SeriesRhythm: Equatable, Sendable {
    public let taskId: String
    public let name: String
    public let lifeArea: String?
    public let dots: [SeriesDot]
    public var kept: Int { dots.filter { $0.state == .done }.count }
    public var skipped: Int { dots.filter { $0.state == .skipped }.count }
    /// Done + open: the days that were due so far and not skipped on purpose.
    public var dueSoFar: Int { dots.filter { $0.state == .done || $0.state == .open }.count }
}

/// Every repeating series with at least one occurrence dated in `[from, to]`,
/// dots by block date. Sorted by kept (desc), then due so far (desc), then
/// name, then id — web's order (lib/period-facts.ts), the same on all three.
public func seriesRhythm(_ data: PeriodData, from: String, to: String, today: String) -> [SeriesRhythm] {
    var dots: [String: [SeriesDot]] = [:]
    var order: [String] = []
    for b in data.blocks {
        guard let tpl = data.template(of: b), !utf16Less(b.date, from), !utf16Less(to, b.date) else { continue }
        let state: SeriesDotState = (b.done && !b.skipped) ? .done
            : b.skipped ? .skipped
            : utf16Less(b.date, today) ? .open : .upcoming
        if dots[tpl.id] == nil { order.append(tpl.id) }
        dots[tpl.id, default: []].append(SeriesDot(date: b.date, state: state))
    }
    return order.compactMap { id -> SeriesRhythm? in
        guard let t = data.task(id), let ds = dots[id] else { return nil }
        let area = hasReviewText(t.lifeArea) ? reviewCleanName(t.lifeArea) : nil
        return SeriesRhythm(taskId: id, name: reviewCleanName(t.name), lifeArea: area,
                            dots: ds.sorted { utf16Less($0.date, $1.date) })
    }.sorted {
        if $0.kept != $1.kept { return $0.kept > $1.kept }
        if $0.dueSoFar != $1.dueSoFar { return $0.dueSoFar > $1.dueSoFar }
        if $0.name != $1.name { return utf16Less($0.name, $1.name) }
        return utf16Less($0.taskId, $1.taskId)
    }
}

// MARK: - Got unstuck (quiet wins)

public struct UnstuckWin: Equatable, Sendable {
    public let taskId: String
    public let name: String
    /// Whole days (24 h) from when it was added to when it was done.
    public let waitedDays: Int
    public let moves: Int
}

public let WIN_WAITED_DAYS = 7
public let WIN_MOVES = 2
private let MS_PER_DAY: Int64 = 86_400_000

/// Plain tasks finished in the window that had waited a week or more, or had
/// been moved twice or more. Longest wait first.
public func gotUnstuck(_ f: PeriodFacts) -> [UnstuckWin] {
    f.plainDone.compactMap { d -> UnstuckWin? in
        // Elapsed time, floor((completedAt − createdAt) / 24 h) — the same
        // count web (unstuckWins) and Android (unstuckWins) use, so a task
        // is a win on all three or on none.
        let created = PeriodTime.ms(d.task.createdAt)
        let waited = created.map { d.at.ms > $0 ? Int((d.at.ms - $0) / MS_PER_DAY) : 0 } ?? 0
        let moves = max(0, d.task.moveCount ?? 0)
        guard waited >= WIN_WAITED_DAYS || moves >= WIN_MOVES else { return nil }
        return UnstuckWin(taskId: d.task.id, name: reviewCleanName(d.task.name), waitedDays: waited, moves: moves)
    }.sorted {
        if $0.waitedDays != $1.waitedDays { return $0.waitedDays > $1.waitedDays }
        if $0.moves != $1.moves { return $0.moves > $1.moves }
        if $0.name != $1.name { return utf16Less($0.name, $1.name) }
        return utf16Less($0.taskId, $1.taskId)
    }
}

// MARK: - By area

public struct AreaCount: Equatable, Sendable {
    /// nil = "No area".
    public let area: String?
    public let count: Int
}

/// Done in the window per life area (an occurrence counts under its
/// template's area); named areas by count desc then name, "No area" last.
/// The named counts are the review's "By area" numbers.
public func doneByArea(_ f: PeriodFacts) -> [AreaCount] {
    var named: [String: Int] = [:]
    var none = 0
    func add(_ t: TaskItem) {
        if hasReviewText(t.lifeArea) { named[reviewCleanName(t.lifeArea), default: 0] += 1 } else { none += 1 }
    }
    for d in f.plainDone { add(d.task) }
    for o in f.occDone { add(o.template) }
    var out = named.map { AreaCount(area: $0.key, count: $0.value) }.sorted {
        $0.count != $1.count ? $0.count > $1.count : utf16Less($0.area ?? "", $1.area ?? "")
    }
    if none > 0 { out.append(AreaCount(area: nil, count: none)) }
    return out
}

// MARK: - Insights periods (Week / Month / All + a ‹ › stepper)

public enum InsightsPeriodKind: String, Sendable, CaseIterable {
    case week, month, all
}

/// A resolved Insights period: the span shown, the span it is compared with
/// (the review's previous-equivalent rule, cut at the same minute while the
/// period includes today), and its labels.
public struct InsightsPeriod: Equatable, Sendable {
    public let kind: InsightsPeriodKind
    /// 0 = the current week/month; 1 = the one before; …
    public let offset: Int
    public let from: String
    /// Nominal last day (a week's Sunday, a month's last day).
    public let to: String
    /// Last day reviewed: `to`, or today while the period includes today.
    public let end: String
    public let clipped: Bool
    public let cut: Int?
    public let prev: PeriodWindow?
    /// "This week" / "Last week" / "7–13 Sep" / "This month" / "August" / "All time".
    public let title: String
    /// "Mon 21 – Sun 27 Sep" style span (", so far" while clipped).
    public let subtitle: String
    /// "vs same point last week" / "vs last week" / "vs 31 Aug – 6 Sep" / "vs July" / nil for All.
    public let compareLabel: String?

    public var window: PeriodWindow { PeriodWindow(from: from, to: end, cut: cut) }
    public var days: Int { CivilDay.between(from, end) + 1 }
    /// Can step to a more recent period.
    public var canStepForward: Bool { kind != .all && offset > 0 }
}

private let SHORT_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
private let LONG_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
private let SHORT_DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

/// "7–13 Sep", "28 Sep – 4 Oct", "29 Dec 2025 – 4 Jan" (year only when it isn't `year`).
func shortSpan(_ a: String, _ b: String, year: Int) -> String {
    let (ya, ma, da) = CivilDay.ymd(CivilDay.num(a))
    let (yb, mb, db) = CivilDay.ymd(CivilDay.num(b))
    let yA = ya != year ? " \(ya)" : "", yB = yb != year ? " \(yb)" : ""
    if a == b { return "\(da) \(SHORT_MONTHS[ma - 1])\(yA)" }
    if ya == yb && ma == mb { return "\(da)–\(db) \(SHORT_MONTHS[mb - 1])\(yB)" }
    return "\(da) \(SHORT_MONTHS[ma - 1])\(ya != yb ? yA : "") – \(db) \(SHORT_MONTHS[mb - 1])\(yB)"
}

/// "Mon 21 Sep" (+ year when not `year`).
func dayLabel(_ s: String, year: Int) -> String {
    let (y, m, d) = CivilDay.ymd(CivilDay.num(s))
    return "\(SHORT_DAYS[CivilDay.weekday(s)]) \(d) \(SHORT_MONTHS[m - 1])\(y != year ? " \(y)" : "")"
}

func monthName(_ s: String, year: Int) -> String {
    let (y, m, _) = CivilDay.ymd(CivilDay.num(s))
    return LONG_MONTHS[m - 1] + (y != year ? " \(y)" : "")
}

/// Resolve Week/Month (stepped back `offset` periods) or All for `now`.
/// `earliest` = the first day with any activity (All starts there).
public func resolveInsightsPeriod(_ kind: InsightsPeriodKind, offset: Int, now: Date, earliest: String?) -> InsightsPeriod {
    let nowStamp = PeriodTime.at(Int64((now.timeIntervalSince1970 * 1000).rounded(.down)))
    let today = nowStamp.day
    let year = CivilDay.ymd(CivilDay.num(today)).0
    let k = max(0, offset)
    switch kind {
    case .all:
        var from = earliest ?? today
        if utf16Less(today, from) { from = today }
        return InsightsPeriod(kind: .all, offset: 0, from: from, to: today, end: today, clipped: true,
                              cut: nowStamp.minute, prev: nil, title: "All time",
                              subtitle: "since \(shortSpan(from, from, year: year))", compareLabel: nil)
    case .week:
        let from = CivilDay.add(CivilDay.monday(today), -7 * k)
        let to = CivilDay.add(from, 6)
        let clipped = !utf16Less(to, today)
        let end = clipped ? today : to
        let cut = clipped ? nowStamp.minute : nil
        let prev = PeriodWindow(from: CivilDay.add(from, -7), to: CivilDay.add(end, -7), cut: cut)
        let title = k == 0 ? "This week" : k == 1 ? "Last week" : shortSpan(from, to, year: year)
        let sub = clipped ? "\(shortSpan(from, end, year: year)), so far" : shortSpan(from, to, year: year)
        let cmp = clipped ? "vs same point last week"
            : k == 1 ? "vs the week before" : "vs \(shortSpan(prev.from, prev.to, year: year))"
        return InsightsPeriod(kind: .week, offset: k, from: from, to: to, end: end, clipped: clipped, cut: cut,
                              prev: prev, title: title, subtitle: sub, compareLabel: cmp)
    case .month:
        var from = CivilDay.firstOfMonth(today)
        for _ in 0..<k { from = CivilDay.firstOfMonth(CivilDay.add(from, -1)) }
        let to = CivilDay.lastOfMonth(from)
        let clipped = !utf16Less(to, today)
        let end = clipped ? today : to
        let cut = clipped ? nowStamp.minute : nil
        let prevFrom = CivilDay.firstOfMonth(CivilDay.add(from, -1))
        let prevTo = clipped
            ? String(prevFrom.prefix(8)) + CivilDay.pad(min(CivilDay.dayOfMonth(end), CivilDay.daysInMonth(of: prevFrom)), 2)
            : CivilDay.lastOfMonth(prevFrom)
        let prev = PeriodWindow(from: prevFrom, to: prevTo, cut: cut)
        let title = k == 0 ? "This month" : monthName(from, year: year)
        let sub = clipped ? "\(shortSpan(from, end, year: year)), so far" : shortSpan(from, to, year: year)
        let cmp = clipped ? "vs same point in \(monthName(prevFrom, year: year))" : "vs \(monthName(prevFrom, year: year))"
        return InsightsPeriod(kind: .month, offset: k, from: from, to: to, end: end, clipped: clipped, cut: cut,
                              prev: prev, title: title, subtitle: sub, compareLabel: cmp)
    }
}

/// Whole local days from `a` to `b` ('YYYY-MM-DD'; 0 when either isn't a real date).
public func civilDaysBetween(_ a: String, _ b: String) -> Int {
    guard let x = CivilDay.parse(a), let y = CivilDay.parse(b) else { return 0 }
    return y - x
}

/// "Today" / "Yesterday" / "Wed 16 Sep" (+ year when not this year) for a
/// stamp's local day; nil when unparseable. For session lists.
public func sessionDayLabel(_ stamp: String?, now: Date) -> String? {
    guard let day = PeriodTime.dayOf(stamp) else { return nil }
    let today = PeriodTime.at(Int64((now.timeIntervalSince1970 * 1000).rounded(.down))).day
    if day == today { return "Today" }
    if day == CivilDay.add(today, -1) { return "Yesterday" }
    return dayLabel(day, year: CivilDay.ymd(CivilDay.num(today)).0)
}

/// Whether stepping further back would still land on or after `earliest`
/// (the first activity); true when nothing bounds it yet.
public func canStepBack(_ p: InsightsPeriod, earliest: String?) -> Bool {
    guard p.kind != .all, let earliest else { return false }
    return utf16Less(earliest, p.from)
}

// MARK: - Neutral change figures ("+2", "same", "−40m")

/// "+2" / "same" / "−1" — ink only, never red/green (D4).
public func neutralDelta(_ d: Int) -> String { d == 0 ? "same" : d > 0 ? "+\(d)" : "−\(-d)" }
/// "+1h 5m" / "same" / "−40m" over minute differences.
public func neutralDurDelta(_ d: Int) -> String {
    d == 0 ? "same" : d > 0 ? "+\(fmtFocusDur(d))" : "−\(fmtFocusDur(-d))"
}

// MARK: - Headline (Done · Focused · Showed up) + trend

public struct PeriodHeadline: Equatable, Sendable {
    public let done: Int
    public let plainDone: Int
    public let repeatingDone: Int
    public let added: Int
    public let focusMin: Int
    public let sessions: Int
    public let showedUp: Int
    public let days: Int
    /// nil for All time (nothing to compare with).
    public let prevDone: Int?
    public let prevFocusMin: Int?
    public let prevShowedUp: Int?
}

public func periodHeadline(_ data: PeriodData, _ p: InsightsPeriod) -> PeriodHeadline {
    let cur = periodFacts(data, p.window)
    let prev = p.prev.map { periodFacts(data, $0) }
    return PeriodHeadline(done: cur.doneCount, plainDone: cur.plainDone.count, repeatingDone: cur.occDone.count,
                          added: cur.created.count, focusMin: cur.focusMin, sessions: cur.sessions.count,
                          showedUp: showedUpDays(cur), days: p.days,
                          prevDone: prev?.doneCount, prevFocusMin: prev?.focusMin, prevShowedUp: prev.map(showedUpDays))
}

public struct TrendPoint: Equatable, Sendable {
    public let from: String
    public let label: String
    public let done: Int
    public let focusMin: Int
    /// The period currently selected on screen (highlighted).
    public let selected: Bool
    /// Still in progress ("so far").
    public let partial: Bool
}

/// The last `count` weeks (Week, and All with weekly buckets) or months,
/// oldest first, ending with the current one. The selected period's bar is
/// flagged. Each bucket is a plain calendar week/month up to now.
public func periodTrend(_ data: PeriodData, kind: InsightsPeriodKind, selectedFrom: String?, now: Date, count: Int) -> [TrendPoint] {
    let nowStamp = PeriodTime.at(Int64((now.timeIntervalSince1970 * 1000).rounded(.down)))
    let today = nowStamp.day
    let year = CivilDay.ymd(CivilDay.num(today)).0
    var out: [TrendPoint] = []
    for k in stride(from: count - 1, through: 0, by: -1) {
        let from: String, to: String, label: String
        if kind == .month {
            var f = CivilDay.firstOfMonth(today)
            for _ in 0..<k { f = CivilDay.firstOfMonth(CivilDay.add(f, -1)) }
            from = f; to = CivilDay.lastOfMonth(f)
            label = String(monthName(f, year: year).prefix(3))
        } else {
            from = CivilDay.add(CivilDay.monday(today), -7 * k); to = CivilDay.add(from, 6)
            let (_, m, d) = CivilDay.ymd(CivilDay.num(from))
            label = "\(d) \(SHORT_MONTHS[m - 1])"
        }
        let partial = !utf16Less(to, today)
        let f = periodFacts(data, PeriodWindow(from: from, to: partial ? today : to))
        out.append(TrendPoint(from: from, label: label, done: f.doneCount, focusMin: f.focusMin,
                              selected: from == selectedFrom, partial: partial))
    }
    return out
}

/// Focus minutes this calendar week (Monday 00:00 → now), counted exactly as
/// the Insights page counts them — the Today pill (D3).
public func weekFocusMin(sessions: [Session], now: Date) -> (thisWeek: Int, lastWeek: Int) {
    let data = PeriodData(tasks: [], blocks: [], sessions: sessions)
    let p = resolveInsightsPeriod(.week, offset: 0, now: now, earliest: nil)
    let last = resolveInsightsPeriod(.week, offset: 1, now: now, earliest: nil)
    return (periodFacts(data, p.window).focusMin, periodFacts(data, last.window).focusMin)
}
