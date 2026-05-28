// Ported 1:1 from lib/visible-tasks.test.ts. Run with TZ=UTC for
// determinism (matches the web CI), same as `swift test` in CI.

import XCTest
@testable import UnstuckCore

final class VisibleTasksAreaAgnosticTests: XCTestCase {

    func testTodayShowsEveryAreaScheduledTodayEvenWithActiveArea() {
        let work = mkTask(id: "t-work", lifeArea: "Work")
        let personal = mkTask(id: "t-personal", lifeArea: "Personal")
        let home = mkTask(id: "t-home", lifeArea: "Home")
        let blocks = [
            mkBlock(id: "b1", taskId: "t-work"),
            mkBlock(id: "b2", taskId: "t-personal"),
            mkBlock(id: "b3", taskId: "t-home", date: todayPlus(1)),
        ]
        let out = visibleTasks(view: .today, tasks: [work, personal, home], blocks: blocks,
                               now: NOW, activeArea: "Work", slipMode: false)
        XCTAssertEqual(out.map(\.id).sorted(), ["t-personal", "t-work"])
        XCTAssertNil(out.first { $0.id == "t-home" })
    }

    func testAllViewStillHonoursActiveArea() {
        let work = mkTask(id: "t-work", lifeArea: "Work")
        let personal = mkTask(id: "t-personal", lifeArea: "Personal")
        let out = visibleTasks(view: .all, tasks: [work, personal], blocks: [],
                               now: NOW, activeArea: "Work", slipMode: false)
        XCTAssertEqual(out.map(\.id), ["t-work"])
    }

    func testUpcomingHonoursActiveArea() {
        let tomorrow = todayPlus(1)
        let work = mkTask(id: "t-work", lifeArea: "Work")
        let personal = mkTask(id: "t-personal", lifeArea: "Personal")
        let out = visibleTasks(view: .upcoming, tasks: [work, personal], blocks: [
            mkBlock(id: "b1", taskId: "t-work", date: tomorrow),
            mkBlock(id: "b2", taskId: "t-personal", date: tomorrow),
        ], now: NOW, activeArea: "Personal", slipMode: false)
        XCTAssertEqual(out.map(\.id), ["t-personal"])
    }
}

final class VisibleTasksOrderingTests: XCTestCase {

    func testAllViewOpenBeforeCompleted() {
        let completed = mkTask(id: "t-done", name: "Done thing", done: true, completedAt: iso(NOW))
        let open1 = mkTask(id: "t-open-1", name: "Open 1")
        let open2 = mkTask(id: "t-open-2", name: "Open 2")
        let out = visibleTasks(view: .all, tasks: [completed, open1, open2], blocks: [],
                               now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out.map(\.id), ["t-open-1", "t-open-2", "t-done"])
    }

    func testTodayViewOpenFirstCompletedFilteredOut() {
        let today = Clock.todayISO()
        let completed = mkTask(id: "t-done", done: true, completedAt: iso(NOW))
        let open = mkTask(id: "t-open")
        let out = visibleTasks(view: .today, tasks: [completed, open], blocks: [
            mkBlock(id: "b1", taskId: "t-done", date: today),
            mkBlock(id: "b2", taskId: "t-open", date: today),
        ], now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out.map(\.id), ["t-open"])
    }

    func testCompletedViewKeepsOrder() {
        let d1 = mkTask(id: "d1", done: true, completedAt: iso(NOW))
        let d2 = mkTask(id: "d2", done: true, completedAt: iso(NOW - 60_000))
        let out = visibleTasks(view: .completed, tasks: [d1, d2], blocks: [],
                               now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out.map(\.id), ["d1", "d2"])
    }
}

final class VisibleTasksTodayStrictTests: XCTestCase {

    func testTodayScheduledPlusCreatedTodayButNotOlderUnscheduled() {
        let scheduledToday = mkTask(id: "t-sched", createdAt: "2020-01-01T00:00:00.000Z")
        let freshUnscheduled = mkTask(id: "t-fresh", createdAt: iso(NOW))
        let oldUnscheduled = mkTask(id: "t-old", createdAt: "2020-01-01T00:00:00.000Z")
        let futureScheduled = mkTask(id: "t-future", createdAt: "2020-01-01T00:00:00.000Z")
        let blocks = [
            mkBlock(id: "b1", taskId: "t-sched", date: Clock.todayISO()),
            mkBlock(id: "b2", taskId: "t-future", date: todayPlus(1)),
        ]
        let out = visibleTasks(view: .today,
                               tasks: [scheduledToday, freshUnscheduled, oldUnscheduled, futureScheduled],
                               blocks: blocks, now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out.map(\.id).sorted(), ["t-fresh", "t-sched"])
    }

    func testTodayExcludesLaterEvenWhenScheduledToday() {
        let later = mkTask(id: "t-later", later: true)
        let out = visibleTasks(view: .today, tasks: [later], blocks: [
            mkBlock(id: "b1", taskId: "t-later", date: Clock.todayISO()),
        ], now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out, [])
    }

    func testLaterTabShowsOnlyLater() {
        let later = mkTask(id: "t-l", later: true)
        let not = mkTask(id: "t-n")
        let out = visibleTasks(view: .later, tasks: [later, not], blocks: [],
                               now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out.map(\.id), ["t-l"])
    }
}

