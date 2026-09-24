// The calendar Edit-block sheet's task actions (Mark done / Mark not done,
// Start focus, Open task) — which row they act on and when they're offered.
// Ahmad, 2026-09-24: "Can't complete a task from calendar."

import XCTest
@testable import UnstuckCore

final class CalBlockActionsTests: XCTestCase {
    private func series(id: String = "tpl", done: Bool = false) -> TaskItem {
        var t = mkTask(id: id, name: "Take vitamins", estimateMin: 5, done: done, lifeArea: "Health")
        t.recurrence = .daily(until: nil)
        return t
    }

    private func block(_ id: String, task: String, done: Bool = false, duration: Int = 30,
                       kind: CalBlockKind? = .task, external: String? = nil) -> CalBlock {
        CalBlock(id: id, taskId: task, taskName: "x", startTime: "09:00", durationMinutes: duration,
                 date: "2026-09-24", externalEventId: external, kind: kind, done: done,
                 completedAt: done ? "2026-09-24T09:30:00.000Z" : nil)
    }

    // MARK: plain task

    func testAPlainTaskBlockActsOnTheTaskItself() throws {
        let task = mkTask(id: "t1", name: "Reply to Sarah")
        let a = try XCTUnwrap(calBlockTaskActions(block("b1", task: "t1"), tasks: [task]))
        XCTAssertEqual(a.row, task, "the row Today shows — the task, untouched")
        XCTAssertFalse(a.isOccurrence)
        XCTAssertFalse(a.done)
        XCTAssertTrue(a.canToggleDone)
        XCTAssertTrue(a.canFocus)
        XCTAssertEqual(a.toggleLabel, "Mark done")
    }

    func testADonePlainTaskOffersMarkNotDone() throws {
        let task = mkTask(id: "t1", done: true, completedAt: "2026-09-24T09:00:00.000Z")
        let a = try XCTUnwrap(calBlockTaskActions(block("b1", task: "t1"), tasks: [task]))
        XCTAssertTrue(a.done)
        XCTAssertTrue(a.canToggleDone, "a done task can be reopened, like Today's circle")
        XCTAssertEqual(a.toggleLabel, "Mark not done")
    }

    /// A plain task's completion lives on the TASK — a stale `done` on its
    /// block never makes the sheet say it's done.
    func testAPlainTaskReadsDoneFromTheTaskNotTheBlock() throws {
        let task = mkTask(id: "t1")
        let a = try XCTUnwrap(calBlockTaskActions(block("b1", task: "t1", done: true), tasks: [task]))
        XCTAssertFalse(a.done)
        XCTAssertEqual(a.toggleLabel, "Mark done")
    }

    // MARK: recurring occurrence

    /// A day of a repeating series acts on that DAY's row (id = block id,
    /// recurrence cleared), never the hidden template — so Mark done can't
    /// end the series and Focus carries the day's block.
    func testAnOccurrenceBlockActsOnThatDaysRow() throws {
        let tpl = series()
        let a = try XCTUnwrap(calBlockTaskActions(block("occ-24", task: "tpl", duration: 10), tasks: [tpl]))
        XCTAssertTrue(a.isOccurrence)
        XCTAssertEqual(a.row.id, "occ-24", "the occurrence row, not the template")
        XCTAssertNil(a.row.recurrence)
        XCTAssertEqual(a.row.name, "Take vitamins")
        XCTAssertEqual(a.row.estimateMin, 10, "the day's own duration")
        XCTAssertFalse(a.done)
        XCTAssertEqual(a.toggleLabel, "Mark done")
        XCTAssertTrue(a.canToggleDone)
        XCTAssertTrue(a.canFocus)
    }

    func testADoneOccurrenceOffersMarkNotDone() throws {
        let a = try XCTUnwrap(calBlockTaskActions(block("occ-24", task: "tpl", done: true), tasks: [series()]))
        XCTAssertTrue(a.done)
        XCTAssertTrue(a.row.done)
        XCTAssertEqual(a.row.completedAt, "2026-09-24T09:30:00.000Z")
        XCTAssertEqual(a.toggleLabel, "Mark not done")
    }

    /// The day's completion lives on its block: a sibling day's tick (or the
    /// template) never leaks into this day.
    func testAnOccurrenceReadsDoneFromItsOwnBlock() throws {
        let tpl = series()
        let today = block("occ-24", task: "tpl")
        XCTAssertEqual(calBlockTaskActions(today, tasks: [tpl])?.done, false)
        var tomorrow = block("occ-25", task: "tpl", done: true)
        tomorrow.date = "2026-09-25"
        XCTAssertEqual(calBlockTaskActions(tomorrow, tasks: [tpl])?.done, true)
    }

