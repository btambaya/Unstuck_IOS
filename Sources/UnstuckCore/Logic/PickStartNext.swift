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
    areaFilter: String? = nil
) -> TaskItem? {
    let candidates = tasks
        // !later: a deferred task must never be the top "Start now"
        // suggestion (matches visible-tasks everywhere else).
        .filter { !$0.done && !($0.later ?? false) && $0.id != liveTaskId }
        .filter { matchesArea($0.lifeArea, areaFilter) }
    return candidates.sorted(by: ranksBefore).first
}

public func pickUpNext(
    tasks: [TaskItem],
    blocks: [CalBlock],
    liveTaskId: String?,
    startNextId: String?,
    limit: Int = 3
) -> [TaskItem] {
    var skip = Set<String>()
    if let liveTaskId { skip.insert(liveTaskId) }
    if let startNextId { skip.insert(startNextId) }
    let open = tasks.filter { !$0.done && !($0.later ?? false) && !skip.contains($0.id) }
    return Array(open.sorted(by: ranksBefore).prefix(limit))
}
