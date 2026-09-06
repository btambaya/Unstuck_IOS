// Hands-free write rules: the widget/Siri completion resolver (raw rows AND
// projected recurring occurrences), the "may this unresolved op be dropped"
// gate, the Siri entity relevance order, and the support-notify category rule.

import XCTest
@testable import UnstuckCore

final class HandsFreeWritesTests: XCTestCase {
    // MARK: - resolveHandsFreeCompletion

    func testResolvesARawTaskRow() {
        let t = mkTask(id: "t1", name: "Call dentist")
        XCTAssertEqual(resolveHandsFreeCompletion(id: "t1", tasks: [t], blocks: []), .task(t))
    }

    func testResolvesARecurringOccurrenceByItsBlockId() {
        // The widget's Start-Next tile carries the OCCURRENCE id (a cal_block
        // id) when a recurring task is scheduled today — the drain used to
        // look only at raw rows, miss, and silently drop the completion.
        var tpl = mkTask(id: "tpl", name: "Daily review")
        tpl.recurrence = .daily(until: nil)
        let block = mkBlock(id: "blk-today", taskId: "tpl", taskName: "Daily review", date: todayPlus(0))
        XCTAssertEqual(resolveHandsFreeCompletion(id: "blk-today", tasks: [tpl], blocks: [block]),
                       .occurrence(block))
    }

    func testResolvesAPastOccurrenceToo() {
        // A missed yesterday occurrence surfaced in Backlog is still one block.
        var tpl = mkTask(id: "tpl")
        tpl.recurrence = .daily(until: nil)
        let block = mkBlock(id: "blk-yday", taskId: "tpl", date: todayPlus(-1))
        XCTAssertEqual(resolveHandsFreeCompletion(id: "blk-yday", tasks: [tpl], blocks: [block]),
                       .occurrence(block))
    }

    func testNeverResolvesTheTemplateItself() {
        // Completing the template would end the whole series.
        var tpl = mkTask(id: "tpl")
        tpl.recurrence = .daily(until: nil)
        XCTAssertNil(resolveHandsFreeCompletion(id: "tpl", tasks: [tpl], blocks: []))
    }

    func testPlainBlockOfANonRecurringTaskIsNotAnOccurrence() {
        let t = mkTask(id: "t1")
        let block = mkBlock(id: "b1", taskId: "t1")
        XCTAssertNil(resolveHandsFreeCompletion(id: "b1", tasks: [t], blocks: [block]))
    }

    func testUnknownIdIsNil() {
        XCTAssertNil(resolveHandsFreeCompletion(id: "nope", tasks: [mkTask(id: "t1")], blocks: []))
    }

    // MARK: - handsFreeWriteMayDrop

    func testUnresolvedOpIsKeptUntilTheStoreIsHydrated() {
        XCTAssertFalse(handsFreeWriteMayDrop(targetFound: false, storeHydrated: false))
        XCTAssertTrue(handsFreeWriteMayDrop(targetFound: false, storeHydrated: true))
        XCTAssertTrue(handsFreeWriteMayDrop(targetFound: true, storeHydrated: false))
        XCTAssertTrue(handsFreeWriteMayDrop(targetFound: true, storeHydrated: true))
    }

    // MARK: - siriTaskOrder

    func testTodayThenDueThenMostRecentlyUpdated() {
        let old = mkTask(id: "old", updatedAt: "2026-05-01T10:00:00.000Z")
        let newer = mkTask(id: "newer", updatedAt: "2026-05-20T10:00:00.000Z")
        var dueLater = mkTask(id: "dueLater", updatedAt: "2026-05-02T10:00:00.000Z")
        dueLater.dueAt = "2026-06-10T09:00:00.000Z"
        var dueSoon = mkTask(id: "dueSoon", updatedAt: "2026-05-03T10:00:00.000Z")
        dueSoon.dueAt = "2026-05-25T09:00:00.000Z"
        let today = mkTask(id: "today", updatedAt: "2026-04-01T10:00:00.000Z")

        let ordered = siriTaskOrder([old, newer, dueLater, dueSoon, today], todayIds: ["today"])
        XCTAssertEqual(ordered.map(\.id), ["today", "dueSoon", "dueLater", "newer", "old"])
    }

    func testNewestTasksSurviveTheCap() {
        // 70 open tasks, created oldest-first; the newest must be in the first 50.
        var tasks: [TaskItem] = []
        for i in 0..<70 {
            let stamp = String(format: "2026-05-%02dT%02d:00:00.000Z", 1 + i / 24, i % 24)
            tasks.append(mkTask(id: "t\(i)", createdAt: stamp, updatedAt: stamp))
        }
        let capped = Array(siriTaskOrder(tasks, todayIds: []).prefix(50))
        XCTAssertTrue(capped.contains { $0.id == "t69" })
        XCTAssertFalse(capped.contains { $0.id == "t0" })
    }

    func testOrderIsStableForTies() {
        let a = mkTask(id: "a"), b = mkTask(id: "b"), c = mkTask(id: "c")
        XCTAssertEqual(siriTaskOrder([a, b, c], todayIds: []).map(\.id), ["a", "b", "c"])
    }

    // MARK: - feedbackNotifiesSupport

    func testReportAndBugPageSupport() {
        XCTAssertTrue(feedbackNotifiesSupport(category: "report"))
        XCTAssertTrue(feedbackNotifiesSupport(category: "bug"))
        XCTAssertTrue(feedbackNotifiesSupport(category: " Bug "))
        XCTAssertFalse(feedbackNotifiesSupport(category: "idea"))
        XCTAssertFalse(feedbackNotifiesSupport(category: nil))
        XCTAssertFalse(feedbackNotifiesSupport(category: ""))
    }
}
