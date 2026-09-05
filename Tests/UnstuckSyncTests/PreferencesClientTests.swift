// PreferencesClient's pure helper for the cross-device interview flag:
// `assistant_interview_done_at` comes back from PostgREST as a timestamptz —
// `+00:00` offset, and up to six fractional digits when the server wrote
// `now()`. A nil parse would read as "not done" and re-ask, so every shape
// the column can take must parse.

import XCTest
@testable import UnstuckSync

final class PreferencesClientTests: XCTestCase {
    func testParsesEveryTimestamptzShapePostgRESTEmits() {
        XCTAssertNotNil(PreferencesClient.parseTimestamp("2026-09-05T10:11:12+00:00"), "no fraction")
        XCTAssertNotNil(PreferencesClient.parseTimestamp("2026-09-05T10:11:12.123+00:00"), "millis (our own writes)")
        XCTAssertNotNil(PreferencesClient.parseTimestamp("2026-09-05T10:11:12.123456+00:00"), "micros (server now())")
        XCTAssertNotNil(PreferencesClient.parseTimestamp("2026-09-05T10:11:12.1+00:00"), "trailing zeros trimmed")
        XCTAssertNotNil(PreferencesClient.parseTimestamp("2026-09-05T10:11:12.123Z"))
        XCTAssertNotNil(PreferencesClient.parseTimestamp("  2026-09-05T10:11:12.123456Z  "))
    }

    func testMicrosecondsKeepTheMillisecondPrecision() {
        let micros = PreferencesClient.parseTimestamp("2026-09-05T10:11:12.123456+00:00")!
        let plain = PreferencesClient.parseTimestamp("2026-09-05T10:11:12+00:00")!
        XCTAssertEqual(micros.timeIntervalSince(plain), 0.123, accuracy: 0.001)
    }

    func testGarbageIsNilNotDone() {
        XCTAssertNil(PreferencesClient.parseTimestamp(""))
        XCTAssertNil(PreferencesClient.parseTimestamp("   "))
        XCTAssertNil(PreferencesClient.parseTimestamp("yes"))
        XCTAssertNil(PreferencesClient.parseTimestamp("2026-09-05T10:11:12.+00:00"))
    }
}
