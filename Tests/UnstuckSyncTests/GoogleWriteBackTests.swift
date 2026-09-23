// Google Calendar write-back and pull pieces below the app (audit 2026-09-22,
// C24 / C25): the backlog of write-backs that have not reached Google, the
// delete that reports the row as it was deleted, the mapping clear behind
// "Skip this day", the follow-up reads past the server's one page per
// calendar, and which per-calendar failure really is one.

import XCTest
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

final class GoogleWriteBacklogTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "GoogleWriteBacklogTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDeletesAndPushesAreKeptUntilCleared() {
        let b = GoogleWriteBacklog(defaults: nil, currentUser: { "u1" })
        b.recordDelete(PendingGoogleDelete(blockId: "b1", eventId: "e1", connectionId: "c1"))
        b.recordDelete(PendingGoogleDelete(blockId: "b1", eventId: "e1", connectionId: "c1"))
        b.recordPush(blockId: "b2")
        b.recordPush(blockId: "b2")
        XCTAssertEqual(b.deletes().map(\.eventId), ["e1"], "recorded once")
        XCTAssertEqual(b.pendingDeleteEventIds(), ["e1"])
        XCTAssertEqual(b.pushes(), ["b2"])
        b.clearDelete(eventId: "e1")
        b.clearPush(blockId: "b2")
        XCTAssertTrue(b.deletes().isEmpty)
        XCTAssertTrue(b.pushes().isEmpty)
    }

    /// It outlives the app (a kill before the delete's turn) and belongs to
    /// one account: the next user of the phone never sees it, and nothing is
    /// recorded while signed out.
    func testItSurvivesARelaunchAndIsPerUser() {
        let defaults = suite()
        final class Signed: @unchecked Sendable { var user: String? = "u1" }
        let signed = Signed()
        let first = GoogleWriteBacklog(defaults: defaults, currentUser: { signed.user })
        first.recordDelete(PendingGoogleDelete(blockId: "b1", eventId: "e1", connectionId: nil))
        first.recordPush(blockId: "b2")

        let relaunched = GoogleWriteBacklog(defaults: defaults, currentUser: { "u1" })
        XCTAssertEqual(relaunched.deletes(), [PendingGoogleDelete(blockId: "b1", eventId: "e1", connectionId: nil)])
        XCTAssertEqual(relaunched.pushes(), ["b2"])

        let other = GoogleWriteBacklog(defaults: defaults, currentUser: { "u2" })
        XCTAssertTrue(other.deletes().isEmpty)
        XCTAssertTrue(other.pushes().isEmpty)

        signed.user = nil
        first.recordPush(blockId: "b3")
        XCTAssertTrue(first.pushes().isEmpty)
        XCTAssertEqual(relaunched.pushes(), ["b2"])
    }

    func testTheOldestEntriesGoPastTheCap() {
        let b = GoogleWriteBacklog(defaults: nil, currentUser: { "u1" })
        for i in 0...GoogleWriteBacklog.cap {
            b.recordDelete(PendingGoogleDelete(blockId: "b\(i)", eventId: "e\(i)", connectionId: nil))
        }
        XCTAssertEqual(b.deletes().count, GoogleWriteBacklog.cap)
        XCTAssertFalse(b.pendingDeleteEventIds().contains("e0"))
        XCTAssertTrue(b.pendingDeleteEventIds().contains("e\(GoogleWriteBacklog.cap)"))
    }
}

