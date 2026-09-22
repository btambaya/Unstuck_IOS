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
        }
    }
}

private func matchesRecurrence(_ r: Recurrence, startDate: Date, candidate: Date) -> Bool {
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
        if matchesRecurrence(recurrence, startDate: startDate, candidate: day) {
            out.append(MaterializedOccurrence(date: iso, startTime: startTime))
        }
    }
    return out
}

/// The diff needed to align a task's existing cal_blocks with
/// `recurrence`: keep past occurrences, delete mismatched future ones,
/// add missing ones. `todayIso` is injected so the boundary is testable.
public struct RegenPlan: Equatable, Sendable {
    public var toUpsert: [CalBlock]
    public var toDelete: [String]   // cal_block ids
    public init(toUpsert: [CalBlock], toDelete: [String]) {
        self.toUpsert = toUpsert
        self.toDelete = toDelete
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

public func regenerateForTask(
    task: TaskItem,
    recurrence: Recurrence?,
    existingBlocks: [CalBlock],
    todayIso: String,
    startTime: String,
    startDate: Date,
    horizonDays: Int = RECURRENCE_HORIZON_DAYS
) -> RegenPlan {
    let existing = existingBlocks.filter { $0.taskId == task.id && isTaskBlock($0) }
    let futureExisting = existing.filter { $0.date > todayIso }

    guard let recurrence else {
        // Clearing recurrence — delete every future occurrence, keep history.
        return RegenPlan(toUpsert: [], toDelete: futureExisting.map(\.id))
    }

    let desired = materializeOccurrences(recurrence, startDate: startDate, startTime: startTime, horizonDays: horizonDays)
        .filter { $0.date > todayIso }
    let desiredKeys = Set(desired.map { "\($0.date)|\($0.startTime)" })
    let existingFutureKeys = Set(futureExisting.map { "\($0.date)|\($0.startTime)" })

    var toDelete: [String] = []
    for b in futureExisting where !desiredKeys.contains("\(b.date)|\(b.startTime)") {
        toDelete.append(b.id)
    }

    var toUpsert: [CalBlock] = []
    for o in desired where !existingFutureKeys.contains("\(o.date)|\(o.startTime)") {
        toUpsert.append(CalBlock(
            id: newUUID(), taskId: task.id, taskName: task.name,
            // The server's CHECK is `duration_minutes between 5 and 1440`, so a
            // 2-minute task would mint occurrences it refuses on flush — the
            // rows then live on that one phone for ever (audit 2026-09-21).
            startTime: o.startTime, durationMinutes: min(1440, max(5, task.estimateMin)),
            date: o.date, kind: .task))
    }

    return RegenPlan(toUpsert: toUpsert, toDelete: toDelete)
}

/// Does anything already cover the chosen `iso` date AFTER a `RegenPlan` is
/// applied? Pure decision behind `scheduleTaskAt`'s guarantee-upsert: an
/// existing block on the date that the plan is about to DELETE does NOT count
/// (or we'd skip minting a block, run the delete, and leave the day empty — the
/// task would silently vanish from the day just scheduled), while a planned
/// upsert on the date DOES count. Extracted so the post-plan boundary is unit-
/// testable; the caller mints a guarantee block only when this returns false.
public func recurrenceCoversChosenDate(existing: [CalBlock], plan: RegenPlan, iso: String) -> Bool {
    let deleting = Set(plan.toDelete)
    return existing.contains { $0.date == iso && !deleting.contains($0.id) }
        || plan.toUpsert.contains { $0.date == iso }
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
