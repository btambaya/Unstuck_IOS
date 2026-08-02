// Ported from lib/assistant/checkin.test.ts. The check-in is spoken in the
// assistant's voice but built from real counts with zero tokens — so the copy
// (and its grammar) is pinned.

import XCTest
@testable import UnstuckCore

final class AssistantCheckinTests: XCTestCase {

    func testGreetsByFirstNameWithCountsAndUsableTime() {
        XCTAssertEqual(
            buildCheckin(firstName: "Maya", openTodayCount: 3, usableLabel: "2h 40m", hour: 9),
            "Morning, Maya. 3 things on today, 2h 40m usable. Want me to sequence them, or take something off the list?")
    }

    func testSingularGrammarAndNoUsableLabel() {
        XCTAssertEqual(
            buildCheckin(firstName: nil, openTodayCount: 1, usableLabel: nil, hour: 14),
            "Afternoon. 1 thing on today. Want me to sequence them, or take something off the list?")
    }

    func testEmptyDayOffersPlanningInstead() {
        XCTAssertEqual(
            buildCheckin(firstName: "Maya", openTodayCount: 0, usableLabel: nil, hour: 20),
            "Evening, Maya. Nothing scheduled yet — want me to help plan today?")
    }

    func testTimeOfDayBoundaries() {
        XCTAssertTrue(buildCheckin(firstName: nil, openTodayCount: 0, usableLabel: nil, hour: 0).hasPrefix("Morning"))
        XCTAssertTrue(buildCheckin(firstName: nil, openTodayCount: 0, usableLabel: nil, hour: 11).hasPrefix("Morning"))
        XCTAssertTrue(buildCheckin(firstName: nil, openTodayCount: 0, usableLabel: nil, hour: 12).hasPrefix("Afternoon"))
        XCTAssertTrue(buildCheckin(firstName: nil, openTodayCount: 0, usableLabel: nil, hour: 17).hasPrefix("Afternoon"))
        XCTAssertTrue(buildCheckin(firstName: nil, openTodayCount: 0, usableLabel: nil, hour: 18).hasPrefix("Evening"))
        XCTAssertTrue(buildCheckin(firstName: nil, openTodayCount: 0, usableLabel: nil, hour: 23).hasPrefix("Evening"))
    }
}
