// Recurrence — materialise + regenerate cal_blocks for repeating tasks.
// Pure functions, no I/O. Port of lib/recurrence.ts. Callers pipe the
// returned diff through the sync layer.
//
// Model: a task has at most one `recurrence`. When set, the client
// materialises cal_blocks for RECURRENCE_HORIZON_DAYS into the future at
// the same start time. Past occurrences are preserved; future ones are
// regenerated on edit.

import Foundation

/// How far ahead we materialise occurrences on create/edit (8 weeks).
public let RECURRENCE_HORIZON_DAYS = 56

public struct MaterializedOccurrence: Equatable, Sendable {
    public let date: String        // YYYY-MM-DD
    public let startTime: String   // HH:MM
    public init(date: String, startTime: String) {
        self.date = date
        self.startTime = startTime
    }
}

public extension Recurrence {
    /// The inclusive `until` bound (YYYY-MM-DD), regardless of kind.
    var untilDate: String? {
        switch self {
        case .daily(let u), .monthly(let u): return u
        case .weekly(_, let u): return u
        case .everyNWeeks(_, _, _, let u): return u
        }
    }

    /// Weeks between on-weeks for a rule the weekly pickers show: 1 for
    /// weekly, N for every N weeks, nil for any other kind.
    var intervalWeeks: Int? {
        switch self {
        case .weekly: return 1
        case .everyNWeeks(let n, _, _, _): return n
        default: return nil
        }
    }

    /// The day list of a weekly or every-N-weeks rule, as stored (nil for any
    /// other kind).
    var weekDays: [Int]? {
        switch self {
        case .weekly(let d, _), .everyNWeeks(_, let d, _, _): return d
        default: return nil
        }
    }

    /// The same rule with `until` replaced (nil clears it).
    func withUntil(_ until: String?) -> Recurrence {
        switch self {
        case .daily: return .daily(until: until)
        case .weekly(let d, _): return .weekly(daysOfWeek: d, until: until)
        case .monthly: return .monthly(until: until)
        case .everyNWeeks(let n, let d, let a, _): return .everyNWeeks(interval: n, daysOfWeek: d, anchor: a, until: until)
        }
    }
}

// MARK: - every N weeks: civil-date arithmetic (spec §4)
//
// The week index is whole weeks between Mondays, counted in EPOCH DAYS built
// from the civil Y/M/D fields — never from instants (a floor of millisecond
// differences loses a day after a spring-forward: 2027-03-28 became an off
// week in New York), and never the ISO week-of-year number (2026 has 53
// weeks, so a fortnightly Thursday would fire on 31 Dec AND 7 Jan).

/// Days from 1970-01-01 to the proleptic-Gregorian civil date y-m-d (pure
/// integer arithmetic, no calendar or time zone).
public func civilEpochDay(_ y: Int, _ m: Int, _ d: Int) -> Int {
    let yy = m <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

/// The civil 'YYYY-MM-DD' of an epoch day (inverse of `civilEpochDay`).
public func civilIso(epochDay e: Int) -> String {
    let z = e + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
    return String(format: "%04d-%02d-%02d", y, m, d)
}

/// The epoch day of a STRICT 'YYYY-MM-DD' — exactly ten ASCII characters in
/// that shape, and a real date (it must round-trip: 2026-02-31 is nil, never
/// 3 Mar). The validator every everyNWeeks reader uses; `LocalDate.parse` is
/// not one (it reads "soon" as 1970-01-01).
public func strictEpochDay(_ iso: String) -> Int? {
    let u = Array(iso.utf8)
    guard u.count == 10, u[4] == 45, u[7] == 45 else { return nil }
    func num(_ r: Range<Int>) -> Int? {
        var v = 0
        for i in r {
            guard (48...57).contains(u[i]) else { return nil }
            v = v * 10 + Int(u[i] - 48)
        }
        return v
    }
    guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10), (1...12).contains(m), d >= 1 else { return nil }
    let e = civilEpochDay(y, m, d)
    return civilIso(epochDay: e) == iso ? e : nil
}

/// `a mod n` in 0..<n for any sign of `a` (n > 0). Never `(a % n + n) % n`:
/// with a stored interval near Int.max that sum overflows and traps.
@inline(__always) func floorMod(_ a: Int, _ n: Int) -> Int {
    let m = a % n
    return m < 0 ? m + n : m
}

/// 0=Sun … 6=Sat of an epoch day (1970-01-01 was a Thursday).
@inline(__always) func epochDayOfWeek(_ e: Int) -> Int { floorMod(e + 4, 7) }

/// The epoch day of the Monday of `e`'s ISO week.
@inline(__always) func epochMonday(_ e: Int) -> Int { e - floorMod(epochDayOfWeek(e) + 6, 7) }

/// The distinct days of `days` that are real weekdays (0…6), sorted.
/// Out-of-range values are ignored, never folded into 0…6.
public func validWeekdays(_ days: [Int]) -> [Int] {
    Array(Set(days.filter { (0...6).contains($0) })).sorted()
}

/// The parts of an every-N-weeks rule readers need, or nil when it isn't a
/// valid one (interval < 1 or an anchor that isn't a strict real date).
/// Readers are total: an invalid rule matches no day and never traps.
private func everyNWeeksParts(_ r: Recurrence) -> (interval: Int, days: Set<Int>, anchorMonday: Int)? {
    guard case .everyNWeeks(let n, let days, let anchor, _) = r, n >= 1, let a = strictEpochDay(anchor) else { return nil }
    return (n, Set(days.filter { (0...6).contains($0) }), epochMonday(a))
}

/// True when `r` is an every-N-weeks rule a reader can use (spec §2).
public func isValidEveryNWeeks(_ r: Recurrence?) -> Bool {
    guard let r else { return false }
    return everyNWeeksParts(r) != nil
}

/// Does `iso` fall on the rule's days and weeks — the §4 test without the
/// start / until bounds? Weekly: its weekday; every N weeks: its weekday AND
/// `floorMod(weekIndex, N) == 0`. False for any other kind, or a bad date.
public func isRuleDay(_ r: Recurrence, iso: String) -> Bool {
    guard let e = strictEpochDay(iso) else { return false }
    switch r {
    case .weekly(let days, _):
        return days.contains(epochDayOfWeek(e))
    case .everyNWeeks:
        guard let p = everyNWeeksParts(r), p.days.contains(epochDayOfWeek(e)) else { return false }
        return floorMod((epochMonday(e) - p.anchorMonday) / 7, p.interval) == 0
    default:
        return false
    }
}

