// The calendar chip text for a block someone shared with me: the TASK leads,
// the sharer is a suffix (dropped first under truncation, dropped entirely in
// compact mode). Mirrors lib/shared-blocks.test.ts (`sharedBlockLabel`) and
// the Android SharedScheduleTest.

import XCTest
@testable import UnstuckCore

final class SharedBlockLabelTests: XCTestCase {

    func testTaskLeadsAndTheSharerFollows() {
        XCTAssertEqual(sharedBlockLabel(taskName: "London weekend", sharer: "Anna Ahmed"), "London weekend · Anna Ahmed")
    }

    func testAnEmailSharerLosesItsDomain() {
        XCTAssertEqual(sharedBlockLabel(taskName: "Trip", sharer: "anna@example.com"), "Trip · anna")
    }

    func testCompactDropsTheSharerEntirely() {
        XCTAssertEqual(sharedBlockLabel(taskName: "London weekend", sharer: "anna odu", compact: true), "London weekend")
    }

    func testABlankSharerAddsNoSuffix() {
        XCTAssertEqual(sharedBlockLabel(taskName: "Trip", sharer: nil), "Trip")
        XCTAssertEqual(sharedBlockLabel(taskName: "Trip", sharer: ""), "Trip")
        XCTAssertEqual(sharedBlockLabel(taskName: "Trip", sharer: "   "), "Trip")
        XCTAssertEqual(sharedBlockLabel(taskName: "Trip", sharer: "@nowhere.example"), "Trip")
    }

    func testABlankTaskNameNeverYieldsAnEmptyChip() {
        XCTAssertEqual(sharedBlockLabel(taskName: "  ", sharer: "anna"), "Shared task · anna")
        XCTAssertEqual(sharedBlockLabel(taskName: "", sharer: nil, compact: true), "Shared task")
    }

    func testWhitespaceIsTrimmedOnBothSides() {
        XCTAssertEqual(sharedBlockLabel(taskName: "  Arabic Class ", sharer: " anna odu "), "Arabic Class · anna odu")
    }

    func testSharerDisplayName() {
        XCTAssertEqual(sharerDisplayName("anna@example.com"), "anna")
        XCTAssertEqual(sharerDisplayName("Anna B"), "Anna B")
        XCTAssertNil(sharerDisplayName(""))
        XCTAssertNil(sharerDisplayName(nil))
        XCTAssertNil(sharerDisplayName("@example.com"))
    }
}
