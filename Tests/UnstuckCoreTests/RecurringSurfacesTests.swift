// Regression cases for the 2026-09-12 cross-platform core review (the web's
// lib/visible-tasks.recurring.test.ts + lib/use-focus-timer.occurrence.test.ts
// + lib/use-tasks.delete-and-schedule.test.ts, ported to the iOS rules):
//
//  • a focus deep link must resolve a repeating series to an OCCURRENCE row,
//    never to the hidden template (whose "Done" would end the whole series)
//    and never to an id nothing can resolve;
//  • Upcoming must advance to the next OPEN occurrence when one is ticked;
//  • a completed occurrence must still appear somewhere in /tasks;
//  • scheduling a task parked in Later must un-park it.
//
// Run with TZ=UTC (the `swift test` CI setting), like the other ported cases.

import XCTest
@testable import UnstuckCore

final class FocusRowResolutionTests: XCTestCase {

    private let today = Clock.todayISO()
    private var tomorrow: String { LocalDate.addDays(today, 1) }

    private func template() -> TaskItem {
        var t = mkTask(id: "tpl", name: "Daily review")
        t.recurrence = .daily(until: nil)
        return t
    }

    private func occ(_ id: String, _ date: String, done: Bool = false, skipped: Bool = false) -> CalBlock {
        CalBlock(id: id, taskId: "tpl", taskName: "Daily review", startTime: "09:00",
                 durationMinutes: 25, date: date, kind: .task, done: done, skipped: skipped,
                 completedAt: done ? iso(NOW) : nil)
    }

    /// The starts-now notification's "Start" action carries the BLOCK's taskId
    /// — the hidden template for a repeating series. Focusing the template ran
    /// the session with no occurrence attached, so "Done" marked the template
    /// done (ending the series) and left today's occurrence open.
    func testTemplateIdResolvesToTodaysOccurrenceRow() {
        let blocks = [occ("b-today", today), occ("b-tomorrow", tomorrow)]
        let row = focusRowForId("tpl", tasks: [template()], blocks: blocks, todayISO: today)
        XCTAssertEqual(row?.id, "b-today")       // the occurrence, not the template
        XCTAssertNil(row?.recurrence)            // a plain one-day row
        XCTAssertEqual(row?.name, "Daily review")
    }

    /// The assistant re-opens a live session on its occurrence ROW id (a
    /// cal_block id), which a bare task fetch could never resolve — it silently
    /// landed on Today instead of the running session.
    func testOccurrenceBlockIdResolvesToThatOccurrence() {
        let blocks = [occ("b-today", today), occ("b-tomorrow", tomorrow)]
        let row = focusRowForId("b-tomorrow", tasks: [template()], blocks: blocks, todayISO: today)
        XCTAssertEqual(row?.id, "b-tomorrow")
    }

    func testTodaysTickedOccurrenceFallsThroughToTheNextOpenOne() {
        let blocks = [occ("b-today", today, done: true), occ("b-tomorrow", tomorrow)]
        XCTAssertEqual(focusRowForId("tpl", tasks: [template()], blocks: blocks, todayISO: today)?.id, "b-tomorrow")
    }

    func testSkippedOccurrencesAreNeverPicked() {
        let blocks = [occ("b-today", today, skipped: true), occ("b-tomorrow", tomorrow)]
        XCTAssertEqual(focusRowForId("tpl", tasks: [template()], blocks: blocks, todayISO: today)?.id, "b-tomorrow")
    }

    func testTemplateWithNoOccurrencesFallsBackToItself() {
        XCTAssertEqual(focusRowForId("tpl", tasks: [template()], blocks: [], todayISO: today)?.id, "tpl")
    }

    func testPlainTaskAndItsBlockBothResolveToTheTask() {
        let t = mkTask(id: "t1", name: "Write memo")
        let b = mkBlock(id: "b1", taskId: "t1", date: today)
        XCTAssertEqual(focusRowForId("t1", tasks: [t], blocks: [b], todayISO: today)?.id, "t1")
        XCTAssertEqual(focusRowForId("b1", tasks: [t], blocks: [b], todayISO: today)?.id, "t1")
    }

    func testUnknownAndEmptyIdsResolveToNothing() {
        let t = mkTask(id: "t1")
        XCTAssertNil(focusRowForId("nope", tasks: [t], blocks: [], todayISO: today))
        XCTAssertNil(focusRowForId("", tasks: [t], blocks: [], todayISO: today))
    }
}

final class RecurringVisibilityTests: XCTestCase {

    private let today = Clock.todayISO()
    private var tomorrow: String { LocalDate.addDays(today, 1) }
    private var dayAfter: String { LocalDate.addDays(today, 2) }

