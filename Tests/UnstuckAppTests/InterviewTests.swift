// Unit tests for the get-to-know-you interview state machine (InterviewMachine)
// — the pure half of App/Features/Interview.swift: the web's seven-step
// script (order, categories, copy), what each answer saves, the people-answer
// splitting, a failed save keeping the step, done-on-reaching-the-picker, the
// auto-done rule (≥1 fact, never while open, never while a mid-way step is
// parked), resume after a collapse, the "I'm done" finisher, the cross-device
// done hook and the server done-flag. The interview now lives INSIDE the
// assistant thread (InterviewThreadTests covers that driver); the old Today
// card's auto-open gate is gone with the card. Each test uses a throwaway
// UserDefaults suite so nothing touches the device defaults.

import XCTest
import UnstuckCore
@testable import Unstuck

@MainActor
final class InterviewTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "test.interview.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// Captures the machine's side effects: saves as (category, fact) pairs
    /// (`saveOK` = whether the fake store accepts the write) and the number of
    /// times the done hook fired.
    private final class Harness {
        var saved: [(UnstuckCore.ProfileFactCategory, String)] = []
        var saveOK = true
        var doneCalls = 0
    }

    private func make(_ defaults: UserDefaults? = nil) -> (InterviewMachine, Harness) {
        let h = Harness()
        let m = InterviewMachine(
            defaults: defaults ?? freshDefaults(),
            save: { c, f in
                guard h.saveOK else { return false }
                h.saved.append((c, f))
                return true
            },
            onDone: { h.doneCalls += 1 })
        return (m, h)
    }

    private func chip(_ m: InterviewMachine, _ label: String) -> InterviewChip {
        m.current!.chips.first { $0.label == label }!
    }

    private func skip(_ m: InterviewMachine, times n: Int) { for _ in 0..<n { m.skipQuestion() } }

    // MARK: script (web parity — components/assistant/interview.tsx)

    func testScriptIsTheWebsSevenQuestionsInTheWebsOrder() {
        XCTAssertEqual(INTERVIEW_QUESTIONS.count, 7)
        XCTAssertEqual(INTERVIEW_QUESTIONS.map(\.key), ["rhythm", "work", "people", "fixed", "commitments", "nogo", "nudge"])
        XCTAssertEqual(INTERVIEW_QUESTIONS.map(\.category),
                       [.rhythm, .context, .person, .constraint, .context, .constraint, .preference],
                       "categories are the web's: work + commitments are context, fixed points + no-go are constraints")
        XCTAssertEqual(INTERVIEW_QUESTIONS.map(\.freePrefix), [nil, "Work", nil, nil, nil, "Never schedule", nil])
        XCTAssertEqual(INTERVIEW_QUESTIONS.map(\.allowFree), [false, true, true, true, true, true, false])
        XCTAssertEqual(INTERVIEW_QUESTIONS.map(\.splitNames), [false, false, true, false, false, false, false],
                       "names are one person fact each")
        XCTAssertTrue(INTERVIEW_QUESTIONS.allSatisfy { !$0.chips.isEmpty }, "every step is tap-answerable")
    }

    func testScriptCopyAndChipsMatchTheWeb() {
        let q = Dictionary(uniqueKeysWithValues: INTERVIEW_QUESTIONS.map { ($0.key, $0) })
        XCTAssertEqual(q["rhythm"]?.question, "When’s your head clearest?")
        XCTAssertEqual(q["rhythm"]?.chips.map(\.label), ["Morning", "Afternoon", "Evening", "It varies"])
        XCTAssertEqual(q["rhythm"]?.chips.map(\.fact), [
            "Mornings are the good hours — schedule the hard things early", "Afternoons are the good hours",
            "Evenings are the good hours — slow starter", nil])
        XCTAssertEqual(q["work"]?.question, "What do your work days look like?")
        XCTAssertEqual(q["work"]?.chips.map(\.label), ["9–5 weekdays", "Shifts", "Flexible / freelance", "Studying"])
        XCTAssertEqual(q["work"]?.chips.map(\.fact), [
            "Works roughly 9–5 on weekdays", "Works shifts — hours change week to week",
            "Flexible schedule — sets their own hours", "Studying — timetable over office hours"])
        XCTAssertEqual(q["people"]?.question, "Anyone whose schedule shapes yours — kids, a partner, someone you care for? Names help.")
        XCTAssertEqual(q["people"]?.chips.map(\.label), ["No one right now"])
        XCTAssertEqual(q["fixed"]?.question, "Fixed points in the week I should plan around? School runs, prayers, classes…")
        XCTAssertEqual(q["fixed"]?.chips.map(\.label), ["None"])
        XCTAssertEqual(q["commitments"]?.question, "Regular commitments — gym, rehearsals, clubs, volunteering?")
        XCTAssertEqual(q["commitments"]?.chips.map(\.label), ["Not really"])
        XCTAssertEqual(q["nogo"]?.question, "When should I never schedule anything?")
        XCTAssertEqual(q["nogo"]?.chips.map(\.label), ["Before 9am", "After 9pm", "Weekends", "No hard limits"])
        XCTAssertEqual(q["nogo"]?.chips.map(\.fact), [
            "Never schedule anything before 9am", "Never schedule anything after 9pm",
            "Keep weekends free — never schedule work there", nil])
        XCTAssertEqual(q["nudge"]?.question, "Last one — how should I nudge you?")
        XCTAssertEqual(q["nudge"]?.chips.map(\.label), ["Gently", "Keep me honest", "Barely at all"])
        XCTAssertEqual(q["nudge"]?.chips.map(\.fact), [
            "Prefers gentle nudges — suggest, never push", "Wants to be kept honest — direct nudges are welcome",
            "Minimal nudging — only speak up when it really matters"])
        for k in ["people", "fixed", "commitments"] {
            XCTAssertEqual(q[k]?.chips.map(\.fact), [nil], "\(k): the only chip is a null-fact opt-out")
        }
    }

    // MARK: steps

    func testFreshMachineStartsAtTheGreetingStep() {
        let (m, h) = make()
        XCTAssertEqual(m.step, 0)
        XCTAssertTrue(m.isFirstStep)
        XCTAssertFalse(m.isPicker)
        XCTAssertEqual(m.current?.key, "rhythm")
        XCTAssertEqual(m.progress, "1/7", "the eyebrow reads GETTING TO KNOW YOU · 1/7 — the web's count")
        XCTAssertTrue(h.saved.isEmpty)
        XCTAssertFalse(m.finished)
        XCTAssertNil(m.saveError)
    }

    func testChipWithFactSavesAndAdvances() {
        let (m, h) = make()
        m.answer(chip: chip(m, "Morning"))
        XCTAssertEqual(h.saved.count, 1)
        XCTAssertEqual(h.saved[0].0, .rhythm)
        XCTAssertEqual(h.saved[0].1, "Mornings are the good hours — schedule the hard things early")
        XCTAssertEqual(m.noted.last, "Mornings are the good hours — schedule the hard things early")
        XCTAssertEqual(m.step, 1)
        XCTAssertEqual(m.current?.key, "work", "work days come second, like the web")
        XCTAssertEqual(m.progress, "2/7")
        XCTAssertFalse(m.isFirstStep, "the greeting bubble only shows on the first step")
    }

    func testChipWithoutFactSavesNothingButStillAdvances() {
        let (m, h) = make()
        m.answer(chip: chip(m, "It varies"))
        XCTAssertTrue(h.saved.isEmpty)
        XCTAssertTrue(m.noted.isEmpty)
        XCTAssertEqual(m.step, 1)
    }

    func testWorkFreeTextIsAContextFactWithThePrefix() {
        let (m, h) = make()
        skip(m, times: 1)                                  // → work
        XCTAssertEqual(m.current?.key, "work")
        m.answerFree("four days, Fridays off")
        XCTAssertEqual(h.saved.last?.0, .context)
        XCTAssertEqual(h.saved.last?.1, "Work: four days, Fridays off")
        XCTAssertEqual(m.step, 2)
    }

    func testPeopleFreeTextSplitsCommaSeparatedNamesIntoPersonFacts() {
        let (m, h) = make()
        skip(m, times: 2)                                  // → people
        XCTAssertEqual(m.current?.key, "people")
        m.answerFree(" Maleek, Sam ,, ")
        XCTAssertEqual(h.saved.map(\.1), ["Maleek", "Sam"])
        XCTAssertTrue(h.saved.allSatisfy { $0.0 == .person })
        XCTAssertEqual(m.step, 3)
    }

    func testFixedPointsFreeTextIsAConstraintSavedVerbatim() {
        let (m, h) = make()
        skip(m, times: 3)                                  // → fixed
        XCTAssertEqual(m.current?.key, "fixed")
        m.answerFree("school run 8:30 and 15:15")
        XCTAssertEqual(h.saved.last?.0, .constraint, "the web files fixed points as a constraint")
        XCTAssertEqual(h.saved.last?.1, "school run 8:30 and 15:15", "no prefix on the web either")
        XCTAssertEqual(m.step, 4)
    }

    func testCommitmentsFreeTextIsAContextFactSavedVerbatim() {
        let (m, h) = make()
        skip(m, times: 4)                                  // → commitments
        XCTAssertEqual(m.current?.key, "commitments")
        m.answerFree("five-a-side Tuesdays")
        XCTAssertEqual(h.saved.last?.0, .context)
        XCTAssertEqual(h.saved.last?.1, "five-a-side Tuesdays")
        XCTAssertEqual(m.step, 5)
    }

    func testFreeTextUsesThePrefixOnTheNoGoStep() {
        let (m, h) = make()
        skip(m, times: 5)                                  // → nogo
        XCTAssertEqual(m.current?.key, "nogo")
        m.answerFree("during school runs")
        XCTAssertEqual(h.saved.last?.0, .constraint)
        XCTAssertEqual(h.saved.last?.1, "Never schedule: during school runs")
        XCTAssertEqual(m.step, 6)
        XCTAssertEqual(m.current?.key, "nudge")
        XCTAssertEqual(m.progress, "7/7")
    }

    // MARK: people splitting (C6)

    func testADescriptorWithACommaIsOnePersonFact() {
        XCTAssertEqual(InterviewMachine.splitPeople("Maleek — son, 9"), ["Maleek — son, 9"])
        XCTAssertEqual(InterviewMachine.splitPeople("Maleek - son, 9"), ["Maleek - son, 9"])
        XCTAssertEqual(InterviewMachine.splitPeople("Zara – daughter, turning 8"), ["Zara – daughter, turning 8"])
    }

    func testPlainNamesSplitOnCommas() {
        XCTAssertEqual(InterviewMachine.splitPeople("Maleek, Sam"), ["Maleek", "Sam"])
        XCTAssertEqual(InterviewMachine.splitPeople("Mary-Jane, Sam"), ["Mary-Jane", "Sam"],
                       "a hyphen inside a name is not a descriptor dash")
    }

    func testPiecesWithoutALetterAreDropped() {
        XCTAssertEqual(InterviewMachine.splitPeople("Maleek, 9"), ["Maleek"])
        XCTAssertEqual(InterviewMachine.splitPeople("9, , 42"), [])
    }

    func testOneFactPerName() {
        XCTAssertEqual(InterviewMachine.splitPeople("Maleek, maleek, Sam"), ["Maleek", "Sam"])
    }

    func testPeopleAnswerStoresEachSplitPiece() {
        let (m, h) = make()
        skip(m, times: 2)                                  // → people
        m.answerFree("Maleek — son, 9")
        XCTAssertEqual(h.saved.map(\.1), ["Maleek — son, 9"], "the comma is part of the description")
        XCTAssertEqual(h.saved.first?.0, .person)
        XCTAssertEqual(m.step, 3)
    }

    func testEmptyFreeTextIsANoOp() {
        let (m, h) = make()
        skip(m, times: 2)                                  // → people (free text allowed)
        m.answerFree("   ")
        m.answerFree(" , , ")
        XCTAssertTrue(h.saved.isEmpty)
        XCTAssertEqual(m.step, 2, "stays on the question")
    }

    func testSkipQuestionAdvancesWithoutSaving() {
        let (m, h) = make()
        m.skipQuestion()
        XCTAssertEqual(m.step, 1)
        XCTAssertTrue(h.saved.isEmpty)
    }

    func testAfterTheLastQuestionComesTheRitualsPickerAndThatIsDone() {
        let d = freshDefaults()
        let (m, h) = make(d)
        skip(m, times: 6)
        XCTAssertFalse(m.isPicker)
        XCTAssertFalse(InterviewMachine.isDone(d), "on the last question, not done yet")
        m.skipQuestion()
        XCTAssertTrue(m.isPicker)
        XCTAssertNil(m.current)
        XCTAssertEqual(m.progress, "7/7")
        // Reaching the picker IS being onboarded — even with every answer a
        // null-fact chip or skip, which the ≥1-fact auto-done can't see.
        XCTAssertTrue(InterviewMachine.isDone(d), "reaching the end marks done even with zero facts saved")
        XCTAssertEqual(h.doneCalls, 1, "the account flag is pushed once, right here")
        XCTAssertFalse(m.finished, "the picker still renders — finish/skip dismisses it")
        m.skipQuestion()
        XCTAssertEqual(m.step, INTERVIEW_QUESTIONS.count, "the picker is the terminal step — never past it")
        m.finish()
        XCTAssertTrue(m.finished)
        XCTAssertEqual(h.doneCalls, 1, "finishing after the picker doesn't push twice")
    }

    // MARK: failed saves keep the step

    func testFailedChipSaveKeepsTheStepAndSaysSo() {
        let (m, h) = make()
        h.saveOK = false
        m.answer(chip: chip(m, "Morning"))
        XCTAssertEqual(m.step, 0, "nothing landed — stay so they can retry")
        XCTAssertTrue(m.noted.isEmpty, "no ✓ Noted over a dropped write")
        XCTAssertEqual(m.saveError, InterviewMachine.saveFailedMessage)
        XCTAssertEqual(m.saveError, "Couldn’t save that — try again")
        h.saveOK = true
        m.answer(chip: chip(m, "Morning"))
        XCTAssertEqual(m.step, 1)
        XCTAssertEqual(m.noted, ["Mornings are the good hours — schedule the hard things early"])
        XCTAssertNil(m.saveError, "a successful retry clears the message")
    }

    func testFailedFreeTextSaveKeepsTheStep() {
        let (m, h) = make()
        skip(m, times: 2)                                  // → people
        h.saveOK = false
        m.answerFree("Maleek, Sam")
        XCTAssertEqual(m.step, 2)
        XCTAssertTrue(h.saved.isEmpty)
        XCTAssertTrue(m.noted.isEmpty)
        XCTAssertNotNil(m.saveError)
        h.saveOK = true
        m.answerFree("Maleek, Sam")
        XCTAssertEqual(m.step, 3)
        XCTAssertEqual(h.saved.map(\.1), ["Maleek", "Sam"])
        XCTAssertNil(m.saveError)
    }

    func testNullFactChipAndSkipNeverFailAndClearAStaleError() {
        let (m, h) = make()
        h.saveOK = false
        m.answer(chip: chip(m, "Morning"))
        XCTAssertNotNil(m.saveError)
        m.answer(chip: chip(m, "It varies"))               // nothing to save → always advances
        XCTAssertEqual(m.step, 1)
        XCTAssertNil(m.saveError)
        m.answer(chip: chip(m, "Shifts"))
        XCTAssertNotNil(m.saveError)
        m.skipQuestion()
        XCTAssertEqual(m.step, 2)
        XCTAssertNil(m.saveError)
    }

    // MARK: done flag / collapse / resume

    func testFinishMarksDoneAndNeverReAsks() {
        let d = freshDefaults()
        let (m, h) = make(d)
        m.answer(chip: chip(m, "Evening"))
        XCTAssertFalse(InterviewMachine.isDone(d))
        XCTAssertEqual(h.doneCalls, 0)
        m.finish()
        XCTAssertTrue(m.finished)
        XCTAssertTrue(InterviewMachine.isDone(d))
        XCTAssertEqual(h.doneCalls, 1, "\"I'm done\" pushes the account flag")
        XCTAssertNil(d.object(forKey: InterviewMachine.stepKey), "no stale resume step once done")
        m.finish()
        XCTAssertEqual(h.doneCalls, 1, "idempotent")
    }

    func testCollapseParksItAndResumes() {
        let d = freshDefaults()
        let (m, h) = make(d)
        m.answer(chip: chip(m, "Morning"))
        m.collapse()                                       // the header chevron
        XCTAssertFalse(m.finished, "the chevron is not the finisher (that's \"I'm done\", web parity)")
        XCTAssertFalse(InterviewMachine.isDone(d), "the pill stays — the way back in")
        XCTAssertEqual(h.doneCalls, 0)
        XCTAssertTrue(InterviewMachine.hasResumeStep(d), "the step is persisted")
        XCTAssertEqual(InterviewMachine.parkedStep(d), 1)
        XCTAssertEqual(h.saved.count, 1, "what was answered stays saved")
        let (resumed, _) = make(d)
        XCTAssertEqual(resumed.step, 1, "re-opening resumes where they left off")
    }

    func testImDoneFinishesFromAnyStep() {
        let d = freshDefaults()
        let (m, _) = make(d)
        m.skipQuestion()
        m.finish()                                         // the header's "I'm done"
        XCTAssertTrue(m.finished)
        XCTAssertTrue(InterviewMachine.isDone(d))
        XCTAssertFalse(InterviewMachine.hasResumeStep(d))
    }

    func testCollapseMidWayIsResumable() {
        let d = freshDefaults()
        let (m, _) = make(d)
        m.answer(chip: chip(m, "Afternoon"))
        m.skipQuestion()                                   // step 2 (people)
        m.collapse()
        XCTAssertFalse(InterviewMachine.isDone(d), "collapsing is not finishing")
        let (resumed, _) = make(d)
        XCTAssertEqual(resumed.step, 2)
        XCTAssertEqual(resumed.current?.key, "people")
        XCTAssertFalse(resumed.isFirstStep)
    }

    func testProgressSurvivesRelaunchEvenWithoutAnExplicitCollapse() {
        let d = freshDefaults()
        let (m, _) = make(d)
        skip(m, times: 3)
        let (again, _) = make(d)
        XCTAssertEqual(again.step, 3, "each advance persists the step")
    }

    func testOutOfRangeSavedStepRestarts() {
        let d = freshDefaults()
        d.set(42, forKey: InterviewMachine.stepKey)
        let (m, _) = make(d)
        XCTAssertEqual(m.step, 0)
    }

    func testResetDoneForgetsBothFlagsForTheNextAccount() {
        let d = freshDefaults()
        let (m, _) = make(d)
        m.skipQuestion()
        m.finish()
        InterviewMachine.resetDone(d)
        XCTAssertFalse(InterviewMachine.isDone(d))
        XCTAssertNil(d.object(forKey: InterviewMachine.stepKey))
    }

    // MARK: a parked step 0 holds no answers

    func testMarkInProgressParksStepZeroWhichHoldsNoAnswersOfItsOwn() {
        let d = freshDefaults()
        let (m, h) = make(d)
        m.markInProgress()                                 // what the thread driver does when it starts asking
        XCTAssertTrue(InterviewMachine.hasResumeStep(d))
        XCTAssertEqual(InterviewMachine.parkedStep(d), 0)
        XCTAssertFalse(InterviewMachine.isDone(d))
        XCTAssertEqual(h.doneCalls, 0)
        // A parked step 0 holds none of its own answers: a fact saved via chat
        // still stands the interview down.
        XCTAssertTrue(InterviewMachine.shouldAutoComplete(factCount: 1, isOpen: false, done: false,
                                                          parkedStep: InterviewMachine.parkedStep(d)))
        let (again, _) = make(d)
        XCTAssertEqual(again.step, 0, "resumes at the first question")
    }

    // MARK: auto rules

    func testAutoDoneAtOneFactButNeverWhileOpen() {
        XCTAssertTrue(InterviewMachine.shouldAutoComplete(factCount: 1, isOpen: false, done: false),
                      "one saved fact means they engaged (web parity — was three)")
        XCTAssertTrue(InterviewMachine.shouldAutoComplete(factCount: 7, isOpen: false, done: false))
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 0, isOpen: false, done: false))
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 1, isOpen: true, done: false),
                       "its own answers grow the count — auto-closing mid-interview looks like a crash")
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 3, isOpen: false, done: true))
    }

    func testAutoDoneNeverWhileAMidWayStepIsParked() {
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 1, isOpen: false, done: false, parkedStep: 2),
                       "that fact may be its OWN hidden-mid-way answer — completing here skipped the rest + the picker")
        XCTAssertTrue(InterviewMachine.shouldAutoComplete(factCount: 1, isOpen: false, done: false, parkedStep: nil),
                      "facts from elsewhere with nothing parked: stand down")
        XCTAssertTrue(InterviewMachine.shouldAutoComplete(factCount: 1, isOpen: false, done: false, parkedStep: 0),
                      "parked at the greeting = auto-opened, never answered: those facts aren't its own")
    }

    func testHiddenMidWayWithThreeAnswersStillReachesThePickerAfterRelaunch() {
        let d = freshDefaults()
        let (m, h) = make(d)
        m.answer(chip: chip(m, "Morning"))                 // → work
        m.answer(chip: chip(m, "Shifts"))                  // → people
        m.answerFree("Maleek")                             // → fixed
        XCTAssertEqual(h.saved.count, 3)
        m.collapse()
        // Relaunch: the card sees 3 facts and a parked mid-way step → must NOT auto-complete.
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 3, isOpen: false, done: InterviewMachine.isDone(d),
                                                           parkedStep: InterviewMachine.parkedStep(d)))
        let (again, _) = make(d)
        XCTAssertEqual(again.step, 3)
        XCTAssertEqual(again.current?.key, "fixed")
        skip(again, times: 4)
        XCTAssertTrue(again.isPicker, "the rituals picker is reachable")
        XCTAssertTrue(InterviewMachine.isDone(d))
        again.finish()
        XCTAssertTrue(InterviewMachine.isDone(d))
        XCTAssertFalse(InterviewMachine.hasResumeStep(d))
    }

    // MARK: server says done (user_preferences.assistant_interview_done_at, migration 052)

    func testServerDoneFlagPinsLocal() {
        let d = freshDefaults()
        XCTAssertFalse(InterviewMachine.isDone(d), "fresh install: nothing local")
        // What AppModel.applyServerInterviewFlag does when the account row
        // carries assistant_interview_done_at — BEFORE profileFactsHydrated flips.
        InterviewMachine.markDone(d)
        XCTAssertTrue(InterviewMachine.isDone(d),
                      "onboarded on the web with zero synced facts on this phone: never greeted as a stranger")
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 5, isOpen: false, done: InterviewMachine.isDone(d)),
                       "already done — nothing to auto-complete")
        // Sign-out forgets it; the next sign-in's hydrate re-applies it from the server.
        InterviewMachine.resetDone(d)
        XCTAssertFalse(InterviewMachine.isDone(d))
    }
}
