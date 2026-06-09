// Reconcile rules for the Google calendar pull — port of the Android
// SyncCoordinator.pullCalendar edge cases (spec 02-sync-engine §1.8):
// own-event filter, all-day skip, and the keep-set deletion reconcile.

import XCTest
@testable import UnstuckCore

final class CalendarPullReconcileTests: XCTestCase {
    private let fromYmd = "2026-06-02"
    private let toYmd = "2026-07-09"

    private func ev(_ id: String, summary: String = "Standup",
                    start: String = "2026-06-10T09:00:00.000Z",
                    end: String = "2026-06-10T09:30:00.000Z") -> ExternalEvent {
        ExternalEvent(id: id, connectionId: "conn_1", calendarId: "primary",
                      summary: summary, start: start, end: end)
    }

    func testMapsPulledEventsToExternalGBlocks() {
        let plan = reconcileCalendarPull(events: [ev("e1")], localBlocks: [],
                                         fromYmd: fromYmd, toYmd: toYmd)
        XCTAssertEqual(plan.toUpsert.map(\.id), ["g_e1"])
        XCTAssertEqual(plan.toUpsert.first?.kind, .external)
        XCTAssertTrue(plan.toDelete.isEmpty)
    }

    func testSkipsEventsTheAppPushedItself() {
        // The originating task block already represents the pushed event —
        // mirroring it would put a duplicate g_ block next to it.
        var own = mkBlock(id: "b1", taskId: "t1", date: "2026-06-10", kind: .task)
        own.externalEventId = "e1"
        let plan = reconcileCalendarPull(events: [ev("e1"), ev("e2")], localBlocks: [own],
                                         fromYmd: fromYmd, toYmd: toYmd)
        XCTAssertEqual(plan.toUpsert.map(\.id), ["g_e2"])
    }

    func testSkipsAllDayEvents() {
        // Date-only start (no 'T') — would collapse to a 15-min 00:00 sliver.
        let allDay = ev("e1", start: "2026-06-10", end: "2026-06-11")
        let plan = reconcileCalendarPull(events: [allDay], localBlocks: [],
                                         fromYmd: fromYmd, toYmd: toYmd)
        XCTAssertTrue(plan.toUpsert.isEmpty)
    }

    func testDropsInWindowExternalsGoogleNoLongerReturns() {
        let stale = mkBlock(id: "g_gone", taskId: nil, date: "2026-06-15", kind: .external)
        let outOfWindow = mkBlock(id: "g_old", taskId: nil, date: "2026-01-01", kind: .external)
        let taskBlock = mkBlock(id: "b1", taskId: "t1", date: "2026-06-15", kind: .task)
        let plan = reconcileCalendarPull(events: [ev("e1")],
                                         localBlocks: [stale, outOfWindow, taskBlock],
                                         fromYmd: fromYmd, toYmd: toYmd)
        XCTAssertEqual(plan.toDelete, ["g_gone"])   // never task blocks or out-of-window mirrors
    }

    func testKeepsExternalsStillReturnedByGoogle() {
        let kept = mkBlock(id: "g_e1", taskId: nil, date: "2026-06-10", kind: .external)
        let plan = reconcileCalendarPull(events: [ev("e1")], localBlocks: [kept],
                                         fromYmd: fromYmd, toYmd: toYmd)
        XCTAssertTrue(plan.toDelete.isEmpty)
        XCTAssertEqual(plan.toUpsert.map(\.id), ["g_e1"])
    }
}
