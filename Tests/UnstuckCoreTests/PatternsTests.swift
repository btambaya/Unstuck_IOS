// Ported from lib/assistant/patterns.test.ts.

import XCTest
@testable import UnstuckCore

// Saturday 29 Aug 2026 → current week starts Monday 2026-08-24; the history
// window is [2026-07-25, 2026-08-24). Recent Wednesdays (dow 3), newest
// first: 08-19, 08-12, 08-05, 07-29 (in window) and 07-22 (too old).
private let TODAY = "2026-08-29"
private let WEDS = ["2026-08-19", "2026-08-12", "2026-08-05", "2026-07-29"]

nonisolated(unsafe) private var seq = 0
private func nextId() -> String { seq += 1; return "id\(seq)" }

private func task(id: String = "gym", name: String = "Gym") -> TaskItem {
    TaskItem(id: id, name: name, estimateMin: 60, totalFocused: 0, done: false,
             createdAt: "2026-07-01T10:00:00Z", updatedAt: "2026-07-01T10:00:00Z")
}

private func block(_ date: String, taskId: String? = "gym", startTime: String = "07:00", done: Bool = false) -> CalBlock {
    CalBlock(id: nextId(), taskId: taskId, taskName: "Gym", startTime: startTime, durationMinutes: 60, date: date, done: done)
}

final class DerivePatternsTests: XCTestCase {

    func testThreeDistinctWeeksMakeAPatternTwoAreJustNoise() {
        let three = derivePatterns([task()], WEDS.prefix(3).map { block($0) }, todayIso: TODAY)
        XCTAssertEqual(three.count, 1)
        XCTAssertEqual(three[0].taskId, "gym")
        XCTAssertEqual(three[0].taskName, "Gym")
        XCTAssertEqual(three[0].dow, 3)
        XCTAssertEqual(three[0].time, "07:00")
        XCTAssertEqual(three[0].weeksSeen, 3)
        XCTAssertEqual(three[0].label, "Gym most Wednesdays at 07:00 (3 of the last 4 weeks)")

        XCTAssertEqual(derivePatterns([task()], WEDS.prefix(2).map { block($0) }, todayIso: TODAY), [])
    }

    func testFourWeeksReadExactlyLikeTheSpecExample() {
        let p = derivePatterns([task()], WEDS.map { block($0) }, todayIso: TODAY)
        XCTAssertEqual(p[0].label, "Gym most Wednesdays at 07:00 (4 of the last 4 weeks)")
        XCTAssertEqual(p[0].weeksSeen, 4)
    }

    func testCurrentWeekBlocksAreThePlanNotHistoryTheyNeverCount() {
        // Two history Wednesdays + this week's Wednesday (26 Aug) = still only 2.
        let blocks = WEDS.prefix(2).map { block($0) } + [block("2026-08-26")]
        XCTAssertEqual(derivePatterns([task()], blocks, todayIso: TODAY), [])
    }

    func testBlocksOlderThan35DaysFallOutOfTheWindow() {
        // 22 Jul is a Wednesday but predates today-35 (25 Jul).
        let blocks = WEDS.prefix(2).map { block($0) } + [block("2026-07-22")]
        XCTAssertEqual(derivePatterns([task()], blocks, todayIso: TODAY), [])
        // …whereas 29 Jul (in window) completes the trio.
        let ok = WEDS.prefix(2).map { block($0) } + [block("2026-07-29")]
        XCTAssertEqual(derivePatterns([task()], ok, todayIso: TODAY).count, 1)
    }

    func testDoneOccurrencesStillCount() {
        let blocks = WEDS.prefix(3).map { block($0, done: true) }
        XCTAssertEqual(derivePatterns([task()], blocks, todayIso: TODAY).count, 1)
    }

    func testTwoBlocksInTheSameWeekCountAsOneWeek() {
        let blocks = [block("2026-08-19"), block("2026-08-19"), block("2026-08-12")]
        XCTAssertEqual(derivePatterns([task()], blocks, todayIso: TODAY), [])
    }

