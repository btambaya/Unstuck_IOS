// Ported from lib/assistant/action-claim.test.ts + the stripSelfCorrection
// half of time-guard.test.ts. The claim detector must catch first-person
// completed-action claims and must NOT trip on honest answers about existing
// state.

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

    func testStripsAtMostThreeLeadingCorrections() {
        let s = "Sorry. My mistake. Correction: it wasn't saved. Apologies again. Saved it now."
        // Three passes remove the first three sentences; the fourth apology stays.
        XCTAssertEqual(stripSelfCorrection(s), "Apologies again. Saved it now.")
    }
}
