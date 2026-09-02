// Unit tests for the get-to-know-you interview state machine (InterviewMachine)
// — the pure half of App/Features/Interview.swift: step order, what each
// answer saves, the auto-done rule (≥3 facts, never while open), resume after
// a mid-way collapse, skip, and the never-re-asks-once-done flag. Each test
// uses a throwaway UserDefaults suite so nothing touches the device defaults.

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
        XCTAssertEqual(INTERVIEW_QUESTIONS.map(\.category), [.rhythm, .person, .constraint, .constraint, .preference])
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

    func testFreeTextUsesThePrefixOnConstraintSteps() {
        let (m, saved) = make()
        m.skipQuestion(); m.skipQuestion(); m.skipQuestion()   // → nogo
        XCTAssertEqual(m.current?.key, "nogo")
        m.answerFree("during school runs")
        XCTAssertEqual(saved().last?.0, .constraint)
        XCTAssertEqual(saved().last?.1, "Never schedule: during school runs")
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

    func testSkipForNowIsFinal() {
        let d = freshDefaults()
        let (m, saved) = make(d)
        m.skip()
        XCTAssertTrue(m.finished)
        XCTAssertTrue(InterviewMachine.isDone(d), "skip = done: a nudge that keeps coming back reads as nagging")
        XCTAssertTrue(saved().isEmpty)
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

    func testAutoOpenOnlyWithNothingLearnedAnywhere() {
        XCTAssertTrue(InterviewMachine.shouldAutoOpen(factCount: 0, done: false))
        XCTAssertFalse(InterviewMachine.shouldAutoOpen(factCount: 1, done: false),
                       "facts from another device / chat: the pill nudges instead of the panel opening itself")
        XCTAssertFalse(InterviewMachine.shouldAutoOpen(factCount: 0, done: true))
    }
}
