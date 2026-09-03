// The harness contract (docs/assistant-tool-contract.md §"Harness contract"):
// the fabrication guard bounces a tool-less claim ONCE with the exact hidden
// corrective, nothing is ever synthesised as "Done.", a cut-off reply gets the
// split hint, truncated tool JSON gets the retry hint, the style preference is
// saved BEFORE the model sees the message, and a send mid-turn is queued and
// drained in order — never dropped.

import XCTest
import Supabase
import UnstuckCore
import UnstuckSync
@testable import Unstuck

@MainActor
private final class ScriptedTransport: AssistantTransport {
    var replies: [HarnessAsk]
    /// Every request the loop made, in order.
    var asks: [[ChatMessage]] = []
    var contexts: [[String: AnyJSON]] = []
    /// Something to observe at ask time (the style-preference ordering test).
    var onAsk: (() -> Void)?

    init(_ replies: [HarnessAsk]) { self.replies = replies }

    func ask(messages: [ChatMessage], context: [String: AnyJSON]) async -> HarnessAsk {
        asks.append(messages)
        contexts.append(context)
        onAsk?()
        return replies.isEmpty ? .err("upstream") : replies.removeFirst()
    }
}

@MainActor
final class AssistantHarnessTests: XCTestCase {
    private var api = FakeAssistantState()
    private var committed: [[AssistantTurn]] = []
    private var persisted: [Bool] = []

    // The async override is MainActor-isolated (the sync one inherits XCTest's
    // nonisolated signature and can't touch the fakes under Swift 6).
    override func setUp() async throws {
        try await super.setUp()
        reset()
    }
    private func reset() {
        api = FakeAssistantState()
        committed = []
        persisted = []
    }

    private func text(_ s: String) -> HarnessAsk { .ok(HarnessReply(content: s)) }
    private func call(_ name: String, _ args: String, content: String? = nil, finishReason: String? = nil, id: String = "c1") -> HarnessAsk {
        .ok(HarnessReply(content: content, toolCalls: [ToolCall(id: id, type: "function", function: ToolFunction(name: name, arguments: args))],
                         finishReason: finishReason))
    }

    private func runTurn(_ userText: String, _ transport: ScriptedTransport) async -> AssistantHarness.Outcome {
        let base = [AssistantTurn(ChatMessage(role: "user", content: userText), at: 1)]
        let scratch = TurnScratch()
        let api = self.api
        let deps = AssistantHarness.Deps(
            transport: transport, api: api, scratch: scratch,
            context: { buildAssistantContext(api) },
            receipt: { name, args, result in
                assistantReceipt(name: name, args: args, result: result, tasks: Array(scratch.newTasks.values) + api.tasks, facts: api.facts)
            },
            stylePreference: { text in
                guard let pref = ProfileFactsLogic.detectStylePreference(text), let stored = api.saveStylePreference(pref) else { return nil }
                return Receipt(icon: .pencil, label: "Noted: \(stored.fact)", undo: .forgetFact(id: stored.id))
            },
            commit: { [weak self] working, persist in self?.committed.append(working); self?.persisted.append(persist) },
            now: { 2 },
            isCancelled: { false })
        return await AssistantHarness.runTurn(text: userText, base: base, deps: deps)
    }

    private var finalThread: [AssistantTurn] { committed.last ?? [] }
    private var visible: [AssistantTurn] { finalThread.filter { ($0.role == "user" || $0.role == "assistant") && !$0.isHidden && !$0.text.isEmpty } }

    // MARK: fabrication guard

