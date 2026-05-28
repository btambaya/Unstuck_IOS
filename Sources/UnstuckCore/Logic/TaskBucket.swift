// "Is this task in today's bucket?" helpers. Port of lib/task-bucket.ts.
// Used by the Today list + the /tasks "All" filter so they agree about
// when a completed task drops off the visible set.

import Foundation

public func isCompletedToday(_ task: TaskItem, now: EpochMillis) -> Bool {
    guard let completedAt = task.completedAt, let t = Time.parseMillis(completedAt) else { return false }
    let start = Time.startOfDayMillis(now)
    return t >= start && t < start + DAY_MS
}

/// True if the task was created during today's local-midnight window.
/// Lets freshly-created tasks (no cal_block yet) still surface in Today.
public func isCreatedToday(_ task: TaskItem, now: EpochMillis) -> Bool {
    guard let t = Time.parseMillis(task.createdAt) else { return false }
    let start = Time.startOfDayMillis(now)
    return t >= start && t < start + DAY_MS
}
