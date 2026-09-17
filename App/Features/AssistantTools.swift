// Assistant tool executor — the CLIENT half of the shared assistant contract
// (docs/assistant-tool-contract.md). The `assistant` edge function owns the
// tool SCHEMAS and the prompt; this file executes the calls through the same
// write paths the UI uses, returning the contract's exact result strings
// (`ok: …` / `error: …`) — the server prompt reads them, so wording is not
// ours to change. 1:1 port of lib/assistant/tools.ts `runAssistantTool`.
//
// The executor is written against `AssistantAppState` (not AppModel) so it
// runs unchanged in unit tests against an in-memory fake, and in the app
// against `AppModelAssistantState` (AssistantTools+AppModel.swift). Both the
// text harness and the realtime voice session dispatch through it.

import Foundation
import Supabase
import UnstuckCore
import UnstuckSync

// MARK: - the app-state seam

struct CirclePerson: Equatable, Sendable {
    let name: String
    let status: String
}

struct TaskShareInfo: Equatable, Sendable {
    let shareId: String
    let recipientName: String
    let level: String
}

/// Everything the executor reads and writes. Mirrors web `AssistantApi`:
/// reads return the FRESHEST committed state; writes go through the same
/// store/sync path the UI uses (cascades, outbox, realtime).
///
/// Store writes are `async` and RETURN ONLY AFTER THE LOCAL ROW IS COMMITTED:
/// the executor reads the store synchronously between its own writes
/// (add_capture → promote_capture; create_task → schedule_task → delete_task
/// in one turn), and a fire-and-forget write behind a synchronous read
/// produced "capture not found" and ghost blocks (review of 2a73c7c).
@MainActor
protocol AssistantAppState: AnyObject {
    // ── reads ──
    func getTasks() -> [TaskItem]
    func getBlocks() -> [CalBlock]
    func getCollections() -> [ItemCollection]
    func getAreas() -> [String]
    func getTags() -> [String]
    func currentUserName() -> String
    /// 'YYYY-MM-DD' in the user's local tz.
    func todayIso() -> String
    /// LOCAL wall-clock 'HH:MM' — injectable so the time guards are testable.
    func nowHM() -> String
    // ── tasks + blocks ──
    func upsertTask(_ t: TaskItem) async
    func removeTask(_ id: String) async
    /// A task that just went done → open is a loop-promoted shared-list item
    /// (`sourceCollectionId` + `sourceItemId` set): un-tick the collection row
    /// for the other members (collection-task-done `reopen`) — the same hook
    /// the UI's un-complete path fires, or the shared row stays ticked forever
    /// with an open task behind it. No-op for any other task.
    func notifyTaskReopenedIfShared(_ t: TaskItem)
    func upsertBlock(_ b: CalBlock) async
    func deleteBlock(_ id: String) async
    // ── lists ──
    /// → the new list's id.
    func addCollection(name: String, color: String) -> String?
    func addCollectionItem(collectionId: String, body: String)
    /// Turn a list item into a task through the SAME path the list UI uses
    /// (task + promotion mark + loop scheduling). `loop` = keep everyone in the loop.
    func promoteItemToTask(collectionId: String, itemId: String, loop: Bool, dueAt: String?)
    func renameCollection(_ id: String, name: String)
    func updateCollection(_ id: String, archived: Bool?, color: String?)
    func removeCollection(_ id: String)
    func updateCollectionItem(collectionId: String, itemId: String, body: String?, done: Bool?)
    func removeCollectionItem(collectionId: String, itemId: String)
    func canEditCollection(_ id: String) -> Bool
    /// Rename / archive / delete are OWNER-only — in the UI (CollectionsFeature
    /// gates them on `isOwner`) and server-side (RLS + the metadata lock), where
    /// an EDITOR's write is accepted and silently discarded. Gating those tools
    /// on `canEditCollection` let the assistant report a change that reverted a
    /// second later.
    func ownsCollection(_ id: String) -> Bool
    // ── sharing ──
    func getShareCandidates() -> [ShareCandidate]
    /// Stage a share for the USER to confirm on screen. Never shares.
    func stageShare(_ p: PendingShare)
    func getCirclePeople() -> [CirclePerson]
    func listTaskShares(taskId: String) async -> [TaskShareInfo]
    /// Throws when the server did NOT revoke the share.
    func unshareTask(shareId: String) async throws
    // ── profile memory ──
    func getProfileFacts() -> [ProfileFact]
    /// Throws `ProfileFactSaveError` — the executor tells a text rejection
    /// (`.empty` / `.instructionLike`) from a store failure (`.storeFailed`).
    func saveProfileFact(category: String?, fact: String, whenIso: String?) throws -> ProfileFact
    /// The deterministic "don't use my name" / "call me X" save (a `preference` fact from `chat`).
    func saveStylePreference(_ pref: StylePreference) -> ProfileFact?
    func removeProfileFact(_ id: String) -> Bool
    // ── behavioural history ──
    func getSessions() -> [UnstuckCore.Session]
    func getReasonLogs() -> [ReasonLog]
    func getStruggles() -> [String]
    // ── captures ──
    func getCaptures() -> [Capture]
    func getArchivedCaptureIds() -> [String]
    func upsertCapture(_ c: Capture) async
    func removeCapture(_ id: String) async
    /// Device-local (UserDefaults) — synchronous.
    func archiveCapture(_ id: String, archived: Bool)
    // ── focus ──
    func getLiveFocus() -> LiveSession?
    func startFocus(taskId: String, estimateMin: Int?, occurrenceBlockId: String?)
    func pauseFocus()
    func resumeFocus()
    func extendFocus(_ minutes: Int)
    func cancelFocus()
    // ── navigation ──
    func navigate(screen: String, id: String?)
    // ── areas + tags ──
    func getAreaRows() -> [LifeArea]
    func addArea(name: String, color: String?) async
    func updateArea(_ id: String, name: String?, color: String?) async
    func removeArea(_ id: String) async
    func getTagRows() -> [TagRow]
    func addTag(name: String) async
    func updateTag(_ id: String, name: String?) async
    func removeTag(_ id: String) async
    // ── settings ──
    func setUsableMinutes(weekday: Int?, weekend: Int?) async -> Bool
    func setNotificationLevel(_ level: String) async -> Bool
    func setReminderLead(_ minutes: Int) async -> Bool
    func setRitual(_ ritual: String, on: Bool)
    // ── first-run interview ──
    /// True until the get-to-know-you interview is finished or skipped on
    /// this account (InterviewMachine's done flag): the voice opening asks
    /// the questions while it is.
    func interviewPending() -> Bool
    /// `finish_interview`: the model has been through every question — set
    /// the same done flag the in-thread interview sets.
    func markInterviewDone()
}

