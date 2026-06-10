// Parity with lib/occurrences.test.ts / OccurrencesTest.kt.

import XCTest
@testable import UnstuckCore

final class OccurrencesTests: XCTestCase {
    private func template() -> TaskItem {
        var t = mkTask(id: "t1", name: "Water plants", tags: ["home"], lifeArea: "Personal")
        t.recurrence = .daily(until: nil)
        return t
    }
    private func block(_ id: String, _ date: String, done: Bool = false, skipped: Bool = false,
                       completedAt: String? = nil, duration: Int = 10, taskId: String = "t1") -> CalBlock {
        CalBlock(id: id, taskId: taskId, taskName: "Water plants", startTime: "09:00",
                 durationMinutes: duration, date: date, kind: .task, done: done, skipped: skipped, completedAt: completedAt)
    }

    func testTemplateDetection() {
        XCTAssertTrue(isTemplate(template()))
        XCTAssertFalse(isTemplate(mkTask(id: "t2")))
    }

    func testProjectsOneRowPerBlockWithTemplateFields() {
        let blocks = [block("b1", "2026-06-10"), block("b2", "2026-06-11")]
        let out = projectOccurrences([template()], blocks, fromISO: "2026-06-10")
        XCTAssertEqual(out.map(\.id), ["b1", "b2"])
        XCTAssertEqual(out[0].name, "Water plants")
        XCTAssertEqual(out[0].tags, ["home"])
        XCTAssertEqual(out[0].lifeArea, "Personal")
        XCTAssertNil(out[0].recurrence)
    }

    func testTakesDoneAndEstimateFromBlock() {
        let b = block("b1", "2026-06-10", done: true, completedAt: "2026-06-10T10:00:00.000Z", duration: 40)
        let occ = projectOccurrences([template()], [b], fromISO: "2026-06-10")[0]
        XCTAssertTrue(occ.done)
        XCTAssertEqual(occ.completedAt, "2026-06-10T10:00:00.000Z")
        XCTAssertEqual(occ.estimateMin, 40)
    }

    func testExcludesSkippedAndPast() {
        let blocks = [
            block("past", "2026-06-09"),
            block("skip", "2026-06-10", skipped: true),
            block("ok", "2026-06-10"),
        ]
        XCTAssertEqual(projectOccurrences([template()], blocks, fromISO: "2026-06-10").map(\.id), ["ok"])
    }

    func testOccurrenceBlockForResolvesOnlyTemplateBlocks() {
        let tplBlock = block("b1", "2026-06-10")
        let normal = mkTask(id: "t2")
        let normalBlock = block("b2", "2026-06-10", taskId: "t2")
        XCTAssertEqual(occurrenceBlockFor("b1", tasks: [template(), normal], blocks: [tplBlock, normalBlock])?.id, "b1")
        XCTAssertNil(occurrenceBlockFor("b2", tasks: [template(), normal], blocks: [tplBlock, normalBlock]))
    }

    func testTaskForBlockReturnsOccurrenceForTemplate() {
        let occ = taskForBlock(block("b1", "2026-06-10"), tasks: [template()])
        XCTAssertEqual(occ?.id, "b1")
        XCTAssertNil(occ?.recurrence)
    }

    func testRecurringViewReturnsTemplatesOnly() {
        let tpl = template()
        let blocks = [block("b1", todayPlus(0)), block("b2", todayPlus(1))]
        let recurring = visibleTasks(view: .recurring, tasks: [tpl], blocks: blocks, now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(recurring.map(\.id), ["t1"])
        // Today shows the occurrence, NOT the template.
        let today = visibleTasks(view: .today, tasks: [tpl], blocks: blocks, now: NOW, activeArea: nil, slipMode: false)
        XCTAssertTrue(today.contains { $0.id == "b1" })
        XCTAssertFalse(today.contains { $0.id == "t1" })
    }
}
