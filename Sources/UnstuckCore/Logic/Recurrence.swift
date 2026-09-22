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
        toUpsert.append(occurrenceBlock(task, o))
    }

    return RegenPlan(toUpsert: toUpsert, toDelete: toDelete)
}

/// A new occurrence block for `task` — the one place a series mints a block.
/// The server's CHECK is `duration_minutes between 5 and 1440`, so a 2-minute
/// task would mint occurrences it refuses on flush — the rows then live on
/// that one phone for ever (audit 2026-09-21).
private func occurrenceBlock(_ task: TaskItem, _ o: MaterializedOccurrence) -> CalBlock {
    CalBlock(id: newUUID(), taskId: task.id, taskName: task.name,
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
    public init(date: String, startTime: String, horizonDays: Int) {
        self.date = date
        self.startTime = startTime
        self.horizonDays = horizonDays
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
    // Two of the last three must agree before the day moves off the anchor's:
    // switching a weekly series to monthly keeps the next occurrence's day.
    guard case .monthly = recurrence, let series = recurrenceSeriesDay(timed), series.votes >= 2 else {
        return RecurrenceStart(date: anchor.date, startTime: time, horizonDays: horizonDays)
    }
    let date = monthlyStart(day: series.day, onOrBefore: anchor.date)
    return RecurrenceStart(date: date, startTime: time, horizonDays: horizonDays + LocalDate.daysUntil(date, anchor.date))
}

/// The occurrences the horizon top-up adds for one repeating task: the TAIL
/// only — dates after both its latest block (the frontier) and today, up to
/// today + horizonDays - 1, at the series' own time (recurrenceSeriesTime, or
/// `seriesTime` when the caller has just placed the series explicitly).
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
///   frontier's, which may be a moved or clamped one (C22).
/// - Today is never minted, matching regenerateForTask.
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
    if case .monthly = recurrence, let series = recurrenceSeriesDay(inHorizon) {
        start = monthlyStart(day: series.day, onOrBefore: frontier)
    }
    return materializeOccurrences(recurrence, startDate: LocalDate.parse(start), startTime: time,
                                  horizonDays: LocalDate.daysUntil(start, lastIso) + 1)
        .filter { $0.date > floor }
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
public func recurrenceChosenDateAction(existing: [CalBlock], plan: RegenPlan, iso: String, startTime: String) -> ChosenDateAction {
    if plan.toUpsert.contains(where: { $0.date == iso }) { return .covered }
    let deleting = Set(plan.toDelete)
    let onDay = existing.filter { $0.date == iso && isTaskBlock($0) && !deleting.contains($0.id) }
    let live = onDay.filter { !$0.done && !$0.skipped }
    if live.contains(where: { $0.startTime == startTime }) { return .covered }
    if let open = live.min(by: { $0.startTime < $1.startTime }) { return .retime(open) }
    if onDay.contains(where: { $0.done }) { return .covered }
    if let skipped = onDay.first(where: { $0.skipped }) { return .retime(skipped) }
    return .mint
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
