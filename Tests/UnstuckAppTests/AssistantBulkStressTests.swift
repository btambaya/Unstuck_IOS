// Bulk-turn stress over the PRODUCTION seam.
//
// Testers keep reporting the app dying "after being asked to add a lot of
// items to the calendar" (TestFlight builds 33/34/41, no crash logs attached).
// These tests drive the REAL executor + the REAL harness against the REAL
// AppModelAssistantState over a live GRDB store (in-memory AppDatabase + the
// real WriteThrough + outbox), the way a bulk turn does:
//
//   round 1  create_tasks  × 25 items
//   round 2  schedule_task × 25 calls in ONE reply
//   round 3  block_time    × 25 calls in ONE reply
//   round 4  the plain-text reply
//
// plus the variants the reports describe: the same burst while the Today and
// Calendar view-models are observing the store, and a teardown mid-turn ("I
// tried exiting the AI").
//
// A crash here is the point; the assertions are only there to prove the writes
// really happened (so the burst isn't quietly no-oping).

import XCTest
import Supabase
import UnstuckCore
import UnstuckData
import UnstuckSync
@testable import Unstuck

@MainActor
private final class BulkTransport: AssistantTransport {
    var replies: [HarnessAsk]
    var asks = 0
    /// Runs on every ask — a hook for the teardown variant.
    var onAsk: (() -> Void)?
    init(_ replies: [HarnessAsk]) { self.replies = replies }
    func ask(messages: [ChatMessage], context: [String: AnyJSON]) async -> HarnessAsk {
        asks += 1
        onAsk?()
        return replies.isEmpty ? .err("upstream") : replies.removeFirst()
    }
}

@MainActor
final class AssistantBulkStressTests: XCTestCase {

    /// Keeps the model + assistant alive (the state holds both `unowned`).
    private struct Live {
        let model: AppModel
        let assistant: AssistantModel
        let state: AppModelAssistantState
        let db: AppDatabase
    }

    private func liveStack() throws -> Live {
        AssistantModel.scrubPersisted()
        let model = AppModel()
        model.startUITestMode()
        let db = try XCTUnwrap(model.db)
        let assistant = model.assistant
        return Live(model: model, assistant: assistant,
                    state: AppModelAssistantState(model: model, assistant: assistant), db: db)
    }

    // MARK: - the scripted bulk turn

    private static let names = (1...25).map { "Bulk item \($0)" }