    /// A series the old path ENDED (its template done) still has its days: each
    /// reads its own block, so an untouched day is open, not struck.
    func testAnEndedSeriesDayReadsItsOwnBlockNotTheTemplate() throws {
        let a = try XCTUnwrap(calBlockTaskActions(block("occ-24", task: "tpl"), tasks: [series(done: true)]))
        XCTAssertTrue(a.isOccurrence)
        XCTAssertFalse(a.done)
        XCTAssertEqual(a.toggleLabel, "Mark done")
    }

    // MARK: blockIsDone — the grids' strike rule (web lib/occurrences blockIsDone)

    func testBlockIsDoneOnARepeatingDayIsItsOwnBlock() {
        XCTAssertTrue(blockIsDone(block("occ", task: "tpl", done: true), task: series()))
        XCTAssertFalse(blockIsDone(block("occ", task: "tpl"), task: series()))
        XCTAssertFalse(blockIsDone(block("occ", task: "tpl"), task: series(done: true)),
                       "an ended series' flag never strikes its days")
    }

    /// A ticked day whose series was turned off (the block keeps done = true),
    /// then reopened: the one-off's slot follows the TASK, so reopening it from
    /// the sheet un-strikes the block on the grid.
    func testBlockIsDoneOnAOneOffFollowsTheTask() {
        XCTAssertTrue(blockIsDone(block("b1", task: "t1"), task: mkTask(id: "t1", done: true)))
        XCTAssertFalse(blockIsDone(block("b1", task: "t1", done: true), task: mkTask(id: "t1")))
    }

    func testBlockIsDoneWithNoTaskIsFalse() {
        XCTAssertFalse(blockIsDone(block("b1", task: "gone", done: true), task: nil))
    }

    /// The sheet's done and the grid's strike are one rule.
    func testTheSheetAndTheGridAgree() {
        let tpl = series(done: true), plain = mkTask(id: "t1")
        let cases: [(CalBlock, TaskItem)] = [
            (block("occ-a", task: "tpl"), tpl), (block("occ-b", task: "tpl", done: true), tpl),
            (block("b1", task: "t1", done: true), plain),
            (block("b2", task: "t2"), mkTask(id: "t2", done: true)),
        ]
        for (b, t) in cases {
            XCTAssertEqual(calBlockTaskActions(b, tasks: [t])?.done, blockIsDone(b, task: t), b.id)
        }
    }

    // MARK: no actions

    func testAnExternalEventHasNoActions() {
        let task = mkTask(id: "t1")
        let google = CalBlock(id: "g_abc", taskId: nil, taskName: "Standup", startTime: "09:00",
                              durationMinutes: 15, date: "2026-09-24", externalEventId: "abc", kind: .external)
        XCTAssertNil(calBlockTaskActions(google, tasks: [task]))
        // A legacy row with no stored kind is still read as external by its event id.
        let legacy = CalBlock(id: "g_def", taskId: "t1", taskName: "Standup", startTime: "09:00",
                              durationMinutes: 15, date: "2026-09-24", externalEventId: "def")
        XCTAssertNil(calBlockTaskActions(legacy, tasks: [task]))
    }

    func testAPlaceholderBlockHasNoActions() {
        let ph = CalBlock(id: "p1", taskId: "placeholder", taskName: "Hold", startTime: "09:00",
                          durationMinutes: 30, date: "2026-09-24")
        XCTAssertNil(calBlockTaskActions(ph, tasks: [mkTask(id: "placeholder")]))
    }

    func testABlockWhoseTaskIsGoneHasNoActions() {
        XCTAssertNil(calBlockTaskActions(block("b1", task: "deleted"), tasks: [mkTask(id: "t1")]))
    }

    // MARK: shared — assigned out (T3)

    /// A task I've assigned to someone is theirs to finish: Open stays (the
    /// row is still there), Mark done and Start focus go — the editor's rule.
    func testATaskIAssignedOutKeepsOpenOnly() throws {
        let task = mkTask(id: "t1")
        let a = try XCTUnwrap(calBlockTaskActions(block("b1", task: "t1"), tasks: [task], assignedOutIds: ["t1"]))
        XCTAssertEqual(a.row.id, "t1")
        XCTAssertFalse(a.canToggleDone)
        XCTAssertFalse(a.canFocus)
    }

    func testAnotherTasksAssignmentDoesNotGateThisOne() throws {
        let a = try XCTUnwrap(calBlockTaskActions(block("b1", task: "t1"), tasks: [mkTask(id: "t1")],
                                                  assignedOutIds: ["t2"]))
        XCTAssertTrue(a.canToggleDone)
        XCTAssertTrue(a.canFocus)
    }

    /// Occurrences are never assigned out — the series id in the set can't
    /// take the day's actions away.
    func testAnOccurrenceIsNeverGatedByAnAssignment() throws {
        let a = try XCTUnwrap(calBlockTaskActions(block("occ-24", task: "tpl"), tasks: [series()],
                                                  assignedOutIds: ["tpl", "occ-24"]))
        XCTAssertTrue(a.canToggleDone)
        XCTAssertTrue(a.canFocus)
    }
}
