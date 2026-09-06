// The in-app agent — an agentic chat that brain-dumps to manage the user's
// schedule. The user types a request ("schedule my taxes for tomorrow
// morning", "make a groceries list with milk and eggs"); the qwen-backed
// `assistant` edge fn replies with text and/or tool calls; the CLIENT executes
// the tool calls against the user's data through the same offline-first methods
// the UI uses, looping until a plain-text reply.
//
// 1:1 with the WEB gateway (lib/assistant/use-assistant.ts + tools.ts) per
// docs/assistant-tool-contract.md:
//  • AssistantModel owns the ONE endless conversation (`turns`), the in-flight
//    `sending` flag, the send QUEUE, the last `error` code and persistence;
//    the loop itself is `AssistantHarness`, the executor `runAssistantTool`,
//    the context `buildAssistantContext` — all written against the
//    `AssistantAppState` seam (AppModelAssistantState in production).
//  • The turn runs in a detached Task (NOT tied to the sheet's lifetime) so
//    dismissing the sheet mid-"Thinking…" can't cancel a multi-step turn and
//    leave tool actions half-applied with no reply.
//  • DISPLAY history persists LONG (200 turns, with day dividers + receipts);
//    the MODEL window stays short (40, aligned to start at a user turn, local
//    check-in turns excluded) so a long thread never blows the context.
//  • Every successful write tool yields a deterministic action RECEIPT derived
//    from the executor's own result string (never model prose).
//  • `share_task` NEVER shares: it stages a request the user confirms on
//    screen (the one action that sends their content to another person).
//
// Both text and realtime-voice tool calls run through the same executor.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign
import Supabase
import UnstuckSync

/// One turn in the endless thread: the wire message the model sees, plus the
/// display-only metadata the panel renders. The wire shape (`ChatMessage`) is
/// untouched — `at` / `local` / `hidden` / `receipts` never reach the edge
/// function because only `message` is sent (see `modelWindow`).
struct AssistantTurn: Codable, Equatable, Identifiable {
    var id: String
    var message: ChatMessage
    /// Epoch ms — drives the Today / Yesterday / date dividers.
    var at: Double?
    /// Locally injected (the daily check-in, voice receipts): displayed, never sent upstream.
    var local: Bool?
    /// Sent to the model but never displayed (the fabrication-guard bounce,
    /// the length-cut-off hint).
    var hidden: Bool?
    /// A queued send waiting for the current turn to finish — displayed
    /// faded, never persisted, never sent until it becomes a real turn.
    var pending: Bool?
    /// Deterministic ✓-cards for what this turn actually changed.
    var receipts: [Receipt]?

    init(_ message: ChatMessage, id: String = newUUID(), at: Double? = nil,
         local: Bool? = nil, hidden: Bool? = nil, pending: Bool? = nil, receipts: [Receipt]? = nil) {
        self.id = id
        self.message = message
        self.at = at
        self.local = local
        self.hidden = hidden
        self.pending = pending
        self.receipts = receipts
    }

    var role: String { message.role }
    var text: String { message.content ?? "" }
    var isLocal: Bool { local == true }
    var isHidden: Bool { hidden == true }
    var isPending: Bool { pending == true }
    /// A model round that asked for tools — its text is narration of the next
    /// step, never a reply (see `AssistantModel.displayTurns`).
    var hasToolCalls: Bool { !(message.toolCalls ?? []).isEmpty }
    /// The undoable receipts still on offer for this turn.
    var undoableReceipts: [Receipt] { (receipts ?? []).filter(\.isUndoable) }
}