    private func template() -> TaskItem {
        var t = mkTask(id: "tpl", name: "Daily review")
        t.recurrence = .daily(until: nil)
        return t
    }

    private func occ(_ id: String, _ date: String, done: Bool = false, completedAt: String? = nil) -> CalBlock {
        CalBlock(id: id, taskId: "tpl", taskName: "Daily review", startTime: "09:00",
                 durationMinutes: 25, date: date, kind: .task, done: done,
                 completedAt: done ? (completedAt ?? iso(Date().timeIntervalSince1970 * 1000)) : nil)
    }

    /// Upcoming picked the earliest future occurrence and only THEN dropped it
    /// for being done, so ticking tomorrow's occurrence removed the whole
    /// series from Upcoming instead of advancing to the day after.
    func testUpcomingAdvancesPastATickedFutureOccurrence() {
        let blocks = [occ("b-tomorrow", tomorrow, done: true), occ("b-after", dayAfter)]
        let out = visibleTasks(view: .upcoming, tasks: [template()], blocks: blocks,
                               now: Date().timeIntervalSince1970 * 1000, activeArea: nil, slipMode: false)
        XCTAssertEqual(out.map(\.id), ["b-after"])
    }

    /// A completed occurrence used to appear in NO /tasks view at all: Today
    /// filtered it out, and Completed / All never carry occurrence rows.
    func testTickedTodayOccurrenceStaysInTodayAndShowsUnderCompleted() {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let blocks = [occ("b-today", today, done: true)]
        let todayRows = visibleTasks(view: .today, tasks: [template()], blocks: blocks,
                                     now: nowMs, activeArea: nil, slipMode: false)
        XCTAssertEqual(todayRows.map(\.id), ["b-today"])
        XCTAssertTrue(todayRows[0].done)
        let completed = visibleTasks(view: .completed, tasks: [template()], blocks: blocks,
                                     now: nowMs, activeArea: nil, slipMode: false)
        XCTAssertEqual(completed.map(\.id), ["b-today"])
    }

    /// An OPEN occurrence still belongs to Today only — never to Completed.
    func testOpenTodayOccurrenceIsNotCompleted() {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let blocks = [occ("b-today", today)]
        XCTAssertEqual(visibleTasks(view: .today, tasks: [template()], blocks: blocks,
                                    now: nowMs, activeArea: nil, slipMode: false).map(\.id), ["b-today"])
        XCTAssertTrue(visibleTasks(view: .completed, tasks: [template()], blocks: blocks,
                                   now: nowMs, activeArea: nil, slipMode: false).isEmpty)
    }
}

final class UnparkOnScheduleTests: XCTestCase {

    private let today = Clock.todayISO()

    /// Scheduling a task parked in Later left `later` set, so it sat on the
    /// calendar while every active list (Today / Backlog / Upcoming / the Today
    /// tab / Start-Next) filtered it out as deferred.
    func testSchedulingAParkedTaskClearsTheLaterFlag() {
        let parked = mkTask(id: "t1", later: true)
        let block = mkBlock(id: "b1", taskId: "t1", date: today)
        let next = unparkedTaskForBlock(block, tasks: [parked], nowISO: "2026-09-12T10:00:00.000Z")
        XCTAssertEqual(next?.id, "t1")
        XCTAssertEqual(next?.later, false)
        XCTAssertEqual(next?.updatedAt, "2026-09-12T10:00:00.000Z")
        // …and the task then shows up in Today rather than only in Later.
        let nowMs = Date().timeIntervalSince1970 * 1000
        XCTAssertTrue(visibleTasks(view: .today, tasks: [parked], blocks: [block],
                                   now: nowMs, activeArea: nil, slipMode: false).isEmpty)
        XCTAssertEqual(visibleTasks(view: .today, tasks: [next!], blocks: [block],
                                    now: nowMs, activeArea: nil, slipMode: false).map(\.id), ["t1"])
    }

    func testNothingToWriteForATaskThatIsNotParked() {
        let t = mkTask(id: "t1")
        XCTAssertNil(unparkedTaskForBlock(mkBlock(id: "b1", taskId: "t1"), tasks: [t], nowISO: "x"))
    }

    /// A recurring TEMPLATE's occurrence blocks are generated by the horizon
    /// regen, not a scheduling decision — never un-park on those.
    func testRecurringTemplatesAreLeftAlone() {
        var tpl = mkTask(id: "tpl", later: true)
        tpl.recurrence = .daily(until: nil)
        let b = mkBlock(id: "b1", taskId: "tpl", date: today)
        XCTAssertNil(unparkedTaskForBlock(b, tasks: [tpl], nowISO: "x"))
    }

