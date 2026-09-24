// James's TestFlight reports (build 51, 2026-09-13), still open on build 90:
// the park run booked on a Sunday for a Saturday series (SeriesWeekday), and
// ✓ Deleted cards for tasks nobody asked to delete (ConfirmFirst).

import XCTest
@testable import UnstuckCore

final class SeriesWeekdayTests: XCTestCase {
    // Sunday 13 Sep 2026: the coming Saturday is the 19th; the 20th is a Sunday.
    private let today = "2026-09-13"
    private let saturdays: Recurrence = .weekly(daysOfWeek: [6], until: nil)

    func testTheParkRunDateIsRefusedWithTheComingSaturdayNamedFirst() throws {
        let r = try XCTUnwrap(rejectOffSeriesDay(taskName: "Park run", recurrence: saturdays, date: "2026-09-20", today: today))
        XCTAssertEqual(r, "error: \"Park run\" repeats every Saturday, but 2026-09-20 is a Sunday — nothing was scheduled."
            + " Its nearest days are Saturday 19 September (2026-09-19) or Saturday 26 September (2026-09-26)."
            + " Call schedule_task again with the day the user meant (a weekday name means the coming one — copy it from context.upcoming)."
            + " Only if they asked for Sunday 20 September on purpose, as a one-off, call schedule_task again with exactly 2026-09-20."
            + " To change the days it repeats on, call set_task_recurrence first.")
    }

    func testADayTheSeriesRepeatsOnAndOtherRecurrencesPass() {
        XCTAssertNil(rejectOffSeriesDay(taskName: "Park run", recurrence: saturdays, date: "2026-09-19", today: today))
        XCTAssertNil(rejectOffSeriesDay(taskName: "Gym", recurrence: .daily(until: nil), date: "2026-09-20", today: today))
        XCTAssertNil(rejectOffSeriesDay(taskName: "Rent", recurrence: .monthly(until: nil), date: "2026-09-20", today: today))
        XCTAssertNil(rejectOffSeriesDay(taskName: "Once", recurrence: nil, date: "2026-09-20", today: today))
        // A weekly series with no days has nothing to check against.
        XCTAssertNil(rejectOffSeriesDay(taskName: "Odd", recurrence: .weekly(daysOfWeek: [], until: nil), date: "2026-09-20", today: today))
        XCTAssertFalse(isOffSeriesDay(saturdays, date: "2026-09-31"))
    }

    func testNearestDaysNeverReachBeforeToday() {
        XCTAssertEqual(nearestSeriesDays(daysOfWeek: [6], date: "2026-09-20", today: today), ["2026-09-19", "2026-09-26"])
        // Asked on the Sunday itself: last Saturday is gone.
        XCTAssertEqual(nearestSeriesDays(daysOfWeek: [6], date: "2026-09-20", today: "2026-09-20"), ["2026-09-26"])
        // Mon / Wed / Fri, a Tuesday given.
        XCTAssertEqual(nearestSeriesDays(daysOfWeek: [1, 3, 5], date: "2026-09-15", today: today), ["2026-09-14", "2026-09-16"])
    }

    func testPlainWords() {
        XCTAssertEqual(plainDayName("2026-09-19"), "Saturday 19 September")
        XCTAssertEqual(weekdayList([5, 1, 3]), "Monday, Wednesday and Friday")
        XCTAssertEqual(weekdayList([0, 6]), "Sunday and Saturday")
        XCTAssertEqual(offSeriesDayNote(recurrence: saturdays, date: "2026-09-20"),
                       " — a one-off on Sunday 20 September; the series stays on Saturday")
    }

    /// The variant: create_task on Sunday 20 Sep, then weekly on Saturday.
    func testASlotPlacedThisTurnOnTheWrongDayStopsTheRecurrence() throws {
        let r = try XCTUnwrap(rejectOffSeriesPlacement(taskName: "Park run", placedDate: "2026-09-20", daysOfWeek: [6], today: today))
        XCTAssertTrue(r.hasPrefix("error: \"Park run\" was just put on Sunday 20 September (2026-09-20), which isn't one of the days asked for (Saturday) — nothing changed."), r)
        XCTAssertTrue(r.contains("Saturday 19 September (2026-09-19)"), r)
        XCTAssertNil(rejectOffSeriesPlacement(taskName: "Park run", placedDate: "2026-09-19", daysOfWeek: [6], today: today))
    }
}

final class ConfirmFirstTests: XCTestCase {
    private func allows(_ target: String?, _ user: String, prev: String? = nil) -> Bool {
        ConfirmFirst.allows(tool: "delete_task", target: target, userText: user, previousAssistant: prev)
    }
    private func allows(tool: String, _ target: String?, _ user: String, prev: String? = nil) -> Bool {
        ConfirmFirst.allows(tool: tool, target: target, userText: user, previousAssistant: prev)
    }

    /// The exact turns James saw ✓ Deleted cards under.
    func testUnrelatedRequestsNeverDeleteAnything() {
        let prev = "Pack ski gear checklist is next — want me to schedule it?"
        XCTAssertFalse(allows("Pack ski gear checklist", "Show park run on calendar", prev: prev))
        XCTAssertFalse(allows("Gym", "Add travel to Skipton for tomorrow at 3pm for 3 hours", prev: prev))
        XCTAssertFalse(allows("Pack ski gear checklist", "Add travel to Skipton for tomorrow at 3pm for 3 hours", prev: prev))
    }