    /// `create_tasks` with 25 items, none pre-scheduled.
    private func createTasksCall() -> HarnessAsk {
        let items = Self.names.map { #"{"name":"\#($0)","estimateMin":30}"# }.joined(separator: ",")
        return .ok(HarnessReply(content: "Adding those now.", toolCalls: [
            ToolCall(id: "bulk-create", type: "function",
                     function: ToolFunction(name: "create_tasks", arguments: #"{"tasks":[\#(items)]}"#)),
        ]))
    }

    /// One `schedule_task` per created id, all in ONE assistant round — every
    /// block lands on the SAME day and overlapping slots (the lane-layout
    /// worst case the reports describe).
    private func scheduleCalls(_ ids: [String], date: String) -> HarnessAsk {
        let calls = ids.enumerated().map { i, id in
            ToolCall(id: "sched-\(i)", type: "function",
                     function: ToolFunction(name: "schedule_task",
                                            arguments: #"{"taskId":"\#(id)","date":"\#(date)","startTime":"\#(String(format: "%02d:00", 9 + i % 6))"}"#))
        }
        return .ok(HarnessReply(content: "Putting them on the calendar.", toolCalls: calls))
    }

    /// 25 `block_time` calls in ONE round — each creates a task AND a block.
    private func blockTimeCalls(date: String) -> HarnessAsk {
        let calls = (0..<25).map { i in
            ToolCall(id: "blk-\(i)", type: "function",
                     function: ToolFunction(name: "block_time",
                                            arguments: #"{"name":"Commitment \#(i)","date":"\#(date)","startTime":"\#(String(format: "%02d:30", 8 + i % 8))","durationMin":90}"#))
        }
        return .ok(HarnessReply(content: "And the commitments.", toolCalls: calls))
    }

    private func deps(_ live: Live, transport: AssistantTransport, scratch: TurnScratch,
                      commit: @escaping ([AssistantTurn], Bool) -> Void = { _, _ in },
                      isCancelled: @escaping () -> Bool = { false }) -> AssistantHarness.Deps {
        let api: AssistantAppState = live.state
        return AssistantHarness.Deps(
            transport: transport, api: api, scratch: scratch,
            context: { buildAssistantContext(api) },
            receipt: { name, args, result in
                assistantReceipt(name: name, args: args, result: result,
                                 tasks: Array(scratch.newTasks.values) + api.getTasks(), facts: api.getProfileFacts())
            },
            stylePreference: { _ in nil },
            commit: { working, persist in commit(working, persist) },
            now: { Date().timeIntervalSince1970 * 1000 },
            isCancelled: isCancelled)
    }

    /// Tomorrow, so no past-time refusal whatever the wall clock says.
    private var target: String { LocalDate.addDays(Clock.todayISO(), 1) }

    // MARK: - 1. the bulk turn on the real store

    func testABulkCalendarTurnOfSeventyFiveWritesSurvivesOnTheRealStore() async throws {
        let live = try liveStack()
        let date = target
        let scratch = TurnScratch()

        // Round 1 runs first so the ids exist for rounds 2/3.
        let t = BulkTransport([createTasksCall()])
        var thread: [AssistantTurn] = []
        var d = deps(live, transport: t, scratch: scratch, commit: { w, _ in thread = w })
        _ = await AssistantHarness.runTurn(
            text: "add these 25 things", base: [AssistantTurn(ChatMessage(role: "user", content: "add these 25 things"), at: 1)], deps: d)
        let ids = Array(scratch.newTasks.keys)
        XCTAssertEqual(ids.count, 25, "all 25 tasks created")
        XCTAssertEqual(live.state.getTasks().filter { $0.name.hasPrefix("Bulk item ") }.count, 25,
                       "…and committed to GRDB before the tool returned")

        // Rounds 2–4 in one turn: 25 schedule_task, then 25 block_time.
        let t2 = BulkTransport([scheduleCalls(ids, date: date), blockTimeCalls(date: date),
                                .ok(HarnessReply(content: "All 50 are on tomorrow."))])
        d = deps(live, transport: t2, scratch: scratch, commit: { w, _ in thread = w })
        let outcome = await AssistantHarness.runTurn(
            text: "now schedule them all tomorrow", base: thread + [AssistantTurn(ChatMessage(role: "user", content: "now schedule them all tomorrow"), at: 2)], deps: d)

        XCTAssertEqual(outcome, .reply("All 50 are on tomorrow."))
        let blocks = live.state.getBlocks().filter { $0.date == date }
        XCTAssertEqual(blocks.count, 50, "25 scheduled tasks + 25 blocked commitments")
        // The outbox carries every one of them (the real write-through path).
        let pending = try OutboxStore(live.db).pending()
        XCTAssertGreaterThanOrEqual(pending.filter { $0.tableName == "cal_blocks" }.count, 50)
    }

    // MARK: - 2. the same burst while the views observe the store

    func testABulkCalendarTurnWhileTodayAndCalendarObserveTheStore() async throws {
        let live = try liveStack()
        let date = target
        let repo = try XCTUnwrap(live.model.taskRepo)
        let db = live.db

        // The two screens that re-derive everything on each snapshot (lane
        // layout, occurrence projection, widget snapshot).
        let today = TodayModel(repo)
        let calendar = CalendarModel(repo, Repository<CalendarConnection>(db, orderColumn: "createdAt"))
        let obs = Task { await today.observe() }
        let obs2 = Task { await calendar.observe() }
        defer { obs.cancel(); obs2.cancel() }
        // Let the first snapshots land.
        try await Task.sleep(nanoseconds: 200_000_000)

        let scratch = TurnScratch()
        let t = BulkTransport([createTasksCall()])
        var thread: [AssistantTurn] = []
        var d = deps(live, transport: t, scratch: scratch, commit: { w, _ in thread = w })
        _ = await AssistantHarness.runTurn(text: "dump", base: [AssistantTurn(ChatMessage(role: "user", content: "dump"), at: 1)], deps: d)
        let ids = Array(scratch.newTasks.keys)

        let t2 = BulkTransport([scheduleCalls(ids, date: date), blockTimeCalls(date: date),
                                .ok(HarnessReply(content: "Done for tomorrow."))])
        d = deps(live, transport: t2, scratch: scratch, commit: { w, _ in thread = w })
        _ = await AssistantHarness.runTurn(text: "schedule", base: thread + [AssistantTurn(ChatMessage(role: "user", content: "schedule"), at: 2)], deps: d)

        // Drain the observation stream so every derived cache is rebuilt over
        // the final 50-block day (lane layout over 50 overlapping blocks).
        for _ in 0..<40 {
            if calendar.blocks.filter({ $0.date == date }).count == 50 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(calendar.blocks.filter { $0.date == date }.count, 50)
        XCTAssertEqual(calendar.laidBlocks(on: date).count, 50, "every block got a lane")
        XCTAssertFalse(today.all.isEmpty)
    }

    // MARK: - 3. tearing the assistant down mid-turn

    /// "I tried exiting the AI after two prompts … and then it crashed."
    /// The turn keeps running after the sheet goes away (by design — the
    /// detached Task is not tied to the view), and the panel-closed bookkeeping
    /// + a `clear()` land while tools are still executing.
    func testExitingTheSheetMidTurnDoesNotTakeTheTurnDownWithIt() async throws {
        let live = try liveStack()
        let date = target
        let scratch = TurnScratch()

        let t = BulkTransport([createTasksCall()])
        var thread: [AssistantTurn] = []
        var d = deps(live, transport: t, scratch: scratch, commit: { w, _ in thread = w })
        _ = await AssistantHarness.runTurn(text: "dump", base: [AssistantTurn(ChatMessage(role: "user", content: "dump"), at: 1)], deps: d)
        let ids = Array(scratch.newTasks.keys)

        // The sheet is dismissed between rounds, then the conversation cleared.
        let t2 = BulkTransport([scheduleCalls(ids, date: date), blockTimeCalls(date: date),
                                .ok(HarnessReply(content: "Done."))])
        t2.onAsk = { [assistant = live.assistant] in
            if t2.asks == 2 {
                assistant.panelClosed()
                assistant.clear()
            }
        }
        d = deps(live, transport: t2, scratch: scratch, commit: { w, _ in thread = w })
        let outcome = await AssistantHarness.runTurn(
            text: "schedule", base: thread + [AssistantTurn(ChatMessage(role: "user", content: "schedule"), at: 2)], deps: d)
        XCTAssertEqual(outcome, .reply("Done."), "the turn finishes even though the sheet went away")
        XCTAssertEqual(live.state.getBlocks().filter { $0.date == date }.count, 50)
    }

    /// The same thing through the model's OWN detached turn task (the real
    /// send path), cleared mid-flight: the executor keeps writing against an
    /// AppModelAssistantState whose `assistant` is the cleared model.
    func testClearWhileTheModelsOwnTurnTaskIsRunning() async throws {
        let live = try liveStack()
        let assistant = live.assistant
        assistant.send("do a lot of things")
        // Not configured (no coordinator) → the turn errors out fast; the
        // point is that clear() racing the in-flight task is safe.
        assistant.clear()
        for _ in 0..<40 where assistant.sending { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertFalse(assistant.sending)
        XCTAssertTrue(assistant.transcript.isEmpty)
    }
}
