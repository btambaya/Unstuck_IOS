// Pure filter logic for the tasks list. Port of lib/visible-tasks.ts.
//
// Today is intentionally area-agnostic: even with an area filter active,
// the Today bucket surfaces tasks of every area that have a today-dated
// cal_block. The area filter only applies to All / Backlog / Upcoming /
// Later / Completed.

import Foundation

public enum TaskListView: String, Sendable, CaseIterable {
    case all = "All"
    case backlog = "Backlog"
    case today = "Today"
    case upcoming = "Upcoming"
    case later = "Later"
    case recurring = "Recurring"
    case completed = "Completed"
}

/// Sentinel area name for "no area assigned." Use via `matchesArea` so
/// callers don't special-case the sentinel string.
public let UNASSIGNED_AREA = "Unassigned"

private let SLIP_AGE_MS: Double = 21 * 24 * 60 * 60 * 1000
private let SLIP_MOVE_THRESHOLD = 3

/// Single source of truth for "does this task belong to this area
/// filter?". Handles the `UNASSIGNED_AREA` sentinel and the no-filter
/// case so `visibleTasks` + `pickStartNext` stay in sync.
public func matchesArea(_ taskArea: String?, _ activeArea: String?) -> Bool {
    guard let activeArea, !activeArea.isEmpty else { return true }
    if activeArea == UNASSIGNED_AREA { return (taskArea ?? "").isEmpty }
    return taskArea == activeArea
}

/// True if any of the task's tags matches the active tag (case-insensitive).
public func matchesTag(_ taskTags: [String]?, _ activeTag: String?) -> Bool {
    guard let activeTag, !activeTag.isEmpty else { return true }
    return (taskTags ?? []).contains { $0.lowercased() == activeTag.lowercased() }
}

public func isSlipping(_ task: TaskItem, now: EpochMillis) -> Bool {
    if task.done { return false }
    let moves = task.moveCount ?? 0
    if moves >= SLIP_MOVE_THRESHOLD { return true }
    guard let created = Time.parseMillis(task.createdAt) else { return false }
    return now - created >= SLIP_AGE_MS
}

/// Whole days between `task.createdAt` and `now` (0 for today, 1 for
/// yesterday, …). Used by the Backlog tab's "how long has this sat?".
public func daysSinceCreated(_ task: TaskItem, now: EpochMillis) -> Int {
    guard let created = Time.parseMillis(task.createdAt) else { return 0 }
    let diffMs = max(0, now - created)
    return Int((diffMs / (24 * 60 * 60 * 1000)).rounded(.down))
}

/// Everything `visibleTasks` derives from the task + block sets BEFORE it
/// knows which view is being asked for: the template/occurrence projections
/// and the scheduled-id sets. It is identical for every view, and building it
/// is the whole cost of the pass (the per-view step is one filter), so a
/// caller that needs several views — `TodayModel.recomputeSnapshot` asks for
/// `.today` AND `.backlog` on every tasks-or-blocks change — builds it once
/// and hands it to `visibleTasks(view:prep:…)` instead of paying for it twice.
///
/// Also pins `today` for the whole batch, so two views computed together can
/// no longer straddle local midnight and disagree about what "today" is.
public struct VisibleTasksPrep: Sendable {
    let tasks: [TaskItem]
    let today: String
    let nonTemplates: [TaskItem]
    let todayOccurrences: [TaskItem]
    let upcomingOccurrences: [TaskItem]
    let overdueOccurrences: [TaskItem]
    let todayTaskIds: Set<String>
    let upcomingTaskIds: Set<String>
    let scheduledTaskIds: Set<String>
    let pastOnlyTaskIds: Set<String>

    public init(tasks: [TaskItem], blocks: [CalBlock]) {
        let today = Clock.todayISO()
        self.tasks = tasks
        self.today = today
        self.nonTemplates = tasks.filter { !isTemplate($0) }
        let templateIds = Set(tasks.filter { $0.recurrence != nil }.map { $0.id })

        // Recurring occurrences surface ONLY in Today (the due day) + the single
        // NEXT upcoming one in Upcoming — never in All / Backlog / Later / Completed
        // (a repeating task would otherwise list once per horizon date). The template
        // itself lives only in the Recurring view. occurrence row id == its block id.
        let occBlocks = blocks.filter {
            isTaskBlock($0) && !$0.skipped && ($0.taskId.map { templateIds.contains($0) } ?? false) && $0.date >= today
        }
        let todayOccIds = Set(occBlocks.filter { $0.date == today }.map { $0.id })
        // template id -> its earliest FUTURE, STILL-OPEN occurrence block. Done
        // occurrences are skipped HERE, not filtered after the pick: choosing
        // tomorrow's block and only then dropping it for being done removed the
        // whole series from Upcoming (ticking one future occurrence hid the
        // daily task) instead of advancing to the next open one.
        var nextPerTemplate: [String: CalBlock] = [:]
        for b in occBlocks where b.date > today && !b.done {
            guard let tid = b.taskId else { continue }
            if let cur = nextPerTemplate[tid], cur.date <= b.date { continue }
            nextPerTemplate[tid] = b
        }
        let nextUpcomingOccIds = Set(nextPerTemplate.values.map { $0.id })
        let projected = projectOccurrences(tasks, blocks, fromISO: today)
        self.todayOccurrences = projected.filter { todayOccIds.contains($0.id) }
        self.upcomingOccurrences = projected.filter { nextUpcomingOccIds.contains($0.id) }
        // Missed recurring occurrences: one overdue row per template whose most-
        // recent past occurrence went undone — surfaced in Backlog so a skipped
        // "every Friday" task doesn't silently vanish until next Friday.
        self.overdueOccurrences = projectOverdueOccurrences(tasks, blocks, todayISO: today)

        // Non-template task bucketing — over NON-recurring task blocks only (an
        // occurrence block's taskId is its template, never a row in these buckets).
        let taskBlocks = blocks.filter { isTaskBlock($0) && !($0.taskId.map { templateIds.contains($0) } ?? false) }
        let todayTaskIds = Set(taskBlocks.filter { $0.date == today }.compactMap { $0.taskId })
        let upcomingTaskIds = Set(taskBlocks.filter { $0.date > today }.compactMap { $0.taskId })
        let scheduledTaskIds = Set(taskBlocks.compactMap { $0.taskId })
        self.todayTaskIds = todayTaskIds
        self.upcomingTaskIds = upcomingTaskIds
        self.scheduledTaskIds = scheduledTaskIds
        // Tasks whose only task-shaped cal_blocks are dated before today —
        // planned for a past day but never done. These are "overdue" → Backlog.
        var pastOnlyTaskIds = Set<String>()
        for id in scheduledTaskIds where !todayTaskIds.contains(id) && !upcomingTaskIds.contains(id) {
            pastOnlyTaskIds.insert(id)
        }
        self.pastOnlyTaskIds = pastOnlyTaskIds
    }
}

