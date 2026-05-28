// Ported 1:1 from lib/sync/google-sync.test.ts.

import XCTest
@testable import UnstuckCore

final class GoogleSyncMappingHelperTests: XCTestCase {

    func testIsoToLocalYmd() {
        // Noon UTC so timezone wobble can't cross a day boundary.
        XCTAssertTrue(isoToLocalYmd("2026-05-21T12:00:00.000Z").range(of: #"^2026-05-2[01]$"#, options: .regularExpression) != nil)
    }

    func testIsoToLocalHHMMZeroPads() {
        XCTAssertTrue(isoToLocalHHMM("2026-05-21T01:05:00.000Z").range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil)
    }

    func testDiffMinutesClampsToMin15() {
        XCTAssertEqual(diffMinutes("2026-05-21T10:00:00.000Z", "2026-05-21T10:05:00.000Z"), 15)
        XCTAssertEqual(diffMinutes("2026-05-21T10:00:00.000Z", "2026-05-21T11:30:00.000Z"), 90)
    }
}

final class ExternalEventToBlockTests: XCTestCase {
    private let ev = ExternalEvent(
        id: "goog_abc123", connectionId: "conn_1", calendarId: "primary",
        summary: "Standup", start: "2026-05-21T09:00:00.000Z", end: "2026-05-21T09:30:00.000Z")

    func testMarksExternalAndCarriesGoogleIds() {
        let b = externalEventToBlock(ev, calendarId: "primary")
        XCTAssertEqual(b.kind, .external)
        XCTAssertEqual(b.externalEventId, "goog_abc123")
        XCTAssertEqual(b.externalConnectionId, "conn_1")
        XCTAssertNil(b.taskId)
        XCTAssertEqual(b.taskName, "Standup")
    }

    func testStableGPrefixedId() {
        let a = externalEventToBlock(ev, calendarId: "primary")
        let b = externalEventToBlock(ev, calendarId: "primary")
        XCTAssertEqual(a.id, b.id)
        XCTAssertTrue(a.id.hasPrefix("g_"))
    }

    func testUntitledFallback() {
        var empty = ev; empty.summary = ""
        XCTAssertEqual(externalEventToBlock(empty, calendarId: "primary").taskName, "(untitled)")
    }

    func testDurationFloor() {
        var short = ev; short.end = ev.start
        XCTAssertEqual(externalEventToBlock(short, calendarId: "primary").durationMinutes, 15)
    }
}

final class BlockToIsoRangeTests: XCTestCase {
    func testBuildsUtcRangeFromDateAndTime() {
        // Under TZ=UTC, local civil time == UTC.
        let b = mkBlock(taskId: "t", startTime: "09:00", durationMinutes: 90, date: "2026-05-21")
        let r = blockToIsoRange(b)
        XCTAssertEqual(r.start, "2026-05-21T09:00:00.000Z")
        XCTAssertEqual(r.end, "2026-05-21T10:30:00.000Z")
    }
}