/// Week one of a series that starts at `fromIso` (spec §4, §5): the Monday of
/// the first date on or after `fromIso` whose weekday is in `days`. A start
/// on an off weekday (a Friday for a Thursday rule) therefore does not push
/// the first Thursday back by N weeks. Only called with a non-empty valid day
/// set; with none it is `fromIso`'s own Monday.
public func seriesAnchor(days: [Int], fromIso: String) -> String {
    guard let from = strictEpochDay(fromIso) else { return fromIso }
    let wanted = Set(validWeekdays(days))
    for i in 0..<7 where wanted.contains(epochDayOfWeek(from + i)) {
        return civilIso(epochDay: epochMonday(from + i))
    }
    return civilIso(epochDay: epochMonday(from))
}

/// The last civil day a rule date is ever computed for (9999-12-31): past it
/// a date no longer has four year digits.
private let LAST_CIVIL_EPOCH_DAY = 2_932_896

/// The first date on or after `fromIso` that `r` (weekly or every N weeks)
/// matches, from the RULE alone — never from blocks, which may have been
/// moved by hand. Bounded by `until`. Nil when nothing matches (another kind,
/// no valid days, an ended or invalid rule).
///
/// Computed directly — this week when it is an on week and one of its days
/// is still ahead, else the first day of the next on week — never by
/// scanning up to 7N days: readers accept ANY integral interval ≥ 1 (spec
/// §2), and a stored interval of a million weeks froze the editor (a 7N-day
/// scan), while one past Int.max / 7 trapped on `7 * N`. Readers are total.
public func nextRuleDate(_ r: Recurrence, fromIso: String) -> String? {
    guard let from = strictEpochDay(fromIso) else { return nil }
    let found: Int?
    switch r {
    case .weekly(let days, _):
        found = (from..<(from + 7)).first { days.contains(epochDayOfWeek($0)) }
    case .everyNWeeks:
        guard let p = everyNWeeksParts(r), !p.days.isEmpty else { return nil }
        let monday = epochMonday(from)
        let phase = floorMod((monday - p.anchorMonday) / 7, p.interval)
        if phase == 0, let d = (from...(monday + 6)).first(where: { p.days.contains(epochDayOfWeek($0)) }) {
            found = d
        } else {
            // The next on week: N − phase weeks on (N when this one is on but
            // its days have passed). Its first series day is the answer.
            let (offset, overflow) = (phase == 0 ? p.interval : p.interval - phase).multipliedReportingOverflow(by: 7)
            guard !overflow, offset <= LAST_CIVIL_EPOCH_DAY - monday else { return nil }
            let week = monday + offset
            found = (week...(week + 6)).first { p.days.contains(epochDayOfWeek($0)) }
        }
    default: return nil
    }
    guard let e = found, e <= LAST_CIVIL_EPOCH_DAY else { return nil }
    let iso = civilIso(epochDay: e)
    if let until = r.untilDate, iso > until { return nil }
    return iso
}

/// One "Starts" chip (spec §6): the first series day on or after the base in
/// one week, and the Monday that week one would be if it is picked.
public struct StartsChip: Equatable, Sendable {
    public let date: String
    public let anchor: String
    public init(date: String, anchor: String) {
        self.date = date
        self.anchor = anchor
    }
}

/// The "Starts" row for an every-N-weeks pick: N chips, one per consecutive
/// week, beginning with the week of `seriesAnchor(days, base)`. Each chip is
/// the first series day ≥ base in its week. Base Thu 24 Sep for Thursdays,
/// N 2: [Thu 24 Sep, Thu 1 Oct]; base Fri 25 Sep: [Thu 1 Oct, Thu 8 Oct]
/// (the week of 21 Sep has no Thursday left). Empty with no valid day.
/// At most 8 chips: writers write 2…8, and a larger interval stored some
/// other way must not build a chip per week (the editor renders this).
public func startsChips(days: [Int], interval: Int, baseIso: String) -> [StartsChip] {
    let wanted = Set(validWeekdays(days))
    guard !wanted.isEmpty, interval >= 1, let base = strictEpochDay(baseIso),
          let first = strictEpochDay(seriesAnchor(days: days, fromIso: baseIso)) else { return [] }
    return (0..<min(interval, 8)).compactMap { k in
        let monday = first + 7 * k
        guard let day = (0..<7).map({ monday + $0 }).first(where: { $0 >= base && wanted.contains(epochDayOfWeek($0)) })
        else { return nil }
        return StartsChip(date: civilIso(epochDay: day), anchor: civilIso(epochDay: monday))
    }
}

/// The create sheet's every-N-weeks save (spec §5 "Create sheet"): the rule,
/// with week one the "Starts" chip picked (`startsAnchor`; nil or stale = the
/// first chip), and the day the first occurrence is scheduled on. The FIRST
/// chip is the picked day's own series week (seriesAnchor of it), so the
/// series is scheduled from the picked day itself, exactly as weekly is — an
/// off-pattern pick keeps its one-off (web and Android do the same). A LATER
/// chip starts on its own day: scheduling the picked day would re-anchor the
/// series back to that day's week (scheduleTaskAt, "the series starts here").
/// Either way the schedule step never moves the weeks the user picked. Nil
/// for every week (interval < 2) or with no valid day.
public func createSeriesStart(days: [Int], interval: Int, until: String?, pickedIso: String,
                              startsAnchor: String?) -> (rule: Recurrence, scheduleIso: String)? {
    let chips = startsChips(days: days, interval: interval, baseIso: pickedIso)
    guard interval >= 2, let first = chips.first else { return nil }
    let pick = chips.first { $0.anchor == startsAnchor } ?? first
    return (weeklyRule(days: days, interval: interval, anchor: pick.anchor, until: until),
            pick == first ? pickedIso : pick.date)
}

/// Do two anchors give the same on-weeks for an N-week rule?
public func sameWeeks(_ a: String, _ b: String, interval: Int) -> Bool {
    guard interval >= 1, let x = strictEpochDay(a), let y = strictEpochDay(b) else { return a == b }
    return floorMod((epochMonday(x) - epochMonday(y)) / 7, interval) == 0
}