    func testTheMostCommonStartTimeWinsTheLabel() {
        let blocks = [
            block("2026-08-19", startTime: "07:00"),
            block("2026-08-12", startTime: "08:30"),
            block("2026-08-05", startTime: "07:00"),
        ]
        let p = derivePatterns([task()], blocks, todayIso: TODAY)[0]
        XCTAssertEqual(p.time, "07:00")
        XCTAssertTrue(p.label.contains("at 07:00"))
    }

    func testUntimedOccurrencesYieldNoTimeAndALabelWithoutOne() {
        let blocks = WEDS.prefix(3).map { block($0, startTime: "") }
        let p = derivePatterns([task()], blocks, todayIso: TODAY)[0]
        XCTAssertNil(p.time)
        XCTAssertEqual(p.label, "Gym most Wednesdays (3 of the last 4 weeks)")
    }

    func testBlocksWithoutAResolvableTaskOrNoTaskIdAreIgnored() {
        let orphan = WEDS.prefix(3).map { block($0, taskId: "ghost") }
        XCTAssertEqual(derivePatterns([task()], orphan, todayIso: TODAY), [])
        let untasked = WEDS.prefix(3).map { block($0, taskId: nil) }
        XCTAssertEqual(derivePatterns([task()], untasked, todayIso: TODAY), [])
    }

    func testSeparateWeekdaysBuildSeparatePatternsForTheSameTask() {
        let mons = ["2026-08-17", "2026-08-10", "2026-08-03"] // Mondays, dow 1
        let blocks = WEDS.prefix(3).map { block($0) } + mons.map { block($0, startTime: "18:00") }
        let pats = derivePatterns([task()], blocks, todayIso: TODAY)
        XCTAssertEqual(pats.map { $0.dow }.sorted(), [1, 3])
    }
}

final class PatternGapsTests: XCTestCase {
    private let pattern = Pattern(taskId: "gym", taskName: "Gym", dow: 3, time: "07:00", weeksSeen: 4,
                                  label: "Gym most Wednesdays at 07:00 (4 of the last 4 weeks)")

    func testRollsToNextWeekWhenTheWeekdayAlreadyPassedThisWeek() {
        // Saturday 29 Aug: this week's Wednesday (26th) is behind us → 2 Sept.
        let gaps = patternGaps([pattern], [], todayIso: TODAY)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].dueDate, "2026-09-02")
        XCTAssertEqual(gaps[0].taskId, "gym")
        XCTAssertEqual(gaps[0].taskName, "Gym")
        XCTAssertEqual(gaps[0].dow, 3)
    }

    func testLandsThisWeekWhileTheWeekdayIsStillAheadAndTodayCounts() {
        XCTAssertEqual(patternGaps([pattern], [], todayIso: "2026-08-24")[0].dueDate, "2026-08-26") // Monday
        XCTAssertEqual(patternGaps([pattern], [], todayIso: "2026-08-26")[0].dueDate, "2026-08-26") // Wednesday itself
    }

    func testANonDoneBlockForTheTaskOnTheDueDateSuppressesTheGap() {
        XCTAssertEqual(patternGaps([pattern], [block("2026-09-02")], todayIso: TODAY), [])
    }

    func testADoneBlockDoesNotSuppress() {
        XCTAssertEqual(patternGaps([pattern], [block("2026-09-02", done: true)], todayIso: TODAY).count, 1)
    }

    func testABlockForADifferentTaskOnTheDueDateDoesNotSuppress() {
        XCTAssertEqual(patternGaps([pattern], [block("2026-09-02", taskId: "other")], todayIso: TODAY).count, 1)
    }

    func testTheDueDateReallyFallsOnThePatternWeekday() {
        for dow in 0...6 {
            var p = pattern
            p.dow = dow
            let gap = patternGaps([p], [], todayIso: TODAY)[0]
            XCTAssertEqual(LocalDate.dayOfWeek(gap.dueDate), dow)
            XCTAssertTrue(gap.dueDate >= TODAY)
        }
    }

    func testFeedsStraightFromDerivePatternsEndToEnd() {
        let history = WEDS.map { block($0, done: true) }
        let pats = derivePatterns([task()], history, todayIso: TODAY)
        let gaps = patternGaps(pats, history, todayIso: TODAY)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].dueDate, "2026-09-02")
        XCTAssertEqual(gaps[0].label, "Gym most Wednesdays at 07:00 (4 of the last 4 weeks)")
    }
}
