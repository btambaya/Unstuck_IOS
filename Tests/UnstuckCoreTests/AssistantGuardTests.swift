// Ported from lib/assistant/action-claim.test.ts + the guard half of
// lib/assistant/receipts.test.ts (verb width, turn awareness, apology-only
// stripping — 2026-09-20 tooling rewrite). The claim detector must catch
// first-person completed-action claims and must NOT trip on honest answers
// about existing state or truthful references to an earlier turn.

import XCTest
@testable import UnstuckCore

final class AssistantGuardTests: XCTestCase {

    // MARK: looksLikeActionClaim

    func testCatchesTheObservedQwenFabrications() {
        XCTAssertTrue(looksLikeActionClaim("Done — added \"Feed the goldfish\" (5 min)."))
        XCTAssertTrue(looksLikeActionClaim("Done — added ‘Water the plants’ (10 min)."))
        XCTAssertTrue(looksLikeActionClaim("I've scheduled it for Tuesday morning."))
        XCTAssertTrue(looksLikeActionClaim("I have created “Renew passport”."))
        XCTAssertTrue(looksLikeActionClaim("All set — moved “Gym” to Thursday."))
    }

    func testLetsHonestScheduleAnswersAndQuestionsThrough() {
        XCTAssertFalse(looksLikeActionClaim("Your dentist appointment is scheduled for Friday at 10:00."))
        XCTAssertFalse(looksLikeActionClaim("Want me to schedule it Tuesday morning?"))
        XCTAssertFalse(looksLikeActionClaim("You have three things today — the project update at 11:00 is the anchor."))
        XCTAssertFalse(looksLikeActionClaim("Who’s Maleek — should I remember him?"))
        XCTAssertFalse(looksLikeActionClaim(""))
        XCTAssertFalse(looksLikeActionClaim(nil))
    }

    // Tester-round widenings (2026-08-31)

    func testCatchesPassiveVerbLeadAndArticleForms() {
        XCTAssertTrue(looksLikeActionClaim("The task has been created."))
        XCTAssertTrue(looksLikeActionClaim("Your tasks have been moved to tomorrow."))
        XCTAssertTrue(looksLikeActionClaim("Created the task for you."))
        XCTAssertTrue(looksLikeActionClaim("I just moved the task to Friday."))
    }

    func testCatchesEmptyMemoryPromises() {
        XCTAssertTrue(looksLikeActionClaim("I'll take a note of it."))
        XCTAssertTrue(looksLikeActionClaim("I will make a note of that."))
        XCTAssertTrue(looksLikeActionClaim("Noted — I won't mention your name again."))
        XCTAssertTrue(looksLikeActionClaim("I'll remember that."))
    }

    func testStillAllowsHonestStateAnswersAndQuestions() {
        XCTAssertFalse(looksLikeActionClaim("Your dentist task is scheduled for Friday at 10:00."))
        XCTAssertFalse(looksLikeActionClaim("Want me to move it to Tuesday?"))
        XCTAssertFalse(looksLikeActionClaim("That task was created last week by you."))
    }

    func testCatchesSettingsStyleLies() {
        XCTAssertTrue(looksLikeActionClaim("Set to 240 minutes per day — done."))
        XCTAssertTrue(looksLikeActionClaim("Reminders on, done."))
        XCTAssertTrue(looksLikeActionClaim("Set to calm ✓ enjoy the quiet"))
        XCTAssertFalse(looksLikeActionClaim("When you are done, tell me how it went."))
    }

    func testCatchesCompliancePromisesThatNeedPersistence() {
        XCTAssertTrue(looksLikeActionClaim("Sure — I'll stop using your name from now on."))
        XCTAssertTrue(looksLikeActionClaim("Okay, I will not mention it again."))
    }

    // MARK: stripSelfCorrection (tester: "it trips itself", 2026-09-02)

    func testDropsTheApologyAimedAtTheHiddenIntegrityCheck() {
        XCTAssertEqual(
            stripSelfCorrection("Oh sorry — I said I added a capture but I didn't. Let me add it now. Captured \"ask Sam\" on Project check-in."),
            "Captured \"ask Sam\" on Project check-in.")
        XCTAssertEqual(
            stripSelfCorrection("Sorry, that wasn't actually done. Actually, I hadn't added it yet! Done — added the capture."),
            "Done — added the capture.")
        XCTAssertEqual(
            stripSelfCorrection("My mistake. Added \"Walk the dog\" for tomorrow at 9."),
            "Added \"Walk the dog\" for tomorrow at 9.")
    }

