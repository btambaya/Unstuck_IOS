// Ported 1:1 from lib/assistant/suggestions.test.ts — the chips are the
// assistant's promise about the user's own data, so every predicate and every
// piece of copy is pinned here exactly as the web pins it.

import XCTest
@testable import UnstuckCore

final class AssistantSuggestionsTests: XCTestCase {
    /// The web fixture's TODAY — a Sunday, so the coming weekend is 08-08/08-09.
    private let TODAY = "2026-08-02"

    private var counter = 0
    private func nextId() -> String { counter += 1; return "id\(counter)" }

    private func task(
        id: String? = nil,
        name: String = "A task",
        estimateMin: Int = 25,
        done: Bool = false,
        lifeArea: String? = nil,
        firstPhysicalAction: String? = nil,
        moveCount: Int? = nil,
        later: Bool? = nil,
        recurrence: Recurrence? = nil
    ) -> TaskItem {
        TaskItem(id: id ?? nextId(), name: name, estimateMin: estimateMin, totalFocused: 0,
                 done: done, lifeArea: lifeArea, firstPhysicalAction: firstPhysicalAction,
                 moveCount: moveCount, later: later, recurrence: recurrence,
                 createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z")
    }

    private func block(taskId: String? = "t", date: String? = nil, done: Bool = false) -> CalBlock {
        CalBlock(id: nextId(), taskId: taskId, taskName: "A task", startTime: "10:00",
                 durationMinutes: 30, date: date ?? TODAY, done: done)
    }

    private func list(_ name: String, archived: Bool? = nil) -> ItemCollection {
        ItemCollection(id: nextId(), name: name, color: "indigo", items: [], sortOrder: 0,
                       archived: archived)
    }

    private func labels(_ chips: [AssistantSuggestion]) -> [String] { chips.map(\.label) }

    // MARK: - the ported cases

    func testEmptyAccountOffersNothing() {
        let g = buildSuggestions(tasks: [], blocks: [], collections: [], todayIso: TODAY)
        XCTAssertTrue(g.gettingStarted.isEmpty)
        XCTAssertTrue(g.planAndSchedule.isEmpty)
        XCTAssertTrue(g.refine.isEmpty)
        XCTAssertTrue(g.isEmpty)
    }

    func testOpenTasksLightUpNextAndAnEmptyDayOffersToBlockItOut() {
        let g = buildSuggestions(tasks: [task()], blocks: [], collections: [], todayIso: TODAY)
        XCTAssertEqual(labels(g.gettingStarted), ["What should I work on next?"])
        XCTAssertTrue(labels(g.planAndSchedule).contains("Block out my day"))
    }

    func testALoadedTodayEarnsTheOverwhelmAndRealisticChips() {
        let t = task(id: "t1")
        let blocks = [block(taskId: "t1"), block(taskId: "t1"), block(taskId: "t1")]
        let g = buildSuggestions(tasks: [t], blocks: blocks, collections: [], todayIso: TODAY)
        let l = labels(g.gettingStarted)
        XCTAssertTrue(l.contains("I’m overwhelmed"))
        XCTAssertTrue(l.contains("What’s realistic today?"))
        XCTAssertTrue(l.contains("What should I work on next?"))
    }

    func testBreakDownTargetsTheBiggestChunkyTaskLackingAFirstAction() {
        let small = task(name: "Quick email", estimateMin: 15)
        let big = task(name: "Write the quarterly investor report", estimateMin: 90)
        let decomposed = task(name: "Prep deck", estimateMin: 120, firstPhysicalAction: "Open slides")
        let g = buildSuggestions(tasks: [small, big, decomposed], blocks: [], collections: [], todayIso: TODAY)
        let chip = g.refine.first { $0.label.hasPrefix("Break down") }
        XCTAssertNotNil(chip)
        XCTAssertTrue(chip!.label.contains("Write the quarterly"))
        XCTAssertTrue(chip!.message.contains("\"Write the quarterly investor report\""))
    }

    func testArchivedListsNeverSurface() {
        let g = buildSuggestions(tasks: [], blocks: [],
                                 collections: [list("Groceries", archived: true)], todayIso: TODAY)
        XCTAssertTrue(g.refine.isEmpty)
    }

    func testRecurringTemplatesAndDeferredTasksNeverDriveBreakDown() {
        let template = task(name: "Weekly review", estimateMin: 60,
                            recurrence: .weekly(daysOfWeek: [1], until: nil))
        let later = task(name: "Someday thing", estimateMin: 90, later: true)
        let g = buildSuggestions(tasks: [template, later], blocks: [], collections: [], todayIso: TODAY)
        XCTAssertNil(g.refine.first { $0.label.hasPrefix("Break down") })
    }

    func testLongNamesTruncateInTheLabelButStayFullInTheMessage() {
        let t = task(name: "Reorganize the entire garage storage system before winter", estimateMin: 60)
        let g = buildSuggestions(tasks: [t], blocks: [], collections: [], todayIso: TODAY)
        let chip = g.refine.first { $0.label.hasPrefix("Break down") }!
        XCTAssertLessThan(chip.label.count, 45)
        XCTAssertTrue(chip.label.contains("…"))
        XCTAssertTrue(chip.message.contains("Reorganize the entire garage storage system before winter"))
    }

    func testUnscheduledWorkBecomesAOneTapSchedulingActionNamedForTheCount() {
        let one = buildSuggestions(tasks: [task(name: "Call the bank")], blocks: [],
                                   collections: [], todayIso: TODAY)
        XCTAssertEqual(one.planAndSchedule[0].label, "Find time for “Call the bank”")
        XCTAssertTrue(one.planAndSchedule[0].message.contains("schedule it"))

        let many = buildSuggestions(tasks: [task(), task(), task()], blocks: [],
                                    collections: [], todayIso: TODAY)
        XCTAssertEqual(many.planAndSchedule[0].label, "Schedule my 3 unscheduled tasks")
    }

    func testAlreadyScheduledTasksAreNotOfferedForSchedulingAgain() {
        let t = task(id: "sched1")
        let g = buildSuggestions(tasks: [t], blocks: [block(taskId: "sched1")],
                                 collections: [], todayIso: TODAY)
        XCTAssertFalse(labels(g.planAndSchedule).joined(separator: ",").contains("unscheduled"))
        XCTAssertTrue(labels(g.planAndSchedule).contains("Move today’s leftovers to tomorrow"))
    }

    func testQuietWeekendPlanningNeedsAtLeastTwoLightPersonalOrHomeTasks() {
        let heavy = [task(name: "Deck", estimateMin: 90, lifeArea: "Work"),
                     task(name: "Deck 2", estimateMin: 60, lifeArea: "Work")]
        XCTAssertFalse(labels(buildSuggestions(tasks: heavy, blocks: [], collections: [], todayIso: TODAY).planAndSchedule)
            .contains("Plan a quiet weekend"))

        let light = [task(name: "Laundry", estimateMin: 30, lifeArea: "Home"),
                     task(name: "Call mum", estimateMin: 20, lifeArea: "Personal")]
        let g = buildSuggestions(tasks: light, blocks: [], collections: [], todayIso: TODAY)
        XCTAssertTrue(labels(g.planAndSchedule).contains("Plan a quiet weekend"))
        // Real weekend dates, not vague prose — and the REAL coming Sat/Sun.
        let msg = g.planAndSchedule.first { $0.label == "Plan a quiet weekend" }!.message
        XCTAssertTrue(msg.contains("2026-08-08 and 2026-08-09"), msg)
    }

    /// The tapped message becomes the user's own bubble, so its "not before"
    /// time reads in the phone's 12/24-hour clock (2026-09-24).
    func testQuietWeekendMessageFollowsThePhonesClock() {
        let light = [task(estimateMin: 30, lifeArea: "Home"), task(estimateMin: 20, lifeArea: "Personal")]
        func msg(_ clock: ClockFormat) -> String {
            buildSuggestions(tasks: light, blocks: [], collections: [], todayIso: TODAY, clock: clock)
                .planAndSchedule.first { $0.label == "Plan a quiet weekend" }!.message
        }
        XCTAssertTrue(msg(.h24).contains("nothing before 10:00,"), msg(.h24))
        XCTAssertTrue(msg(.h12).contains("nothing before 10 AM,"), msg(.h12))
        XCTAssertFalse(msg(.h24).contains("10am"))
    }

    func testAWeekendChipOnASaturdayPlansTodayAndTomorrow() {
        // 2026-08-08 IS a Saturday: `(6 - day + 7) % 7 == 0` keeps it today.
        let light = [task(estimateMin: 30, lifeArea: "Home"), task(estimateMin: 20, lifeArea: "Health")]
        let g = buildSuggestions(tasks: light, blocks: [], collections: [], todayIso: "2026-08-08")
        let msg = g.planAndSchedule.first { $0.label == "Plan a quiet weekend" }!.message
        XCTAssertTrue(msg.contains("2026-08-08 and 2026-08-09"), msg)
    }

    func testBulkFirstStepRefinementAppearsOnlyWithTwoOrMoreSteplessTasks() {
        let single = buildSuggestions(tasks: [task(estimateMin: 20)], blocks: [],
                                      collections: [], todayIso: TODAY)
        XCTAssertFalse(labels(single.refine).joined(separator: ",").contains("first steps"))

        let g = buildSuggestions(tasks: [task(estimateMin: 20), task(estimateMin: 30)],
                                 blocks: [], collections: [], todayIso: TODAY)
        XCTAssertTrue(labels(g.refine).contains("Add first steps to 2 tasks"))
    }

    func testTheLaterPileIsOfferedForTriageWithItsRealCount() {
        let later = [task(later: true), task(later: true), task(later: true)]
        XCTAssertTrue(labels(buildSuggestions(tasks: later, blocks: [], collections: [], todayIso: TODAY).refine)
            .contains("Tidy my Later pile (3)"))
    }

    func testAListIsOfferedByItsRealName() {
        let g1 = buildSuggestions(tasks: [], blocks: [], collections: [list("Groceries")], todayIso: TODAY)
        XCTAssertTrue(labels(g1.refine).contains("Add to Groceries"))
        XCTAssertTrue(g1.refine[0].message.contains("\"Groceries\""))

        let g2 = buildSuggestions(tasks: [], blocks: [], collections: [list("Lisbon trip")], todayIso: TODAY)
        XCTAssertTrue(labels(g2.refine).contains("Add to “Lisbon trip”"))
    }

    func testSlipRadarSurfacesOnlyWhenSomethingActuallySlipped() {
        XCTAssertFalse(labels(buildSuggestions(tasks: [task()], blocks: [], collections: [], todayIso: TODAY).refine)
            .contains("What keeps slipping?"))
        XCTAssertTrue(labels(buildSuggestions(tasks: [task(moveCount: 3)], blocks: [], collections: [], todayIso: TODAY).refine)
            .contains("What keeps slipping?"))
    }

    func testSlipRadarCountsAnAbandonedPastBlockForAnOpenTaskButNotADoneOne() {
        let t = task(id: "open1")
        let left = block(taskId: "open1", date: "2026-07-30")
        XCTAssertTrue(labels(buildSuggestions(tasks: [t], blocks: [left], collections: [], todayIso: TODAY).refine)
            .contains("What keeps slipping?"))
        let done = block(taskId: "open1", date: "2026-07-30", done: true)
        XCTAssertFalse(labels(buildSuggestions(tasks: [t], blocks: [done], collections: [], todayIso: TODAY).refine)
            .contains("What keeps slipping?"))
    }

    // MARK: - helper contracts the copy depends on

    func testShortenTrimsTrailingSpaceBeforeTheEllipsis() {
        XCTAssertEqual(shortenSuggestion("short", max: 24), "short")
        XCTAssertEqual(shortenSuggestion("Reorganize the entire garage"), "Reorganize the entire g…")
        // The 23-char prefix ends in a space → trimmed, exactly like JS trimEnd().
        XCTAssertEqual(shortenSuggestion("Call the bank about the thing", max: 15), "Call the bank…")
    }
}
