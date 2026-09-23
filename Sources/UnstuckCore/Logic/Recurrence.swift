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
/// least 28 days from the next; a daily one has no room.
private func occurrenceReach(_ r: Recurrence) -> Int {
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