@MainActor
@Observable
final class AssistantModel {
    /// The ONE endless conversation (user / assistant / tool turns + local
    /// check-ins). The UI derives the visible transcript from this; the turn
    /// loop appends to it; `modelWindow` narrows it for the edge function.
    private(set) var turns: [AssistantTurn] = []
    /// A message sent while a turn was in flight. Minted with its own id at
    /// enqueue time so the pending bubble's identity is stable across drains
    /// (an index/hash id re-keyed every bubble when the head was drained, and
    /// collided for a repeated message).
    struct QueuedSend: Equatable, Identifiable {
        let id: String
        let text: String
    }
    /// Messages sent while a turn was in flight — QUEUED, not dropped (a
    /// silently dropped message read as "it ignored me", prod 2026-09-01).
    /// Drained one per idle moment; shown in the thread as faded bubbles.
    private(set) var queued: [QueuedSend] = []
    /// Share requests the agent PREPARED this session — the panel renders a
    /// confirm card for each; nothing is shared without the user's tap.
    private(set) var pendingShares: [PendingShare] = []
    /// The user's trusted circle, refreshed when the panel opens. Cached so the
    /// synchronous tool dispatcher can resolve "share it with Zubair" without a
    /// blocking network call. Active members only.
    private(set) var shareCandidates: [ShareCandidate] = []
    /// Every circle member (name + status) for the context's `people`.
    private(set) var circlePeople: [CirclePerson] = []
    /// True while an agentic turn is in flight (survives sheet reopen).
    private(set) var sending = false
    /// Error code of the last failed turn (nil = none); survives sheet reopen.
    private(set) var error: String?
    /// The most recent completed assistant reply text + a monotonic tick, so the
    /// chat's "read aloud" toggle can speak each new reply exactly once.
    private(set) var lastReply: String?
    private(set) var lastReplyTick = 0
    /// Live transcript target for the chat's on-device dictation (STT). The chat
    /// observes this and copies it into its input field — keeps the @Sendable STT
    /// callbacks off the SwiftUI @State binding.
    var voiceDraft = ""
    func setVoiceDraft(_ s: String) { voiceDraft = s }
    /// On-device dictation in progress. Lives here (not @State) so the @Sendable
    /// STT callbacks can flip it back off from the recognizer's queue.
    var dictating = false

    /// The app model — the executor + context builder reach its write methods
    /// + repos through the `AssistantAppState` bridge.
    private unowned let model: AppModel
    private let client: AssistantClient?
    /// The app-state seam the executor/context/harness run against.
    @ObservationIgnored private var _api: AssistantAppState?
    private var api: AssistantAppState {
        if let a = _api { return a }
        let a = AppModelAssistantState(model: model, assistant: self)
        _api = a
        return a
    }

    /// The in-flight turn. Detached from any view so dismissing the sheet can't
    /// cancel it (a half-applied multi-step turn with no reply is the bug we're
    /// avoiding — same reason Android runs it on viewModelScope).
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    /// Bumped by clear(): a send that was mid-flight when the user cleared the
    /// conversation must NOT resurrect the whole thread when it commits.
    @ObservationIgnored private var historyEpoch = 0

    /// Display persistence (the endless thread) + the model window. Both mirror
    /// the web (lib/assistant/use-assistant.ts). `nonisolated` so the pure
    /// `modelWindow` (and its unit tests) can read them off the main actor.
    nonisolated static let maxPersisted = 200
    nonisolated static let maxModelWindow = 40

    private static let threadKey = "unstuck.assistant.thread"
    /// Pre-redesign key (a bare `[ChatMessage]` array) — migrated once on load.
    private static let legacyHistoryKey = "unstuck.assistant.history"
    /// Day stamp of the last injected check-in line.
    private static let checkinKey = "unstuck.assistant.checkin"

    /// This VISIT's check-in bookkeeping (the web keeps these as refs on the
    /// panel component; the model outlives the sheet here, so the panel resets
    /// them on dismiss). `engaged` stops a mid-conversation send from summoning
    /// the greeting retroactively.
    @ObservationIgnored private var checkinConsidered = false
    @ObservationIgnored private var engagedThisVisit = false

    init(model: AppModel, client: AssistantClient?) {
        self.model = model
        self.client = client
        loadHistory()
    }

    // MARK: - public surface