    /// External (g_) calendar events and placeholder blocks carry no task.
    func testNonTaskBlocksAndUnknownTasksAreIgnored() {
        let parked = mkTask(id: "t1", later: true)
        let external = CalBlock(id: "g_1", taskId: nil, taskName: "Standup", startTime: "09:00",
                                durationMinutes: 15, date: today, kind: .external)
        XCTAssertNil(unparkedTaskForBlock(external, tasks: [parked], nowISO: "x"))
        XCTAssertNil(unparkedTaskForBlock(mkBlock(id: "b1", taskId: "ghost"), tasks: [parked], nowISO: "x"))
    }
}

// ── verifier pass, 2026-09-12 ────────────────────────────────────────────────
// Three holes the port of the web review left open on iOS.

final class RecurringFollowUpTests: XCTestCase {

    private let today = Clock.todayISO()

    private func template(_ id: String = "tpl") -> TaskItem {
        var t = mkTask(id: id, name: "Daily review")
        t.recurrence = .daily(until: nil)
        return t
    }

    /// Today now KEEPS a ticked occurrence (so the win stays visible and can be
    /// un-ticked), and the hero is fed that very bucket — so without an explicit
    /// `!done` it started offering "Start: Daily review" for work already done,
    /// and starting it minted a session on a finished day.
    func testHeroNeverOffersAnAlreadyCompletedOccurrence() {
        let now = Date().timeIntervalSince1970 * 1000
        let doneOcc = CalBlock(id: "occ", taskId: "tpl", taskName: "Daily review", startTime: "07:00",
                               durationMinutes: 25, date: today, kind: .task, done: true,
                               completedAt: iso(now))
        let plain = mkTask(id: "plain", estimateMin: 45, createdAt: iso(now))
        // The bucket really does still carry the ticked occurrence…
        let todayRows = visibleTasks(view: .today, tasks: [template(), plain], blocks: [doneOcc],
                                     now: now, activeArea: nil, slipMode: false)
        XCTAssertTrue(todayRows.contains { $0.id == "occ" && $0.done })
        // …and the hero skips straight past it.
        XCTAssertEqual(pickTodayHero(tasks: [template(), plain], blocks: [doneOcc], now: now)?.id, "plain")
        // With nothing else open today there is no hero at all — not the done one.
        XCTAssertNil(pickTodayHero(tasks: [template()], blocks: [doneOcc], now: now))
    }

    /// The move-count bump is a WHOLE-ROW upsert issued alongside the async
    /// un-park, so it has to be built from the CLEARED row — bumping the
    /// caller's pre-un-park snapshot wrote `later: true` straight back and put
    /// the freshly-scheduled task back into hiding.
    func testTheMoveBumpCarriesTheClearedLaterFlag() {
        let parked = mkTask(id: "t1", later: true)
        let moved = mkBlock(id: "b1", taskId: "t1", date: today)
        let now = "2026-09-12T10:00:00.000Z"
        let owner = unparkedTaskForBlock(moved, tasks: [parked], nowISO: now) ?? parked
        let bumped = bumpMoveCount(owner, nowISO: now)
        XCTAssertEqual(bumped.later, false, "the bump must not resurrect the Later parking")
        XCTAssertEqual(bumped.moveCount, 1)
        // A task that was never parked is bumped exactly as before.
        let plain = mkTask(id: "t2", moveCount: 3)
        let owner2 = unparkedTaskForBlock(mkBlock(id: "b2", taskId: "t2"), tasks: [plain], nowISO: now) ?? plain
        XCTAssertEqual(bumpMoveCount(owner2, nowISO: now).moveCount, 4)
        XCTAssertNil(bumpMoveCount(owner2, nowISO: now).later)
    }

    /// Finishing focus with "Done" on a row that resolved to NO occurrence block
    /// must never flip a TEMPLATE's own `done` — that ends the whole series.
    /// Reachable from the notification's "Start" once today's occurrence has
    /// been ticked or skipped, which is exactly when no block resolves.
    func testFocusDoneNeverCompletesARecurringTemplateRow() {
        XCTAssertFalse(focusMayCompleteRow(template()))
        XCTAssertTrue(focusMayCompleteRow(mkTask(id: "t1")))
        // A projected occurrence ROW is a plain one-day row — still completable.
        let occ = mkBlock(id: "occ", taskId: "tpl", date: today)
        let row = focusRowForId("tpl", tasks: [template()], blocks: [occ], todayISO: today)
        XCTAssertEqual(row?.id, "occ")
        XCTAssertTrue(focusMayCompleteRow(row!))
    }
}
