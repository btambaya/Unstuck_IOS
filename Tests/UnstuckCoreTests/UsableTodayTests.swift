// Ported from lib/use-usable-today.ts (the assistant context strip must show
// the SAME number as the web's right-rail TimeRemaining panel).

import XCTest
@testable import UnstuckCore

final class UsableTodayTests: XCTestCase {
    private let TODAY = "2026-08-02"

    private func block(_ id: String, minutes: Int, date: String? = nil,
                       kind: CalBlockKind? = nil, taskId: String? = "t") -> CalBlock {
        CalBlock(id: id, taskId: taskId, taskName: "A task", startTime: "09:00",
                 durationMinutes: minutes, date: date ?? TODAY, kind: kind)
    }

    func testSubtractsMeetingsAndBuffersFromTodaysScheduledMinutes() {
        let blocks = [
            block("a", minutes: 90, kind: .task),
            block("b", minutes: 60, kind: .external),
            block("c", minutes: 30, kind: .placeholder),
            block("d", minutes: 45, date: "2026-08-03", kind: .task),   // tomorrow — ignored
        ]
        let u = usableToday(blocks: blocks, todayIso: TODAY)
        XCTAssertEqual(u.totalScheduled, 180)
        XCTAssertEqual(u.meetingMins, 60)
        XCTAssertEqual(u.bufferedMins, 30)
        XCTAssertEqual(u.usableMins, 90)
    }

    func testFloorsAtZeroAndReportsNothingForAnEmptyDay() {
        XCTAssertEqual(usableToday(blocks: [], todayIso: TODAY).usableMins, 0)
        let onlyMeetings = [block("a", minutes: 120, kind: .external)]
        XCTAssertEqual(usableToday(blocks: onlyMeetings, todayIso: TODAY).usableMins, 0)
    }

    func testFmtHrsMatchesTheWebFormatter() {
        XCTAssertEqual(fmtHrs(0), "0m")
        XCTAssertEqual(fmtHrs(45), "45m")
        XCTAssertEqual(fmtHrs(60), "1h")
        XCTAssertEqual(fmtHrs(160), "2h 40m")
    }
}
