// Unit tests for the get-to-know-you interview state machine (InterviewMachine)
// — the pure half of App/Features/Interview.swift: step order, what each
// answer saves, the people-answer splitting, the auto-done rule (≥3 facts,
// never while open, never while parked), resume after a mid-way collapse /
// "Skip for now", the "I'm done" finisher, and the auto-open gate that waits
// for the server hydrate. Each test uses a throwaway UserDefaults suite so
// nothing touches the device defaults.

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

    /// A machine whose saves are captured as (category, fact) pairs.
    private func make(_ defaults: UserDefaults? = nil) -> (InterviewMachine, () -> [(UnstuckCore.ProfileFactCategory, String)]) {
        var saved: [(UnstuckCore.ProfileFactCategory, String)] = []
        let m = InterviewMachine(defaults: defaults ?? freshDefaults(), save: { saved.append(($0, $1)) })
        return (m, { saved })
    }

    private func chip(_ m: InterviewMachine, _ label: String) -> InterviewChip {
        m.current!.chips.first { $0.label == label }!
    }

    // MARK: steps

    func testScriptOrderAndCategories() {
        XCTAssertEqual(INTERVIEW_QUESTIONS.map(\.key), ["rhythm", "people", "work", "nogo", "nudge"])
        XCTAssertEqual(INTERVIEW_QUESTIONS.map(\.category), [.rhythm, .person, .context, .constraint, .preference],
                       "work days are `context` like the web — `constraint` here duplicated the fact across devices")
        XCTAssertTrue(INTERVIEW_QUESTIONS[1].splitNames, "names are one person fact each")
        XCTAssertTrue(INTERVIEW_QUESTIONS.allSatisfy { !$0.chips.isEmpty }, "every step is tap-answerable")
    }

    func testFreshMachineStartsAtTheGreetingStep() {
        let (m, saved) = make()
        XCTAssertEqual(m.step, 0)
        XCTAssertTrue(m.isFirstStep)
        XCTAssertFalse(m.isPicker)
        XCTAssertEqual(m.current?.key, "rhythm")
        XCTAssertEqual(m.progress, "1/5")
        XCTAssertTrue(saved().isEmpty)
        XCTAssertFalse(m.finished)
    }

    func testChipWithFactSavesAndAdvances() {
        let (m, saved) = make()
        m.answer(chip: chip(m, "Morning"))
        XCTAssertEqual(saved().count, 1)
        XCTAssertEqual(saved()[0].0, .rhythm)
        XCTAssertEqual(saved()[0].1, "Mornings are the good hours — schedule the hard things early")
        XCTAssertEqual(m.noted.last, "Mornings are the good hours — schedule the hard things early")
        XCTAssertEqual(m.step, 1)
        XCTAssertEqual(m.current?.key, "people")
        XCTAssertFalse(m.isFirstStep, "the greeting bubble only shows on the first step")
    }

    func testChipWithoutFactSavesNothingButStillAdvances() {
        let (m, saved) = make()
        m.answer(chip: chip(m, "It varies"))
        XCTAssertTrue(saved().isEmpty)
        XCTAssertTrue(m.noted.isEmpty)
        XCTAssertEqual(m.step, 1)
    }

    func testPeopleFreeTextSplitsCommaSeparatedNamesIntoPersonFacts() {
        let (m, saved) = make()
        m.skipQuestion()                                   // → people
        XCTAssertEqual(m.current?.key, "people")
        m.answerFree(" Maleek, Sam ,, ")
        XCTAssertEqual(saved().map(\.1), ["Maleek", "Sam"])
        XCTAssertTrue(saved().allSatisfy { $0.0 == .person })
        XCTAssertEqual(m.step, 2)
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
        let (m, saved) = make()
        m.skipQuestion()                                   // → people
        m.answerFree("Maleek — son, 9")
        XCTAssertEqual(saved().map(\.1), ["Maleek — son, 9"], "the comma is part of the description")
        XCTAssertEqual(saved().first?.0, .person)
        XCTAssertEqual(m.step, 2)
    }

    func testFreeTextUsesThePrefixOnConstraintSteps() {
        let (m, saved) = make()
        m.skipQuestion(); m.skipQuestion(); m.skipQuestion()   // → nogo
        XCTAssertEqual(m.current?.key, "nogo")
        m.answerFree("during school runs")
        XCTAssertEqual(saved().last?.0, .constraint)
        XCTAssertEqual(saved().last?.1, "Never schedule: during school runs")
    }

    func testWorkFreeTextIsAContextFact() {
        let (m, saved) = make()
        m.skipQuestion(); m.skipQuestion()                 // → work
        XCTAssertEqual(m.current?.key, "work")
        m.answerFree("four days, Fridays off")
        XCTAssertEqual(saved().last?.0, .context)
        XCTAssertEqual(saved().last?.1, "Work: four days, Fridays off")
    }

    func testEmptyFreeTextIsANoOp() {
        let (m, saved) = make()
        m.skipQuestion()                                   // → people (free text allowed)
        m.answerFree("   ")
        m.answerFree(" , , ")
        XCTAssertTrue(saved().isEmpty)
        XCTAssertEqual(m.step, 1, "stays on the question")
    }

    func testSkipQuestionAdvancesWithoutSaving() {
        let (m, saved) = make()
        m.skipQuestion()
        XCTAssertEqual(m.step, 1)
        XCTAssertTrue(saved().isEmpty)
    }

    func testAfterTheLastQuestionComesTheRitualsPicker() {
        let (m, _) = make()
        for _ in 0..<INTERVIEW_QUESTIONS.count { m.skipQuestion() }
        XCTAssertTrue(m.isPicker)
        XCTAssertNil(m.current)
        XCTAssertEqual(m.progress, "5/5")
        m.skipQuestion()
        XCTAssertEqual(m.step, INTERVIEW_QUESTIONS.count, "the picker is the terminal step — never past it")
        XCTAssertFalse(m.finished, "the picker needs an explicit finish/skip")
    }

    // MARK: done flag / skip / resume

    func testFinishMarksDoneAndNeverReAsks() {
        let d = freshDefaults()
        let (m, _) = make(d)
        m.answer(chip: chip(m, "Evening"))
        XCTAssertFalse(InterviewMachine.isDone(d))
        m.finish()
        XCTAssertTrue(m.finished)
        XCTAssertTrue(InterviewMachine.isDone(d))
        XCTAssertNil(d.object(forKey: InterviewMachine.stepKey), "no stale resume step once done")
        XCTAssertFalse(InterviewMachine.shouldAutoOpen(factCount: 0, done: InterviewMachine.isDone(d)))
    }

    func testSkipForNowParksItAndResumes() {
        let d = freshDefaults()
        let (m, saved) = make(d)
        m.answer(chip: chip(m, "Morning"))
        m.skip()
        XCTAssertFalse(m.finished, "\"Skip for now\" is not the finisher (that's \"I'm done\", web parity)")
        XCTAssertFalse(InterviewMachine.isDone(d), "the pill stays — the way back in")
        XCTAssertTrue(InterviewMachine.hasResumeStep(d), "the step is persisted")
        XCTAssertEqual(saved().count, 1, "what was answered stays saved")
        let (resumed, _) = make(d)
        XCTAssertEqual(resumed.step, 1, "re-opening resumes where they left off")
        XCTAssertFalse(InterviewMachine.shouldAutoOpen(factCount: 0, done: false,
                                                       hasResumeStep: InterviewMachine.hasResumeStep(d)),
                       "parked ≠ pop back open on the next launch — that's the nag it exists to avoid")
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
        m.skipQuestion()                                   // step 2 (work)
        m.collapse()
        XCTAssertFalse(InterviewMachine.isDone(d), "collapsing is not finishing")
        let (resumed, _) = make(d)
        XCTAssertEqual(resumed.step, 2)
        XCTAssertEqual(resumed.current?.key, "work")
        XCTAssertFalse(resumed.isFirstStep)
    }

    func testProgressSurvivesRelaunchEvenWithoutAnExplicitCollapse() {
        let d = freshDefaults()
        let (m, _) = make(d)
        m.skipQuestion(); m.skipQuestion(); m.skipQuestion()
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
        XCTAssertTrue(InterviewMachine.shouldAutoOpen(factCount: 0, done: InterviewMachine.isDone(d)))
    }

    // MARK: auto rules

    func testAutoDoneAtThreeFactsButNeverWhileOpen() {
        XCTAssertTrue(InterviewMachine.shouldAutoComplete(factCount: 3, isOpen: false, done: false))
        XCTAssertTrue(InterviewMachine.shouldAutoComplete(factCount: 7, isOpen: false, done: false))
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 2, isOpen: false, done: false))
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 3, isOpen: true, done: false),
                       "its own answers grow the count — auto-closing mid-interview looks like a crash")
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 3, isOpen: false, done: true))
    }

    func testAutoDoneNeverWhileAResumeStepIsParked() {
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 3, isOpen: false, done: false, hasResumeStep: true),
                       "those ≥3 facts are its OWN hidden-mid-way answers — completing here skipped the rituals picker")
        XCTAssertTrue(InterviewMachine.shouldAutoComplete(factCount: 3, isOpen: false, done: false, hasResumeStep: false),
                      "facts from elsewhere with nothing parked: stand down")
    }

    func testHiddenMidWayWithThreeAnswersStillReachesThePickerAfterRelaunch() {
        let d = freshDefaults()
        let (m, saved) = make(d)
        m.answer(chip: chip(m, "Morning"))
        m.answerFree("Maleek")
        m.answer(chip: chip(m, "Shifts"))
        XCTAssertEqual(saved().count, 3)
        m.collapse()
        // Relaunch: the card sees 3 facts and a parked step → must NOT auto-complete.
        XCTAssertFalse(InterviewMachine.shouldAutoComplete(factCount: 3, isOpen: false, done: InterviewMachine.isDone(d),
                                                           hasResumeStep: InterviewMachine.hasResumeStep(d)))
        let (again, _) = make(d)
        XCTAssertEqual(again.step, 3)
        again.skipQuestion(); again.skipQuestion()
        XCTAssertTrue(again.isPicker, "the rituals picker is reachable")
        again.finish()
        XCTAssertTrue(InterviewMachine.isDone(d))
        XCTAssertFalse(InterviewMachine.hasResumeStep(d))
    }

    func testAutoOpenOnlyWithNothingLearnedAnywhere() {
        XCTAssertTrue(InterviewMachine.shouldAutoOpen(factCount: 0, done: false))
        XCTAssertFalse(InterviewMachine.shouldAutoOpen(factCount: 1, done: false),
                       "facts from another device / chat: the pill nudges instead of the panel opening itself")
        XCTAssertFalse(InterviewMachine.shouldAutoOpen(factCount: 0, done: true))
        XCTAssertFalse(InterviewMachine.shouldAutoOpen(factCount: 0, done: false, hasResumeStep: true))
    }

    // MARK: auto-open gate (C1 — waits for the server hydrate)

    func testNoAutoOpenWhileNotHydratedEvenWithZeroLocalFacts() {
        var g = InterviewAutoOpenGate()
        XCTAssertFalse(g.evaluate(hydrated: false, factsLoaded: true, factCount: 0, done: false),
                       "the first local GRDB emission is empty on a fresh install whose facts live on the web")
        XCTAssertFalse(g.evaluate(hydrated: false, factsLoaded: true, factCount: 0, done: false))
        XCTAssertFalse(g.decided, "still undecided — nothing has been ruled out")
    }

    func testNoAutoOpenBeforeTheLocalFactsAreRead() {
        var g = InterviewAutoOpenGate()
        XCTAssertFalse(g.evaluate(hydrated: true, factsLoaded: false, factCount: 0, done: false))
        XCTAssertFalse(g.decided)
    }

    func testOpensOnceAfterHydrateWithZeroFacts() {
        var g = InterviewAutoOpenGate()
        XCTAssertFalse(g.evaluate(hydrated: false, factsLoaded: true, factCount: 0, done: false))
        XCTAssertTrue(g.evaluate(hydrated: true, factsLoaded: true, factCount: 0, done: false), "hydrate landed, nothing anywhere")
        XCTAssertTrue(g.decided)
        XCTAssertFalse(g.evaluate(hydrated: true, factsLoaded: true, factCount: 0, done: false), "decides exactly once")
    }

    func testNeverOpensWhenHydrateBringsFacts() {
        var g = InterviewAutoOpenGate()
        XCTAssertFalse(g.evaluate(hydrated: true, factsLoaded: true, factCount: 3, done: false))
        XCTAssertTrue(g.decided, "decided: the pill (not the panel) is the nudge from here")
        XCTAssertFalse(g.evaluate(hydrated: true, factsLoaded: true, factCount: 0, done: false),
                       "a later empty emission (forget everything) must not pop the interview open")
        var one = InterviewAutoOpenGate()
        XCTAssertFalse(one.evaluate(hydrated: true, factsLoaded: true, factCount: 1, done: false))
    }

    func testGateHonoursDoneAndParked() {
        var done = InterviewAutoOpenGate()
        XCTAssertFalse(done.evaluate(hydrated: true, factsLoaded: true, factCount: 0, done: true))
        var parked = InterviewAutoOpenGate()
        XCTAssertFalse(parked.evaluate(hydrated: true, factsLoaded: true, factCount: 0, done: false, hasResumeStep: true))
    }
}