/// The Monday of the week holding a strict 'YYYY-MM-DD' (the string itself
/// when it isn't one). Writers store an every-N-weeks anchor as its Monday
/// (spec §0 rule 3; web `mondayIso`).
public func mondayIso(_ iso: String) -> String {
    guard let e = strictEpochDay(iso) else { return iso }
    return civilIso(epochDay: epochMonday(e))
}

/// The day the "Starts" chips (and a repeat edit's default week one) count
/// from (spec §5, §6; web `startsBase`), for an edit of `current` into every
/// `interval` weeks on `newDays`:
///  • already every N weeks with the SAME N → the stored rule's next date ON
///    THE NEW DAYS (the edit keeps the stored anchor, so that is the series'
///    real first date — counted on the old days, a Thu → Mon change on a
///    Wednesday labelled the stored weeks' chip "Mon 19 Oct" over a series
///    that starts Mon 5 Oct; web review 17181ed). With the days unchanged it
///    is exactly `nextRuleDate(stored, today)`;
///  • weekly, or every N weeks with another N → the week of the CURRENT
///    rule's next date (from the rule, not the blocks: E3), or today when
///    that week has begun — the next occurrence never jumps;
///  • anything else (no repeat, daily, monthly) → the series' next block day
///    (`blockIso`, recurrenceAnchor's) when it is AHEAD of today, else today:
///    a task whose only blocks are history never starts its weeks in the past
///    (web's rule, canonical — the spec's literal `recurrenceEditStart(...)
///    .date` could be a past week).
public func startsBase(current: Recurrence?, interval: Int, todayIso: String, blockIso: String? = nil,
                       newDays: [Int]? = nil) -> String {
    if case .everyNWeeks(let n, let days, let anchor, let until)? = current, n == interval, isValidEveryNWeeks(current) {
        let edited = validWeekdays(newDays ?? [])
        let kept = Recurrence.everyNWeeks(interval: n, daysOfWeek: edited.isEmpty ? days : edited, anchor: anchor, until: until)
        return nextRuleDate(kept, fromIso: todayIso) ?? todayIso
    }
    switch current {
    case .weekly?, .everyNWeeks?:
        guard let current, let next = nextRuleDate(current, fromIso: todayIso) else { return todayIso }
        return max(todayIso, mondayIso(next))
    default:
        guard let blockIso, blockIso > todayIso else { return todayIso }
        return blockIso
    }
}

/// Week one for a repeat EDIT that writes every N weeks (spec §5), when the
/// user picked no week in "Starts":
///  • the task is already every N weeks with the SAME N (days, time or until
///    changed) → the stored anchor, written as its Monday: such an edit never
///    moves the weeks;
///  • it is weekly, or every N weeks with another N → the week of the CURRENT
///    rule's next date (from the rule, not from blocks), so the next
///    occurrence never jumps — or, when the new days in that week have passed,
///    the next week that has one: `seriesAnchor(newDays, max(today,
///    monday(nextRuleDate(current, today))))`;
///  • from daily, monthly or no repeat → `seriesAnchor(newDays, startIso)`
///    when `startIso` (the series' next block) is ahead of today, else from
///    TODAY — a task whose only blocks are in the past starts its weeks now,
///    never in a past week (web's rule, canonical; see `startsBase`).
public func recurrenceEditAnchor(current: Recurrence?, newDays: [Int], newInterval: Int,
                                 todayIso: String, startIso: String? = nil) -> String {
    if case .everyNWeeks(let n, _, let anchor, _)? = current, n == newInterval, strictEpochDay(anchor) != nil {
        return mondayIso(anchor)
    }
    return seriesAnchor(days: newDays, fromIso: startsBase(current: current, interval: newInterval, todayIso: todayIso,
                                                           blockIso: startIso))
}

/// The rule a weekly-days pick writes (the pickers, set_task_recurrence):
/// 1 week is plain weekly; 2 and up is every N weeks. Days are written
/// distinct, sorted and in 0…6, and the anchor as its Monday (spec §0 rule 3).
public func weeklyRule(days: [Int], interval: Int, anchor: String, until: String?) -> Recurrence {
    let d = validWeekdays(days)
    return interval <= 1 ? .weekly(daysOfWeek: d, until: until)
        : .everyNWeeks(interval: interval, daysOfWeek: d, anchor: mondayIso(anchor), until: until)
}

/// Scheduling a series on a chosen day means "the series starts here" (spec
/// §5): an every-N-weeks rule re-anchors to `seriesAnchor(days, chosen)`. Nil
/// when nothing changes — another kind, or a chosen day whose week is already
/// an on week (the same weeks, so the task row need not be written).
public func reanchoredForSchedule(_ r: Recurrence?, chosenIso: String) -> Recurrence? {
    guard case .everyNWeeks(let n, let days, let anchor, let until)? = r, isValidEveryNWeeks(r),
          !validWeekdays(days).isEmpty else { return nil }
    let next = seriesAnchor(days: days, fromIso: chosenIso)
    guard !sameWeeks(next, anchor, interval: n) else { return nil }
    return .everyNWeeks(interval: n, daysOfWeek: days, anchor: next, until: until)
}

private func matchesRecurrence(_ r: Recurrence, startDate: Date, candidate: Date, candidateIso: String) -> Bool {
    if Time.startOfDay(candidate) < Time.startOfDay(startDate) { return false }
    switch r {
    case .daily:
        return true
    case .weekly(let days, _):
        return days.contains(Time.dayOfWeekJS(candidate))
    case .monthly:
        // Clamp a day-31 start to each month's last day (Feb 28/29, Apr 30, …),
        // recovering to 31 in long months — matches current Android (the v0.4.23 fix).
        return Time.dayOfMonth(candidate) == min(Time.dayOfMonth(startDate), Time.daysInMonth(candidate))
    case .everyNWeeks:
        // From the civil date string, never the instant (spec §4).
        return isRuleDay(r, iso: candidateIso)
    }
}

