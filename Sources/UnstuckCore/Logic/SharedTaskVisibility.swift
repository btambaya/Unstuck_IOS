// Where a shared task shows up once it's completed — the same rules the user's
// OWN tasks follow (VisibleTasks / TaskBucket): Today hides completed work,
// "All" keeps today's wins visible (struck, last) and ages older ones out, and
// Completed is where finished things live. Applies whoever ticked it — owner or
// an assign/partner recipient (Ahmad, 2026-08-02: completed shared tasks should
// move to Completed "for all, like all other tasks").
//
// Port of lib/shared-task-visibility.ts (+ its .test.ts). Pure; `completedAt`
// is optional so the client behaves correctly against an RPC that hasn't been
// migrated yet (migration 049) — without a timestamp a completed share simply
// leaves the active lists.

import Foundation

/// Which list a shared row is being rendered inside.
public enum ShareViewMode: String, Sendable, Equatable, CaseIterable {
    case today
    case all
    case completed

    /// The task-list view a shared group is mounted in → its share mode.
    /// Only All / Today / Completed mount the group (1:1 with the web
    /// task-list-pane); any other view degrades to `.all`.
    public init(_ view: TaskListView) {
        switch view {
        case .completed: self = .completed
        case .today: self = .today
        default: self = .all
        }
    }
}

/// The two fields the visibility rule reads. `SharedWithMe` conforms; tests
/// (and any future projection) can supply their own row.
public protocol ShareVisibilityItem {
    var done: Bool { get }
    /// ISO completion time, when the projection provides one.
    var completedAt: String? { get }
}

extension SharedWithMe: ShareVisibilityItem {}

/// True when a shared row with this state belongs in the given view.
public func shareVisibleIn(done: Bool, completedAt: String?, mode: ShareViewMode, now: EpochMillis) -> Bool {
    if mode == .completed { return done }
    if !done { return true }
    // Completed rows: only "finished today" lingers, and only in All —
    // mirroring isCompletedToday() for the user's own tasks. A missing or
    // unparseable timestamp means it simply leaves the active lists.
    if mode == .today { return false }
    guard let completedAt, let t = Time.parseMillis(completedAt) else { return false }
    let start = Time.startOfDayMillis(now)
    return t >= start && t < start + DAY_MS
}

/// True when this shared row belongs in the given view.
public func shareVisibleIn<T: ShareVisibilityItem>(_ item: T, _ mode: ShareViewMode, now: EpochMillis) -> Bool {
    shareVisibleIn(done: item.done, completedAt: item.completedAt, mode: mode, now: now)
}

/// Filter + order a shared list for a view: open first, completed last (never
/// park struck-through rows above the next thing to do). The web relies on a
/// STABLE sort here; Swift's sort is not guaranteed stable, so partition by
/// hand to match exactly (same shape as `visibleTasks`).
public func visibleShares<T: ShareVisibilityItem>(
    _ items: [T],
    mode: ShareViewMode,
    now: EpochMillis = Date().timeIntervalSince1970 * 1000
) -> [T] {
    let kept = items.filter { shareVisibleIn($0, mode, now: now) }
    return kept.filter { !$0.done } + kept.filter { $0.done }
}
