// What the calendar's "Edit block" sheet offers for a tapped block besides its
// time chips: Mark done / Mark not done, Start focus and Open task — the three
// things a Today row does (its circle, its Focus, its tap). Ahmad, 2026-09-24:
// "Can't complete a task from calendar." Web reference:
// components/calendar/cal-block-edit-modal.tsx (Start now · Mark complete ·
// Open in tasks).
//
// Every action works on the ROW Today shows for the block (`taskForBlock`):
// the one-day OCCURRENCE row (id = cal_block id) for a repeating series, else
// the task itself. Handing that row to the app's existing paths keeps them one
// path:
//   • toggle → AppModel.toggleDone(row) — an occurrence id flips THAT day's
//     cal_block (never the series); a plain task flips the stored task row;
//   • focus  → router.beginFocus(row) — FocusView resolves the occurrence, so
//     its Done ticks the day;
//   • open   → router.detailTask = row — the editor opens on that day.
//
// External / placeholder blocks (Google events, block-time) have no task: nil,
// no actions. A task I have ASSIGNED to someone else is theirs to finish (T3):
// it keeps Open but loses Mark done and Start focus, as in the task editor and
// Today (which lists it under Delegated, with no circle).

import Foundation

public struct CalBlockTaskActions: Equatable, Sendable {
    /// The row every action hands on — the day's occurrence row for a series.
    public let row: TaskItem
    /// The block is one day of a repeating series.
    public let isOccurrence: Bool
    /// Done as Today shows it: the day's block for an occurrence, else the task.
    public let done: Bool
    /// Mark done / Mark not done is offered.
    public let canToggleDone: Bool
    /// Start focus is offered.
    public let canFocus: Bool

    public init(row: TaskItem, isOccurrence: Bool, done: Bool, canToggleDone: Bool, canFocus: Bool) {
        self.row = row
        self.isOccurrence = isOccurrence
        self.done = done
        self.canToggleDone = canToggleDone
        self.canFocus = canFocus
    }

    /// The toggle's label — the same words as Today's circle.
    public var toggleLabel: String { done ? "Mark not done" : "Mark done" }
}

/// The Edit-block sheet's task actions for `block`, or nil when it has none (an
/// external / placeholder block, or a task block whose task is not in `tasks`).
public func calBlockTaskActions(_ block: CalBlock, tasks: [TaskItem],
                                assignedOutIds: Set<String> = []) -> CalBlockTaskActions? {
    guard isTaskBlock(block),
          let task = tasks.first(where: { $0.id == block.taskId }),
          let row = taskForBlock(block, tasks: tasks) else { return nil }
    let isOccurrence = task.recurrence != nil
    // Occurrences are never assigned out; only a real task with an outgoing
    // assign share is gated (the editor's isAssignedOut rule).
    let assignedOut = !isOccurrence && assignedOutIds.contains(task.id)
    return CalBlockTaskActions(row: row, isOccurrence: isOccurrence, done: row.done,
                               canToggleDone: !assignedOut, canFocus: !assignedOut)
}