final class GoogleMappingWriteTests: XCTestCase {
    private var db: AppDatabase!
    private var box: OutboxStore!
    private var write: WriteThrough!
    private let now = "2026-09-23T10:00:00.000Z"

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        box = OutboxStore(db)
        write = WriteThrough(db: db)
    }

    private func block(_ id: String = "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d") -> CalBlock {
        CalBlock(id: id, taskId: nil, taskName: "Dentist", startTime: "10:00", durationMinutes: 30,
                 date: "2026-09-24", kind: .task)
    }

    /// The delete reports the row as it was deleted — with the event a
    /// stamp put on it after the caller read its copy (audit 2026-09-22, C24).
    func testDeleteReturnsTheRowAsDeletedWithItsMapping() async throws {
        let callersCopy = block()
        try db.save(callersCopy)
        try await write.stampCalBlockMapping(id: callersCopy.id, eventId: "evt1", connectionId: "c1", nowISO: now)
        let deleted = try await write.deleteCalBlock(id: callersCopy.id, nowISO: now)
        XCTAssertEqual(deleted?.externalEventId, "evt1")
        XCTAssertEqual(deleted?.externalConnectionId, "c1")
        let again = try await write.deleteCalBlock(id: callersCopy.id, nowISO: now)
        XCTAssertNil(again, "nothing here any more")
        let gRow = CalBlock(id: "g_x", taskId: nil, taskName: "Meeting", startTime: "10:00", durationMinutes: 30,
                            date: "2026-09-24", externalEventId: "x", kind: .external)
        try db.save(gRow)
        let gDeleted = try await write.deleteCalBlock(id: gRow.id, nowISO: now)
        XCTAssertNil(gDeleted, "a Google import has no event of ours")
        XCTAssertNil(try db.fetchById(CalBlock.self, id: gRow.id))
    }

    /// "Skip this day" deleted the occurrence's event: the mapping comes off
    /// the row (queued for the server) — only while the row still names it.
    func testClearingTheMappingTakesOnlyThatEventOff() async throws {
        let b = block()
        try db.save(b)
        try await write.stampCalBlockMapping(id: b.id, eventId: "evt1", connectionId: "c1", nowISO: now)
        let before = try box.count()
        let other = try await write.clearCalBlockMapping(id: b.id, eventId: "evt-other", nowISO: now)
        XCTAssertEqual(other, .unchanged)
        XCTAssertEqual(try db.fetchById(CalBlock.self, id: b.id)?.externalEventId, "evt1")
        let cleared = try await write.clearCalBlockMapping(id: b.id, eventId: "evt1", nowISO: now)
        XCTAssertEqual(cleared, .stamped)
        let row = try XCTUnwrap(try db.fetchById(CalBlock.self, id: b.id))
        XCTAssertNil(row.externalEventId)
        XCTAssertNil(row.externalConnectionId)
        XCTAssertEqual(try box.count(), before + 1, "the server row loses the mapping too")
        let gone = try await write.clearCalBlockMapping(id: "missing", eventId: "evt1", nowISO: now)
        XCTAssertEqual(gone, .gone)
    }
}

/// `count` events on one calendar, one an hour, on day `day`.
private func events(_ conn: String, _ cal: String, count: Int, day: Int = 1, prefix: String = "e") -> [ExternalEvent] {
    (0..<count).map { i in
        let t = Date(timeIntervalSince1970: 1_790_000_000 + Double(day * 86_400 + i * 3_600))
        let f = ISO8601DateFormatter()
        return ExternalEvent(id: "\(prefix)\(day)_\(i)", connectionId: conn, calendarId: cal, summary: "M",
                             start: f.string(from: t), end: f.string(from: t.addingTimeInterval(1_800)))
    }
}

final class CalendarPullPagingTests: XCTestCase {
    private typealias Pull = CalendarClient.CalendarPull

    private actor Calls {
        var made: [String] = []
        func add(_ s: String) { made.append(s) }
    }

    /// A calendar that came back as one FULL page is read again from its last
    /// event's start until it comes back short: the tail of a busy calendar
    /// arrives, and nothing is left "truncated" (audit 2026-09-22, C25).
    func testAFullPageIsFollowedUntilTheCalendarComesBackShort() async {
        let page = 4
        let firstPage = events("c1", "team", count: page) + events("c1", "primary", count: 2, prefix: "p")
        let tail = Array(firstPage[page - 1...page - 1]) + events("c1", "team", count: 2, day: 2)
        let calls = Calls()
        let (pull, truncated) = await SyncCoordinator.readRemainingPages(
            Pull(events: firstPage, allDayEventIds: [], failures: []), pageSize: page, maxRounds: 4
        ) { from, conn in
            await calls.add("\(conn)@\(from)")
            return Pull(events: tail, allDayEventIds: ["e2_1"], failures: [])
        }
        let made = await calls.made
        XCTAssertEqual(made, ["c1@\(firstPage[page - 1].start)"], "from the full calendar's last start")
        XCTAssertEqual(pull.events.count, page + 2 + 2, "the tail is merged, the overlapping event once")
        XCTAssertEqual(pull.allDayEventIds, ["e2_1"])
        XCTAssertTrue(truncated.isEmpty)
    }

