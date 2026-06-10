// The in-app agent — an agentic chat that brain-dumps to manage the user's
// schedule. The user types a request ("schedule my taxes for tomorrow
// morning", "make a groceries list with milk and eggs"); the qwen-backed
// `assistant` edge fn replies with text and/or tool calls; the CLIENT executes
// the tool calls against the user's data through the same offline-first methods
// the UI uses, looping until a plain-text reply.
//
// 1:1 with the Android AppViewModel assistant block + AssistantSheet:
//  • AssistantModel owns the conversation (`history`), the in-flight `sending`
//    flag, the last `error` code, the agentic turn loop (≤5 iterations), the
//    tool dispatcher, and the compact context builder.
//  • The turn runs in a detached Task (NOT tied to the sheet's lifetime) so
//    dismissing the sheet mid-"Thinking…" can't cancel a multi-step turn and
//    leave tool actions half-applied with no reply.
//  • History is persisted to UserDefaults (windowed to the last 40 messages
//    starting at a user turn) so it survives close/reopen + an app restart,
//    and is scrubbed on sign-out / account-delete (cross-account leak class).
//
// VOICE IS DEFERRED — text chat + tool execution only. No realtime, no audio.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign
import Supabase
import UnstuckSync

@MainActor
@Observable
final class AssistantModel {
    /// The full OpenAI-shape conversation (user / assistant / tool). The UI
    /// derives the visible transcript from this; the turn loop appends to it.
    private(set) var history: [ChatMessage] = []
    /// True while an agentic turn is in flight (survives sheet reopen).
    private(set) var sending = false
    /// Error code of the last failed turn (nil = none); survives sheet reopen.
    private(set) var error: String?

    /// The app model — the dispatcher + context builder reach its write methods
    /// + repos through this. Weak isn't needed (AppModel owns this lazily and
    /// outlives it), but the closure-free direct reference keeps it simple.
    private unowned let model: AppModel

    private let client: AssistantClient?

    /// The in-flight turn. Detached from any view so dismissing the sheet can't
    /// cancel it (a half-applied multi-step turn with no reply is the bug we're
    /// avoiding — same reason Android runs it on viewModelScope).
    private var turnTask: Task<Void, Never>?

    private static let historyKey = "unstuck.assistant.history"

    init(model: AppModel, client: AssistantClient?) {
        self.model = model
        self.client = client
        loadHistory()
    }

    // MARK: - public surface