    /// Append a user message + run the agentic turn. Fire-and-forget for the
    /// caller: progress/result surface via `sending`/`error`/`turns`. A send
    /// while a turn is in flight is QUEUED (visible) and sent when it lands.
    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if sending { queued.append(QueuedSend(id: newUUID(), text: t)); return }
        startTurn(t)
    }

    private func startTurn(_ text: String) {
        sending = true
        error = nil
        engagedThisVisit = true
        let base = turns + [AssistantTurn(ChatMessage(role: "user", content: text), at: Self.nowMillis())]
        turns = base
        persist()
        let epoch = historyEpoch
        let deps = harnessDeps(base: base, epoch: epoch)
        // The Task inherits this @MainActor isolation, so the loop + the state
        // writes below run on the main actor. It is NOT tied to the sheet.
        turnTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await AssistantHarness.runTurn(text: text, base: base, deps: deps)
            guard self.historyEpoch == epoch else { return }   // cleared mid-flight
            switch outcome {
            case .reply(let reply):
                self.lastReply = reply
                self.lastReplyTick += 1
            case .error(let code):
                self.error = code
            case .cancelled:
                break
            }
            self.persist()
            self.sending = false
            self.drainQueue()
        }
    }

    /// Drain the queue one message per idle moment.
    private func drainQueue() {
        guard !sending, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        startTurn(next.text)
    }

    private func harnessDeps(base: [AssistantTurn], epoch: Int) -> AssistantHarness.Deps {
        let api = self.api
        let scratch = TurnScratch()
        let transport: AssistantTransport = client.map { AssistantClientTransport($0) } ?? NotConfiguredTransport()
        return AssistantHarness.Deps(
            transport: transport,
            api: api,
            scratch: scratch,
            context: { buildAssistantContext(api) },
            receipt: { [weak self] name, args, result in
                guard let self else { return nil }
                return self.receipt(name: name, args: args, result: result, scratch: scratch)
            },
            stylePreference: { [weak self] text in self?.saveStylePreference(text) },
            commit: { [weak self] working, persist in
                guard let self, self.historyEpoch == epoch else { return }   // thread was cleared — drop
                // MERGE, don't replace: turns appended to the thread meanwhile
                // (a voice session's receipts, the check-in line) must survive.
                let have = Set(working.map(\.id))
                let baseIds = Set(base.map(\.id))
                let appendedMeanwhile = self.turns.filter { !have.contains($0.id) && !baseIds.contains($0.id) }
                self.turns = working + appendedMeanwhile
                if persist { self.persist() }
            },
            now: { Self.nowMillis() },
            isCancelled: { Task.isCancelled }
        )
    }

    /// Receipt for one executed call, resolving undo targets against the
    /// scratch rows first (the store lags the optimistic write).
    private func receipt(name: String, args: ToolArgs, result: String, scratch: TurnScratch) -> Receipt? {
        assistantReceipt(name: name, args: args, result: result,
                         tasks: Array(scratch.newTasks.values) + api.getTasks(), facts: api.getProfileFacts())
    }

    /// "Don't use my name" / "call me X" are saved by the APP before the model
    /// sees the message; the receipt makes it visible.
    private func saveStylePreference(_ text: String) -> Receipt? {
        guard let pref = ProfileFactsLogic.detectStylePreference(text),
              let stored = api.saveStylePreference(pref) else { return nil }
        return Receipt(icon: .pencil, label: "Noted: \(stored.fact)", undo: .forgetFact(id: stored.id))
    }

    /// "Clear conversation" (the ⋯ menu) + the sign-out / account-delete scrub.
    /// Cancels any in-flight turn and wipes the persisted thread so the next
    /// account on a shared device never sees the previous user's brain-dump.
    func clear() {
        historyEpoch += 1
        turnTask?.cancel()
        turnTask = nil
        sending = false
        error = nil
        queued.removeAll()
        turns.removeAll()
        pendingShares.removeAll()
        Self.scrubPersisted()
    }

    /// Wipe the persisted assistant thread WITHOUT building the live model.
    /// Called from sign-out / account-delete so the scrub doesn't pay the cost
    /// of instantiating the agent just to clear it when the user never opened it.
    static func scrubPersisted() {
        UserDefaults.standard.removeObject(forKey: threadKey)
        UserDefaults.standard.removeObject(forKey: legacyHistoryKey)
        UserDefaults.standard.removeObject(forKey: checkinKey)
    }

    /// The visible transcript: user bubbles + each turn's FINAL reply (with
    /// its receipts) + local lines, followed by the queued sends as faded
    /// pending bubbles. Mirrors the web's `messages` + `queued`.
    var transcript: [AssistantTurn] {
        let shown = Self.displayTurns(turns)
        let pending = queued.map { AssistantTurn(ChatMessage(role: "user", content: $0.text), id: $0.id, pending: true) }
        return shown + pending
    }

    var hasHistory: Bool { !transcript.isEmpty }

    /// The DISPLAY filter (1:1 with lib/assistant/display.ts). The persisted
    /// thread keeps every round — the model needs its own tool_calls narration
    /// and the hidden bounces next request — but a person sees only their
    /// bubbles, each turn's final reply and the local check-in lines. Hidden:
    /// tool turns, the guard bounce + the claim it answers, the cut-off hint,
    /// empty turns, and every assistant round that CARRIES tool_calls — its
    /// text ("I'll get your lists…", "Let me try the correct tool:") is the
    /// model narrating its next step. That narration rendered as one bubble
    /// per round (tester round, 2026-09-06: four bubbles for one question);
    /// it now only feeds the transient status while the turn runs.
    nonisolated static func displayTurns(_ turns: [AssistantTurn]) -> [AssistantTurn] {
        turns.filter {
            ($0.role == "user" || $0.role == "assistant") && !$0.isHidden && !$0.hasToolCalls
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The in-flight turn's latest narration — the newest assistant round with
    /// tool_calls since the last visible user turn — as ONE line for the
    /// typing indicator; nil when there is none yet ("Thinking…"). A hidden
    /// user turn (the guard bounce / cut-off hint) does not end the turn.
    nonisolated static func workingStatus(_ turns: [AssistantTurn]) -> String? {
        for t in turns.reversed() {
            if t.role == "user" && !t.isHidden { return nil }
            if t.role == "assistant" && t.hasToolCalls, let line = oneLine(t.text) { return line }
        }
        return nil
    }

    /// First non-empty line, trimmed, capped for a single status row.
    nonisolated static func oneLine(_ text: String, max: Int = 80) -> String? {
        guard let first = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        guard first.count > max else { return first }
        return String(first.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// What the typing indicator says: the in-flight turn's narration, only
    /// while a turn runs — never persisted as a message.
    var status: String? { sending ? Self.workingStatus(turns) : nil }

    /// The per-request model window: the non-local tail, aligned to start at a
    /// user turn so the model never resumes from a dangling tool/assistant turn.
    nonisolated static func modelWindow(_ turns: [AssistantTurn]) -> [ChatMessage] {
        var win = Array(turns.filter { !$0.isLocal && !$0.isPending }.suffix(maxModelWindow))
        if let firstUser = win.firstIndex(where: { $0.role == "user" }), firstUser > 0 {
            win = Array(win[firstUser...])
        }
        // No user turn in the tail (a huge multi-tool turn): never lead with
        // orphaned tool messages whose tool_calls parent was sliced off — the
        // upstream 400s on that (harness audit, 2026-09-01).
        while let first = win.first, first.role == "tool" { win.removeFirst() }
        return win.map(\.message)
    }

    // MARK: - local (zero-token) turns + the daily check-in

    /// Inject a LOCAL display-only assistant turn. Never enters the model
    /// window; persists like any other display turn.
    func appendLocal(_ content: String, receipts: [Receipt]? = nil) {
        turns.append(AssistantTurn(ChatMessage(role: "assistant", content: content),
                                   at: Self.nowMillis(), local: true, receipts: receipts))
        persist()
    }

    /// Once per day, when the panel opens onto an EXISTING conversation, say
    /// the grounded check-in line (a fresh account gets the full hero instead;
    /// a send mid-visit must not summon it retroactively). Zero tokens.
    func maybeInjectCheckin(line: String, now: Date = Date()) {
        guard !checkinConsidered, hasHistory else { return }
        checkinConsidered = true
        guard !engagedThisVisit else { return }
        let today = Self.dayStamp(now)
        let d = UserDefaults.standard
        guard d.string(forKey: Self.checkinKey) != today else { return }
        d.set(today, forKey: Self.checkinKey)
        appendLocal(line)
    }

    /// The panel dismissed — a later reopen counts as a fresh visit.
    func panelClosed() {
        checkinConsidered = false
        engagedThisVisit = false
    }

    private static func dayStamp(_ date: Date) -> String { Clock.dateISO(date) }
    private static func nowMillis() -> Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: - receipts (undo)

    /// Receipts whose undo is waiting on a network round-trip (`cancel_call`),
    /// keyed "turnId:index" — the panel shows "cancelling…" instead of Undo.
    private(set) var undoInFlight: Set<String> = []
    /// Inline note for a receipt whose last undo FAILED (the receipt stays
    /// undoable; cleared on the next attempt).
    private(set) var undoFailures: [String: String] = [:]
    private static func undoKey(_ turnId: String, _ index: Int) -> String { "\(turnId):\(index)" }
    func isUndoInFlight(turnId: String, index: Int) -> Bool { undoInFlight.contains(Self.undoKey(turnId, index)) }
    func undoFailureNote(turnId: String, index: Int) -> String? { undoFailures[Self.undoKey(turnId, index)] }

    /// The network cancel behind a `cancel_call` undo — the calls client the
    /// coordinator holds (AppModel.start attaches it). Injectable for tests.
    @ObservationIgnored var cancelCallRequest: (@MainActor (String) async throws -> Void)?
    private func cancelCall(_ id: String) async throws {
        if let override = cancelCallRequest { return try await override(id) }
        guard let client = CallCoordinator.shared.callsClient else { throw AssistantStateError.offline }
        try await client.cancel(id: id)
    }

    /// Undo one receipt on a persisted turn; flips `undone` so the button
    /// doesn't come back. Returns true when the undo applied — after the
    /// store write is committed (local undo) or the server accepted it
    /// (`cancel_call`), never before.
    @discardableResult
    func undoReceipt(turnId: String, index: Int) async -> Bool {
        guard let ti = turns.firstIndex(where: { $0.id == turnId }),
              let receipts = turns[ti].receipts, index < receipts.count else { return false }
        let receipt = receipts[index]
        guard let undo = receipt.undo, !(receipt.undone ?? false),
              let action = planReceiptUndo(undo, tasks: api.getTasks(), nowISO: AppModel.isoNow())
        else { return false }
        let key = Self.undoKey(turnId, index)
        undoFailures[key] = nil
        switch action {
        case .cancelCall(let id):
            // Network write: the receipt flips to undone only once the server
            // accepted the cancel; meanwhile it reads "cancelling…". A failure
            // keeps the button AND says so, so the user can retry.
            guard !undoInFlight.contains(key) else { return false }
            undoInFlight.insert(key)
            defer { undoInFlight.remove(key) }
            do { try await cancelCall(id) } catch {
                undoFailures[key] = "Couldn't cancel the call — check your connection and try again."
                return false
            }
        default:
            guard await Self.applyLocalUndo(action, api: api) else { return false }
        }
        markUndone(turnId: turnId, index: index)
        return true
    }

    /// The store half of an undo — every action but `cancelCall` (a network
    /// write with its own in-flight bookkeeping). Runs against the
    /// `AssistantAppState` seam so it is testable on the in-memory fake.
    /// Returns false when nothing could be undone (the fact is already gone).
    static func applyLocalUndo(_ action: ReceiptUndoAction, api: AssistantAppState) async -> Bool {
        // Undoing a "Created" mirrors the executor's delete_task: the task AND
        // its calendar blocks — ghost blocks were a confirmed flow bug.
        func removeTaskAndBlocks(_ id: String) async {
            for b in api.getBlocks() where b.taskId == id { await api.deleteBlock(b.id) }
            await api.removeTask(id)
        }
        // Undoing a "Completed" reopens the task — for a loop-promoted shared
        // list item that has to reach the other members (collection-task-done
        // `reopen`) exactly as the UI's un-complete does; a bare upsert left the
        // shared row ticked. Only when the store still had it done: the user
        // may have reopened it by hand in between, and that path already sent it.
        func restore(_ task: TaskItem) async {
            let wasDone = api.getTasks().first { $0.id == task.id }?.done ?? false
            await api.upsertTask(task)
            if wasDone, !task.done { api.notifyTaskReopenedIfShared(task) }
        }
        switch action {
        case .deleteTask(let id): await removeTaskAndBlocks(id)
        case .deleteTasks(let ids): for id in ids { await removeTaskAndBlocks(id) }
        case .restoreTask(let task): await restore(task)
        case .restoreTasks(let tasks): for t in tasks { await restore(t) }
        case .completeTask(let task): await api.upsertTask(task)
        case .forgetFact(let id):
            guard api.removeProfileFact(id) else { return false }
        case .deleteCapture(let id): await api.removeCapture(id)
        case .cancelCall:
            // Handled by undoReceipt (needs the instance's in-flight state).
            return false
        }
        return true
    }

    private func markUndone(turnId: String, index: Int) {
        guard let ti = turns.firstIndex(where: { $0.id == turnId }),
              let n = turns[ti].receipts?.count, index < n else { return }
        turns[ti].receipts?[index].undone = true
        persist()
    }

    /// The LAST turn that still has undoable changes — the "Undo all N changes"
    /// affordance. nil once every receipt has been used.
    var undoAllTarget: (turnId: String, count: Int)? {
        guard let turn = turns.last(where: { !$0.undoableReceipts.isEmpty }) else { return nil }
        return (turn.id, turn.undoableReceipts.count)
    }

    /// One-tap revert of every still-undoable change on `turnId`.
    func undoAll(turnId: String) async {
        guard let ti = turns.firstIndex(where: { $0.id == turnId }) else { return }
        for (i, r) in (turns[ti].receipts ?? []).enumerated() where r.isUndoable {
            await undoReceipt(turnId: turnId, index: i)
        }
    }

    // MARK: - staged shares (never sent without a tap)

    /// Refresh the trusted-circle roster the `share_task` tool resolves against
    /// and the `people` the context lists. Called when the panel opens; a
    /// pending invite can't receive a share but IS a person the model knows of.
    func refreshShareCandidates() async {
        guard let circle = model.coordinator?.circle else { shareCandidates = []; circlePeople = []; return }
        let members = await circle.listCircle()
        circlePeople = members.map { m in
            let name = [m.memberName, m.relationshipLabel]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? "Someone"
            return CirclePerson(name: name, status: m.status)
        }
        shareCandidates = members.compactMap { m in
            guard m.status == "active", let uid = m.memberUserId, !uid.isEmpty else { return nil }
            let name = [m.memberName, m.relationshipLabel]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? "Someone"
            return ShareCandidate(userId: uid, name: name)
        }
    }

    /// The executor staged a share — the panel renders its confirm card.
    func stagePendingShare(_ p: PendingShare) { pendingShares.append(p) }

    /// Mark a staged share resolved (after the user's tap, or dismissal).
    func resolveShare(id: String, outcome: PendingShareOutcome) {
        guard let i = pendingShares.firstIndex(where: { $0.id == id }) else { return }
        pendingShares[i].outcome = outcome
    }

    // MARK: - tour Q&A (guided-tour "Ask a question")

    /// One STATELESS round-trip for the guided tour, through the SAME
    /// `assistant` edge fn + transport as the chat — with `context.tour`
    /// flagging product-tour Q&A mode server-side (the edge fn appends its
    /// stricter tour addendum and withholds the tool schemas; the guardrail
    /// lives on the SERVER). Never touches `turns`/`sending`; the tour ignores
    /// any tool_calls in the reply and falls back to canned TOUR_QA on
    /// error/timeout (see Tour/TourAsk.swift).
    func tourAsk(messages: [ChatMessage], stepId: String, stepTitle: String) async -> AssistantResult {
        guard let client else { return .err("not_configured") }
        var context = buildAssistantContext(api)
        context["tour"] = .object(["step": .string(stepId), "title": .string(stepTitle)])
        return await client.ask(messages: messages, context: context)
    }

    // MARK: - persistence

    /// Persist the DISPLAY thread (last 200 turns). The model window is derived
    /// per-request from this (`modelWindow`), so persistence no longer has to
    /// trim for the context budget — the endless thread is the point.
    private func persist() {
        let tail = Array(turns.suffix(Self.maxPersisted))
        guard let data = try? JSONEncoder().encode(tail) else { return }
        UserDefaults.standard.set(data, forKey: Self.threadKey)
    }

    /// Load the thread, migrating a pre-redesign `[ChatMessage]` blob once so an
    /// existing conversation survives the upgrade (timestamp-less turns simply
    /// render without a day divider).
    private func loadHistory() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.threadKey),
           let loaded = try? JSONDecoder().decode([AssistantTurn].self, from: data) {
            turns = loaded
            return
        }
        if let data = d.data(forKey: Self.legacyHistoryKey),
           let legacy = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            turns = legacy.map { AssistantTurn($0) }
            d.removeObject(forKey: Self.legacyHistoryKey)
            persist()
        }
    }

    // MARK: - voice (realtime "Talk" mode wiring)
    //
    // The realtime session is configured CLIENT-side (session.update), so the
    // instructions + tool schemas live here; tool execution reuses the SAME
    // executor as text mode, with a per-session scratch for mid-call entities.
    // Every persistent action the voice model takes gets the SAME receipt the
    // text path shows, landing in the thread when the overlay closes.

    @ObservationIgnored private var voiceScratch = TurnScratch()
    /// Receipts for what the voice session actually changed (newest last).
    private(set) var voiceReceipts: [Receipt] = []

    /// Reset the mid-call scratch + receipts at the start of a voice session.
    func resetVoiceScratch() {
        voiceScratch = TurnScratch()
        voiceReceipts = []
    }

    /// Execute one realtime tool call (args arrive as a JSON string from the
    /// model) → the short result string. Same executor as text mode.
    func runVoiceTool(name: String, argsJSON: String) async -> String {
        let args = ToolArgs(json: argsJSON)
        let scratch = voiceScratch
        let result = await runAssistantTool(name: name, args: args, api: api, scratch: scratch)
        if let r = receipt(name: name, args: args, result: result, scratch: scratch) { voiceReceipts.append(r) }
        return result
    }

    /// The overlay closed — its receipts (and their Undo) must not vanish: they
    /// land in the shared thread as a local turn (flow review, 2026-08-30).
    func endVoiceSession() {
        let rs = voiceReceipts.filter { !($0.undone ?? false) }
        voiceReceipts = []
        if !rs.isEmpty { appendLocal("While we talked:", receipts: rs) }
    }

    /// What the assistant should DO the moment the session opens (sent as a
    /// one-shot hidden primer): the first-meeting interview, or a by-name hello.
    func voiceOpening() -> String { buildVoiceOpening(api) }

    /// The system prompt + the live context snapshot, for the realtime session.
    func voiceInstructions() -> String { buildVoiceInstructions(api) }

    /// Tool schemas for the realtime session — all 56 (incl. the four call tools), mirroring tools.ts VOICE_TOOLS.
    func voiceTools() -> [[String: Any]] { VOICE_TOOLS }
}

/// Transport when the edge function client isn't available (signed-out demo
/// boot): every ask reports `not_configured`, never a fake reply.
@MainActor
private final class NotConfiguredTransport: AssistantTransport {
    func ask(messages: [ChatMessage], context: [String: AnyJSON]) async -> HarnessAsk { .err("not_configured") }
}

/// Map an edge-fn error code to a calm inline message. Covers every code the
/// client + edge fn can return (1:1 with Android friendlyError, plus the edge
/// fn's own body codes). The assistant may currently return `not_configured`
/// until QWEN_API_KEY is set — handled gracefully, not blocking.
func assistantFriendlyError(_ code: String) -> String {
    switch code {
    case "not_configured": return "The assistant isn't set up yet."
    case "network": return "Couldn't reach the assistant — check your connection."
    case "timeout", "upstream_timeout": return "That took too long — try again."
    case "upstream", "server_error": return "The assistant had a hiccup. Try again."
    case "unauthorized": return "Please sign in to use the assistant."
    case "rate_limited": return "You've sent a lot just now — give it a minute."
    case "payload_too_large": return "That's a bit much at once — try a shorter message."
    default: return "Something went wrong. Try again."
    }
}