/// Date/time pairs for a recurrence starting at `startDate`/`startTime`,
/// going `horizonDays` ahead (inclusive of startDate). Stops at
/// `recurrence.until` (inclusive) when set.
public func materializeOccurrences(
    _ recurrence: Recurrence,
    startDate: Date,
    startTime: String,
    horizonDays: Int = RECURRENCE_HORIZON_DAYS
) -> [MaterializedOccurrence] {
    var out: [MaterializedOccurrence] = []
    let untilIso = recurrence.untilDate
    // Anchor on local midnight and re-floor each step. `Calendar.addDays`
    // preserves wall-clock time, so a `startDate` carrying a time-of-day could,
    // across a DST transition, land an occurrence in the wrong civil day (drop /
    // double the transition day). Flooring before AND after addDays makes the
    // series land on exact civil days regardless. Byte-identical for a midnight
    // startDate (the documented contract — web/Android pass local midnight).
    let base = Time.startOfDay(startDate)
    for i in 0..<horizonDays {
        let day = Time.startOfDay(Time.addDays(base, i))
        let iso = Clock.dateISO(day)
        if let untilIso, iso > untilIso { break }
        if matchesRecurrence(recurrence, startDate: startDate, candidate: day, candidateIso: iso) {
            out.append(MaterializedOccurrence(date: iso, startTime: startTime))
        }
    }
    return out
}

/// The diff needed to align a task's existing cal_blocks with
/// `recurrence`: keep past occurrences, delete mismatched future ones,
/// add missing ones. `todayIso` is injected so the boundary is testable.
///
/// The three lists are DISJOINT by id (rule B, deterministic-occurrence-ids.md
/// §3b), so callers may write them in any order:
///  • `toUpsert` — NEW occurrences, each with its deterministic id: MINTS,
///    written insert-if-absent (`insert_or_retime`);
///  • `toRetime` — existing rows rewritten in place: an occurrence whose
///    deterministic id the plan would otherwise delete and mint again (a time
///    change). A plain upsert; the row keeps its Google mapping;
///  • `toDelete` — ids to delete.
public struct RegenPlan: Equatable, Sendable {
    public var toUpsert: [CalBlock]
    public var toDelete: [String]   // cal_block ids
    public var toRetime: [CalBlock]
    public init(toUpsert: [CalBlock], toDelete: [String], toRetime: [CalBlock] = []) {
        self.toUpsert = toUpsert
        self.toDelete = toDelete
        self.toRetime = toRetime
    }
}

/// THE anchor a recurrence change regenerates from: the task's earliest LIVE
/// block at or after today, falling back to its latest past block so a series
/// with only history keeps its time of day. Nil when the task has no block at
/// all (nothing to anchor on; the caller leaves the calendar alone).
///
/// Why this exists: `regenerateForTask` deletes every future block whose
/// date|time doesn't match the anchor's, so the anchor decides what survives.
/// The assistant used `blocks.first(where:)` — an arbitrary block in SQLite
/// rowid order, commonly a done past occurrence at a different time or one
/// with no time at all — and the UI used the earliest block of any kind,
/// including history. "Make Office every Monday at 11" then deleted the
/// Monday 11:00 block and rebuilt the series at the old time, which is how one
/// tester ended up with four "Office" tasks, one of them timeless, and nothing
/// on the next Monday (audit 2026-09-21).
public func recurrenceAnchor(taskId: String, blocks: [CalBlock], todayIso: String) -> CalBlock? {
    let mine = blocks.filter { $0.taskId == taskId && isTaskBlock($0) && !$0.startTime.isEmpty }
    let live = mine.filter { !$0.done && !$0.skipped && $0.date >= todayIso }
    if let next = live.min(by: { ($0.date + $0.startTime) < ($1.date + $1.startTime) }) { return next }
    return mine.max(by: { ($0.date + $0.startTime) < ($1.date + $1.startTime) })
}

/// `keepIds` are rows the edit must keep where they are (`RecurrenceStart.keepId`):
/// they are never deleted and never rewritten, and they count as HELD, so the
/// day whose id they carry is not minted again. They go INTO the plan, not
/// around it: a caller filtering `toDelete` afterwards could not stop rule B
/// from moving a kept row (deterministic-occurrence-ids.md §3b).
///
/// Deterministic ids (audit 2026-09-22 C21, stage 2) add two rules:
///  • rule A — a desired occurrence whose id a KEPT row already holds (moved,
///    done, skipped, kept, history) is not minted: the day's occurrence lives
///    on elsewhere, and a mint would twin it;
///  • rule B — a desired occurrence whose id is a row in the delete set (a
///    time change: the 07:00 row is deleted and the 09:00 one minted with the
///    SAME id) becomes that row rewritten in place (`toRetime`). Emitted as
///    delete + mint, iOS's own callers cancelled the mint with the delete and
///    the day was lost.
public func regenerateForTask(
    task: TaskItem,
    recurrence: Recurrence?,
    existingBlocks: [CalBlock],
    todayIso: String,
    startTime: String,
    startDate: Date,
    horizonDays: Int = RECURRENCE_HORIZON_DAYS,
    keepIds: Set<String> = []
) -> RegenPlan {
    let existing = existingBlocks.filter { $0.taskId == task.id && isTaskBlock($0) }
    let futureExisting = existing.filter { $0.date > todayIso }

    guard let recurrence else {
        // Clearing recurrence — delete every future occurrence, keep history.
        return RegenPlan(toUpsert: [], toDelete: futureExisting.map(\.id).filter { !keepIds.contains($0) })
    }

    let desired = materializeOccurrences(recurrence, startDate: startDate, startTime: startTime, horizonDays: horizonDays)
        .filter { $0.date > todayIso }
    let desiredKeys = Set(desired.map { "\($0.date)|\($0.startTime)" })
    let existingFutureKeys = Set(futureExisting.map { "\($0.date)|\($0.startTime)" })

    var toDelete: [String] = []
    for b in futureExisting where !desiredKeys.contains("\(b.date)|\(b.startTime)") {
        toDelete.append(b.id)
    }
    // A kept row is HELD: never deleted, never rewritten.
    var deleteSet = Set(toDelete).subtracting(keepIds)
    let existingById = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    var toUpsert: [CalBlock] = []
    var toRetime: [CalBlock] = []
    for o in desired where !existingFutureKeys.contains("\(o.date)|\(o.startTime)") {
        let id = occurrenceId(taskId: task.id, date: o.date)
        if deleteSet.contains(id), let row = existingById[id] {
            // Rule B: the same id deleted + minted → rewrite it in place, from
            // the EXISTING row (it keeps its Google mapping). The net effect of
            // the old delete + fresh mint: the new date/time, open again.
            deleteSet.remove(id)
            var next = row
            next.date = o.date
            next.startTime = o.startTime
            next.taskName = task.name
            next.durationMinutes = clampDurationMin(task.estimateMin)
            next.done = false
            next.skipped = false
            next.completedAt = nil
            toRetime.append(next)
        } else if existingById[id] != nil {
            continue   // rule A: held by a kept row (moved, done, skipped, kept, history)
        } else {
            toUpsert.append(occurrenceBlock(task, o))
        }
    }

    return RegenPlan(toUpsert: toUpsert, toDelete: toDelete.filter { deleteSet.contains($0) }, toRetime: toRetime)
}

