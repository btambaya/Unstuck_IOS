// Deterministic "what should I work on next?" ranker. Port of
// lib/pick-start-next.ts. Same logic powers the dashboard Start Next
// card, the Up Next list, the /tasks NEXT badge, and the focus-mode UP
// NEXT panel — so every surface agrees.
//
// Rules: exclude done + Later + currently-focused tasks, honour the
// active area filter, then rank by priority desc → estimateMin asc →
// createdAt asc.

import Foundation

private func priorityRank(_ p: Priority?) -> Int {
    switch p ?? .low {
    case .urgent: return 4
    case .high: return 3
    case .medium: return 2
    case .low: return 1
    }
}

/// `true` if `a` should rank before `b`. ISO `createdAt` strings sort
/// lexicographically == chronologically, matching the web's
/// `localeCompare` tiebreak.
private func ranksBefore(_ a: TaskItem, _ b: TaskItem) -> Bool {
    let ar = priorityRank(a.priority), br = priorityRank(b.priority)
    if ar != br { return ar > br }
    if a.estimateMin != b.estimateMin { return a.estimateMin < b.estimateMin }
    return a.createdAt < b.createdAt
}

public func pickStartNext(
    tasks: [TaskItem],
    blocks: [CalBlock],
    liveTaskId: String?,
    areaFilter: String? = nil,
    excludeIds: Set<String>? = nil
) -> TaskItem? {
    let candidates = tasks
        // !later: a deferred task must never be the top "Start now"
        // suggestion. recurrence == nil: skip hidden recurring TEMPLATES —
        // their per-day occurrences surface in Today on their own.
        // excludeIds: tasks you've assigned away — they're someone else's now.
        .filter { !$0.done && !($0.later ?? false) && $0.recurrence == nil && $0.id != liveTaskId
            && !(excludeIds?.contains($0.id) ?? false) }
        .filter { matchesArea($0.lifeArea, areaFilter) }
    return candidates.sorted(by: ranksBefore).first
}

public func pickUpNext(
    tasks: [TaskItem],
    blocks: [CalBlock],
    liveTaskId: String?,
    startNextId: String?,
    limit: Int = 3,
    excludeIds: Set<String>? = nil
) -> [TaskItem] {
    var skip = Set<String>()
    if let liveTaskId { skip.insert(liveTaskId) }
    if let startNextId { skip.insert(startNextId) }
    // excludeIds: tasks you've assigned away — no longer your work to queue up.
    let open = tasks.filter { !$0.done && !($0.later ?? false) && $0.recurrence == nil && !skip.contains($0.id)
        && !(excludeIds?.contains($0.id) ?? false) }
    return Array(open.sorted(by: ranksBefore).prefix(limit))
}

/// The Today "Start Next" hero pick — scoped to TODAY, never the backlog:
///  1. If any task is SCHEDULED today (a cal_block dated today, incl. a recurring
///     occurrence), return the NEXT by start time — the soonest start ≥ the
///     current time, else the earliest of the day if all of today's are past.
///  2. Else, among today's UNscheduled tasks (created today, no block today),
///     return the lowest-friction one — the shortest estimate.
///  3. Else nil — the caller shows a "check your Backlog" pointer instead of
///     pulling a backlog task into the hero.
public func pickTodayHero(
    tasks: [TaskItem],
    blocks: [CalBlock],
    now: EpochMillis,
    liveTaskId: String? = nil,
    areaFilter: String? = nil,
    excludeIds: Set<String>? = nil
) -> TaskItem? {
    // Today's open rows (non-template today tasks + today's occurrences), minus
    // the live-focused task and anything assigned away, narrowed by the active area.
    let rows = visibleTasks(view: .today, tasks: tasks, blocks: blocks, now: now,
                            activeArea: nil, slipMode: false)
        .filter { $0.id != liveTaskId && !(excludeIds?.contains($0.id) ?? false)
            && matchesArea($0.lifeArea, areaFilter) }
    if rows.isEmpty { return nil }

    let today = Clock.todayISO()
    let todayBlocks = blocks.filter { isTaskBlock($0) && $0.date == today && !$0.skipped }
    // A row's today start time: an occurrence row's id IS its block id; a normal
    // task matches by taskId (its earliest block today).
    func startToday(_ row: TaskItem) -> String? {
        if let b = todayBlocks.first(where: { $0.id == row.id }) { return b.startTime }
        return todayBlocks.filter { $0.taskId == row.id }.map(\.startTime).min()
    }
    let scheduled = rows.compactMap { row in startToday(row).map { (row, $0) } }

    if !scheduled.isEmpty {
        let nowHHMM = currentLocalHHMM(now)
        let upcoming = scheduled.filter { $0.1 >= nowHHMM }       // still ahead today
        let pool = upcoming.isEmpty ? scheduled : upcoming        // all past → earliest of the day
        return pool.min { a, b in a.1 != b.1 ? a.1 < b.1 : ranksBefore(a.0, b.0) }?.0
    }
    // No scheduled-today: lowest friction = shortest estimate (shared tiebreak after).
    return rows.min { a, b in a.estimateMin != b.estimateMin ? a.estimateMin < b.estimateMin : ranksBefore(a, b) }
}

/// Current LOCAL time as "HH:MM" — for comparing against cal_block start times
/// (which are stored in the device's local timezone).
private func currentLocalHHMM(_ now: EpochMillis) -> String {
    let date = Date(timeIntervalSince1970: now / 1000)
    let c = Foundation.Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}
