// Time.parseMillis — both ISO-8601 forms must still parse after the shared
// static formatters were hoisted out of the per-call path (perf fix).

import XCTest
@testable import UnstuckCore

final class TimeTests: XCTestCase {
    func testParsesFractionalSecondForm() {
        // 2026-06-11T10:00:00.000Z == 1781172000000 ms.
        let ms = Time.parseMillis("2026-06-11T10:00:00.000Z")
        XCTAssertNotNil(ms)
        XCTAssertEqual(ms!, 1781172000000, accuracy: 0.5)
    }

    func testParsesPlainSecondForm() {
        // Same instant, no fractional seconds — must hit the plain formatter.
        let ms = Time.parseMillis("2026-06-11T10:00:00Z")
        XCTAssertNotNil(ms)
        XCTAssertEqual(ms!, 1781172000000, accuracy: 0.5)
    }

    func testFractionalAndPlainAgree() {
        XCTAssertEqual(Time.parseMillis("2026-06-11T10:00:00.000Z"),
                       Time.parseMillis("2026-06-11T10:00:00Z"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(Time.parseMillis("not-a-date"))
        XCTAssertNil(Time.parseMillis(""))
    }

    // The shared static formatters must stay correct across many calls (no
    // mutation leaking between the two forms).
    func testRepeatedAlternatingCallsStayConsistent() {
        // 2026-01-02T03:04:05Z == 1767323045000 ms; +678 ms for the fractional form.
        let plain: Double = 1767323045000
        let frac: Double = 1767323045678
        for _ in 0..<100 {
            XCTAssertEqual(Time.parseMillis("2026-01-02T03:04:05.678Z")!, frac, accuracy: 0.5)
            XCTAssertEqual(Time.parseMillis("2026-01-02T03:04:05Z")!, plain, accuracy: 0.5)
        }
    }
}
