// Bucket helpers (lib/task-bucket.ts), block-kind derivation
// (lib/cal-block-kind.ts), and Recurrence JSON round-trips (the tagged
// union must match the web's JSONB shape exactly).

import XCTest
@testable import UnstuckCore

final class TaskBucketTests: XCTestCase {

    func testIsCompletedTodayTrueForNow() {
        XCTAssertTrue(isCompletedToday(mkTask(completedAt: iso(NOW)), now: NOW))
    }

    func testIsCompletedTodayFalseWhenNil() {
        XCTAssertFalse(isCompletedToday(mkTask(completedAt: nil), now: NOW))
    }

    func testIsCompletedTodayFalseForYesterday() {
        XCTAssertFalse(isCompletedToday(mkTask(completedAt: iso(NOW - DAY_MS)), now: NOW))
    }

    func testIsCreatedToday() {
        XCTAssertTrue(isCreatedToday(mkTask(createdAt: iso(NOW)), now: NOW))
        XCTAssertFalse(isCreatedToday(mkTask(createdAt: "2020-01-01T00:00:00.000Z"), now: NOW))
    }

    func testDaysSinceCreated() {
        XCTAssertEqual(daysSinceCreated(mkTask(createdAt: iso(NOW)), now: NOW), 0)
        XCTAssertEqual(daysSinceCreated(mkTask(createdAt: iso(NOW - 3 * DAY_MS)), now: NOW), 3)
    }
}

final class CalBlockKindTests: XCTestCase {

    func testStoredKindWins() {
        XCTAssertEqual(blockKind(mkBlock(taskId: "x", kind: .placeholder)), .placeholder)
    }

    func testExternalEventIdImpliesExternal() {
        let b = CalBlock(id: "b", taskId: "x", taskName: "n", startTime: "09:00",
                         durationMinutes: 25, date: "2026-05-21", externalEventId: "g_1")
        XCTAssertEqual(blockKind(b), .external)
        XCTAssertFalse(isTaskBlock(b))
    }

    func testPlaceholderAndCalPrefixHeuristics() {
        XCTAssertEqual(blockKind(mkBlock(taskId: "placeholder")), .placeholder)
        XCTAssertEqual(blockKind(mkBlock(taskId: "cal-123")), .external)
    }

    func testPlainTaskBlock() {
        let b = mkBlock(taskId: "real-task")
        XCTAssertEqual(blockKind(b), .task)
        XCTAssertTrue(isTaskBlock(b))
    }

    func testBlockTimeEventWithNilTaskIsNotTaskBlock() {
        let b = CalBlock(id: "b", taskId: nil, taskName: "Lunch", startTime: "12:00",
                         durationMinutes: 60, date: "2026-05-21", kind: .external)
        XCTAssertFalse(isTaskBlock(b))
    }
}

final class RecurrenceCodableTests: XCTestCase {

    private func roundTrip(_ r: Recurrence) throws -> Recurrence {
        let data = try JSONEncoder().encode(r)
        return try JSONDecoder().decode(Recurrence.self, from: data)
    }

    func testDailyRoundTrips() throws {
        XCTAssertEqual(try roundTrip(.daily(until: nil)), .daily(until: nil))
        XCTAssertEqual(try roundTrip(.daily(until: "2026-09-01")), .daily(until: "2026-09-01"))
    }

    func testWeeklyRoundTrips() throws {
        XCTAssertEqual(try roundTrip(.weekly(daysOfWeek: [1, 3, 5], until: nil)),
                       .weekly(daysOfWeek: [1, 3, 5], until: nil))
    }

    func testMonthlyRoundTrips() throws {
        XCTAssertEqual(try roundTrip(.monthly(until: "2026-12-31")), .monthly(until: "2026-12-31"))
    }

    func testDecodesWebJSONShape() throws {
        let json = #"{"kind":"weekly","daysOfWeek":[0,6],"until":null}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(Recurrence.self, from: json)
        XCTAssertEqual(r, .weekly(daysOfWeek: [0, 6], until: nil))
    }

    // Forward-compat: an UNKNOWN kind must NOT throw — a throw would abort the
    // whole TaskRow decode and the task would VANISH. It degrades to an inert
    // no-op daily (Recurrence.isUnknown) instead. (Was testUnknownKindThrows,
    // which asserted the old buggy behavior; mirrors Android's degrade fix.)
    func testUnknownKindDegradesToInertSentinel() throws {
        let json = #"{"kind":"yearly"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(Recurrence.self, from: json)
        XCTAssertTrue(Recurrence.isUnknown(r))
        XCTAssertEqual(r, .daily(until: Recurrence.UNKNOWN_UNTIL))
    }
}

final class UUIDTests: XCTestCase {
    func testNewUUIDIsLowercasedAndValid() {
        let u = newUUID()
        XCTAssertEqual(u, u.lowercased())
        XCTAssertTrue(isUUID(u))
    }
    func testIsUUIDRejectsGarbage() {
        XCTAssertFalse(isUUID("not-a-uuid"))
        XCTAssertFalse(isUUID(""))
    }
}