/// A new occurrence block for `task` — the one place a series mints a block.
/// Its id is the DETERMINISTIC `occurrenceId(task, date)` (audit 2026-09-22,
/// C21, "same id for same day"): two devices minting the same day land on
/// one row instead of twins. Written insert-if-absent, never over a row.
/// The server's CHECK is `duration_minutes between 5 and 1440`, so a 2-minute
/// task would mint occurrences it refuses on flush — the rows then live on
/// that one phone for ever (audit 2026-09-21).
private func occurrenceBlock(_ task: TaskItem, _ o: MaterializedOccurrence) -> CalBlock {
    CalBlock(id: occurrenceId(taskId: task.id, date: o.date), taskId: task.id, taskName: task.name,
             startTime: o.startTime, durationMinutes: clampDurationMin(task.estimateMin),
             date: o.date, kind: .task)
}

/// The most common start time in `pool`. Ties go to the time used most across
/// `tieBreak`, then to the one used most recently, then to the later string.
/// Nil when nothing in the pool has a time.
private func mostCommonStartTime(_ pool: [CalBlock], tieBreak: [CalBlock]) -> String? {
    var total: [String: Int] = [:]
    for b in tieBreak where !b.startTime.isEmpty { total[b.startTime, default: 0] += 1 }
    let groups = Dictionary(grouping: pool.filter { !$0.startTime.isEmpty }, by: { $0.startTime })
    func rank(_ time: String, _ blocks: [CalBlock]) -> (Int, Int, String, String) {
        (blocks.count, total[time] ?? 0, blocks.map { $0.date }.max() ?? "", time)
    }
    return groups.max { rank($0.key, $0.value) < rank($1.key, $1.value) }?.key
}

/// The time of day a series runs at: the most common start time among the
/// task's timed blocks in the `horizonDays` up to `frontierIso` (all of its
/// timed blocks when none fall in that window). Ties go to the time used most
/// across every block passed in, then to the most recent. Nil when no block
/// has a time.
///
/// Why not the next open occurrence (audit 2026-09-22, C1): that is often the
/// one the user moved by hand — the notification's Reschedule, a calendar drag,
/// schedule_task — and the horizon top-up that took it as the series time
/// minted ~55 copies of the series at the moved time. The window keeps a
/// whole-series re-plan to a new time from being outvoted by older history.
public func recurrenceSeriesTime(taskId: String, blocks: [CalBlock], frontierIso: String,
                                 horizonDays: Int = RECURRENCE_HORIZON_DAYS) -> String? {
    let timed = blocks.filter { $0.taskId == taskId && isTaskBlock($0) && !$0.startTime.isEmpty }
    let from = LocalDate.addDays(frontierIso, -(horizonDays - 1))
    let recent = timed.filter { $0.date >= from && $0.date <= frontierIso }
    return mostCommonStartTime(recent.isEmpty ? timed : recent, tieBreak: timed)
}

/// The day of the month a monthly series runs on, voted by its LAST THREE
/// occurrences (any state) with how many of them agree on it. A month-end
/// clamp counts for the longer day (a 31st series shows Feb 28 / Apr 30), so
/// the clamp recovers to 31. A 1-1 split goes to the earlier day: a hand move
/// of one occurrence almost always pushes it later (carry to tomorrow, "push
/// it back"). Nil when there are no blocks.
private func recurrenceSeriesDay(_ blocks: [CalBlock]) -> (day: Int, votes: Int)? {
    let lastThree = blocks.map { $0.date }.filter { $0.split(separator: "-").count == 3 }.sorted().suffix(3)
    let dates: [Date] = lastThree.map { LocalDate.parse($0) }
    var best: (day: Int, votes: Int)?
    for day in Set(dates.map { Time.dayOfMonth($0) }) {
        let votes = dates.filter { Time.dayOfMonth($0) == min(day, Time.daysInMonth($0)) }.count
        if let b = best, votes < b.votes || (votes == b.votes && day > b.day) { continue }
        best = (day, votes)
    }
    return best
}

/// How many days either side of one of the series' dates a block still counts
/// as that date's occurrence, moved: under half the gap to the neighbouring
/// dates, so it is nearer that date than any other. A monthly date is at
/// least 28 days from the next; a daily one has no room. Every N weeks is
/// measured over its 7N-day cycle with ISO positions (Mon=0 … Sun=6) of the
/// days in week one (spec §4): 6 for fortnightly on one day, 27 for every 8
/// weeks; with N = 1 it equals the weekly value for every day set.
func occurrenceReach(_ r: Recurrence) -> Int {
    switch r {
    case .daily:
        return 0
    case .weekly(let days, _):
        let sorted = Set(days.filter { (0...6).contains($0) }).sorted()
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1 - $0 } + [7 - last + first]
        return ((gaps.min() ?? 7) - 1) / 2
    case .monthly:
        return 14
    case .everyNWeeks(let n, let days, _, _):
        guard isValidEveryNWeeks(r) else { return 0 }
        let sorted = validWeekdays(days).map { ($0 + 6) % 7 }.sorted()
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        // Readers accept any integral interval: 7N must not trap past Int.max
        // / 7 (the top-up runs at launch), and the top-up adds ±reach days to
        // a date. 10 000 weeks (~190 years) already reaches every block a
        // series can have, so a larger N gives the same answer.
        let cycle = 7 * min(n, 10_000)
        let gaps = zip(sorted, sorted.dropFirst()).map { $1 - $0 } + [cycle - last + first]
        return ((gaps.min() ?? cycle) - 1) / 2
    }
}

/// The nearest date on or before `iso` whose day of month is exactly `day`
/// (materializeOccurrences takes a monthly series' day from its start date,
/// so a clamped Feb 28 would turn a 31st series into a 28th one).
private func monthlyStart(day: Int, onOrBefore iso: String) -> String {
    for back in 0..<62 {
        let d = LocalDate.addDays(iso, -back)
        if Time.dayOfMonth(LocalDate.parse(d)) == day { return d }
    }
    return iso
}

