// Bucket helpers (lib/task-bucket.ts), block-kind derivation
// (lib/cal-block-kind.ts), and Recurrence JSON round-trips (the tagged
// union must match the web's JSONB shape exactly).

import CryptoKit
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

    /// The shared vectors (deterministic-occurrence-ids.md §1.5): web and
    /// Android must produce these exact strings too, or two devices minting
    /// the same day would land on two rows (C21).
    func testOccurrenceIdVectors() {
        XCTAssertEqual(OCCURRENCE_ID_NAMESPACE, "acd13342-1379-568a-9f73-6acb660047d5")
        let a = "3f1c2a9e-5b7d-4c21-9a0e-7d2b1c4e8f60"
        let b = "b0d8e7c6-1a2b-4c3d-8e9f-0a1b2c3d4e5f"
        let vectors: [(String, String, String)] = [
            (a, "2026-09-24", "f8f5c8e7-0bb2-58d7-bc30-2701a2c9e1be"),
            (a, "2026-09-25", "94be29ab-5eb6-52f4-bade-486972b834ae"),
            (a.uppercased(), "2026-09-24", "f8f5c8e7-0bb2-58d7-bc30-2701a2c9e1be"),
            (a, "2028-02-29", "101e2d03-3451-56d1-83b8-5f8e3d482db3"),
            (b, "2026-12-31", "5bfa0f7f-0aea-502e-9b9d-40acfdf8cb3d"),
            (b, "2027-01-01", "72f3d112-a4f9-5197-89f8-192492309c27"),
            ("00000000-0000-0000-0000-000000000000", "2026-01-01", "33b3ff38-ce8b-5bfa-96a2-960ee8ea4a94"),
            // #8 pins the trim: space, tab, VT, FF before; CR LF after; upper case.
            (" \t\u{0B}\u{0C}\(a.uppercased())\r\n", "2026-09-24", "f8f5c8e7-0bb2-58d7-bc30-2701a2c9e1be"),
        ]
        for (i, v) in vectors.enumerated() {
            let id = occurrenceId(taskId: v.0, date: v.1)
            XCTAssertEqual(id, v.2, "vector #\(i + 1)")
            XCTAssertTrue(isUUID(id))
            XCTAssertEqual(id, id.lowercased())
            let chars = Array(id)
            XCTAssertEqual(chars[14], "5", "version nibble, vector #\(i + 1)")
            XCTAssertTrue("89ab".contains(chars[19]), "variant nibble, vector #\(i + 1)")
        }
        XCTAssertNotEqual(occurrenceId(taskId: a, date: "2026-09-24"), occurrenceId(taskId: a, date: "2026-09-25"),
                          "consecutive days differ")
        // `.whitespaces` would have kept the newline (the critique's trap).
        XCTAssertNotEqual(occurrenceId(taskId: a + "\n", date: "2026-09-24"), "20d80b18-cc95-5836-83dc-4597fa48e5db")
    }

    /// The hard-coded namespace IS uuid5(NAMESPACE_URL, the occurrence URL).
    func testOccurrenceNamespaceDerivation() {
        let nsURL = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")!.uuid
        var bytes = withUnsafeBytes(of: nsURL) { Array($0) }
        bytes += Array("https://unstucknow.io/ns/cal-block-occurrence".utf8)
        var h = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        h[6] = (h[6] & 0x0F) | 0x50
        h[8] = (h[8] & 0x3F) | 0x80
        let derived = UUID(uuid: h.withUnsafeBytes { $0.load(as: uuid_t.self) }).uuidString.lowercased()
        XCTAssertEqual(derived, OCCURRENCE_ID_NAMESPACE)
    }
}