extension AssistantAppState {
    func interviewPending() -> Bool { !InterviewMachine.isDone() }
    func markInterviewDone() { InterviewMachine.markDone() }
}

/// Tools that never change anything — a success here must NOT count as "the
/// assistant acted" for either fabrication guard (text or voice).
let READ_ONLY_TOOLS: Set<String> = ["get_schedule", "get_tasks", "get_captures", "get_lists", "get_insights", "get_calls"]

/// Entities created THIS turn/session, so a later call (schedule_task after
/// create_task) can reference them by id before the optimistic write has
/// propagated back through the store.
@MainActor
final class TurnScratch {
    var newTasks: [String: TaskItem] = [:]
    var newLists: [String: ItemCollection] = [:]
    init() {}
}

// MARK: - arguments

/// Typed accessors over the model's JSON arguments (Supabase `AnyJSON`).
/// `str` trims and treats blank as absent, matching the web helpers.
struct ToolArgs {
    let raw: [String: AnyJSON]

    init(_ raw: [String: AnyJSON] = [:]) { self.raw = raw }
    init(json: String) { self.raw = parseToolArgs(json) }

    var isEmpty: Bool { raw.isEmpty }
    func has(_ k: String) -> Bool { raw[k] != nil }
    func isNull(_ k: String) -> Bool { if case .null? = raw[k] { return true }; return false }