/// Where a recurrence EDIT regenerates the series from (saveTaskWithRecurrence,
/// set_task_recurrence). Nil when the task has no timed block to anchor on.
public struct RecurrenceStart: Equatable, Sendable {
    public let date: String       // YYYY-MM-DD, handed to regenerateForTask as startDate
    public let startTime: String  // HH:MM
    public let horizonDays: Int   // stretched so the horizon still ends 8 weeks after the anchor
    /// A block the edit must NOT delete although the plan lists it: this
    /// month's occurrence, moved later off a series day that has passed.
    public let keepId: String?
    public init(date: String, startTime: String, horizonDays: Int, keepId: String? = nil) {
        self.date = date
        self.startTime = startTime
        self.horizonDays = horizonDays
        self.keepId = keepId
    }
}

/// An edit keeps the series' OWN time and day. The time is the most common one
/// among its live upcoming occurrences once there are at least two (else the
/// anchor's, which keeps the build-79 "Office every Monday at 11" fix: one live
/// 11:00 block over 09:15 history still gives 11:00). A monthly series takes
/// its day from the last three occurrences when two of them agree.
///
/// Why (audit 2026-09-22, C1): regenerateForTask deletes every future block
/// that doesn't match the start's date|time, and the start was the next open
/// occurrence. Editing only the repeat's end date on a day when that occurrence
/// had been moved by hand deleted the whole series and rebuilt it at the moved
/// time (or, monthly, on the moved day).
public func recurrenceEditStart(taskId: String, recurrence: Recurrence?, blocks: [CalBlock], todayIso: String,
                                horizonDays: Int = RECURRENCE_HORIZON_DAYS) -> RecurrenceStart? {
    guard let anchor = recurrenceAnchor(taskId: taskId, blocks: blocks, todayIso: todayIso) else { return nil }
    let timed = blocks.filter { $0.taskId == taskId && isTaskBlock($0) && !$0.startTime.isEmpty }
    let live = timed.filter { !$0.done && !$0.skipped && $0.date >= todayIso }
    let time = live.count >= 2 ? (mostCommonStartTime(live, tieBreak: timed) ?? anchor.startTime) : anchor.startTime
    // Every N weeks regenerates from TODAY over the full horizon (spec §5):
    // the rule's anchor decides the weeks, so the start needs no day of its
    // own, and a window starting at the next block (up to N weeks out) or on
    // a Monday ended before the top-up's today + 55 — every on-week block in
    // that gap was deleted, then minted again by the next top-up (vector E1),
    // re-arming reminders and churning Google events.
    if case .everyNWeeks? = recurrence {
        return RecurrenceStart(date: todayIso, startTime: time, horizonDays: horizonDays)
    }
    // Two of the last three must agree before the day moves off the anchor's:
    // switching a weekly series to monthly keeps the next occurrence's day.
    guard case .monthly = recurrence, let series = recurrenceSeriesDay(timed), series.votes >= 2 else {
        return RecurrenceStart(date: anchor.date, startTime: time, horizonDays: horizonDays)
    }
    let date = monthlyStart(day: series.day, onOrBefore: anchor.date)
    // The anchor is this month's occurrence moved later, and the series day it
    // left has passed: regenerateForTask only wants dates after today, so it
    // deleted the moved one and the month lost its occurrence (audit
    // 2026-09-22, C1). Kept unless it is past `until` or too far out to be
    // this month's (then it is next month's, moved earlier, and is re-aligned).
    let ownsPassedDay = date <= todayIso && anchor.date > todayIso
        && LocalDate.daysUntil(date, anchor.date) <= occurrenceReach(.monthly(until: nil))
        && (recurrence?.untilDate.map { anchor.date <= $0 } ?? true)
    return RecurrenceStart(date: date, startTime: time, horizonDays: horizonDays + LocalDate.daysUntil(date, anchor.date),
                           keepId: ownsPassedDay ? anchor.id : nil)
}

/// The occurrences the horizon top-up adds for one repeating task: the TAIL
/// only — dates after both its latest block (the frontier) and today, up to
/// today + horizonDays - 1, at the series' own time (recurrenceSeriesTime, or
/// `seriesTime` when the caller has just placed the series explicitly — the
/// placed occurrence is then the frontier, and a monthly series keeps its day).
///
/// Why (audit 2026-09-22, C1): the top-up used to rebuild the whole 8 weeks
/// from the next open occurrence and add every missing date|time. The store
/// keeps no record of a removal, so every occurrence the user deleted,
/// unscheduled or moved came back at its old slot on each launch and at
/// midnight, and a moved next occurrence copied the whole series at its new
/// time. Extending only past the frontier never fills a date the series
/// already covered.
/// - Blocks after the horizon don't count toward the frontier, so one
///   occurrence moved months ahead can't stop the series extending; a series
///   with nothing in the horizon but blocks beyond it was re-planned to start
///   later on purpose and is left alone.
/// - The span starts at the frontier, so a series idle for more than 8 weeks
///   comes back from tomorrow (C95).
/// - A monthly series keeps its day of month (recurrenceSeriesDay), not the
///   frontier's, which may be a moved or clamped one (C22). The vote also
///   reads the blocks up to a month past the horizon: a whole-series re-plan
///   to a later day (the Schedule sheet, web, Android) puts its second
///   occurrence there, and without it the vote read [old, old, new] and kept
///   the old day. Blocks moved further out don't vote.
/// - A date with one of the task's blocks within reach (occurrenceReach; any
///   state, past the horizon too) already has its occurrence, moved: the
///   frontier dragged a few days earlier, or a re-plan's next one. Minting it
///   gave that month (or week) a second occurrence and a second reminder.
/// - Today is never minted, matching regenerateForTask.
/// - A date whose deterministic occurrence id one of the task's blocks already
///   holds (any date, any state, past the horizon too) is never minted (rule
///   A, stage 2): that occurrence was moved further than `occurrenceReach`,
///   and it lives on there.
public func recurrenceTopUp(task: TaskItem, existingBlocks: [CalBlock], todayIso: String, seriesTime: String? = nil,
                            horizonDays: Int = RECURRENCE_HORIZON_DAYS) -> [CalBlock] {
    guard let recurrence = task.recurrence else { return [] }
    let mine = existingBlocks.filter { $0.taskId == task.id && isTaskBlock($0) }
    let lastIso = LocalDate.addDays(todayIso, horizonDays - 1)
    let inHorizon = mine.filter { $0.date <= lastIso }
    if !inHorizon.contains(where: { $0.date > todayIso }), mine.contains(where: { $0.date > lastIso }) { return [] }
    guard let frontier = inHorizon.map(\.date).max(), frontier.split(separator: "-").count == 3,
          let time = seriesTime ?? recurrenceSeriesTime(taskId: task.id, blocks: inHorizon, frontierIso: frontier,
                                                        horizonDays: horizonDays) else { return [] }
    let floor = max(frontier, todayIso)
    guard floor < lastIso else { return [] }
    var start = frontier
    let voters = mine.filter { $0.date <= LocalDate.addDays(lastIso, 31) }
    if seriesTime == nil, case .monthly = recurrence, let series = recurrenceSeriesDay(voters) {
        start = monthlyStart(day: series.day, onOrBefore: frontier)
    }
    let reach = occurrenceReach(recurrence)
    let held = Set(mine.map(\.id))
    return materializeOccurrences(recurrence, startDate: LocalDate.parse(start), startTime: time,
                                  horizonDays: LocalDate.daysUntil(start, lastIso) + 1)
        .filter { $0.date > floor }
        .filter { o in
            let (lo, hi) = (LocalDate.addDays(o.date, -reach), LocalDate.addDays(o.date, reach))
            return !mine.contains { $0.date >= lo && $0.date <= hi }
        }
        .filter { !held.contains(occurrenceId(taskId: task.id, date: $0.date)) }
        .map { occurrenceBlock(task, $0) }
}

