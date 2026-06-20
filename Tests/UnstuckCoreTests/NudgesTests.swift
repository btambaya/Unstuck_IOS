// Pure tests for computeNudges (the only Logic file with no dedicated test).
// `now` is injected, so every case is deterministic. Mirrors the Android
// computeNudges contract: slipping = open, non-recurring tasks older than 3
// weeks OR rescheduled 3+ times; capped at the first 3; recurring templates
// (recurrence != nil) never slip.

import XCTest
@testable import UnstuckCore

final class ComputeNudgesTests: XCTestCase {
    // A fixed reference "now" so age math is deterministic regardless of TZ.
    private let now: EpochMillis = Time.parseMillis("2026-05-21T12:00:00.000Z")!

    private func recurringTask(id: String) -> TaskItem {
        var t = mkTask(id: id, name: "Daily standup", createdAt: iso(now - 40 * DAY_MS))
        t.recurrence = .daily(until: nil)
        return t
    }

    func testFlagsTaskOlderThan21Days() {
        let old = mkTask(id: "t1", name: "Old", createdAt: iso(now - 30 * DAY_MS))
        let out = computeNudges(tasks: [old], captures: [], now: now)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, .slipping)
        XCTAssertEqual(out[0].taskId, "t1")
        XCTAssertEqual(out[0].id, "slip:t1")
        XCTAssertEqual(out[0].action, "Open")
    }

    func testFlagsRescheduled3Plus() {
        // Created today (not old) but moved 3 times → still slips.
        let moved = mkTask(id: "t1", name: "Moved", createdAt: iso(now), moveCount: 3)
        XCTAssertEqual(computeNudges(tasks: [moved], captures: [], now: now).count, 1)
    }

    func testIgnoresFreshLowMoveTasks() {
        let fresh = mkTask(id: "t1", name: "Fresh", createdAt: iso(now - 5 * DAY_MS), moveCount: 2)
        XCTAssertTrue(computeNudges(tasks: [fresh], captures: [], now: now).isEmpty)
    }

    func testIgnoresDoneTasks() {
        let doneOld = mkTask(id: "t1", done: true, createdAt: iso(now - 30 * DAY_MS), moveCount: 9)
        XCTAssertTrue(computeNudges(tasks: [doneOld], captures: [], now: now).isEmpty)
    }

    func testIgnoresRecurringTemplates() {
        // A hidden recurring template is old + moved a lot but must NOT slip.
        var tpl = recurringTask(id: "t1")
        tpl.moveCount = 9
        XCTAssertTrue(computeNudges(tasks: [tpl], captures: [], now: now).isEmpty)
    }

    func testCapsAtThree() {
        let tasks = (0..<5).map { mkTask(id: "t\($0)", name: "Old \($0)", createdAt: iso(now - 30 * DAY_MS)) }
        XCTAssertEqual(computeNudges(tasks: tasks, captures: [], now: now).count, 3)
    }

    func testPreservesInputOrder() {
        // No re-sort: nudges come out in task order, capped to the first 3.
        let tasks = (0..<4).map { mkTask(id: "t\($0)", name: "Old \($0)", createdAt: iso(now - 30 * DAY_MS)) }
        let out = computeNudges(tasks: tasks, captures: [], now: now)
        XCTAssertEqual(out.map(\.taskId), ["t0", "t1", "t2"])
    }

    func testUnparseableCreatedAtCountsAsAgeZero() {
        // A task whose createdAt can't be parsed has ageDays 0, so it only slips
        // on moveCount — never on age.
        let bad = mkTask(id: "t1", name: "Bad date", createdAt: "not-a-date", moveCount: 0)
        XCTAssertTrue(computeNudges(tasks: [bad], captures: [], now: now).isEmpty)
        let badMoved = mkTask(id: "t2", name: "Bad date moved", createdAt: "not-a-date", moveCount: 3)
        XCTAssertEqual(computeNudges(tasks: [badMoved], captures: [], now: now).count, 1)
    }

    func testTitleQuotesTaskName() {
        let old = mkTask(id: "t1", name: "Taxes", createdAt: iso(now - 30 * DAY_MS))
        let out = computeNudges(tasks: [old], captures: [], now: now)
        XCTAssertTrue(out[0].title.contains("Taxes"), "title should reference the task name")
    }
}