final class VisibleTasksBacklogTests: XCTestCase {

    func testIncludesUnscheduledOlderThanToday() {
        let unscheduled = mkTask(id: "t-u", createdAt: "2020-01-01T00:00:00.000Z")
        let out = visibleTasks(view: .backlog, tasks: [unscheduled], blocks: [],
                               now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out.map(\.id), ["t-u"])
    }

    func testIncludesPastOnlyOverdue() {
        let overdue = mkTask(id: "t-old", createdAt: "2020-01-01T00:00:00.000Z")
        let out = visibleTasks(view: .backlog, tasks: [overdue], blocks: [
            mkBlock(id: "b1", taskId: "t-old", date: todayPlus(-1)),
        ], now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out.map(\.id), ["t-old"])
    }

    func testExcludesCreatedTodayEvenIfUnscheduled() {
        let fresh = mkTask(id: "t-fresh", createdAt: iso(NOW))
        let out = visibleTasks(view: .backlog, tasks: [fresh], blocks: [],
                               now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out.map(\.id), [])
    }

    func testExcludesTodayScheduled() {
        let scheduled = mkTask(id: "t-sched")
        let out = visibleTasks(view: .backlog, tasks: [scheduled], blocks: [
            mkBlock(id: "b1", taskId: "t-sched", date: Clock.todayISO()),
        ], now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out, [])
    }

    func testExcludesFutureScheduled() {
        let future = mkTask(id: "t-fut")
        let out = visibleTasks(view: .backlog, tasks: [future], blocks: [
            mkBlock(id: "b1", taskId: "t-fut", date: todayPlus(1)),
        ], now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out, [])
    }

    func testExcludesLaterEvenIfUnscheduled() {
        let later = mkTask(id: "t-l", later: true)
        let out = visibleTasks(view: .backlog, tasks: [later], blocks: [],
                               now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out, [])
    }

    func testExcludesDone() {
        let done = mkTask(id: "t-d", done: true)
        let out = visibleTasks(view: .backlog, tasks: [done], blocks: [],
                               now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out, [])
    }

    func testPastAndTodayBlockCountsAsTodayNotBacklog() {
        let mixed = mkTask(id: "t-mix")
        let out = visibleTasks(view: .backlog, tasks: [mixed], blocks: [
            mkBlock(id: "b1", taskId: "t-mix", date: todayPlus(-1)),
            mkBlock(id: "b2", taskId: "t-mix", date: Clock.todayISO()),
        ], now: NOW, activeArea: nil, slipMode: false)
        XCTAssertEqual(out, [])
    }
}

final class VisibleTasksTagFilterTests: XCTestCase {

    func testFiltersByTagCaseInsensitive() {
        var a = mkTask(id: "t-a", name: "a"); a.tags = ["deep-work"]
        var b = mkTask(id: "t-b", name: "b"); b.tags = ["phone-call"]
        var c = mkTask(id: "t-c", name: "c"); c.tags = ["deep-work", "client-x"]
        let out = visibleTasks(view: .all, tasks: [a, b, c], blocks: [],
                               now: NOW, activeArea: nil, activeTag: "Deep-Work", slipMode: false)
        XCTAssertEqual(out.map(\.id).sorted(), ["t-a", "t-c"])
    }

    func testAndCombinesTagAndArea() {
        var a = mkTask(id: "t-a", lifeArea: "Work"); a.tags = ["urgent"]
        var b = mkTask(id: "t-b", lifeArea: "Personal"); b.tags = ["urgent"]
        let out = visibleTasks(view: .all, tasks: [a, b], blocks: [],
                               now: NOW, activeArea: "Work", activeTag: "urgent", slipMode: false)
        XCTAssertEqual(out.map(\.id), ["t-a"])
    }

    func testEmptyWhenNoTaskCarriesTag() {
        var a = mkTask(id: "t-a"); a.tags = ["foo"]
        let out = visibleTasks(view: .all, tasks: [a], blocks: [],
                               now: NOW, activeArea: nil, activeTag: "bar", slipMode: false)
        XCTAssertEqual(out, [])
    }

    func testNilTagIsNoOp() {
        var a = mkTask(id: "t-a"); a.tags = ["foo"]
        let out = visibleTasks(view: .all, tasks: [a], blocks: [],
                               now: NOW, activeArea: nil, activeTag: nil, slipMode: false)
        XCTAssertEqual(out.map(\.id), ["t-a"])
    }
}

final class IsSlippingTests: XCTestCase {

    func testFlagsTasksMoved3Plus() {
        XCTAssertTrue(isSlipping(mkTask(moveCount: 3), now: NOW))
        XCTAssertFalse(isSlipping(mkTask(moveCount: 2), now: NOW))
    }

    func testFlagsTasksOlderThan21Days() {
        let old = mkTask(createdAt: "2026-04-01T00:00:00.000Z")
        XCTAssertTrue(isSlipping(old, now: NOW))
    }

    func testSkipsDoneTasks() {
        XCTAssertFalse(isSlipping(mkTask(done: true, moveCount: 9), now: NOW))
    }
}