/// What scheduling a series onto `iso` at `startTime` must do on that day once
/// a `RegenPlan` is applied.
public enum ChosenDateAction: Equatable, Sendable {
    /// The day already has its occurrence: nothing to write.
    case covered
    /// Move this existing block to the chosen time (and un-skip it).
    case retime(CalBlock)
    /// Nothing on the day: mint a new occurrence.
    case mint
}

/// Pure decision behind `scheduleTaskAt`'s guarantee on the chosen day (and
/// the assistant's schedule_task on a series). An existing block the plan is
/// about to DELETE does not count (or the day would end up empty); a planned
/// upsert on the date does.
///
/// Why not "any block on the day covers it" (audit 2026-09-22, C7 /
/// core-scheduling#8): regenerateForTask never touches today, so scheduling a
/// series for today at 16:00 left today's occurrence at 07:00, and a SKIPPED
/// occurrence counted as coverage, so the day just scheduled stayed hidden.
/// Now an open occurrence at another time is retimed (only possible on today
/// or earlier — for a future day the plan either keeps the date|time or
/// deletes the block), a skipped one is retimed and un-skipped, and a done
/// one still covers the day so no second open copy appears. Retiming rather
/// than minting keeps one block per task per day.
///
/// Rule B′ (stage 2): a row the plan rewrites (`toRetime`) is treated exactly
/// like one it deletes — it is moving to its own date, so it can't be the
/// chosen day's occurrence (counted, the day the user picked could end up
/// empty, or the row got two writes). A planned block covers the day only by
/// its NEW date.
public func recurrenceChosenDateAction(existing: [CalBlock], plan: RegenPlan, iso: String, startTime: String) -> ChosenDateAction {
    if (plan.toUpsert + plan.toRetime).contains(where: { $0.date == iso }) { return .covered }
    let moving = Set(plan.toDelete).union(plan.toRetime.map(\.id))
    let onDay = existing.filter { $0.date == iso && isTaskBlock($0) && !moving.contains($0.id) }
    let live = onDay.filter { !$0.done && !$0.skipped }
    if live.contains(where: { $0.startTime == startTime }) { return .covered }
    if let open = live.min(by: { $0.startTime < $1.startTime }) { return .retime(open) }
    if onDay.contains(where: { $0.done }) { return .covered }
    if let skipped = onDay.first(where: { $0.skipped }) { return .retime(skipped) }
    return .mint
}

/// The chosen day's write (`recurrenceChosenDateWrite`).
public enum ChosenDateWrite: Equatable, Sendable {
    /// The day already has its occurrence.
    case none
    /// A plain upsert: a retime, an in-place rewrite of the day's own row, or
    /// a random-id block.
    case upsert(CalBlock)
    /// A deterministic mint: written insert-if-absent (`insert_or_retime`).
    case insert(CalBlock)
}

/// §3b′ of deterministic-occurrence-ids.md: what guaranteeing the chosen day
/// writes, computed AFTER regenerate and applied before any of the plan's
/// writes are dispatched (Schedule on a series, "Start repeating", the create
/// sheet, and — with an empty plan — a series' first placement). Returns the
/// plan (possibly minus one delete) and the write; the plan's three lists and
/// the write are disjoint by id.
///  • `.covered` → `.none`; `.retime(b)` → `b` at `startTime`, un-skipped.
///  • `.mint`, with `id = occurrenceId(task, iso)`:
///    1. `id` is in `plan.toDelete` → that row is taken OUT of the delete and
///       rewritten in place onto the day (from the existing row, so its Google
///       mapping survives — a fresh block would null it);
///    2. a block with `id` survives elsewhere (moved, done early, kept) → a
///       block with a RANDOM id: the user asked for this day explicitly, and
///       the surviving row is never taken over;
///    3. otherwise → the deterministic mint.
public func recurrenceChosenDateWrite(task: TaskItem, existing: [CalBlock], plan: RegenPlan,
                                      iso: String, startTime: String) -> (RegenPlan, ChosenDateWrite) {
    var plan = plan
    switch recurrenceChosenDateAction(existing: existing, plan: plan, iso: iso, startTime: startTime) {
    case .covered:
        return (plan, .none)
    case .retime(let b):
        var moved = b
        moved.startTime = startTime
        moved.skipped = false
        return (plan, .upsert(moved))
    case .mint:
        let id = occurrenceId(taskId: task.id, date: iso)
        let mine = existing.filter { $0.taskId == task.id && isTaskBlock($0) }
        let duration = clampDurationMin(task.estimateMin)
        if let i = plan.toDelete.firstIndex(of: id), let row = mine.first(where: { $0.id == id }) {
            plan.toDelete.remove(at: i)
            var next = row
            next.date = iso
            next.startTime = startTime
            next.taskName = task.name
            next.durationMinutes = duration
            next.done = false
            next.skipped = false
            next.completedAt = nil
            return (plan, .upsert(next))
        }
        if mine.contains(where: { $0.id == id }) {
            return (plan, .upsert(CalBlock(id: newUUID(), taskId: task.id, taskName: task.name, startTime: startTime,
                                           durationMinutes: duration, date: iso, kind: .task)))
        }
        return (plan, .insert(CalBlock(id: id, taskId: task.id, taskName: task.name, startTime: startTime,
                                       durationMinutes: duration, date: iso, kind: .task)))
    }
}

