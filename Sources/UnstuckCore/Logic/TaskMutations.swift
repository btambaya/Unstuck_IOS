// Pure task-mutation rules from lib/use-tasks.ts: the done-flip
// completedAt stamping and the reschedule move-count bump. The web hook
// wraps these with localStorage + Supabase writes; the rules themselves
// are pure and injected with `nowISO` for determinism.

import Foundation

/// First done-flip captures the completion time; subsequent toggles
/// preserve the original. Un-completing CLEARS the timestamp so a later
/// re-completion re-stamps fresh (otherwise a stale date suppresses the
/// "completed today" win and mis-dates analytics).
public func stampCompletion(isDone: Bool, incomingCompletedAt: String?, priorCompletedAt: String?, nowISO: String) -> String? {
    isDone ? (incomingCompletedAt ?? priorCompletedAt ?? nowISO) : nil
}

/// Apply the completion stamp + bump updatedAt to `item`, given its prior
/// stored version (for the preserve-original-timestamp rule).
public func applyCompletion(_ item: TaskItem, prior: TaskItem?, nowISO: String) -> TaskItem {
    var next = item
    next.completedAt = stampCompletion(
        isDone: item.done,
        incomingCompletedAt: item.completedAt,
        priorCompletedAt: prior?.completedAt,
        nowISO: nowISO)
    next.updatedAt = nowISO
    return next
}

/// Increment a task's reschedule counter (feeds the slip detector).
public func bumpMoveCount(_ task: TaskItem, nowISO: String) -> TaskItem {
    var next = task
    next.moveCount = (task.moveCount ?? 0) + 1
    next.updatedAt = nowISO
    return next
}
