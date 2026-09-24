// Unit tests for InterviewThreadDriver — the get-to-know-you interview
// re-hosted inside the assistant thread (App/Features/InterviewThread.swift):
// the user's first message is handled FIRST (no question before the reply),
// then one question per local assistant turn with the chip row keyed on its
// id; chip / free-text / Skip advance and echo the answer; a failed save
// keeps the question; a mid-interview change of subject gets its reply and
// the same question again; reaching the picker marks done, "That's me set
// up" closes; someone with facts from elsewhere is stood down; nothing is
// decided before the account's memory has been read. The thread is two
// closures here, so no AssistantModel / SwiftUI is involved.

import XCTest
import UnstuckCore
@testable import Unstuck

@MainActor
final class InterviewThreadTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "test.interview-thread.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// The thread as the driver sees it: every post (text + prompt meta + the
    /// id it was given) and every echoed user bubble, in order.
    private final class Thread {
        struct Post: Equatable { let id: String; let text: String; let meta: InterviewPromptMeta? }
        var posts: [Post] = []
        var echoes: [String] = []
        var saved: [(UnstuckCore.ProfileFactCategory, String)] = []
        var saveOK = true
        var doneCalls = 0
        var factCount = 0
        var ready = true
        private var seq = 0
        func post(_ text: String, _ meta: InterviewPromptMeta?) -> String {
            seq += 1
            let id = "t\(seq)"
            posts.append(Post(id: id, text: text, meta: meta))
            return id
        }
        /// The prompts (posts carrying interview meta), in order.
        var prompts: [Post] { posts.filter { $0.meta != nil } }
    }

    private func make(_ defaults: UserDefaults? = nil, firstName: String? = "Maya",
                      clock: ClockFormat? = nil) -> (InterviewThreadDriver, Thread) {
        let t = Thread()
        let d = defaults ?? freshDefaults()
        let machine = InterviewMachine(
            questions: clock.map { interviewQuestions(clock: $0) } ?? INTERVIEW_QUESTIONS,
            defaults: d,
            save: { c, f in
                guard t.saveOK else { return false }
                t.saved.append((c, f))
                return true
            },
            onDone: { t.doneCalls += 1 })
        let driver = InterviewThreadDriver(
            machine: machine, firstName: firstName, defaults: d,
            ready: { t.ready }, factCount: { t.factCount },
            post: { text, meta in t.post(text, meta) },
            echo: { t.echoes.append($0) })
        return (driver, t)
    }

    private func chip(_ driver: InterviewThreadDriver, _ label: String) -> InterviewChip {
        driver.machine.current!.chips.first { $0.label == label }!
    }

    // MARK: the user's message comes first

    func testNothingIsAskedUntilTheFirstReplyHasLanded() {
        let (driver, t) = make()
        XCTAssertEqual(driver.phase, .idle)
        driver.userSent()
        XCTAssertEqual(driver.phase, .waitingForReply)
        XCTAssertTrue(t.posts.isEmpty, "the assistant handles the message first — no question before the reply")
        XCTAssertNil(driver.promptTurnId)
        driver.turnFinished()
        XCTAssertEqual(driver.phase, .asking)
        XCTAssertTrue(driver.isAsking)
        // Greeting (with the first name, once) then the first question,
        // tagged with its key; the chip row keys on that turn's id.
        XCTAssertEqual(t.posts.count, 2)
        XCTAssertTrue(t.posts[0].text.hasPrefix("Hey Maya. A few quick questions"))
        XCTAssertNil(t.posts[0].meta)
        XCTAssertEqual(t.posts[1].text, INTERVIEW_QUESTIONS[0].question)
        XCTAssertEqual(t.posts[1].meta, InterviewPromptMeta(key: "rhythm"))
        XCTAssertEqual(driver.promptTurnId, t.posts[1].id)
    }

    func testTurnFinishedBeforeAnySendAsksNothing() {
        let (driver, t) = make()
        driver.turnFinished()                              // a stray sending flip (a queued drain)
        XCTAssertEqual(driver.phase, .idle)
        XCTAssertTrue(t.posts.isEmpty)
    }

    func testGreetingWithoutAName() {
        let (driver, t) = make(firstName: nil)
        driver.userSent(); driver.turnFinished()
        XCTAssertTrue(t.posts[0].text.hasPrefix("Hey. A few quick questions"))
    }

    // MARK: chips / free text / skip

    func testChipSavesEchoesAndAsksTheNextQuestion() {
        let (driver, t) = make()
        driver.userSent(); driver.turnFinished()
        let first = driver.promptTurnId
        driver.answer(chip: chip(driver, "Morning"))
        XCTAssertEqual(t.saved.map(\.1), ["Mornings are the good hours — schedule the hard things early"])
        XCTAssertEqual(t.echoes, ["Morning"], "the tap reads as the user's bubble")
        XCTAssertEqual(t.prompts.last?.meta, InterviewPromptMeta(key: "work"))
        XCTAssertEqual(t.prompts.last?.text, INTERVIEW_QUESTIONS[1].question)
        XCTAssertNotEqual(driver.promptTurnId, first, "the chip row moves to the new question")
        XCTAssertEqual(driver.promptTurnId, t.prompts.last?.id)
        XCTAssertEqual(driver.machine.step, 1)
    }

    /// The never-schedule chips read in the phone's clock, and the echoed
    /// bubble is exactly the chip that was tapped ("Before 09:00" on a 24-hour
    /// phone, "Before 9 AM" on a 12-hour one) — while the SAVED fact stays
    /// "Never schedule anything before 9am" in both, since the fact is shared
    /// data every device reads (cross-platform decision, 2026-09-24).
    func testNoGoChipEchoesTheTappedClockLabelAndSavesTheSharedFact() {
        let cases: [(ClockFormat, String, String)] = [
            (.h24, "Before 09:00", "After 21:00"),
            (.h12, "Before 9 AM", "After 9 PM"),
            (ClockFormat(cycle: .h12, amSymbol: "am", pmSymbol: "pm"), "Before 9 am", "After 9 pm"),   // en_GB on 12-hour
        ]
        for (clock, before, after) in cases {
            for (label, fact) in [(before, "Never schedule anything before 9am"),
                                  (after, "Never schedule anything after 9pm")] {
                let (driver, t) = make(clock: clock)
                driver.userSent(); driver.turnFinished()
                for _ in 0..<5 { driver.skip() }
                XCTAssertEqual(driver.machine.current?.key, "nogo")
                XCTAssertEqual(driver.machine.current?.chips.prefix(2).map(\.label), [before, after], "\(clock.cycle)")
                driver.answer(chip: chip(driver, label))
                XCTAssertEqual(t.echoes.last, label, "the user's bubble is the chip they tapped (\(clock.cycle))")
                XCTAssertEqual(t.saved.map(\.1), [fact], "the saved fact never follows the clock (\(clock.cycle))")
                XCTAssertEqual(t.saved.first?.0, .constraint)
                XCTAssertEqual(driver.machine.current?.key, "nudge")
            }
        }
    }

    func testNullFactChipSavesNothingButStillAdvances() {
        let (driver, t) = make()
        driver.userSent(); driver.turnFinished()
        driver.answer(chip: chip(driver, "It varies"))
        XCTAssertTrue(t.saved.isEmpty)
        XCTAssertEqual(t.echoes, ["It varies"])
        XCTAssertEqual(driver.machine.current?.key, "work")
    }

    func testSkipSavesNothingEchoesSkipAndMovesOn() {
        let (driver, t) = make()
        driver.userSent(); driver.turnFinished()
        driver.skip()
        XCTAssertTrue(t.saved.isEmpty)
        XCTAssertEqual(t.echoes, ["Skip"])
        XCTAssertEqual(driver.machine.current?.key, "work")
        XCTAssertEqual(t.prompts.count, 2)
    }

    func testFreeTextOnAFreeQuestionSavesWithThePrefix() {
        let (driver, t) = make()
        driver.userSent(); driver.turnFinished()
        driver.skip()                                      // → work (free text allowed, prefix "Work")
        driver.answerFree("  4 days a week, from home  ")
        XCTAssertEqual(t.saved.map(\.1), ["Work: 4 days a week, from home"])
        XCTAssertEqual(t.echoes, ["Skip", "4 days a week, from home"])
        XCTAssertEqual(driver.machine.current?.key, "people")
    }

    func testEmptyFreeTextIsANoOp() {
        let (driver, t) = make()
        driver.userSent(); driver.turnFinished()
        driver.skip()
        let prompts = t.prompts.count
        driver.answerFree("   ")
        XCTAssertEqual(driver.machine.current?.key, "work")
        XCTAssertEqual(t.prompts.count, prompts)
        XCTAssertEqual(t.echoes, ["Skip"])
    }

    func testAFailedSaveKeepsTheQuestionAndEchoesNothing() {
        let (driver, t) = make()
        driver.userSent(); driver.turnFinished()
        let prompt = driver.promptTurnId
        t.saveOK = false
        driver.answer(chip: chip(driver, "Evening"))
        XCTAssertEqual(driver.machine.step, 0, "the step is kept so they can retry")
        XCTAssertEqual(driver.machine.saveError, InterviewMachine.saveFailedMessage)
        XCTAssertTrue(t.echoes.isEmpty, "nothing echoed that didn't land")
        XCTAssertEqual(driver.promptTurnId, prompt, "the chip row stays on the same question")
        XCTAssertEqual(t.prompts.count, 1)
        t.saveOK = true
        driver.answer(chip: chip(driver, "Evening"))
        XCTAssertNil(driver.machine.saveError)
        XCTAssertEqual(t.echoes, ["Evening"])
        XCTAssertEqual(driver.machine.step, 1)
    }

    func testAnswersAreIgnoredBeforeTheInterviewIsAsking() {
        let (driver, t) = make()
        driver.userSent()                                  // waiting for the reply
        driver.answer(chip: INTERVIEW_QUESTIONS[0].chips[0])
        driver.skip()
        driver.answerFree("Maleek")
        XCTAssertEqual(driver.machine.step, 0)
        XCTAssertTrue(t.saved.isEmpty)
        XCTAssertTrue(t.echoes.isEmpty)
    }

    // MARK: the user changes the subject mid-interview

    func testAMessageMidInterviewGetsItsReplyThenTheSameQuestionAgain() {
        let (driver, t) = make()
        driver.userSent(); driver.turnFinished()
        driver.answer(chip: chip(driver, "Afternoon"))     // → work
        let before = driver.promptTurnId
        driver.userSent()                                  // "what's on tomorrow?" — a no-op for the driver
        XCTAssertEqual(driver.phase, .asking)
        XCTAssertEqual(t.prompts.count, 2, "nothing is asked until the reply has landed")
        driver.turnFinished()                              // the reply landed
        XCTAssertEqual(t.prompts.count, 3)
        XCTAssertEqual(t.prompts.last?.meta, InterviewPromptMeta(key: "work"), "the SAME question, underneath the reply")
        XCTAssertNotEqual(driver.promptTurnId, before, "the chip row moves to the fresh copy")
        XCTAssertEqual(driver.promptTurnId, t.prompts.last?.id)
        XCTAssertEqual(driver.machine.step, 1, "no progress was lost")
        XCTAssertEqual(t.posts.filter { $0.meta == nil }.count, 1, "the greeting is not repeated")
    }

    // MARK: completion

    func testAnsweringOrSkippingEverythingReachesThePickerAndMarksDone() {
        let d = freshDefaults()
        let (driver, t) = make(d)
        driver.userSent(); driver.turnFinished()
        driver.answer(chip: chip(driver, "Morning"))
        for _ in 0..<5 { driver.skip() }
        XCTAssertEqual(driver.machine.current?.key, "nudge")
        XCTAssertFalse(InterviewMachine.isDone(d))
        driver.answer(chip: chip(driver, "Gently"))
        // Reaching the picker IS being onboarded — done + the account hook,
        // exactly as before; the picker is the last prompt.
        XCTAssertTrue(driver.machine.isPicker)
        XCTAssertTrue(InterviewMachine.isDone(d))
        XCTAssertEqual(t.doneCalls, 1)
        XCTAssertEqual(t.prompts.last?.meta, InterviewPromptMeta(key: InterviewPromptMeta.pickerKey))
        XCTAssertEqual(t.prompts.last?.text, InterviewThreadDriver.pickerQuestion)
        XCTAssertEqual(driver.promptTurnId, t.prompts.last?.id)
        XCTAssertEqual(driver.phase, .asking)
        driver.skip()                                      // no question to skip on the picker
        XCTAssertEqual(t.echoes.count, 7)
        driver.finish()                                    // "That's me set up"
        XCTAssertEqual(driver.phase, .done)
        XCTAssertNil(driver.promptTurnId, "no chip row once finished")
        XCTAssertEqual(t.posts.last?.text, InterviewThreadDriver.closingLine)
        XCTAssertNil(t.posts.last?.meta)
        XCTAssertEqual(t.doneCalls, 1, "the account hook fires once")
        XCTAssertFalse(InterviewMachine.hasResumeStep(d), "no stale resume step once done")
        // Never again: a later send + reply asks nothing.
        driver.userSent(); driver.turnFinished()
        XCTAssertEqual(t.posts.last?.text, InterviewThreadDriver.closingLine)
    }

    func testANewVisitOnADoneAccountAsksNothing() {
        let d = freshDefaults()
        InterviewMachine.markDone(d)
        let (driver, t) = make(d)
        driver.userSent()
        XCTAssertEqual(driver.phase, .done)
        driver.turnFinished()
        XCTAssertTrue(t.posts.isEmpty)
    }

    // MARK: resume

    func testANewVisitResumesAtTheParkedStepWithoutTheGreeting() {
        let d = freshDefaults()
        let (first, _) = make(d)
        first.userSent(); first.turnFinished()
        first.answer(chip: chip(first, "Morning"))
        first.skip()                                       // → people, parked at 2
        XCTAssertEqual(InterviewMachine.parkedStep(d), 2)
        let (again, t) = make(d)                           // the sheet re-presented later
        again.userSent(); again.turnFinished()
        XCTAssertEqual(t.posts.count, 1, "no greeting mid-way")
        XCTAssertEqual(t.prompts.first?.meta, InterviewPromptMeta(key: "people"))
        XCTAssertEqual(again.machine.step, 2)
    }

    // MARK: stand-down + readiness

    func testFactsFromElsewhereWithNothingParkedStandTheInterviewDown() {
        let d = freshDefaults()
        let (driver, t) = make(d)
        t.factCount = 2                                    // synced from the web / saved by chat
        driver.userSent()
        XCTAssertEqual(driver.phase, .done, "someone the assistant already knows is never greeted as a stranger")
        XCTAssertTrue(InterviewMachine.isDone(d))
        XCTAssertEqual(t.doneCalls, 1, "mirrored to the account")
        driver.turnFinished()
        XCTAssertTrue(t.posts.isEmpty)
    }

    func testFactsWithAMidWayParkedStepDoNotStandItDown() {
        let d = freshDefaults()
        let (first, _) = make(d)
        first.userSent(); first.turnFinished()
        first.answer(chip: chip(first, "Morning"))         // its own fact; parked at 1
        let (again, t) = make(d)
        t.factCount = 1
        again.userSent(); again.turnFinished()
        XCTAssertEqual(again.phase, .asking, "that fact may be its OWN answer — carry on")
        XCTAssertEqual(t.prompts.first?.meta, InterviewPromptMeta(key: "work"))
        XCTAssertFalse(InterviewMachine.isDone(d))
    }

    func testAFactSavedByTheFirstReplyItselfDoesNotStandItDown() {
        // The stand-down is decided when the message is SENT: a fact the reply
        // saves ("remember I work 9–5") must not cancel the interview.
        let (driver, t) = make()
        driver.userSent()
        t.factCount = 1
        driver.turnFinished()
        XCTAssertEqual(driver.phase, .asking)
        XCTAssertEqual(t.prompts.count, 1)
    }

    func testNothingIsDecidedBeforeTheAccountsMemoryHasBeenRead() {
        let (driver, t) = make()
        t.ready = false                                    // profile-facts hydrate still in flight
        driver.userSent()
        XCTAssertEqual(driver.phase, .idle)
        driver.turnFinished()
        XCTAssertTrue(t.posts.isEmpty)
        t.ready = true
        driver.userSent(); driver.turnFinished()
        XCTAssertEqual(driver.phase, .asking)
        XCTAssertEqual(t.prompts.count, 1)
    }

    // MARK: voice

    func testEveryScriptQuestionHasASpokenLineForTheVoicePrimer() {
        for q in INTERVIEW_QUESTIONS {
            XCTAssertNotNil(InterviewVoice.spoken[q.key], "no spoken line for \(q.key)")
        }
        let list = InterviewVoice.questionList()
        XCTAssertFalse(list.contains(InterviewVoice.spoken["rhythm"]!), "the first question is spoken verbatim in the greeting")
        for q in INTERVIEW_QUESTIONS.dropFirst() {
            XCTAssertTrue(list.contains(InterviewVoice.spoken[q.key]!))
        }
        XCTAssertEqual(list.components(separatedBy: "; ").count, INTERVIEW_QUESTIONS.count - 1)
    }
}