    func testAClaimWithNoToolIsHiddenAndBouncedOnceWithTheExactCorrective() async {
        let transport = ScriptedTransport([text("Done — added \"Milk\" to your list."), text("Which list should it go on?")])
        let outcome = await runTurn("add milk", transport)
        XCTAssertEqual(outcome, .reply("Which list should it go on?"))
        XCTAssertEqual(transport.asks.count, 2)
        // The second request carries the hidden claim + the hidden corrective, verbatim.
        let second = transport.asks[1]
        XCTAssertEqual(second.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(second[1].content, "Done — added \"Milk\" to your list.")
        XCTAssertEqual(second[2].content, AssistantHarness.correctiveText)
        XCTAssertEqual(second[2].content, "(integrity check from the app — not the user. The user did NOT see your last message. No tool was called, so nothing was done. If the action is still needed, call the right tool NOW, then answer as if for the first time: no apology, no \"I said\", no \"I didn't\", no mention of this note.)")
        // The user never sees the claim or the check.
        XCTAssertEqual(visible.map(\.text), ["add milk", "Which list should it go on?"])
        XCTAssertEqual(finalThread.filter(\.isHidden).count, 2)
    }

    func testTheGuardBouncesOnlyOncePerTurn() async {
        let transport = ScriptedTransport([text("Done — added it."), text("I've added it for you.")])
        let outcome = await runTurn("add milk", transport)
        XCTAssertEqual(outcome, .reply("I've added it for you."))
        XCTAssertEqual(transport.asks.count, 2)
        XCTAssertEqual(visible.last?.text, "I've added it for you.")
    }

    func testAReadOnlyToolDoesNotDisarmTheGuard() async {
        api.tasks = [task("a", "Alpha")]
        let transport = ScriptedTransport([call("get_schedule", #"{"range":"today"}"#), text("Done — moved it to Friday."), text("Which time on Friday?")])
        let outcome = await runTurn("move alpha to friday", transport)
        XCTAssertEqual(outcome, .reply("Which time on Friday?"))
        XCTAssertEqual(transport.asks.count, 3)
        XCTAssertTrue(transport.asks[2].contains { $0.content == AssistantHarness.correctiveText })
        XCTAssertEqual(api.blocks.count, 0)
    }

    func testAfterABounceTheRetrysToolRunsAndItsSelfCorrectionIsStripped() async {
        let transport = ScriptedTransport([
            text("Done — added \"Milk\"."),
            call("create_task", #"{"name":"Milk"}"#),
            text("Sorry, I said I added it but I didn't. Added it now."),
        ])
        let outcome = await runTurn("add milk", transport)
        XCTAssertEqual(outcome, .reply("Added it now."))
        XCTAssertEqual(api.tasks.map(\.name), ["Milk"])
        let closing = finalThread.last!
        XCTAssertEqual(closing.text, "Added it now.")
        XCTAssertEqual(closing.receipts?.map(\.label), ["Created “Milk”"])
        XCTAssertEqual(closing.receipts?.first?.undo, .deleteTask(id: api.tasks[0].id))
    }

    func testATruthfulClaimAfterAWriteToolIsNotBounced() async {
        let transport = ScriptedTransport([call("create_task", #"{"name":"Milk"}"#), text("Done — added \"Milk\".")])
        let outcome = await runTurn("add milk", transport)
        XCTAssertEqual(outcome, .reply("Done — added \"Milk\"."))
        XCTAssertEqual(transport.asks.count, 2)
    }

    // MARK: honest fallbacks — never a synthesised "Done."

    func testAnEmptyFinalReplyWithNoReceiptsSaysNothingWasChanged() async {
        let transport = ScriptedTransport([text("   ")])
        let outcome = await runTurn("hello", transport)
        XCTAssertEqual(outcome, .reply(AssistantHarness.lostThread))
        XCTAssertEqual(visible.last?.text, "Hmm, I lost my thread there — nothing was changed. Try me again?")
        XCTAssertFalse(finalThread.contains { $0.text == "Done." })
    }

    func testAnEmptyFinalReplyFallsBackToTheFirstReceiptLabel() async {
        let transport = ScriptedTransport([call("create_task", #"{"name":"Milk"}"#), text("")])
        let outcome = await runTurn("add milk", transport)
        XCTAssertEqual(outcome, .reply("Created “Milk”."))
        XCTAssertEqual(finalThread.last?.receipts?.count, 1)
    }

    func testAReceiptLessWriteFallsBackToTheStagedLine() async {
        api.tasks = [task("a", "Alpha")]
        api.candidates = [ShareCandidate(userId: "u2", name: "Zubair")]
        let transport = ScriptedTransport([call("share_task", #"{"taskId":"a","person":"Zubair"}"#), text("")])
        let outcome = await runTurn("share alpha with zubair", transport)
        XCTAssertEqual(outcome, .reply(AssistantHarness.stagedReady))
        XCTAssertEqual(api.staged.count, 1)
    }

    func testExhaustedRoundsCloseHonestly() async {
        let transport = ScriptedTransport((0..<5).map { _ in call("get_schedule", #"{"range":"today"}"#) })
        let outcome = await runTurn("what's on?", transport)
        XCTAssertEqual(outcome, .reply(AssistantHarness.ranOut))
        XCTAssertEqual(transport.asks.count, 5)
        XCTAssertFalse(finalThread.contains { $0.text == "Done." })

        reset()
        let writes = ScriptedTransport((0..<5).map { i in call("create_task", #"{"name":"T\#(i)"}"#, id: "c\(i)") })
        let outcome2 = await runTurn("brain dump", writes)
        XCTAssertEqual(outcome2, .reply(AssistantHarness.partway(5)))
        XCTAssertEqual(finalThread.last?.receipts?.count, 5)
    }

    func testAFailedLaterRoundKeepsWhatWentThroughWithReceipts() async {
        let transport = ScriptedTransport([call("create_task", #"{"name":"Milk"}"#)])   // then .err("upstream")
        let outcome = await runTurn("add milk", transport)
        XCTAssertEqual(outcome, .error("upstream"))
        XCTAssertEqual(finalThread.last?.text, AssistantHarness.droppedMidReply)
        XCTAssertEqual(finalThread.last?.isLocal, true)
        XCTAssertEqual(finalThread.last?.receipts?.count, 1)
        XCTAssertEqual(persisted.last, true)
    }

    // MARK: hints

    func testTruncatedToolJSONGetsTheSplitHint() async {
        let transport = ScriptedTransport([call("create_tasks", #"{"tasks":[{"name":"a"},{"name":"b"#), text("ok")])
        _ = await runTurn("dump", transport)
        let toolTurn = finalThread.first { $0.role == "tool" }
        XCTAssertEqual(toolTurn?.text, AssistantHarness.truncatedArgsResult)
        XCTAssertEqual(api.tasks.count, 0)
    }

    func testFinishReasonLengthAddsTheHiddenCutOffHint() async {
        let transport = ScriptedTransport([call("create_task", #"{"name":"A"}"#, finishReason: "length"), text("Added A.")])
        _ = await runTurn("add a", transport)
        XCTAssertTrue(transport.asks[1].contains { $0.role == "user" && $0.content == AssistantHarness.cutOffHint })
        XCTAssertFalse(visible.contains { $0.text == AssistantHarness.cutOffHint })
    }

    // MARK: deterministic style save

    func testStylePreferenceIsSavedBeforeTheModelSeesTheMessage() async {
        let transport = ScriptedTransport([text("Of course.")])
        var factsAtAsk = -1
        transport.onAsk = { [api] in factsAtAsk = api.facts.count }
        _ = await runTurn("please don't use my name", transport)
        XCTAssertEqual(factsAtAsk, 1, "saved BEFORE the first ask")
        XCTAssertEqual(api.facts.first?.fact, "Don't use their name in replies")
        XCTAssertEqual(finalThread.last?.receipts?.first?.label, "Noted: Don't use their name in replies")
        XCTAssertEqual(finalThread.last?.receipts?.first?.undo, .forgetFact(id: api.facts[0].id))
        // The context the model saw already carries the preference.
        XCTAssertEqual(transport.contexts.first?["nameUse"], .string("never"))
    }

    func testCallMeSavesThePreferredName() async {
        let transport = ScriptedTransport([text("Sure.")])
        _ = await runTurn("Call me Ari from now on", transport)
        XCTAssertEqual(api.facts.first?.fact, "Call them Ari")
        XCTAssertEqual(transport.contexts.first?["preferredName"], .string("Ari"))
    }

    // MARK: send queue (AssistantModel)

    func testASendMidTurnIsQueuedVisiblyAndDrainedInOrder() async throws {
        AssistantModel.scrubPersisted()
        let app = AppModel()   // retained: AssistantModel holds it unowned
        let assistant = AssistantModel(model: app, client: nil)
        assistant.send("first")
        XCTAssertTrue(assistant.sending)
        assistant.send("second")
        assistant.send("third")
        XCTAssertEqual(assistant.queued.map(\.text), ["second", "third"])
        // Queued sends show in the thread as faded pending bubbles, after the live turns.
        let pending = assistant.transcript.filter(\.isPending)
        XCTAssertEqual(pending.map(\.text), ["second", "third"])
        XCTAssertEqual(assistant.transcript.map(\.text), ["first", "second", "third"])
        // Never sent to the model while pending.
        XCTAssertFalse(AssistantModel.modelWindow(assistant.transcript).contains { $0.content == "second" })
        for _ in 0..<200 {
            if !assistant.sending && assistant.queued.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(assistant.sending)
        XCTAssertTrue(assistant.queued.isEmpty)
        XCTAssertEqual(assistant.turns.filter { $0.role == "user" }.map(\.text), ["first", "second", "third"], "drained in order, none dropped")
        XCTAssertEqual(assistant.error, "not_configured")
        assistant.clear()
        withExtendedLifetime(app) {}
    }

    func testQueuedBubblesCarryStableDistinctIds() {
        AssistantModel.scrubPersisted()
        let app = AppModel()   // retained: AssistantModel holds it unowned
        let assistant = AssistantModel(model: app, client: nil)
        assistant.send("first")
        assistant.send("again")
        assistant.send("again")   // a repeated message must not collide
        let ids = assistant.transcript.filter(\.isPending).map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertTrue(ids.allSatisfy(isUUID), "\(ids)")
        XCTAssertEqual(ids, assistant.queued.map(\.id), "the bubble id IS the queued entry's id — stable across drains")
        assistant.clear()
        withExtendedLifetime(app) {}
    }

    func testClearDropsTheQueue() {
        AssistantModel.scrubPersisted()
        let app = AppModel()   // retained: AssistantModel holds it unowned
        let assistant = AssistantModel(model: app, client: nil)
        assistant.send("first")
        assistant.send("second")
        assistant.clear()
        withExtendedLifetime(app) {}
        XCTAssertTrue(assistant.queued.isEmpty)
        XCTAssertFalse(assistant.sending)
        XCTAssertTrue(assistant.turns.isEmpty)
    }

    // MARK: cancel_call undo (a network write)

    func testCancelCallUndoMarksUndoneOnlyOnceTheServerAcceptedAndSurfacesAFailure() async {
        AssistantModel.scrubPersisted()
        let app = AppModel()   // retained: AssistantModel holds it unowned
        let assistant = AssistantModel(model: app, client: nil)
        assistant.appendLocal("Booked.", receipts: [Receipt(icon: .calendar, label: "Call booked", undo: .cancelCall(id: "call-1"))])
        let turnId = assistant.turns.last!.id
        struct Boom: Error {}
        assistant.cancelCallRequest = { _ in throw Boom() }
        let failed = await assistant.undoReceipt(turnId: turnId, index: 0)
        XCTAssertFalse(failed)
        XCTAssertNotEqual(assistant.turns.last?.receipts?[0].undone, true, "a failed cancel keeps the receipt undoable")
        XCTAssertTrue(assistant.turns.last?.receipts?[0].isUndoable ?? false)
        XCTAssertNotNil(assistant.undoFailureNote(turnId: turnId, index: 0), "…and says so")
        XCTAssertFalse(assistant.isUndoInFlight(turnId: turnId, index: 0))
        var cancelled: [String] = []
        assistant.cancelCallRequest = { id in
            cancelled.append(id)
            XCTAssertTrue(assistant.isUndoInFlight(turnId: turnId, index: 0), "reads cancelling… while the server answers")
        }
        let ok = await assistant.undoReceipt(turnId: turnId, index: 0)
        XCTAssertTrue(ok)
        XCTAssertEqual(cancelled, ["call-1"])
        XCTAssertEqual(assistant.turns.last?.receipts?[0].undone, true)
        XCTAssertNil(assistant.undoFailureNote(turnId: turnId, index: 0))
        XCTAssertFalse(assistant.isUndoInFlight(turnId: turnId, index: 0))
        assistant.clear()
        withExtendedLifetime(app) {}
    }

    // MARK: model window

    func testHiddenTurnsReachTheModelButNotTheTranscriptAndLeadingToolTurnsAreDropped() {
        let turns = [
            AssistantTurn(ChatMessage(role: "tool", content: "ok", toolCallId: "x", name: "create_task")),
            AssistantTurn(ChatMessage(role: "user", content: "hi")),
            AssistantTurn(ChatMessage(role: "assistant", content: "claim"), hidden: true),
            AssistantTurn(ChatMessage(role: "user", content: AssistantHarness.correctiveText), hidden: true),
        ]
        let window = AssistantModel.modelWindow(turns)
        XCTAssertEqual(window.map(\.role), ["user", "assistant", "user"])
    }

    // MARK: voice integrity guard

    func testVoiceGuardCorrectsAClaimWithoutAToolOnceAndNeverLoops() {
        var g = VoiceIntegrityGuard()
        g.responseCreated()
        g.transcriptDelta("I've added the dentist for you.")
        XCTAssertTrue(g.shouldCorrect())
        XCTAssertEqual(g.correctionsLeft, 2)
        // The correction's own follow-up is never scored.
        g.responseCreated()
        g.transcriptDelta("I've added it now.")
        XCTAssertFalse(g.shouldCorrect())
        // A reply right after a real write tool is tool-backed.
        g.toolFinished("create_task", result: "ok: created task id=1 name=\"x\"")
        g.responseCreated()
        g.transcriptDelta("Done — added it.")
        XCTAssertFalse(g.shouldCorrect())
        // A read-only tool does not make a reply tool-backed.
        g.toolFinished("get_schedule", result: "ok:\nMonday")
        g.responseCreated()
        g.toolDispatched("get_schedule")
        g.transcriptDelta("Done — moved it.")
        XCTAssertTrue(g.shouldCorrect())
        g.responseCreated(); XCTAssertFalse(g.shouldCorrect())
        g.responseCreated(); g.transcriptDelta("Done — saved."); XCTAssertTrue(g.shouldCorrect())
        g.responseCreated(); XCTAssertFalse(g.shouldCorrect())
        XCTAssertEqual(g.correctionsLeft, 0)
        g.responseCreated(); g.transcriptDelta("Done — saved again."); XCTAssertFalse(g.shouldCorrect(), "capped per session")
        XCTAssertTrue(VoiceIntegrityGuard.correctiveText.hasPrefix("(integrity check from the app, not the user:"))
    }
}
