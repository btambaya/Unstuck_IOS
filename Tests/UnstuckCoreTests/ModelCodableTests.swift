// Construct + JSON round-trip every entity. Beyond coverage this locks
// the Codable shape the sync layer (UnstuckSync, phase P1) will rely on
// when (de)serializing PostgREST / realtime payloads.

import XCTest
@testable import UnstuckCore

final class ModelCodableTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ v: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
    }

    func testTaskItemRoundTrips() throws {
        let t = TaskItem(
            id: newUUID(), name: "Write spec", estimateMin: 45, totalFocused: 600,
            done: false, priority: .high, tags: ["deep-work"],
            objectives: [Objective(text: "outline", done: true, minutes: 10)],
            comments: [Comment(text: "blocked on review", at: iso(NOW))],
            intentWhen: "after lunch", intentThen: "open editor", lifeArea: "Work",
            firstPhysicalAction: "open doc", moveCount: 2, completedAt: nil, later: false,
            recurrence: .weekly(daysOfWeek: [1, 3], until: nil),
            createdAt: iso(NOW), updatedAt: iso(NOW))
        XCTAssertEqual(try roundTrip(t), t)
    }

    func testSessionRoundTrips() throws {
        let s = Session(id: newUUID(), taskId: newUUID(), taskName: "Deep work",
                        tags: ["x"], estimateMin: 25, actualSec: 1500, completedAt: iso(NOW))
        XCTAssertEqual(try roundTrip(s), s)
    }

    func testCalBlockRoundTrips() throws {
        let b = CalBlock(id: newUUID(), taskId: newUUID(), taskName: "Block",
                         startTime: "09:30", durationMinutes: 50, date: "2026-05-28",
                         externalEventId: "g_abc", externalConnectionId: newUUID(), kind: .external)
        XCTAssertEqual(try roundTrip(b), b)
    }

    func testReasonLogRoundTrips() throws {
        let r = ReasonLog(id: newUUID(), taskId: newUUID(), reason: "distracted",
                          action: .pause, at: iso(NOW), durationSec: 42)
        XCTAssertEqual(try roundTrip(r), r)
    }

    func testCaptureRoundTrips() throws {
        let c = Capture(id: newUUID(), taskId: newUUID(), sessionId: newUUID(),
                        tag: .followUp, body: "email Sam", at: iso(NOW))
        XCTAssertEqual(try roundTrip(c), c)
    }

    func testCalendarConnectionRoundTrips() throws {
        let cc = CalendarConnection(id: newUUID(), provider: .google, accountEmail: "a@b.com",
                                    displayName: "Work", selectedCalendarIds: ["primary"],
                                    colorSlot: 2, lastSyncCursor: "cur", connectedAt: iso(NOW))
        XCTAssertEqual(try roundTrip(cc), cc)
    }

    func testExternalEventRoundTrips() throws {
        let e = ExternalEvent(id: newUUID(), connectionId: newUUID(), calendarId: "primary",
                              summary: "Standup", start: iso(NOW), end: iso(NOW + 1800_000))
        XCTAssertEqual(try roundTrip(e), e)
    }

    func testLiveSessionRoundTrips() throws {
        let ls = LiveSession(id: newUUID(), taskId: newUUID(), sessionStart: NOW, paused: true,
                             pausedAt: NOW + 1000, sessionEstimateMin: 25, nudge80Fired: true,
                             overrunPromptFired: false, treatment: .cockpit, priorAccumulatedSec: 300)
        XCTAssertEqual(try roundTrip(ls), ls)
    }

    func testCollectionRoundTrips() throws {
        let col = ItemCollection(id: newUUID(), name: "Books", color: "indigo",
                                 subtitle: "to read", items: [
                                    CollectionItem(id: newUUID(), body: "Deep Work", pinned: true, done: false, at: iso(NOW)),
                                 ], sortOrder: 1)
        XCTAssertEqual(try roundTrip(col), col)
    }

    func testTagRowRoundTrips() throws {
        let t = TagRow(id: newUUID(), name: "urgent", color: "coral", sortOrder: 0)
        XCTAssertEqual(try roundTrip(t), t)
    }
}

final class HelperBranchTests: XCTestCase {

    func testMatchesAreaSentinelAndNil() {
        XCTAssertTrue(matchesArea("Work", nil))
        XCTAssertTrue(matchesArea(nil, UNASSIGNED_AREA))
        XCTAssertFalse(matchesArea("Work", UNASSIGNED_AREA))
        XCTAssertTrue(matchesArea("Work", "Work"))
        XCTAssertFalse(matchesArea("Home", "Work"))
    }

    func testMatchesTagStandalone() {
        XCTAssertTrue(matchesTag(["Deep-Work"], "deep-work"))
        XCTAssertTrue(matchesTag(["x"], nil))
        XCTAssertFalse(matchesTag(nil, "x"))
        XCTAssertFalse(matchesTag([], "x"))
    }

    func testDaysSinceCreatedUnparseableIsZero() {
        XCTAssertEqual(daysSinceCreated(mkTask(createdAt: "not-a-date"), now: NOW), 0)
    }

    func testIsSlippingUnparseableCreatedAtIsFalse() {
        XCTAssertFalse(isSlipping(mkTask(createdAt: "garbage"), now: NOW))
    }

    func testPlaceholderAndExternalPredicates() {
        XCTAssertTrue(isPlaceholderBlock(mkBlock(taskId: "placeholder")))
        XCTAssertTrue(isExternalBlock(mkBlock(taskId: "cal-9")))
        XCTAssertFalse(isPlaceholderBlock(mkBlock(taskId: "real")))
    }

    func testTimeParseWholeSecondAndInvalid() {
        XCTAssertNotNil(Time.parseMillis("2026-05-21T12:00:00Z"))
        XCTAssertNil(Time.parseMillis("nope"))
    }

    func testClockDateISOFromMillis() {
        // NOW is 2026-05-21 noon UTC; under TZ=UTC this is the 21st.
        XCTAssertEqual(Clock.dateISO(millis: NOW), "2026-05-21")
    }
}
