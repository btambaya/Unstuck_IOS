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
        let ahead = mkBlock(id: "g_ahead", taskId: nil, date: "2026-08-01", kind: .external)
        let taskBlock = mkBlock(id: "b1", taskId: "t1", date: "2026-06-15", kind: .task)
        let plan = reconcileCalendarPull(events: [ev("e1")],
                                         localBlocks: [stale, ahead, taskBlock],
                                         fromYmd: fromYmd, toYmd: toYmd)
        XCTAssertEqual(plan.toDelete, ["g_gone"])   // never task blocks or mirrors past the window
    }

    // MARK: - mirrors nothing checks any more (audit 2026-09-22, C25 / calendar#9)

    /// A meeting older than the window is never asked for again, so it can
    /// never be reconciled; every hydrate carried it forward, and they piled
    /// up for good. Only Google imports (g_) — never a task block.
    func testGoogleImportsFromBeforeTheWindowAreDropped() {
        let old = mkBlock(id: "g_old", taskId: nil, date: "2026-01-01", kind: .external)
        let oldTask = mkBlock(id: "b_old", taskId: "t1", date: "2026-01-01", kind: .task)
        let plan = reconcileCalendarPull(events: [], localBlocks: [old, oldTask],
                                         fromYmd: fromYmd, toYmd: toYmd, failedConnectionIds: ["conn_dead"])
        XCTAssertEqual(plan.toDelete, ["g_old"], "past the window, whatever failed this pull")
    }

    /// A connection removed elsewhere (web / Android) while another stays:
    /// its meetings outside the window were never reconciled away.
    func testImportsOfAConnectionThatNoLongerExistsAreDroppedWhateverTheirDate() {
        let gone = external("g_far", conn: "conn_removed", date: "2026-08-20")
        let live = external("g_live", conn: "conn_1", date: "2026-08-20")
        let unstamped = external("g_legacy", conn: nil, date: "2026-08-20")
        let plan = reconcileCalendarPull(events: [], localBlocks: [gone, live, unstamped],
                                         fromYmd: fromYmd, toYmd: toYmd, liveConnectionIds: ["conn_1"])
        XCTAssertEqual(plan.toDelete, ["g_far"])
    }

    // MARK: - events we are still deleting (audit 2026-09-22, C24)

    /// A pushed block is gone but its Google delete has not gone through
    /// (offline, a kill): the event is ours, never a meeting.
    func testAnEventWhoseGoogleDeleteIsPendingIsNeverImported() {
        let plan = reconcileCalendarPull(events: [ev("mine"), ev("theirs")], localBlocks: [],
                                         fromYmd: fromYmd, toYmd: toYmd, pendingDeleteEventIds: ["mine"])
        XCTAssertEqual(plan.toUpsert.map(\.id), ["g_theirs"])
    }

    // MARK: - timed events across midnight (audit 2026-09-22, C25 / calendar#10)

    /// An instant for a LOCAL wall-clock time: the split is by local day.
    private func at(_ ymd: String, _ hour: Int, _ minute: Int = 0) -> String {
        let d = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: LocalDate.parse(ymd))!
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private func shape(_ blocks: [CalBlock]) -> [String] {
        blocks.map { "\($0.id) \($0.date) \($0.startTime) \($0.durationMinutes)" }
    }

    func testAMultiDayEventIsOneBlockPerLocalDay() {
        let conf = ev("conf", summary: "Conference", start: at("2026-06-15", 9), end: at("2026-06-17", 17))
        let plan = reconcileCalendarPull(events: [conf], localBlocks: [], fromYmd: fromYmd, toYmd: toYmd)
        XCTAssertEqual(shape(plan.toUpsert), [
            "g_conf 2026-06-15 09:00 900",
            "g_conf_2026-06-16 2026-06-16 00:00 1440",
            "g_conf_2026-06-17 2026-06-17 00:00 1020",
        ], "Tuesday and Wednesday are busy, and Monday's card ends at midnight")
        XCTAssertTrue(plan.toUpsert.allSatisfy { $0.externalEventId == "conf" && $0.kind == .external })
    }

    func testAnOvernightEventCoversTheNextMorning() {
        let flight = ev("red_eye", start: at("2026-06-15", 22), end: at("2026-06-16", 6))
        XCTAssertEqual(shape(externalEventBlocks(flight)), [
            "g_red_eye 2026-06-15 22:00 120",
            "g_red_eye_2026-06-16 2026-06-16 00:00 360",
        ])
        let toMidnight = ev("late", start: at("2026-06-15", 22), end: at("2026-06-16", 0))
        XCTAssertEqual(shape(externalEventBlocks(toMidnight)), ["g_late 2026-06-15 22:00 120"],
                       "no empty day after an event that ends at midnight")
    }

    /// An event that began before the window still yields its in-window
    /// days; days past the window wait until the window reaches them.
    func testOnlyTheWindowsDaysAreKept() {
        let ooo = ev("ooo", start: at("2026-05-30", 10), end: at("2026-06-03", 10))
        XCTAssertEqual(shape(externalEventBlocks(ooo, fromYmd: fromYmd, toYmd: toYmd)), [
            "g_ooo_2026-06-02 2026-06-02 00:00 1440",
            "g_ooo_2026-06-03 2026-06-03 00:00 600",
        ])
        let trip = ev("trip", start: at(toYmd, 20), end: at("2026-07-11", 8))
        XCTAssertEqual(shape(externalEventBlocks(trip, fromYmd: fromYmd, toYmd: toYmd)), ["g_trip \(toYmd) 20:00 240"])
    }

    /// The single long block an older build stored becomes the start day's
    /// block; a day the event no longer covers is reconciled away.
    func testASplitEventReplacesTheOldLongBlockAndShrinksCleanly() {
        var long = mkBlock(id: "g_conf", taskId: nil, date: "2026-06-15", kind: .external)
        long.durationMinutes = 3360
        let tuesday = mkBlock(id: "g_conf_2026-06-16", taskId: nil, date: "2026-06-16", kind: .external)
        let oneDay = ev("conf", start: at("2026-06-15", 9), end: at("2026-06-15", 17))
        let plan = reconcileCalendarPull(events: [oneDay], localBlocks: [long, tuesday], fromYmd: fromYmd, toYmd: toYmd)
        XCTAssertEqual(shape(plan.toUpsert), ["g_conf 2026-06-15 09:00 480"])
        XCTAssertEqual(plan.toDelete, ["g_conf_2026-06-16"])
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

    /// One calendar of an account fails (a colleague's calendar that 5xxs):
    /// the server answers it with NO events, so every event that came back
    /// for that connection is from a calendar that answered — mirrored, so a
    /// new or moved meeting on the primary calendar still arrives. Nothing of
    /// that connection is deleted this pull (audit 2026-09-22, C25: dropping
    /// the upserts too froze the whole account behind one calendar).
    func testAFailedConnectionsReturnedEventsAreMirroredButNothingOfItIsDeleted() {
        let e = ExternalEvent(id: "x", connectionId: "conn_dead", calendarId: "primary",
                              summary: "Moved", start: "2026-06-10T09:00:00.000Z", end: "2026-06-10T09:30:00.000Z")
        let plan = reconcileCalendarPull(events: [e], localBlocks: [external("g_old", conn: "conn_dead")],
                                         fromYmd: fromYmd, toYmd: toYmd,
                                         failedConnectionIds: ["conn_dead"])
        XCTAssertEqual(plan.toUpsert.map(\.id), ["g_x"])
        XCTAssertTrue(plan.toDelete.isEmpty)
    }
}