/// Does the create sheet need a time before it may add this task? `date` is
/// nil for Later.
///
/// Why (audit 2026-09-22, C7 / tasks-ui#5): every occurrence is a timed block
/// and nothing (the horizon top-up included) can invent the time later, so a
/// repeating task saved without one had zero occurrences and showed nowhere
/// but Tasks → Recurring. The free-slot finder stops at 18:00, so that was the
/// normal evening case. A one-off for a later day with no time got no block
/// and silently landed in Today, then Backlog. A one-off for today may still
/// be added without a time.
public func newTaskNeedsTime(repeats: Bool, date: String?, todayIso: String, pickedTime: String?) -> Bool {
    guard let date else { return repeats }
    guard pickedTime == nil else { return false }
    return repeats || date != todayIso
}

private let DOW_LABELS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

private func formatDays(_ days: [Int]) -> String {
    let sorted = Array(Set(days)).sorted()
    if sorted.count == 5 && [1, 2, 3, 4, 5].allSatisfy(sorted.contains) { return "weekdays" }
    if sorted.count == 2 && sorted.contains(0) && sorted.contains(6) { return "weekends" }
    return sorted.compactMap { (0..<DOW_LABELS.count).contains($0) ? DOW_LABELS[$0] : nil }.joined(separator: "/")
}

/// Short human label for the detail pane / row chips.
public func recurrenceLabel(_ r: Recurrence?) -> String {
    guard let r else { return "" }
    // An unrecognised recurrence kind degraded to the inert sentinel on decode —
    // render nothing (it doesn't repeat on this build). Matches Android.
    if Recurrence.isUnknown(r) { return "" }
    let base: String
    switch r {
    case .daily:
        base = "Repeats daily"
    case .weekly(let days, _):
        base = days.count == 7 ? "Repeats daily" : "Repeats \(formatDays(days))"
    case .monthly:
        base = "Repeats monthly"
    case .everyNWeeks(let n, let days, _, _):
        // Out-of-range days are dropped before formatting; an invalid rule (or
        // one with no real day) repeats zero times and reads as nothing.
        let valid = validWeekdays(days)
        guard isValidEveryNWeeks(r), !valid.isEmpty else { return "" }
        if n == 1 {
            base = valid.count == 7 ? "Repeats daily" : "Repeats \(formatDays(valid))"
        } else {
            base = valid.count == 7 ? "Repeats every day, every \(n) weeks" : "Repeats every \(n) weeks on \(formatDays(valid))"
        }
    }
    if let until = r.untilDate {
        let parts = until.split(separator: "-").map { Int($0) }
        if parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2] {
            let date = Time.civil(y, m, d)
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US")
            df.dateFormat = "MMM d, yyyy"
            return "\(base) until \(df.string(from: date))"
        }
    }
    return base
}

/// A task with its repeat turned on or off (audit 2026-09-22, C3). A series'
/// TEMPLATE carries no done of its own — each day's done lives on its
/// occurrence block — so the done state has to cross over when the repeat
/// changes:
///  • OFF ("Never", set_task_recurrence none): the ex-template is bucketed as
///    a plain task, whose done is task-level, so a ticked today reappeared
///    unticked. When today's occurrences are all ticked, the tick carries onto
///    the task (done, with the latest of their completedAt). An open or absent
///    today leaves it open — no silent completion (owner decision); its kept
///    history puts it in Backlog as overdue.
///  • ON for a plain task that is done: the done is cleared. A done TEMPLATE
///    is an ended series — no reminders, no horizon top-up, no server calls —
///    and "Daily → Never → Daily" on a ticked day would otherwise make one.
///    The day it was done keeps its tick (`occurrencesCarryingTaskDone`).
/// Changing one repeat rule for another leaves the done state as it is.
public func taskAfterSettingRecurrence(_ task: TaskItem, recurrence: Recurrence?, blocks: [CalBlock],
                                       todayIso: String, nowISO: String) -> TaskItem {
    var next = task
    next.recurrence = recurrence
    if recurrence == nil, task.recurrence != nil, !task.done {
        let today = blocks.filter { $0.taskId == task.id && isTaskBlock($0) && $0.date == todayIso && !$0.skipped }
        if !today.isEmpty && today.allSatisfy(\.done) {
            next.done = true
            next.completedAt = today.compactMap(\.completedAt).max() ?? nowISO
        }
    } else if recurrence != nil, task.recurrence == nil, task.done {
        next.done = false
        next.completedAt = nil
    }
    return next
}

/// The occurrence blocks a done task's tick moves onto when its repeat is
/// turned ON (audit 2026-09-22, C3). A plain task's done lives on the TASK —
/// its blocks stay open — and taskAfterSettingRecurrence clears it, so the
/// day it was done became an open occurrence: "Stretch" ticked this morning,
/// made daily, and today's 07:30 row was back in Today to tick again (the
/// evening call counting it open); ticked on yesterday's slot, and that slot
/// showed in Backlog as overdue. The tick lands on the day it fulfilled — the
/// task's latest scheduled day on or before the day it was done — stamped
/// with the task's completedAt, the shape setOccurrenceDone writes. A slot
/// after that day (done early) stays that day's open occurrence. Empty for
/// every other change, and for a day already ticked.
public func occurrencesCarryingTaskDone(_ task: TaskItem, recurrence: Recurrence?, blocks: [CalBlock],
                                        todayIso: String, nowISO: String) -> [CalBlock] {
    guard recurrence != nil, task.recurrence == nil, task.done else { return [] }
    let doneDay = min(task.completedAt.map(isoToLocalYmd) ?? todayIso, todayIso)
    let slots = blocks.filter { $0.taskId == task.id && isTaskBlock($0) && !$0.skipped && $0.date <= doneDay }
    guard let day = slots.map(\.date).max() else { return [] }
    return slots.filter { $0.date == day && !$0.done }.map { b in
        var next = b
        next.done = true
        next.completedAt = task.completedAt ?? nowISO
        return next
    }
}