public func visibleTasks(
    view: TaskListView,
    tasks: [TaskItem],
    blocks: [CalBlock],
    now: EpochMillis,
    activeArea: String?,
    activeTag: String? = nil,
    slipMode: Bool
) -> [TaskItem] {
    visibleTasks(view: view, prep: VisibleTasksPrep(tasks: tasks, blocks: blocks),
                 now: now, activeArea: activeArea, activeTag: activeTag, slipMode: slipMode)
}

/// The same filter, against an already-built `VisibleTasksPrep`. Identical
/// output to the array-taking overload — it IS the same code, with the shared
/// half hoisted into `prep`.
public func visibleTasks(
    view: TaskListView,
    prep: VisibleTasksPrep,
    now: EpochMillis,
    activeArea: String?,
    activeTag: String? = nil,
    slipMode: Bool
) -> [TaskItem] {
    let tasks = prep.tasks
    let nonTemplates = prep.nonTemplates
    let todayOccurrences = prep.todayOccurrences
    let upcomingOccurrences = prep.upcomingOccurrences
    let overdueOccurrences = prep.overdueOccurrences
    let todayTaskIds = prep.todayTaskIds
    let upcomingTaskIds = prep.upcomingTaskIds
    let scheduledTaskIds = prep.scheduledTaskIds
    let pastOnlyTaskIds = prep.pastOnlyTaskIds

    let byView: [TaskItem]
    switch view {
    case .recurring:
        // The repeating definitions themselves (area/tag still narrow it).
        byView = tasks.filter { isTemplate($0) }
    case .today:
        // Scheduled today OR created today (fresh arrivals count), but not tasks
        // scheduled for a future day — plus today's recurring occurrences.
        let nt = nonTemplates.filter { t in
            !t.done && !(t.later ?? false) && (
                todayTaskIds.contains(t.id) ||
                (isCreatedToday(t, now: now) && !upcomingTaskIds.contains(t.id))
            )
        }
        // Today's occurrence STAYS in the bucket once ticked (the same rule the
        // Today tab's own list uses): dropping it on completion made it vanish
        // from /tasks entirely — Completed and All never showed occurrence rows
        // — so the win was invisible and no row was left to un-tick it from.
        byView = nt + todayOccurrences.filter { !$0.done || isCompletedToday($0, now: now) }
    case .backlog:
        // Open work not actively planned AND sitting ≥ a day: never scheduled, or
        // only ever scheduled in the past (overdue). PLUS one overdue row per
        // recurring template whose most-recent occurrence was missed.
        let nt = nonTemplates.filter { t in
            !t.done && !(t.later ?? false) && !isCreatedToday(t, now: now) && (
                !scheduledTaskIds.contains(t.id) || pastOnlyTaskIds.contains(t.id)
            )
        }
        byView = nt + overdueOccurrences
    case .upcoming:
        // Future-scheduled tasks + the single NEXT occurrence per recurring series.
        let nt = nonTemplates.filter { t in
            !t.done && upcomingTaskIds.contains(t.id) && !todayTaskIds.contains(t.id)
        }
        byView = nt + upcomingOccurrences.filter { !$0.done }
    case .later:
        byView = nonTemplates.filter { !$0.done && ($0.later ?? false) == true }
    case .completed:
        // Occurrence rows carry their own done/completedAt (on the cal_block),
        // so a ticked recurring occurrence belongs here too — otherwise it
        // existed in no /tasks view at all.
        byView = nonTemplates.filter { $0.done } + todayOccurrences.filter { $0.done }
    case .all:
        // The master list of distinct tasks — NO per-day occurrence rows.
        byView = nonTemplates.filter { !$0.done || isCompletedToday($0, now: now) }
    }

    // Today is area-agnostic on purpose.
    let afterArea = view == .today ? byView : byView.filter { matchesArea($0.lifeArea, activeArea) }

    // Tag filter applies to EVERY view including Today — an explicit
    // narrowing the user opted into.
    let afterTag: [TaskItem]
    if let activeTag, !activeTag.isEmpty {
        afterTag = afterArea.filter { ($0.tags ?? []).contains { $0.lowercased() == activeTag.lowercased() } }
    } else {
        afterTag = afterArea
    }

    let afterSlip = slipMode ? afterTag.filter { isSlipping($0, now: now) } : afterTag

    // Open tasks first, then completed — preserving original order within
    // each bucket (the web relies on a STABLE sort here; Swift's sort is
    // not guaranteed stable, so partition by hand to match exactly).
    let open = afterSlip.filter { !$0.done }
    let closed = afterSlip.filter { $0.done }
    return open + closed
}