    func testAskingByNameIsEnough() {
        XCTAssertTrue(allows("Gym", "delete the gym task"))
        XCTAssertTrue(allows("Gym", "Can you remove Gym?"))
        XCTAssertTrue(allows("Pack ski gear checklist", "get rid of the ski gear checklist"))
        XCTAssertTrue(allows("Call mum", "bin call mum"))
        // A longer name needs two of its telling words.
        XCTAssertFalse(allows("Pack ski gear checklist", "delete ski"))
        // …and "don't" is never an ask.
        XCTAssertFalse(allows("Gym", "don't delete gym"))
        // Another task named, not this one.
        XCTAssertFalse(allows("Gym", "delete the dentist"))
    }

    func testTheTwoTurnConfirm() {
        let asked = "Want me to delete “Gym”? It has no slots left."
        XCTAssertTrue(allows("Gym", "yes", prev: asked))
        XCTAssertTrue(allows("Gym", "Yep go ahead", prev: asked))
        XCTAssertTrue(allows("Gym", "👍", prev: asked))
        XCTAssertFalse(allows("Gym", "no, keep it", prev: asked))
        XCTAssertFalse(allows("Gym", "wait", prev: asked))
        // A yes to a different question is not a yes to deleting.
        XCTAssertFalse(allows("Gym", "yes", prev: "Want me to schedule “Gym” for 6pm?"))
        // A yes to deleting something else.
        XCTAssertFalse(allows("Gym", "yes", prev: "Delete “Dentist”?"))
        // "yes, and the dentist too" — the dentist is named by the user.
        XCTAssertTrue(allows("Dentist", "yes, and the dentist too", prev: asked))
        // "do you think…" is a question, not a yes.
        XCTAssertFalse(allows("Gym", "do you think I should?", prev: asked))
        // The yes answers what the reply ASKED — its last question — not a
        // "delete" mentioned in passing before it.
        XCTAssertFalse(allows("Gym", "yes", prev: "I won't delete anything unless you say so. Want me to schedule Gym?"))
        XCTAssertTrue(allows("Gym", "yes", prev: "These are done: Gym, Dentist and Taxes. Delete them?"))
        XCTAssertTrue(allows("Gym", "Sí", prev: asked))
        XCTAssertEqual(ConfirmFirst.lastAsk(asked), "Want me to delete “Gym”?")
        XCTAssertEqual(ConfirmFirst.lastAsk("Say yes and I'll delete Gym."), "Say yes and I'll delete Gym.")
    }

    func testReplacingOneTaskWithAnotherIsAnAskToDeleteTheOldOne() {
        XCTAssertTrue(allows("Gym", "replace gym with swimming"))
        XCTAssertFalse(allows("Swimming lessons", "replace gym with a walk"))
    }

    func testPointingAtWhatWasJustNamed() {
        XCTAssertTrue(allows("Gym", "delete it", prev: "Gym is on at 6pm today."))
        XCTAssertFalse(allows("Gym", "delete it", prev: "Dentist is on at 6pm today."))
        XCTAssertFalse(allows("Gym", "delete it"))
        // A sweeping ask covers what the model picks.
        XCTAssertTrue(allows("Old thing", "delete all my completed tasks"))
        XCTAssertTrue(allows("Old thing", "yes", prev: "That's 5 done tasks — delete them all?"))
    }

    func testCancelFocus() {
        XCTAssertTrue(allows(tool: "cancel_focus", "Write report", "cancel this session"))
        XCTAssertTrue(allows(tool: "cancel_focus", "Write report", "stop"))
        XCTAssertTrue(allows(tool: "cancel_focus", "Write report", "scrap the timer, I got interrupted"))
        XCTAssertTrue(allows(tool: "cancel_focus", nil, "yes", prev: "Cancel this focus session without logging it?"))
        XCTAssertFalse(allows(tool: "cancel_focus", "Write report", "cancel my dentist appointment on friday"))
        XCTAssertFalse(allows(tool: "cancel_focus", "Write report", "what's next after this?"))
    }

    func testListsAreasTags() {
        XCTAssertTrue(allows(tool: "leave_list", "Book club", "leave the book club list"))
        XCTAssertTrue(allows(tool: "leave_list", "Book club", "remove me from book club"))
        XCTAssertFalse(allows(tool: "leave_list", "Book club", "add dune to book club"))
        XCTAssertTrue(allows(tool: "delete_list", "Groceries", "delete my groceries list"))
        XCTAssertFalse(allows(tool: "delete_list", "Groceries", "clear the ticked items"))
        XCTAssertTrue(allows(tool: "delete_area", "Volunteering", "remove the volunteering area"))
        XCTAssertTrue(allows(tool: "delete_tag", "urgent", "delete the urgent tag"))
        XCTAssertFalse(allows(tool: "delete_tag", "urgent", "tag it urgent"))
    }

    func testRefusalsSayNothingChangedAndToAskFirst() {
        XCTAssertEqual(ConfirmFirst.refusal(tool: "delete_task", target: "Gym"),
                       "error: not deleted — the user hasn't asked to delete \"Gym\" in this conversation. Nothing was changed. Ask them first (\"Delete “Gym”?\") and call delete_task only once they say yes.")
        XCTAssertTrue(ConfirmFirst.refusal(tool: "cancel_focus", target: "Write report").contains("finish_focus logs the time"))
        XCTAssertTrue(ConfirmFirst.refusal(tool: "leave_list", target: "Book club").hasPrefix("error: not left"))
    }
}
