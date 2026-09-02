// Ported from lib/assistant/brief.test.ts.

import XCTest
@testable import UnstuckCore

private let TODAY = "2026-08-29"
// Local construction — the brief must be DST-proof.
private func at(_ h: Int, _ min: Int = 0) -> Date {
    Calendar.current.date(bySettingHour: h, minute: min, second: 0, of: Time.civil(2026, 8, 29))!
}

nonisolated(unsafe) private var seq = 0
private func nextId() -> String { seq += 1; return "id\(seq)" }

private func task(id: String? = nil, name: String = "A task", done: Bool = false, recurrence: Recurrence? = nil) -> TaskItem {
    TaskItem(id: id ?? nextId(), name: name, estimateMin: 25, totalFocused: 0, done: done, recurrence: recurrence,
             createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z")
}

private func block(_ startTime: String, taskId: String? = "t", taskName: String = "A task",
                   done: Bool = false, skipped: Bool = false) -> CalBlock {
    CalBlock(id: nextId(), taskId: taskId, taskName: taskName, startTime: startTime, durationMinutes: 30,
             date: TODAY, done: done, skipped: skipped)
}

private func brief(_ tasks: [TaskItem], _ blocks: [CalBlock], _ now: Date, _ usable: Int? = nil) -> String {
    composeBrief(tasks: tasks, blocks: blocks, todayIso: TODAY, now: now, usableMinutes: usable)
}

final class ComposeBriefTests: XCTestCase {

    func testReadsExactlyLikeTheSpecExampleNoGreetingPrefix() {
        let anchor = task(id: "w", name: "Write the project update")
        let blocks = [block("11:00", taskId: "w"), block("14:00"), block("16:00")]
        XCTAssertEqual(brief([anchor], blocks, at(9)),
                       "Three things scheduled today — ‘Write the project update’ at 11:00 is the anchor.")
    }

    func testHandlesTheSingularDay() {
        let t = task(id: "w", name: "Deep work")
        XCTAssertEqual(brief([t], [block("10:00", taskId: "w")], at(9)),
                       "One thing scheduled today — ‘Deep work’ at 10:00 is the anchor.")
    }

    func testAnchorsOnTheFirstBlockAtOrAfterNow() {
        let t = task(id: "w", name: "Client call")
        let blocks = [block("09:00"), block("14:00", taskId: "w")]
        XCTAssertEqual(brief([t], blocks, at(12)),
                       "Two things scheduled today — ‘Client call’ at 14:00 is the anchor.")
    }

    func testABlockStartingExactlyNowStillAnchors() {
        let t = task(id: "w", name: "Standup")
        XCTAssertTrue(brief([t], [block("11:00", taskId: "w")], at(11)).contains("‘Standup’ at 11:00"))
    }

    func testWhenEverythingIsBehindUsTheFirstBlockOfTheDayAnchors() {
        let t = task(id: "w", name: "Morning pages")
        let blocks = [block("09:00", taskId: "w"), block("11:00")]
        XCTAssertTrue(brief([t], blocks, at(18)).contains("‘Morning pages’ at 09:00 is the anchor"))
    }

    func testDoneAndSkippedBlocksAreNotScheduledToday() {
        let t = task(id: "w", name: "The one live thing")
        let blocks = [block("09:00", done: true), block("10:00", skipped: true), block("15:00", taskId: "w")]
        XCTAssertEqual(brief([t], blocks, at(9)),
                       "One thing scheduled today — ‘The one live thing’ at 15:00 is the anchor.")
    }

    func testAnUntimedAnchorDropsTheAtClause() {
        let t = task(id: "w", name: "Sometime today")
        XCTAssertEqual(brief([t], [block("", taskId: "w")], at(9)),
                       "One thing scheduled today — ‘Sometime today’ is the anchor.")
    }

    func testPrefersTheTasksCurrentNameOverTheBlocksStaleCopy() {
        let renamed = task(id: "w", name: "Fresh name")
        XCTAssertTrue(brief([renamed], [block("10:00", taskId: "w", taskName: "Stale name")], at(9)).contains("‘Fresh name’"))
        XCTAssertTrue(brief([], [block("10:00", taskId: "ghost", taskName: "Orphan block")], at(9)).contains("‘Orphan block’"))
    }

    // MARK: empty calendar

    func testOffersTheOpenPile() {
        let open = (0..<7).map { _ in task() }
        XCTAssertEqual(brief(open, [], at(9)), "Nothing on the calendar today — 7 open tasks if you want to pull one in.")
    }

    func testSpeaksSingularForASingleOpenTask() {
        XCTAssertEqual(brief([task()], [], at(9)), "Nothing on the calendar today — 1 open task if you want to pull one in.")
    }

    func testDoneTasksAndRecurringTemplatesAreNotOpen() {
        let tasks = [task(), task(done: true), task(recurrence: .weekly(daysOfWeek: [1], until: nil))]
        XCTAssertTrue(brief(tasks, [], at(9)).contains("1 open task"))
    }

    func testATrulyClearDayGetsTheCalmLine() {
        XCTAssertEqual(brief([], [], at(9)), "A clear day. Add what’s on your mind below.")
    }

    // MARK: usable minutes — the runway sentence

    private var deep: TaskItem { task(id: "w", name: "Deep work") }
    private var eleven: [CalBlock] { [block("11:00", taskId: "w")] }

    func testAppendsRoundedToTheNearestFive() {
        XCTAssertEqual(brief([deep], eleven, at(9), 92),
                       "One thing scheduled today — ‘Deep work’ at 11:00 is the anchor. About 90 usable minutes before it.")
        XCTAssertTrue(brief([deep], eleven, at(9), 88).contains("About 90 usable minutes"))
        XCTAssertTrue(brief([deep], eleven, at(9), 87).contains("About 85 usable minutes"))
        XCTAssertTrue(brief([deep], eleven, at(9), 15).contains("About 15 usable minutes"))
    }

    func testSuppressedUnder15Minutes() {
        XCTAssertFalse(brief([deep], eleven, at(9), 14).contains("usable"))
    }

    func testSuppressedWhenTheAnchorIsNotStrictlyAheadOfNow() {
        XCTAssertFalse(brief([deep], eleven, at(11), 90).contains("usable"))   // exactly now
        XCTAssertFalse(brief([deep], eleven, at(12), 90).contains("usable"))   // behind us
        XCTAssertFalse(brief([deep], [block("", taskId: "w")], at(9), 90).contains("usable")) // untimed
    }

    func testSuppressedWhenAbsent() {
        XCTAssertFalse(brief([deep], eleven, at(9)).contains("usable"))
        XCTAssertFalse(brief([deep], eleven, at(9), nil).contains("usable"))
    }
}

final class ProbeQuestionTests: XCTestCase {
    private func gap(taskName: String = "Gym", dow: Int = 3, dueDate: String = "2026-09-02") -> Gap {
        Gap(taskId: "gym", taskName: taskName, dow: dow, time: "07:00", weeksSeen: 4,
            label: "Gym most Wednesdays at 07:00 (4 of the last 4 weeks)", dueDate: dueDate)
    }

    func testReadsExactlyLikeTheSpecExampleBritishSeptNoLeadingZero() {
        XCTAssertEqual(probeQuestion(gap()), "You usually do ‘Gym’ on Wednesdays — still on for Wednesday 2 Sept?")
    }

    func testFormatsOtherWeekdaysAndMonthsFromTheDueDateLocally() {
        XCTAssertEqual(probeQuestion(gap(taskName: "Yoga", dow: 1, dueDate: "2026-08-31")),
                       "You usually do ‘Yoga’ on Mondays — still on for Monday 31 Aug?")
    }
}
