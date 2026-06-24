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

    // MARK: projectOverdueOccurrences — missed recurring surfaces once
    // Parity with lib/occurrences.test.ts "projectOverdueOccurrences" block.

    /// A weekly (Fri) recurring template — matches the web's `tmpl`.
    private func weeklyTemplate() -> TaskItem {
        var t = mkTask(id: "t1", name: "Call mom", lifeArea: "Personal")
        t.recurrence = .weekly(daysOfWeek: [5], until: nil)
        return t
    }
    private let TODAY = "2026-06-12"

    func testOverdueSurfacesOneRowForMostRecentMiss() {
        let blocks = [
            block("b1", "2026-06-05"),   // older miss
            block("b2", "2026-06-11"),   // most-recent miss
        ]
        let out = projectOverdueOccurrences([weeklyTemplate()], blocks, todayISO: TODAY)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "b2")
        XCTAssertFalse(out[0].done)
        XCTAssertNil(out[0].recurrence)
        XCTAssertEqual(out[0].name, "Call mom")
        XCTAssertEqual(out[0].lifeArea, "Personal")
    }

    func testOverdueDoesNotStackAcrossMultipleMisses() {
        let blocks = [
            block("b1", "2026-05-29"),
            block("b2", "2026-06-05"),
            block("b3", "2026-06-11"),
        ]
        XCTAssertEqual(projectOverdueOccurrences([weeklyTemplate()], blocks, todayISO: TODAY).count, 1)
    }

    func testOverdueSupersededByTodayOccurrence() {
        let blocks = [
            block("b1", "2026-06-11"),    // missed
            block("b2", TODAY),           // today's occurrence takes over
        ]
        XCTAssertEqual(projectOverdueOccurrences([weeklyTemplate()], blocks, todayISO: TODAY).count, 0)
    }

    func testOverdueClearsWhenMostRecentPastIsDone() {
        let blocks = [
            block("b1", "2026-06-05"),                  // older, still undone
            block("b2", "2026-06-11", done: true),      // most-recent, done
        ]
        XCTAssertEqual(projectOverdueOccurrences([weeklyTemplate()], blocks, todayISO: TODAY).count, 0)
    }

    func testOverdueClearsWhenMostRecentPastSkipped() {
        let blocks = [block("b2", "2026-06-11", skipped: true)]
        XCTAssertEqual(projectOverdueOccurrences([weeklyTemplate()], blocks, todayISO: TODAY).count, 0)
    }

    func testOverdueNoneForFutureOnlyOccurrences() {
        let blocks = [block("b1", "2026-06-19")]
        XCTAssertEqual(projectOverdueOccurrences([weeklyTemplate()], blocks, todayISO: TODAY).count, 0)
    }

    func testOverdueIgnoresNonRecurringTasks() {
        let normal = mkTask(id: "t1")   // no recurrence
        let blocks = [block("b1", "2026-06-11")]
        XCTAssertEqual(projectOverdueOccurrences([normal], blocks, todayISO: TODAY).count, 0)
    }

    func testOverdueDatesMapsRowIdToOccurrenceDate() {
        let blocks = [
            block("b1", "2026-06-05"),
            block("b2", "2026-06-11"),
        ]
        let dates = overdueOccurrenceDates([weeklyTemplate()], blocks, todayISO: TODAY)
        XCTAssertEqual(dates, ["b2": "2026-06-11"])
    }

    // Backlog wiring: a missed recurring occurrence surfaces in Backlog (and
    // nowhere else), and is cleared by a today occurrence.
    func testBacklogSurfacesMissedRecurringOccurrence() {
        let tpl = weeklyTemplate()
        // most-recent past occurrence (yesterday) is undone → one overdue row.
        let blocks = [mkBlock(id: "occ", taskId: "t1", date: todayPlus(-1), kind: .task)]
        let backlog = visibleTasks(view: .backlog, tasks: [tpl], blocks: blocks,
                                   now: Date().timeIntervalSince1970 * 1000, activeArea: nil, slipMode: false)
        XCTAssertEqual(backlog.map(\.id), ["occ"])
        // Not in Today (no today occurrence) and never in All.
        let today = visibleTasks(view: .today, tasks: [tpl], blocks: blocks,
                                 now: Date().timeIntervalSince1970 * 1000, activeArea: nil, slipMode: false)
        XCTAssertFalse(today.contains { $0.id == "occ" })
        let all = visibleTasks(view: .all, tasks: [tpl], blocks: blocks,
                               now: Date().timeIntervalSince1970 * 1000, activeArea: nil, slipMode: false)
        XCTAssertTrue(all.isEmpty)
    }

    func testBacklogOverdueClearedByTodayOccurrence() {
        let tpl = weeklyTemplate()
        let blocks = [
            mkBlock(id: "missed", taskId: "t1", date: todayPlus(-1), kind: .task),
            mkBlock(id: "live", taskId: "t1", date: todayPlus(0), kind: .task),
        ]
        let backlog = visibleTasks(view: .backlog, tasks: [tpl], blocks: blocks,
                                   now: Date().timeIntervalSince1970 * 1000, activeArea: nil, slipMode: false)
        XCTAssertFalse(backlog.contains { $0.id == "missed" }, "today's occurrence supersedes the stale miss")
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

    // Recurring occurrences must NOT flood All (a Friday task once per horizon).
    func testRecurringAbsentFromAll() {
        let tpl = template()   // daily
        let blocks = [block("b0", todayPlus(0)), block("b1", todayPlus(1)), block("b2", todayPlus(2))]
        let all = visibleTasks(view: .all, tasks: [tpl], blocks: blocks, now: NOW, activeArea: nil, slipMode: false)
        XCTAssertTrue(all.isEmpty, "neither the template nor its occurrences belong in All")
        // A normal task still appears in All alongside the recurring series.
        let normal = mkTask(id: "n1", createdAt: "2026-05-21T10:00:00.000Z")
        let all2 = visibleTasks(view: .all, tasks: [tpl, normal], blocks: blocks, now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(all2.map(\.id), ["n1"])
    }

    // Upcoming shows only the SINGLE next occurrence per series, not the horizon.
    func testUpcomingShowsOnlyNextOccurrence() {
        let tpl = template()
        let blocks = [block("b1", todayPlus(1)), block("b2", todayPlus(2)), block("b3", todayPlus(3))]
        let up = visibleTasks(view: .upcoming, tasks: [tpl], blocks: blocks, now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(up.map(\.id), ["b1"])
    }

    // MARK: pickTodayHero (today-scoped, never backlog)

    func testHeroPrefersScheduledOverShorterUnscheduled() {
        let sched = mkTask(id: "sched", estimateMin: 25)   // scheduled today (longer)
        let quick = mkTask(id: "quick", estimateMin: 5)    // created today, unscheduled (shorter)
        let blocks = [mkBlock(id: "bs", taskId: "sched", startTime: "16:00", date: todayPlus(0))]
        let hero = pickTodayHero(tasks: [sched, quick], blocks: blocks, now: NOW)
        XCTAssertEqual(hero?.id, "sched", "a scheduled-today task wins over a shorter unscheduled one")
    }

    func testHeroShortestWhenNoneScheduled() {
        let a = mkTask(id: "a", estimateMin: 25)
        let b = mkTask(id: "b", estimateMin: 10)
        let hero = pickTodayHero(tasks: [a, b], blocks: [], now: NOW)
        XCTAssertEqual(hero?.id, "b", "lowest-friction (shortest estimate) when nothing is scheduled today")
    }

    func testHeroNilWhenNoTodayTasks() {
        let old = mkTask(id: "old", createdAt: "2026-04-01T10:00:00.000Z")   // backlog, not today
        XCTAssertNil(pickTodayHero(tasks: [old], blocks: [], now: NOW), "the hero never pulls from the backlog")
    }
}