    func str(_ k: String) -> String? {
        if case .string(let v)? = raw[k] {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : v
        }
        return nil
    }
    func int(_ k: String) -> Int? {
        switch raw[k] {
        case .integer(let i)?: return i
        case .double(let d)?: return d.isFinite ? Int(d.rounded()) : nil
        default: return nil
        }
    }
    func bool(_ k: String) -> Bool? {
        if case .bool(let v)? = raw[k] { return v }
        return nil
    }
    func strList(_ k: String) -> [String]? {
        if case .array(let a)? = raw[k] { return a.compactMap { if case .string(let s) = $0 { return s }; return nil } }
        return nil
    }
    func intList(_ k: String) -> [Int]? {
        if case .array(let a)? = raw[k] {
            return a.compactMap {
                switch $0 {
                case .integer(let i): return i
                case .double(let d): return Int(d.rounded())
                default: return nil
                }
            }
        }
        return nil
    }
    func objList(_ k: String) -> [ToolArgs]? {
        if case .array(let a)? = raw[k] { return a.compactMap { if case .object(let o) = $0 { return ToolArgs(o) }; return nil } }
        return nil
    }
    /// The raw arguments re-serialised (for dispatchers that parse their own JSON).
    var json: String {
        (try? JSONEncoder().encode(raw)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    /// The slice the receipt derivation reads.
    var receiptArgs: ReceiptArgs {
        ReceiptArgs(taskId: str("taskId"), date: str("date"), startTime: str("startTime"), later: bool("later"), kind: str("kind"))
    }
}

func parseToolArgs(_ s: String) -> [String: AnyJSON] {
    guard let data = s.data(using: .utf8),
          let obj = try? JSONDecoder().decode([String: AnyJSON].self, from: data) else { return [:] }
    return obj
}

// MARK: - shared helpers (tools.ts module-private functions)

/// The task's NEXT live block (today or later, not done/skipped), by date+time
/// — the same anchor scheduleTask moves.
@MainActor
func nextLiveBlock(_ api: AssistantAppState, taskId: String) -> CalBlock? {
    let today = api.todayIso()
    return api.getBlocks()
        .filter { $0.taskId == taskId && !$0.done && !$0.skipped && $0.date >= today }
        .sorted { ($0.date + $0.startTime) < ($1.date + $1.startTime) }
        .first
}

@MainActor
private func rejectPastDate(_ api: AssistantAppState, _ date: String) -> String? {
    rejectPastDate(today: api.todayIso(), date: date)
}

@MainActor
private func rejectPastTime(_ api: AssistantAppState, _ date: String, _ startTime: String?) -> String? {
    rejectPastTime(blocks: api.getBlocks(), today: api.todayIso(), date: date, startTime: startTime, nowHM: api.nowHM())
}

/// Place (or move) the anchor block for a task at date+time, materialising the
/// recurrence horizon when the task repeats. Returns the time the block landed
/// on (callers report it honestly).
@MainActor
private func scheduleTask(_ api: AssistantAppState, _ task: TaskItem, date: String, startTime: String?) async -> String {
    let blocks = api.getBlocks()
    // The anchor to move is the task's NEXT LIVE block — first-in-array grabbed
    // an old done/skipped occurrence on real accounts (tester round, 2026-09-01).
    let today = api.todayIso()
    let live = blocks
        .filter { $0.taskId == task.id && !$0.done && !$0.skipped }
        .sorted { ($0.date + $0.startTime) < ($1.date + $1.startTime) }
    let anchor = live.first { $0.date >= today } ?? live.last
    // Moving keeps the task's current time; a FIRST-EVER scheduling with no
    // time is refused upstream (the caller asks the user instead of guessing).
    let anchorTime = anchor.flatMap { $0.startTime.isEmpty ? nil : $0.startTime }
    let time = startTime ?? anchorTime ?? "09:00"
    if let anchor {
        var moved = anchor
        moved.date = date
        moved.startTime = time
        await api.upsertBlock(moved)
        // Every UI reschedule bumps move_count (the slip detector's input).
        if anchor.date != date {
            let fresh = api.getTasks().first { $0.id == task.id } ?? task
            await api.upsertTask(bumpMoveCount(fresh, nowISO: AppModel.isoNow()))
        }
    } else {
        await api.upsertBlock(CalBlock(id: newUUID(), taskId: task.id, taskName: task.name, startTime: time,
                                       durationMinutes: task.estimateMin, date: date, kind: .task))
    }
    if let rec = task.recurrence {
        // Only fill dates that DON'T already carry a block for this task.
        let taken = Set(blocks.filter { $0.taskId == task.id }.map(\.date))
        for occ in materializeOccurrences(rec, startDate: LocalDate.parse(date), startTime: time) {
            if occ.date == date || taken.contains(occ.date) { continue }
            await api.upsertBlock(CalBlock(id: newUUID(), taskId: task.id, taskName: task.name, startTime: occ.startTime,
                                           durationMinutes: task.estimateMin, date: occ.date, kind: .task))
        }
    }
    return time
}

/// Read tool: the schedule for a range, as text the model can quote from.
@MainActor
private func renderSchedule(_ api: AssistantAppState, range: String) -> String {
    let today = api.todayIso()
    let from: String
    let to: String   // inclusive from, exclusive to
    switch range {
    case "today": from = today; to = LocalDate.addDays(today, 1)
    case "tomorrow": from = LocalDate.addDays(today, 1); to = LocalDate.addDays(today, 2)
    case "next_week": from = LocalDate.addDays(LocalDate.mondayOf(today), 7); to = LocalDate.addDays(LocalDate.mondayOf(today), 14)
    default: from = LocalDate.mondayOf(today); to = LocalDate.addDays(LocalDate.mondayOf(today), 7)
    }
    let tasks = Dictionary(api.getTasks().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let blocks = api.getBlocks()
        .filter { $0.date >= from && $0.date < to }
        .sorted { ($0.date + $0.startTime) < ($1.date + $1.startTime) }
    var lines: [String] = []
    var d = from
    while d < to {
        let day = WEEKDAY_NAMES_CAP[LocalDate.dayOfWeek(d)]
        let items = blocks.filter { $0.date == d }.map { b -> String in
            let t = b.taskId.flatMap { tasks[$0] }
            let done = (t?.done == true || b.done) ? " (done)" : (b.skipped ? " (skipped)" : "")
            let ext = b.kind == .external ? " [calendar event — not movable here]" : ""
            let name = !b.taskName.isEmpty ? b.taskName : (t?.name ?? "?")
            return "\(b.startTime.isEmpty ? "anytime" : b.startTime) \(name)\(done)\(ext)"
        }
        lines.append("\(day) \(d)\(d == today ? " (TODAY)" : ""): \(items.isEmpty ? "—" : items.joined(separator: "; "))")
        d = LocalDate.addDays(d, 1)
    }
    return "ok:\n" + lines.joined(separator: "\n")
}

// MARK: - the executor

/// Execute one tool call. Returns a short result string the model reads on the
/// next turn ("ok: created task id=… name=…" / "error: …").
@MainActor
func runAssistantTool(name: String, args: ToolArgs, api: AssistantAppState, scratch: TurnScratch) async -> String {
    if let r = await runCoreTool(name: name, args: args, api: api, scratch: scratch) { return r }
    if let r = await runSurfaceTool(name: name, args: args, api: api, scratch: scratch) { return r }
    // Part B ("Unstuck calls you"): request_call / cancel_call / update_call /
    // get_calls / snooze_call live in App/Calls/CallTools.swift — dispatched
    // through THIS executor's state + scratch so a task created this turn
    // resolves; nil for any other name.
    if let r = await runCallTool(name: name, args: args, api: api, scratch: scratch) { return r }
    return unknownToolResult(name)
}

/// Every tool the executor knows (VOICE_TOOLS mirrors the executor 1:1), so
/// an unknown-tool result names the real options — the model picks one next
/// round instead of guessing again (three narrated guesses at a list-reading
/// tool, tester round 2026-09-06). Same wording on web + Android.
@MainActor
func unknownToolResult(_ name: String) -> String {
    let names = VOICE_TOOLS.compactMap { $0["name"] as? String }.sorted()
    return "error: unknown tool \"\(name)\" — available: \(names.joined(separator: ", "))"
}

/// Resolve a task id: scratch map first (the live store lags the optimistic
/// write), then the live store.
@MainActor
func findTask(_ id: String?, api: AssistantAppState, scratch: TurnScratch) -> TaskItem? {
    guard let id else { return nil }
    if let t = scratch.newTasks[id] { return t }
    return api.getTasks().first { $0.id == id }
}

@MainActor
func findList(_ id: String?, api: AssistantAppState, scratch: TurnScratch) -> ItemCollection? {
    guard let id else { return nil }
    if let c = scratch.newLists[id] { return c }
    return api.getCollections().first { $0.id == id }
}

/// The base (pre-2026-09-02) tools: tasks, schedule, lists, profile, sharing.
@MainActor
private func runCoreTool(name: String, args: ToolArgs, api: AssistantAppState, scratch: TurnScratch) async -> String? {
    let now = AppModel.isoNow

    switch name {
    case "create_task":
        guard let nm = args.str("name") else { return "error: name required" }
        let t = TaskItem(id: newUUID(), name: nm, estimateMin: args.int("estimateMin") ?? 25, totalFocused: 0, done: false,
                         tags: args.strList("tags"), lifeArea: args.str("lifeArea"),
                         firstPhysicalAction: args.str("firstPhysicalAction"), later: args.bool("later") ?? false,
                         createdAt: now(), updatedAt: now(), dueAt: args.str("dueAt"))
        await api.upsertTask(t)
        scratch.newTasks[t.id] = t
        return "ok: created task id=\(t.id) name=\"\(t.name)\""

    case "schedule_task":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        guard let date = args.str("date") else { return "error: date required" }
        let startTime = args.str("startTime")
        if let past = rejectPastDate(api, date) { return past }
        // No time given AND the task has never had one: don't guess — ask,
        // suggesting a slot (Ahmad, 2026-09-01: "when confused, prompt").
        let own = api.getBlocks().first { $0.taskId == t.id && !$0.done && !$0.skipped && !$0.startTime.isEmpty }
        if startTime == nil && own == nil {
            return "error: needs a time — \"\(t.name)\" has no time yet and the user gave none. Do NOT pick one: ask ONE short question offering a suggestion (e.g. \"Friday — 9am, or a time you prefer?\"), then schedule when they answer."
        }
        if let pastTime = rejectPastTime(api, date, startTime ?? own?.startTime) { return pastTime }
        let landed = await scheduleTask(api, t, date: date, startTime: startTime)
        return "ok: scheduled \"\(t.name)\" \(date) \(landed)\(startTime == nil ? " (kept its existing time — say so)" : "")"

    case "update_task":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        // Scheduling args used to be SILENTLY dropped while still returning ok
        // (harness audit, 2026-09-01). Refuse loudly instead.
        if args.has("date") || args.has("startTime") || args.has("scheduledDate") || args.has("scheduledTime") {
            return "error: update_task cannot change the schedule — use schedule_task(taskId, date, startTime?) instead"
        }
        var upd = t
        upd.name = args.str("name") ?? t.name
        upd.estimateMin = args.int("estimateMin") ?? t.estimateMin
        upd.lifeArea = args.str("lifeArea") ?? t.lifeArea
        upd.tags = args.strList("tags") ?? t.tags
        upd.firstPhysicalAction = args.str("firstPhysicalAction") ?? t.firstPhysicalAction
        // "make that due Friday" was unreachable (inventory 2026-09-02)
        upd.dueAt = args.isNull("dueAt") ? nil : (args.str("dueAt") ?? t.dueAt)
        upd.updatedAt = now()
        await api.upsertTask(upd)
        scratch.newTasks[upd.id] = upd
        // A new estimate resizes the live block, like the calendar editor does.
        if upd.estimateMin != t.estimateMin, var blk = nextLiveBlock(api, taskId: t.id) {
            blk.durationMinutes = upd.estimateMin
            await api.upsertBlock(blk)
        }
        return "ok: updated \"\(upd.name)\""

    case "set_task_later":
        guard var t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        let wantLater = args.bool("later") ?? true
        // Never ok: for a no-op — the receipt ("Moved to Later") would describe
        // a change that didn't happen (web parity).
        let isLater = t.later ?? false
        if wantLater && isLater { return "error: \"\(t.name)\" is already in Later — nothing changed" }
        if !wantLater && !isLater { return "error: \"\(t.name)\" is not in Later — nothing changed" }
        t.later = wantLater
        t.updatedAt = now()
        await api.upsertTask(t)
        scratch.newTasks[t.id] = t
        return "ok"

    case "set_task_recurrence":
        guard var t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        let kind = args.str("kind")
        // An unrecognized kind used to silently CLEAR the recurrence and report ok.
        if let kind, !["daily", "weekly", "monthly", "none"].contains(kind) {
            return "error: unknown recurrence kind \"\(kind)\" — use daily, weekly, monthly, or none"
        }
        let until = args.str("until")
        let rec: Recurrence?
        switch kind {
        case "daily": rec = .daily(until: until)
        case "weekly": rec = .weekly(daysOfWeek: args.intList("daysOfWeek") ?? [], until: until)
        case "monthly": rec = .monthly(until: until)
        default: rec = nil
        }
        t.recurrence = rec
        t.updatedAt = now()
        await api.upsertTask(t)
        scratch.newTasks[t.id] = t
        // Regenerate future blocks off the existing anchor, if scheduled.
        let blocks = api.getBlocks()
        if let anchor = blocks.first(where: { $0.taskId == t.id }) {
            let plan = regenerateForTask(task: t, recurrence: rec, existingBlocks: blocks, todayIso: api.todayIso(),
                                         startTime: anchor.startTime, startDate: LocalDate.parse(anchor.date))
            for b in plan.toUpsert { await api.upsertBlock(b) }
            for id in plan.toDelete { await api.deleteBlock(id) }
        }
        return "ok"

    case "complete_task":
        guard var t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        // Already done → error, not ok: an "ok: completed" receipt's Undo would
        // REOPEN something the user finished earlier (web parity).
        if t.done { return "error: \"\(t.name)\" is already done — nothing changed" }
        t.done = true
        t.updatedAt = now()
        await api.upsertTask(t)
        scratch.newTasks[t.id] = t
        // id in the result: the receipt's undo must target THIS task.
        return "ok: completed \"\(t.name)\" id=\(t.id)"

    case "create_tasks":
        // Bulk brain-dump — ten spoken tasks must land as ONE call.
        guard let items = args.objList("tasks"), !items.isEmpty else { return "error: tasks required" }
        var made: [(id: String, name: String)] = []
        var needsTime: [String] = []
        for it in items.prefix(25) {
            guard let nm = it.str("name") else { continue }
            let t = TaskItem(id: newUUID(), name: nm, estimateMin: it.int("estimateMin") ?? 25, totalFocused: 0, done: false,
                             lifeArea: it.str("lifeArea"), later: false, createdAt: now(), updatedAt: now())
            await api.upsertTask(t)
            scratch.newTasks[t.id] = t
            let date = it.str("date")
            let startTime = it.str("startTime")
            // Date + time → schedule. Date WITHOUT time → do NOT invent 09:00:
            // create it unscheduled and tell the model to ask ONE question.
            let past = date.flatMap { rejectPastDate(api, $0) ?? rejectPastTime(api, $0, startTime) }
            if let past {
                needsTime.append("\"\(t.name)\" — " + past.replacingOccurrences(of: "error: ", with: "", options: .anchored))
            } else if let date, let startTime {
                _ = await scheduleTask(api, t, date: date, startTime: startTime)
            } else if let date {
                needsTime.append("\"\(t.name)\" (\(date))")
            }
            made.append((t.id, t.name))
        }
        if made.isEmpty { return "error: no valid tasks in the list" }
        let ask = needsTime.isEmpty ? "" :
            " NOTE: \(needsTime.joined(separator: ", ")) \(needsTime.count == 1 ? "has" : "have") a day but no time — left unscheduled. Ask ONE question suggesting a time for them, then schedule_task each."
        return "ok: created \(made.count) tasks ids=\(made.map(\.id).joined(separator: ",")) — \(made.map { "\"\($0.name)\"" }.joined(separator: ", ")).\(ask)"

    case "complete_tasks":
        // Bulk close — "close all my tasks" must be ONE reliable call.
        let ids = args.strList("taskIds") ?? []
        if ids.isEmpty { return "error: taskIds required" }
        // Report only the ids we ACTUALLY flipped — the receipt's undo re-opens exactly these.
        var flipped: [String] = []
        for id in ids {
            if var t = findTask(id, api: api, scratch: scratch), !t.done {
                t.done = true
                t.updatedAt = now()
                await api.upsertTask(t)
                scratch.newTasks[t.id] = t
                flipped.append(t.id)
            }
        }
        if flipped.isEmpty { return "error: no matching open tasks" }
        return "ok: completed \(flipped.count) tasks ids=\(flipped.joined(separator: ","))"

    case "delete_task":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        for b in api.getBlocks() where b.taskId == t.id { await api.deleteBlock(b.id) }
        // Mirror the UI: a deleted task takes its captures with it (else orphans).
        for c in api.getCaptures() where c.taskId == t.id { await api.removeCapture(c.id) }
        await api.removeTask(t.id)
        scratch.newTasks.removeValue(forKey: t.id)
        return "ok: deleted \"\(t.name)\""

    case "create_list":
        guard let nm = args.str("name") else { return "error: name required" }
        let color = args.str("color") ?? "indigo"
        guard let id = api.addCollection(name: nm, color: color) else { return "error: could not create list" }
        scratch.newLists[id] = ItemCollection(id: id, name: nm, color: color, items: [], sortOrder: 0)
        return "ok: created list id=\(id) name=\"\(nm)\""

    case "add_to_list":
        guard let c = findList(args.str("listId"), api: api, scratch: scratch) else { return "error: list not found" }
        if scratch.newLists[c.id] == nil && !api.canEditCollection(c.id) {
            return "error: you only have view access to \"\(c.name)\" — can't add to it"
        }
        guard let body = args.str("body") else { return "error: body required" }
        api.addCollectionItem(collectionId: c.id, body: body)
        return "ok: added to \"\(c.name)\""

    case "promote_item_to_task":
        guard let c = findList(args.str("listId"), api: api, scratch: scratch) else { return "error: list not found" }
        let itemId = args.str("itemId")
        guard let item = c.items.first(where: { $0.id == itemId }) else { return "error: item not found" }
        // The list UI skips an item whose task is already in flight — saying
        // "ok: promoted" over that no-op would be a lie.
        if item.promoted == true && item.promotedDone != true {
            return "error: \"\(item.body)\" is already promoted — its task is still in flight"
        }
        let shared = !(c.members ?? []).isEmpty || c.myRole == "editor" || c.myRole == "viewer"
        let loop = args.str("mode") == "loop" && shared
        api.promoteItemToTask(collectionId: c.id, itemId: item.id, loop: loop, dueAt: loop ? args.str("dueAt") : nil)
        return "ok: promoted \"\(item.body)\""

    case "save_profile_fact":
        guard let fact = args.str("fact") else { return "error: fact required" }
        // The injection filter guards MODEL-written saves — a planted
        // instruction here would live in every future prompt.
        if ProfileFactsLogic.isInstructionLike(fact) {
            return "error: that does not look like a fact I can store — only durable notes about you, not instructions"
        }
        do {
            let stored = try api.saveProfileFact(category: args.str("category"), fact: fact, whenIso: args.str("whenIso"))
            return "ok: remembered id=\(stored.id) [\(stored.category.rawValue)] \"\(stored.fact)\""
        } catch ProfileFactSaveError.empty, ProfileFactSaveError.instructionLike {
            return "error: that does not look like a fact I can store — only durable notes about you, not instructions"
        } catch {
            // A store failure (or no store yet) is NOT "not a fact" — the model
            // should retry, not rephrase.
            return "error: couldn't save that just now — try again"
        }

    case "finish_interview":
        // Voice only (the text interview finishes itself through its chips):
        // the model has been through the get-to-know-you questions —
        // answered or skipped — so the SAME done flag is set, and no host
        // asks them again.
        api.markInterviewDone()
        return "ok: intro done — never ask those questions again"

    case "get_schedule":
        return renderSchedule(api, range: args.str("range") ?? "week")

    case "share_task":
        // NEVER shares here: sharing sends the user's content to another
        // person, so it always waits for an on-screen confirm tap.
        let res = resolveShareRequest(taskId: args.str("taskId"), taskName: args.str("taskName"),
                                      person: args.str("person"), level: args.str("level"),
                                      tasks: api.getTasks(), people: api.getShareCandidates(), newId: { newUUID() })
        if let pending = res.pending { api.stageShare(pending) }
        return res.message

    default:
        return nil
    }
}