    func testLeavesOrdinaryAnswersAlone() {
        XCTAssertEqual(
            stripSelfCorrection("Done — added the capture to Project check-in."),
            "Done — added the capture to Project check-in.")
        XCTAssertTrue(
            stripSelfCorrection("Sorry to hear the day was rough. Want me to move the report to tomorrow?").hasPrefix("Sorry to hear"))
    }

    func testStripsAtMostFourLeadingCorrections() {
        let s = "Sorry. My mistake. Correction: it wasn't saved. Apologies again. Sorry once more. Saved it now."
        // Four passes (web parity) remove the first four sentences; the fifth apology stays.
        XCTAssertEqual(stripSelfCorrection(s), "Sorry once more. Saved it now.")
    }

    // MARK: verb width (receipts.test.ts — harness audit, 2026-09-05)

    func testCatchesVariedOpeners() {
        for s in [
            "Booked. Thursday 2pm.",
            "Skipped gym today.",
            "Reopened “Dentist”.",
            "Ticked “eggs” off Groceries.",
            "Renamed “Home” to “House”.",
            "Unscheduled “Gym”.",
            "Carried three to tomorrow.",
            "Paused your focus session.",
            "Extended the session by 10 minutes.",
            "Cancelled the call.",
            "I've forgotten that about Sam.",
            "I've remembered that you like mornings.",
            "Promoted “Buy paint” to a task.",
            "I've started a focus session on “Report”.",
            "I've set your reminders to 10 minutes.",
            "I've turned the evening sweep off.",
            "The task has been reopened.",
            "Your gym slot has been skipped.",
            "I just blocked the afternoon for it.",
            // 2026-09-20 tools
            "Restored “Call the plumber” to your inbox.",
            "Pinned “Milk” to the top.",
            "I've recoloured “Groceries” green.",
            "Recolored the list.",
        ] {
            XCTAssertTrue(looksLikeActionClaim(s), s)
        }
    }

    func testDoesNotTripOnHonestSentenceLeadsThatShareAVerb() {
        XCTAssertFalse(looksLikeActionClaim("Set aside twenty minutes for it?"))
        XCTAssertFalse(looksLikeActionClaim("Shared tasks show up under People in Settings."))
        XCTAssertFalse(looksLikeActionClaim("Started already? Tell me how far you got."))
    }

    // MARK: turn awareness

    func testPassesTruthfulReferencesToAPreviousTurn() {
        XCTAssertFalse(looksLikeActionClaim("Yes — I added “Buy milk” earlier, it is on your list."))
        XCTAssertFalse(looksLikeActionClaim("I moved it earlier — it is on Friday now."))
        XCTAssertFalse(looksLikeActionClaim("As I said, I scheduled it for Friday at 9."))
        XCTAssertFalse(looksLikeActionClaim("I've already added that one."))
        XCTAssertFalse(looksLikeActionClaim("I created it a moment ago when you asked."))
        XCTAssertTrue(refersToEarlierTurn("Like I mentioned, the task has been created."))
    }

    func testStillBouncesAThisTurnClaimSittingNextToARecap() {
        XCTAssertTrue(looksLikeActionClaim("I moved the dentist earlier. Done — added “Buy milk” too."))
        XCTAssertTrue(looksLikeActionClaim("Sure. I've added “Buy milk” to your tasks."))
    }

    func testThisTurnPhrasingsThatMentionTimeAreStillClaims() {
        XCTAssertTrue(looksLikeActionClaim("I've moved it to 9, before your meeting."))
        XCTAssertTrue(looksLikeActionClaim("I've scheduled it for this morning."))
    }

    // MARK: stripSelfCorrection — apology forms only

    func testKeepsATruthfulLeadingActuallyOrLetMeWhenNoApologyPrecedesIt() {
        let t = "Actually, I scheduled it for Friday at 9 since mornings are your best. Want a reminder?"
        XCTAssertEqual(stripSelfCorrection(t), t)
        XCTAssertEqual(stripSelfCorrection("Let me add that now. Added “Gym” for tomorrow."), "Let me add that now. Added “Gym” for tomorrow.")
    }

    func testStripsATrailingApologyTheUserHasNoContextFor() {
        XCTAssertEqual(stripSelfCorrection("Added “Gym” for tomorrow at 9. Sorry for the confusion earlier."), "Added “Gym” for tomorrow at 9.")
        XCTAssertEqual(stripSelfCorrection("Added “Gym” for tomorrow at 9. My mistake earlier!"), "Added “Gym” for tomorrow at 9.")
    }

    func testNeverBlanksAReplyThatIsOnlyAnApology() {
        XCTAssertEqual(stripSelfCorrection("Sorry about that."), "Sorry about that.")
        XCTAssertEqual(stripSelfCorrection("   Sorry about that.  "), "Sorry about that.")
    }
}
