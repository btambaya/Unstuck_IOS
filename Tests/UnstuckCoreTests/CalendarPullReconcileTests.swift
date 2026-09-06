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

    // MARK: - server `allDay: true` (the adapter used to rewrite date-only
    // starts to 'T00:00:00', so the no-'T' filter above was dead code)

    func testServerFlaggedAllDayEventIsSkippedEvenWithATShapedStart() {
        let holiday = ev("hol", summary: "Public holiday",
                         start: "2026-06-10T00:00:00", end: "2026-06-11T00:00:00")
        let plan = reconcileCalendarPull(events: [holiday, ev("e2")], localBlocks: [],
                                         fromYmd: fromYmd, toYmd: toYmd, allDayEventIds: ["hol"])
        XCTAssertEqual(plan.toUpsert.map(\.id), ["g_e2"], "no 15-min 00:00 sliver for the holiday")
    }

    func testAnAllDayMirrorAlreadyOnDiskIsReconciledAway() {
        // A sliver mirrored by an older build is in-window and not in the keep
        // set → dropped like any event Google no longer returns.
        let sliver = mkBlock(id: "g_hol", taskId: nil, date: "2026-06-10", kind: .external)
        let holiday = ev("hol", start: "2026-06-10T00:00:00", end: "2026-06-11T00:00:00")
        let plan = reconcileCalendarPull(events: [holiday], localBlocks: [sliver],
                                         fromYmd: fromYmd, toYmd: toYmd, allDayEventIds: ["hol"])
        XCTAssertEqual(plan.toDelete, ["g_hol"])
    }

    // MARK: - per-connection failures (`/events` → failures[]): a revoked
    // token / 429 / 5xx on one connection must not read as "all its meetings
    // were deleted in Google"

    private func external(_ id: String, conn: String?, date: String = "2026-06-15") -> CalBlock {
        var b = mkBlock(id: id, taskId: nil, date: date, kind: .external)
        b.externalConnectionId = conn
        return b
    }

    func testBlocksOfAFailedConnectionAreNeverDeleted() {
        let failedMeeting = external("g_a", conn: "conn_dead")
        let healthyGone = external("g_b", conn: "conn_ok")
        let plan = reconcileCalendarPull(events: [], localBlocks: [failedMeeting, healthyGone],
                                         fromYmd: fromYmd, toYmd: toYmd,
                                         failedConnectionIds: ["conn_dead"])
        XCTAssertEqual(plan.toDelete, ["g_b"], "only the healthy connection's vanished meeting goes")
    }

    func testUnknownProvenanceBlocksAreKeptWhileAnyConnectionFailed() {
        // A mirror from before connection stamping: nobody can prove which
        // connection it belongs to — keep it rather than risk wiping a real
        // meeting behind a dead token.
        let legacy = external("g_legacy", conn: nil)
        let plan = reconcileCalendarPull(events: [], localBlocks: [legacy],
                                         fromYmd: fromYmd, toYmd: toYmd,
                                         failedConnectionIds: ["conn_dead"])
        XCTAssertTrue(plan.toDelete.isEmpty)
    }

    func testUnknownProvenanceBlocksStillReconcileWhenEveryConnectionSucceeded() {
        let legacy = external("g_legacy", conn: nil)
        let plan = reconcileCalendarPull(events: [], localBlocks: [legacy],
                                         fromYmd: fromYmd, toYmd: toYmd)
        XCTAssertEqual(plan.toDelete, ["g_legacy"], "a clean pull keeps the old deletion semantics")
    }

    func testPartialEventsFromAFailedConnectionAreNotMirrored() {
        // A connection that failed mid-way may still have returned a page:
        // treat it as unreadable this pull (nothing upserted, nothing deleted).
        let e = ExternalEvent(id: "x", connectionId: "conn_dead", calendarId: "primary",
                              summary: "Half", start: "2026-06-10T09:00:00.000Z", end: "2026-06-10T09:30:00.000Z")
        let plan = reconcileCalendarPull(events: [e], localBlocks: [external("g_old", conn: "conn_dead")],
                                         fromYmd: fromYmd, toYmd: toYmd,
                                         failedConnectionIds: ["conn_dead"])
        XCTAssertTrue(plan.toUpsert.isEmpty)
        XCTAssertTrue(plan.toDelete.isEmpty)
    }
}