    /// Append a user message + run the agentic turn. Fire-and-forget for the
    /// caller: progress/result surface via `sending`/`error`/`history`.
    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        sending = true
        error = nil
        history.append(ChatMessage(role: "user", content: t))
        persist()
        // The Task inherits this @MainActor isolation, so the loop + the state
        // writes below run on the main actor. It is NOT tied to the sheet, so
        // dismissing the sheet can't cancel a multi-step turn.
        turnTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.runTurn()
            switch outcome {
            case .reply: break       // already appended to history by the loop
            case .error(let code): self.error = code
            }
            self.persist()
            self.sending = false
        }
    }

    /// "New chat" + the sign-out / account-delete scrub. Cancels any in-flight
    /// turn and wipes the persisted conversation so the next account on a shared
    /// device never sees the previous user's chat/brain-dump.
    func clear() {
        turnTask?.cancel()
        turnTask = nil
        sending = false
        error = nil
        history.removeAll()
        Self.scrubPersisted()
    }

    /// Wipe the persisted assistant history WITHOUT building the live model.
    /// Called from sign-out / account-delete so the scrub doesn't pay the cost
    /// of instantiating the agent just to clear it when the user never opened it.
    static func scrubPersisted() {
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    /// The visible transcript: user + assistant text bubbles (tool steps and
    /// empty assistant tool-call turns are hidden). Mirrors Android's `shown`.
    var transcript: [ChatMessage] {
        history.filter { ($0.role == "user" || $0.role == "assistant") && !($0.content ?? "").isEmpty }
    }

    // MARK: - the agentic turn

    private enum Turn {
        case reply(String)
        case error(String)   // "not_configured" | "network" | "timeout" | "upstream" | …
    }

    /// Up to 5 iterations: ask → if the reply has tool_calls, run each via the
    /// dispatcher and append a role:"tool" result, then loop; if no tool_calls,
    /// return the content (or "Done."). 1:1 with Android assistantTurn.
    private func runTurn() async -> Turn {
        guard let client else { return .error("not_configured") }
        // Scratch for entities created mid-turn (the live store lags the
        // optimistic write), so a later tool call can reference them by id.
        var newTasks: [String: TaskItem] = [:]
        var newLists: [String: ItemCollection] = [:]

        var iterations = 0
        while iterations < 5 {
            iterations += 1
            if Task.isCancelled { return .reply("Done.") }
            let context = buildContext()
            switch await client.ask(messages: history, context: context) {
            case .err(let code):
                return .error(code)
            case .ok(let reply):
                history.append(ChatMessage(role: "assistant", content: reply.content, toolCalls: reply.toolCalls))
                let calls = reply.toolCalls ?? []
                if calls.isEmpty {
                    let text = (reply.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return .reply(text.isEmpty ? "Done." : text)
                }
                for call in calls {
                    let result = runTool(name: call.function.name,
                                         args: parseArgs(call.function.arguments),
                                         newTasks: &newTasks, newLists: &newLists)
                    history.append(ChatMessage(role: "tool", content: result,
                                               toolCallId: call.id, name: call.function.name))
                }
            }
        }
        return .reply("Done.")
    }

    private func parseArgs(_ s: String) -> [String: AnyJSON] {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONDecoder().decode([String: AnyJSON].self, from: data) else { return [:] }
        return obj
    }

    // MARK: - tool dispatcher

    /// Execute one tool call → a short "ok: …"/"error: …" string the model reads
    /// next turn. `newTasks`/`newLists` are mid-turn scratch so a later call can
    /// reference an entity created earlier THIS turn. 1:1 with Android
    /// runAssistantTool — wrong mutations here corrupt user data, so each branch
    /// mirrors the Android dispatcher exactly.
    private func runTool(name: String, args: [String: AnyJSON],
                         newTasks: inout [String: TaskItem],
                         newLists: inout [String: ItemCollection]) -> String {
        func str(_ k: String) -> String? {
            if case .string(let v)? = args[k] { let t = v.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
            return nil
        }
        func int(_ k: String) -> Int? {
            switch args[k] {
            case .double(let d): return Int(d)
            case .integer(let i): return i
            case .string(let s): return Int(s)
            default: return nil
            }
        }
        func bool(_ k: String) -> Bool? {
            if case .bool(let v)? = args[k] { return v }
            return nil
        }
        func strList(_ k: String) -> [String]? {
            if case .array(let a)? = args[k] {
                return a.compactMap { if case .string(let s) = $0 { return s }; return nil }
            }
            return nil
        }
        func intList(_ k: String) -> [Int]? {
            if case .array(let a)? = args[k] {
                return a.compactMap {
                    switch $0 {
                    case .double(let d): return Int(d)
                    case .integer(let i): return i
                    default: return nil
                    }
                }
            }
            return nil
        }
        // Resolve a task/list id: scratch map first (the live store lags the
        // optimistic write), then the live store.
        func findTask(_ id: String?) -> TaskItem? {
            guard let id else { return nil }
            if let t = newTasks[id] { return t }
            return liveTasks().first { $0.id == id }
        }
        func findList(_ id: String?) -> ItemCollection? {
            guard let id else { return nil }
            if let c = newLists[id] { return c }
            return liveCollections().first { $0.id == id }
        }

        switch name {
        case "create_task":
            guard let nm = str("name") else { return "error: name required" }
            // addTask's signature lacks lifeArea/firstPhysicalAction/later/dueAt
            // — set them after on the returned task + saveTask, like promoteCapture.
            var t = model.addTask(name: nm, estimateMin: int("estimateMin") ?? 25, tags: strList("tags"))
            t.lifeArea = str("lifeArea") ?? t.lifeArea
            t.firstPhysicalAction = str("firstPhysicalAction") ?? t.firstPhysicalAction
            t.dueAt = str("dueAt") ?? t.dueAt
            t.later = bool("later") ?? t.later
            t.updatedAt = AppModel.isoNow()
            model.saveTask(t)
            newTasks[t.id] = t
            return "ok: created task id=\(t.id) name=\"\(t.name)\""

        case "schedule_task":
            guard let t = findTask(str("taskId")) else { return "error: task not found" }
            guard let d = str("date") else { return "error: date required" }
            guard let tm = str("startTime") else { return "error: startTime required" }
            model.scheduleTaskAt(t, date: d, startTime: tm)
            return "ok: scheduled \"\(t.name)\" \(d) \(tm)"

        case "update_task":
            guard var t = findTask(str("taskId")) else { return "error: task not found" }
            t.name = str("name") ?? t.name
            t.estimateMin = int("estimateMin") ?? t.estimateMin
            t.lifeArea = str("lifeArea") ?? t.lifeArea
            t.tags = strList("tags") ?? t.tags
            t.firstPhysicalAction = str("firstPhysicalAction") ?? t.firstPhysicalAction
            t.updatedAt = AppModel.isoNow()
            model.saveTask(t)
            newTasks[t.id] = t
            return "ok: updated \"\(t.name)\""

        case "set_task_later":
            guard let t = findTask(str("taskId")) else { return "error: task not found" }
            model.setLater(t, bool("later") ?? true)
            return "ok"

        case "set_task_recurrence":
            guard let t = findTask(str("taskId")) else { return "error: task not found" }
            let until = str("until")
            let rec: Recurrence?
            switch str("kind") {
            case "daily": rec = .daily(until: until)
            case "weekly": rec = .weekly(daysOfWeek: intList("daysOfWeek") ?? [], until: until)
            case "monthly": rec = .monthly(until: until)
            default: rec = nil   // "none" / unknown → clear recurrence
            }
            model.setRecurrence(t, rec)
            return "ok"

        case "complete_task":
            guard let t = findTask(str("taskId")) else { return "error: task not found" }
            if !t.done { model.toggleDone(t) }
            return "ok: completed \"\(t.name)\""

        case "delete_task":
            guard let t = findTask(str("taskId")) else { return "error: task not found" }
            model.deleteTask(t.id)
            newTasks.removeValue(forKey: t.id)
            return "ok: deleted \"\(t.name)\""

        case "create_list":
            guard let nm = str("name") else { return "error: name required" }
            guard let c = model.addCollection(name: nm, color: str("color") ?? "indigo",
                                              existing: liveCollections()) else {
                return "error: could not create list"
            }
            newLists[c.id] = c
            return "ok: created list id=\(c.id) name=\"\(c.name)\""

        case "add_to_list":
            guard let c = findList(str("listId")) else { return "error: list not found" }
            guard let b = str("body") else { return "error: body required" }
            model.addCollectionItem(c, body: b)
            return "ok: added to \"\(c.name)\""

        case "promote_item_to_task":
            guard let c = findList(str("listId")) else { return "error: list not found" }
            let itemId = str("itemId")
            guard let item = c.items.first(where: { $0.id == itemId }) else { return "error: item not found" }
            let mode: AppModel.PromoteMode = (str("mode") == "loop") ? .loop : .selfOnly
            model.moveItemToTask(c, item: item, mode: mode, dueAtIso: str("dueAt"))
            return "ok: promoted \"\(item.body)\""

        default:
            return "error: unknown tool \(name)"
        }
    }

    // MARK: - store reads

    private func liveTasks() -> [TaskItem] {
        (try? model.taskRepo?.all()) ?? []
    }
    private func liveCollections() -> [ItemCollection] {
        (try? model.db?.fetchAllCollections()) ?? []
    }

    // MARK: - context builder

    /// Compact snapshot of the user's open tasks / lists / areas / tags for the
    /// agent. 1:1 with Android buildAssistantContext: open tasks only (≤60),
    /// non-archived lists, items ≤40. Reference items by their id.
    private func buildContext() -> [String: AnyJSON] {
        let tasks = liveTasks()
        let collections = liveCollections()
        let blocks = (try? model.db?.fetchAllCalBlocks()) ?? []
        let areas = (try? model.db?.fetchAllLifeAreas()) ?? []
        let tags = (try? model.db?.fetchAllTags()) ?? []

        // First task-block per task → its scheduled date/time (Android groups by
        // taskId then takes firstOrNull).
        var firstBlock: [String: CalBlock] = [:]
        for b in blocks {
            guard let tid = b.taskId else { continue }
            if firstBlock[tid] == nil { firstBlock[tid] = b }
        }

        var ctx: [String: AnyJSON] = [:]
        ctx["today"] = .string(Clock.todayISO())
        ctx["now"] = .string(AppModel.isoNow())
        ctx["currentName"] = .string(model.currentUserName ?? "")
        ctx["areas"] = .array(areas.map { .string($0.name) })
        ctx["tags"] = .array(tags.map { .string($0.name) })

        let openTasks = tasks.filter { !$0.done }.prefix(60)
        ctx["tasks"] = .array(openTasks.map { t in
            var o: [String: AnyJSON] = [
                "id": .string(t.id),
                "name": .string(t.name),
                "estimateMin": .integer(t.estimateMin),
            ]
            if let area = t.lifeArea { o["lifeArea"] = .string(area) }
            if t.later == true { o["later"] = .bool(true) }
            if t.recurrence != nil { o["repeats"] = .bool(true) }
            if let b = firstBlock[t.id] {
                o["scheduledDate"] = .string(b.date)
                o["scheduledTime"] = .string(b.startTime)
            }
            return .object(o)
        })

        ctx["lists"] = .array(collections.filter { $0.archived != true }.map { c in
            let items = c.items.prefix(40).map { i -> AnyJSON in
                var io: [String: AnyJSON] = ["id": .string(i.id), "body": .string(i.body)]
                if i.done == true { io["done"] = .bool(true) }
                return .object(io)
            }
            return .object([
                "id": .string(c.id),
                "name": .string(c.name),
                "items": .array(items),
            ])
        })

        return ctx
    }

    // MARK: - persistence

    /// Persist the window (last 40 messages, starting at a user turn so we never
    /// re-send an orphaned tool_call). 1:1 with Android persistAssistant.
    private func persist() {
        let tail = Array(history.suffix(40))
        let window = Array(tail.drop(while: { $0.role != "user" }))
        guard let data = try? JSONEncoder().encode(window) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let loaded = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return }
        history = loaded
    }
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