    /// No progress, a failed follow-up, or out of rounds: that connection is
    /// "truncated" — its meetings are kept, never reconciled away this pull.
    func testAConnectionThatCannotBeReadToTheEndIsTruncated() async {
        let page = 3
        let full = events("c1", "team", count: page)
        let stuck = await SyncCoordinator.readRemainingPages(
            Pull(events: full, allDayEventIds: [], failures: []), pageSize: page, maxRounds: 4
        ) { _, _ in Pull(events: full, allDayEventIds: [], failures: []) }   // the same page again
        XCTAssertEqual(stuck.1, ["c1"])

        struct Offline: Error {}
        let failed = await SyncCoordinator.readRemainingPages(
            Pull(events: full, allDayEventIds: [], failures: []), pageSize: page, maxRounds: 4
        ) { _, _ in throw Offline() }
        XCTAssertEqual(failed.1, ["c1"])
        XCTAssertEqual(failed.0.events.count, page, "what was read is kept")

        let counter = Calls()
        let endless = await SyncCoordinator.readRemainingPages(
            Pull(events: full, allDayEventIds: [], failures: []), pageSize: page, maxRounds: 2
        ) { _, _ in
            await counter.add("x")
            let n = await counter.made.count
            return Pull(events: events("c1", "team", count: page, day: n + 1), allDayEventIds: [], failures: [])
        }
        let rounds = await counter.made.count
        XCTAssertEqual(rounds, 2)
        XCTAssertEqual(endless.1, ["c1"])
    }

    /// A follow-up that reports a failing calendar leaves the connection
    /// truncated — but a calendar that is simply gone (404) does not, and a
    /// follow-up's failures never read as "the sync failed". Its bound goes
    /// out as a UTC instant: Google's "+01:00" would reach the function as a
    /// space in the query.
    func testFollowUpFailuresMarkTheConnectionButStayOutOfThePull() async {
        let page = 2
        var full = events("c1", "team", count: page)
        full[1].start = "2026-10-05T09:00:00+01:00"
        let calls = Calls()
        typealias F = CalendarClient.PullFailure
        let busy = await SyncCoordinator.readRemainingPages(
            Pull(events: full, allDayEventIds: [], failures: []), pageSize: page, maxRounds: 4
        ) { from, _ in
            await calls.add(from)
            return Pull(events: [], allDayEventIds: [], failures: [F(connectionId: "c1", calendarId: "team", status: 503)])
        }
        let made = await calls.made
        XCTAssertEqual(made, ["2026-10-05T08:00:00Z"])
        XCTAssertEqual(busy.1, ["c1"])
        XCTAssertTrue(busy.0.failures.isEmpty)

        let gone = await SyncCoordinator.readRemainingPages(
            Pull(events: full, allDayEventIds: [], failures: []), pageSize: page, maxRounds: 4
        ) { _, _ in Pull(events: [], allDayEventIds: [], failures: [F(connectionId: "c1", calendarId: "old", status: 404)]) }
        XCTAssertTrue(gone.1.isEmpty)
    }

    func testShortPagesNeedNoFollowUp() async {
        let pull = Pull(events: events("c1", "team", count: 3), allDayEventIds: [], failures: [])
        let (merged, truncated) = await SyncCoordinator.readRemainingPages(pull, pageSize: 250, maxRounds: 4) { _, _ in
            XCTFail("no follow-up for a short page")
            return pull
        }
        XCTAssertEqual(merged, pull)
        XCTAssertTrue(truncated.isEmpty)
    }

    /// A calendar Google no longer lets the account read is gone, not
    /// unknown — only that one calendar, never a whole-connection failure.
    func testOnlyAPerCalendar404Or410IsACalendarGone() {
        typealias F = CalendarClient.PullFailure
        XCTAssertTrue(F(connectionId: "c", calendarId: "team@group.calendar.google.com", status: 404).calendarGone)
        XCTAssertTrue(F(connectionId: "c", calendarId: "old", status: 410).calendarGone)
        XCTAssertFalse(F(connectionId: "c", calendarId: "*", status: 404).calendarGone)
        XCTAssertFalse(F(connectionId: "c", calendarId: nil, status: 404).calendarGone)
        XCTAssertFalse(F(connectionId: "c", calendarId: "team", status: 403).calendarGone)
        XCTAssertFalse(F(connectionId: "c", calendarId: "team", status: 503).calendarGone)
    }
}
