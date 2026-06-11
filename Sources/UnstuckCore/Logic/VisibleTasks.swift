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

public func visibleTasks(
    view: TaskListView,
    tasks: [TaskItem],
    blocks: [CalBlock],
    now: EpochMillis,
    activeArea: String?,
    activeTag: String? = nil,
    slipMode: Bool
) -> [TaskItem] {
    let today = Clock.todayISO()
    let nonTemplates = tasks.filter { !isTemplate($0) }
    let templateIds = Set(tasks.filter { $0.recurrence != nil }.map { $0.id })

    // Recurring occurrences surface ONLY in Today (the due day) + the single
    // NEXT upcoming one in Upcoming — never in All / Backlog / Later / Completed
    // (a repeating task would otherwise list once per horizon date). The template
    // itself lives only in the Recurring view. occurrence row id == its block id.
    let occBlocks = blocks.filter {
        isTaskBlock($0) && !$0.skipped && ($0.taskId.map { templateIds.contains($0) } ?? false) && $0.date >= today
    }
    let todayOccIds = Set(occBlocks.filter { $0.date == today }.map { $0.id })
    var nextPerTemplate: [String: CalBlock] = [:]   // template id -> its earliest FUTURE occurrence block
    for b in occBlocks where b.date > today {
        guard let tid = b.taskId else { continue }
        if let cur = nextPerTemplate[tid], cur.date <= b.date { continue }
        nextPerTemplate[tid] = b
    }
    let nextUpcomingOccIds = Set(nextPerTemplate.values.map { $0.id })
    let projected = projectOccurrences(tasks, blocks, fromISO: today)
    let todayOccurrences = projected.filter { todayOccIds.contains($0.id) }
    let upcomingOccurrences = projected.filter { nextUpcomingOccIds.contains($0.id) }

    // Non-template task bucketing — over NON-recurring task blocks only (an
    // occurrence block's taskId is its template, never a row in these buckets).
    let taskBlocks = blocks.filter { isTaskBlock($0) && !($0.taskId.map { templateIds.contains($0) } ?? false) }
    let todayTaskIds = Set(taskBlocks.filter { $0.date == today }.compactMap { $0.taskId })
    let upcomingTaskIds = Set(taskBlocks.filter { $0.date > today }.compactMap { $0.taskId })
    let scheduledTaskIds = Set(taskBlocks.compactMap { $0.taskId })
    // Tasks whose only task-shaped cal_blocks are dated before today —
    // planned for a past day but never done. These are "overdue" → Backlog.
    var pastOnlyTaskIds = Set<String>()
    for id in scheduledTaskIds where !todayTaskIds.contains(id) && !upcomingTaskIds.contains(id) {
        pastOnlyTaskIds.insert(id)
    }

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
        byView = nt + todayOccurrences.filter { !$0.done }
    case .backlog:
        // Open work not actively planned AND sitting ≥ a day: never scheduled, or
        // only ever scheduled in the past (overdue). No recurring occurrences.
        byView = nonTemplates.filter { t in
            !t.done && !(t.later ?? false) && !isCreatedToday(t, now: now) && (
                !scheduledTaskIds.contains(t.id) || pastOnlyTaskIds.contains(t.id)
            )
        }
    case .upcoming:
        // Future-scheduled tasks + the single NEXT occurrence per recurring series.
        let nt = nonTemplates.filter { t in
            !t.done && upcomingTaskIds.contains(t.id) && !todayTaskIds.contains(t.id)
        }
        byView = nt + upcomingOccurrences.filter { !$0.done }
    case .later:
        byView = nonTemplates.filter { !$0.done && ($0.later ?? false) == true }
    case .completed:
        byView = nonTemplates.filter { $0.done }
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
