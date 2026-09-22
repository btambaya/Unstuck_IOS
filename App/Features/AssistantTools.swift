// Assistant tool executor — the CLIENT half of the shared assistant contract
// (docs/assistant-tool-contract.md, generated from lib/assistant/tool-registry.json;
// the behavioural half is docs/assistant-tooling-rules.md). The registry owns
// the tool SCHEMAS (ToolRegistry.generated.swift) and the server owns the text
// prompt; this file executes the calls through the same write paths the UI
// uses, returning the contract's result strings (`ok: …` / `error: …`) — the
// model reads them, so every `ok:` must describe a change the store confirmed
// and every partial result must spell out what was NOT done (2026-09-20
// tooling rewrite: "the model says it did something it didn't").
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
    /// The mirror image (audit 2026-09-22, C6): a task that just went open →
    /// done and was promoted from a shared list ticks the collection row for
    /// the other members (collection-task-done `done`) — the hook the UI's
    /// toggleDone and finishFocus fire. Without it a voice completion left
    /// every member seeing the item open or overdue. No-op for any other task.
    func notifyTaskCompletedIfShared(_ t: TaskItem)
    func upsertBlock(_ b: CalBlock) async
    func deleteBlock(_ id: String) async
    // ── lists ──
    // Every list write returns the REAL outcome (2026-09-20 tooling rules §1):
    // `true` only once the local row is committed; a `Void` seam used to let
    // the executor say `ok:` over a write that never landed.
    /// → the new list's id.
    func addCollection(name: String, color: String) -> String?
    /// → the new item's id once committed (nil = not added).
    func addCollectionItem(collectionId: String, body: String) async -> String?
    /// Turn a list item into a task through the SAME path the list UI uses
    /// (task + promotion mark + loop scheduling). `loop` = keep everyone in
    /// the loop. → the new task's id (nil = nothing promoted).
    func promoteItemToTask(collectionId: String, itemId: String, loop: Bool, dueAt: String?) -> String?
    func renameCollection(_ id: String, name: String) async -> Bool
    func updateCollection(_ id: String, archived: Bool?, color: String?) async -> Bool
    func removeCollection(_ id: String) async -> Bool
    /// `pinned` (2026-09-20): the item's pin flag, alongside body / done.
    func updateCollectionItem(collectionId: String, itemId: String, body: String?, done: Bool?, pinned: Bool?) async -> Bool
    func removeCollectionItem(collectionId: String, itemId: String) async -> Bool
    /// Leave a list shared WITH the user (the owner keeps it). True only when
    /// the server confirmed the leave — the local row is dropped only then.
    func leaveCollection(_ id: String) async -> Bool
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
    /// Join-or-mint, AWAITED: true once a session on `taskId` is live.
    func startFocus(taskId: String, estimateMin: Int?, occurrenceBlockId: String?) async -> Bool
    func pauseFocus()
    func resumeFocus()
    /// False when there is no running session to extend.
    func extendFocus(_ minutes: Int) -> Bool
    /// `finish_focus`: end + LOG the running session the way the focus
    /// screen's Done/End does (Session row, totalFocused, optional completion,
    /// Live Activity ended). nil when nothing was running / nothing landed.
    func finishFocus(markDone: Bool) async -> FocusFinishOutcome?
    func cancelFocus()
    // ── reminders ──
    /// `set_task_reminder`: the per-task lead override (nil = back to the
    /// default) + a scheduler resync. False when it could not be saved.
    func setTaskReminder(taskId: String, minutes: Int?) -> Bool
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
    /// `get_settings`: the current values, read fresh.
    func getSettings() -> AssistantSettingsSnapshot
    func setUsableMinutes(weekday: Int?, weekend: Int?) async -> Bool
    func setNotificationLevel(_ level: String) async -> Bool
    func setReminderLead(_ minutes: Int) async -> Bool
    func setRitual(_ ritual: String, on: Bool) -> Bool
    /// "system" | "light" | "dark".
    func setTheme(_ theme: String) -> Bool
    /// Only the non-nil fields change.
    func setFocusDefaults(defaultMinutes: Int?, overrunMinutes: Int?, softExit: Bool?, pauseReasons: Bool?) -> Bool
    /// "off" | "brown" | "pink".
    func setAmbientSound(_ sound: String) -> Bool
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

/// What `finish_focus` landed — enough for the result line.
struct FocusFinishOutcome: Equatable, Sendable {
    let taskId: String
    let taskName: String
    let elapsedSec: Int
    let markedDone: Bool
}

/// The `get_settings` read (2026-09-20). Strings carry the registry's
/// vocabulary (notification level calm/balanced/coach, theme
/// system/light/dark, ambient off/brown/pink); nil budget = never set.
struct AssistantSettingsSnapshot: Equatable, Sendable {
    var notificationLevel: String
    var reminderLeadMin: Int
    var usableWeekdayMin: Int?
    var usableWeekendMin: Int?
    var focusDefaultMin: Int
    var focusOverrunMin: Int
    var focusSoftExit: Bool
    var focusPauseReasons: Bool
    var theme: String
    var ambient: String
    /// morning / evening / friday / sunday → on.
    var rituals: [String: Bool]
}

/// Tools that never change anything — a success here must NOT count as "the
/// assistant acted" for either fabrication guard (text or voice). From the
/// registry (`kind: read`), never hand-maintained (2026-09-20).
let READ_ONLY_TOOLS: Set<String> = ToolRegistry.readOnly
/// Tools that only NAVIGATE — no data changes, no staged card. Neither a
/// write (they must not disarm the fabrication guard) nor "nothing changed"
/// (the harness's empty-reply fallback says what was opened instead).
let NAVIGATION_TOOLS: Set<String> = ToolRegistry.navigation
/// Tools that STAGE something for the user to confirm on screen (share_task,
/// share_list) — a write for the guard, a card (not a receipt) for the panel.
let STAGED_TOOLS: Set<String> = ToolRegistry.staged

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

/// Complete a task the way the UI's toggleDone does (audit 2026-09-22, C6):
/// completedAt stamped, the shared-list `done` sent. The assistant used to set
/// only done/updatedAt, and nothing downstream stamps completed_at (no server
/// trigger) — so Today's done-today wins, the evening call's "done today"
/// line, get_tasks view=completed's newest-first order and insights all
/// missed every voice completion. Only the done + completedAt delta is applied
/// to the COMMITTED row: a block write in between (saveBlockAwaiting's
/// un-park) must not be reverted by the caller's earlier copy, and a row that
/// is already done is returned as-is — no write, no second shared notice.
@MainActor
func markTaskDone(_ t: TaskItem, api: AssistantAppState, scratch: TurnScratch) async -> TaskItem {
    let prior = api.getTasks().first { $0.id == t.id } ?? t
    if prior.done { return prior }
    var flipped = prior
    flipped.done = true
    let stamped = applyCompletion(flipped, prior: prior, nowISO: AppModel.isoNow())
    await api.upsertTask(stamped)
    api.notifyTaskCompletedIfShared(stamped)
    scratch.newTasks[stamped.id] = stamped
    return stamped
}

/// Tick one day's occurrence block the way the UI's setOccurrenceDone does
/// (audit 2026-09-22, C6): un-skipped and completion-stamped, so the day
/// counts as a done-today win through projectOccurrences.
@MainActor
func markOccurrenceDone(_ b: CalBlock, api: AssistantAppState) async {
    var next = b
    next.done = true
    next.skipped = false
    next.completedAt = AppModel.isoNow()
    await api.upsertBlock(next)
}

/// What `completeSeriesToday` did with a repeating task's day.
enum SeriesDayResult { case ticked, nothingToday, alreadyDone }

/// "I did X" for a repeating series ticks TODAY's occurrence — never the
/// series (audit 2026-09-22, C3). The model only ever sees a series by its
/// TEMPLATE id (the context, get_tasks, find_tasks), and complete_task /
/// complete_tasks set the template's done, which ENDS the series: every
/// reminder stopped, the horizon top-up and the server's calls skip a done
/// task, and today's row stayed open. The earliest open occurrence today is
/// ticked the way the UI ticks one; the template is never written.
@MainActor
func completeSeriesToday(_ t: TaskItem, api: AssistantAppState) async -> SeriesDayResult {
    let today = api.todayIso()
    let day = api.getBlocks().filter { $0.taskId == t.id && $0.date == today && !$0.skipped }
    if day.isEmpty { return .nothingToday }
    guard let open = day.filter({ !$0.done }).min(by: { $0.startTime < $1.startTime }) else { return .alreadyDone }
    await markOccurrenceDone(open, api: api)
    return .ticked
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

/// Every tool the executor knows (the registry — a parity test proves each
/// name has an executor case), so an unknown-tool result names the real
/// options — the model picks one next round instead of guessing again (three
/// narrated guesses at a list-reading tool, tester round 2026-09-06). Same
/// wording on web + Android (tooling rules §1).
@MainActor
func unknownToolResult(_ name: String) -> String {
    "error: unknown tool \"\(name)\". The tools are: \(ToolRegistry.names.joined(separator: ", "))"
}

/// After a successful list write, drop the turn's stale scratch copy in
/// favour of the committed row — `findList` prefers scratch, so a rename or
/// an added item on a list created THIS turn was invisible to the next tool.
@MainActor
func refreshScratchList(_ id: String, api: AssistantAppState, scratch: TurnScratch) {
    guard scratch.newLists[id] != nil, let fresh = api.getCollections().first(where: { $0.id == id }) else { return }
    scratch.newLists[id] = fresh
}

/// The registry's list-colour vocabulary (create_list / recolor_list).
let LIST_COLORS = ["indigo", "coral", "green", "amber", "blue", "violet"]

/// A recurrence's day list, spelled ("Mon, Wed") for a result line.
func weekdayNames(_ days: [Int]) -> String {
    days.sorted().map { WEEKDAY_NAMES_CAP[max(0, min(6, $0))].prefix(3) }.map(String.init).joined(separator: ", ")
}

/// Resolve a task id: the committed store first, the turn's scratch copy only
/// for a row the store doesn't have.
///
/// Store writes are awaited, so the committed row is always at least as fresh
/// as the scratch copy — and scratch went STALE behind writes that don't
/// refresh it (saveBlockAwaiting's un-park, scheduleTask's move-count bump,
/// finish_focus). Every write tool upserts the whole row it gets back, so a
/// rename after "finish it" reopened the finished task and wiped its focus
/// time (audit 2026-09-22, C5).
@MainActor
func findTask(_ id: String?, api: AssistantAppState, scratch: TurnScratch) -> TaskItem? {
    guard let id else { return nil }
    if let t = api.getTasks().first(where: { $0.id == id }) { return t }
    return scratch.newTasks[id]
}

@MainActor
func findList(_ id: String?, api: AssistantAppState, scratch: TurnScratch) -> ItemCollection? {
    guard let id else { return nil }
    if let c = scratch.newLists[id] { return c }
    return api.getCollections().first { $0.id == id }
}

/// The base (pre-2026-09-02) tools: tasks, schedule, lists, profile, sharing —
/// plus the 2026-09-20 read `find_tasks`.
@MainActor
private func runCoreTool(name: String, args: ToolArgs, api: AssistantAppState, scratch: TurnScratch) async -> String? {
    let now = AppModel.isoNow

    switch name {
    case "create_task":
        guard let nm = args.str("name") else { return "error: name required" }
        let date = args.str("date")
        let startTime = args.str("startTime")
        // A past day is refused BEFORE anything is created — an error means
        // nothing happened (rules §1), so the model asks for another day.
        if let date, let past = rejectPastDate(api, date) ?? rejectPastTime(api, date, startTime) {
            return past + " The task was NOT created — give another day, or omit the date."
        }
        // A task by this exact name that the user (or the model) made minutes
        // ago is almost certainly the same one, not a second one. One tester
        // ended up with FOUR identical "Office" tasks: the model could not see
        // the task it had just created (the context carries the 60 OLDEST open
        // tasks, and a task with a day but no time appears in neither list),
        // so a nudge to "call the right tool now" made it create another
        // (audit 2026-09-21). Point the model at the existing one instead.
        if let dupe = recentDuplicateTask(named: nm, api: api, scratch: scratch, now: Date()) {
            return "error: \"\(dupe.name)\" already exists (id=\(dupe.id), created just now) — use schedule_task or update_task on it rather than making another. Only create a second one if the user asks for a separate task."
        }
        let t = TaskItem(id: newUUID(), name: nm, estimateMin: clampEstimateMin(args.int("estimateMin")), totalFocused: 0, done: false,
                         tags: args.strList("tags"), lifeArea: args.str("lifeArea"),
                         firstPhysicalAction: args.str("firstPhysicalAction"), later: args.bool("later") ?? false,
                         createdAt: now(), updatedAt: now(), dueAt: args.str("dueAt"))
        await api.upsertTask(t)
        scratch.newTasks[t.id] = t
        // date + startTime → on the calendar in the same call (registry). A
        // day WITHOUT a time is NOT guessed at: created unscheduled and said so.
        var extras: [String] = []
        var note = ""
        if let date, let startTime {
            let landed = await scheduleTask(api, t, date: date, startTime: startTime)
            extras.append("scheduled \(date) \(landed)")
        } else if let date {
            note = " NOTE: it has a day (\(date)) but no time — left unscheduled. Ask ONE question suggesting a time, then schedule_task."
        }
        // From the COMMITTED row: scheduling un-parks a Later task in
        // saveBlockAwaiting, so the pre-schedule copy said "in Later" over a
        // task that no longer was (audit 2026-09-22, C5).
        let committed = api.getTasks().first { $0.id == t.id } ?? t
        if committed.later == true { extras.append("in Later") }
        if let due = t.dueAt { extras.append("due \(due)") }
        return "ok: created task id=\(t.id) name=\"\(t.name)\"\(extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))")\(note)"

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
        var changed: [String] = []
        if let nm = args.str("name"), nm != t.name { upd.name = nm; changed.append("name") }
        if let est = args.int("estimateMin"), est != t.estimateMin { upd.estimateMin = est; changed.append("estimate") }
        // "none" clears an area / a first step / a deadline (registry wording);
        // a JSON null on dueAt still clears it (older callers).
        if let la = args.str("lifeArea") {
            let next: String? = la.lowercased() == "none" ? nil : la
            if next != t.lifeArea { upd.lifeArea = next; changed.append("area") }
        }
        if let tags = args.strList("tags"), tags != (t.tags ?? []) { upd.tags = tags; changed.append("tags") }
        if let fpa = args.str("firstPhysicalAction") {
            let next: String? = fpa.lowercased() == "none" ? nil : fpa
            if next != t.firstPhysicalAction { upd.firstPhysicalAction = next; changed.append("first step") }
        }
        if args.isNull("dueAt") {
            if t.dueAt != nil { upd.dueAt = nil; changed.append("deadline") }
        } else if let due = args.str("dueAt") {
            let next: String? = due.lowercased() == "none" ? nil : due
            if next != t.dueAt { upd.dueAt = next; changed.append("deadline") }
        }
        if let later = args.bool("later"), later != (t.later ?? false) { upd.later = later; changed.append(later ? "parked in Later" : "back from Later") }
        // A no-op is an error, never an "Updated" receipt over nothing.
        if changed.isEmpty { return "error: nothing to change on \"\(t.name)\" — every field given already has that value (or none was given)" }
        upd.updatedAt = now()
        await api.upsertTask(upd)
        scratch.newTasks[upd.id] = upd
        // A new estimate resizes the live block, like the calendar editor does.
        if upd.estimateMin != t.estimateMin, var blk = nextLiveBlock(api, taskId: t.id) {
            blk.durationMinutes = upd.estimateMin
            await api.upsertBlock(blk)
        }
        return "ok: updated \"\(upd.name)\" (\(changed.joined(separator: ", ")))"

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
        // Names the task (rules §1) — a bare "ok" told the model nothing.
        return wantLater ? "ok: moved \"\(t.name)\" to Later" : "ok: brought \"\(t.name)\" back from Later"

    case "set_task_recurrence":
        guard var t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        let kind = args.str("kind")
        // An unrecognized kind used to silently CLEAR the recurrence and report ok.
        if let kind, !["daily", "weekly", "monthly", "none"].contains(kind) {
            return "error: unknown recurrence kind \"\(kind)\" — use daily, weekly, monthly, or none"
        }
        let until = args.str("until")
        let days = (args.intList("daysOfWeek") ?? []).filter { (0...6).contains($0) }
        // Weekly with no days used to save an EMPTY weekly series (never
        // materialised a single day) and report ok — refuse and ask instead.
        if kind == "weekly" && days.isEmpty { return "error: weekly needs daysOfWeek (0=Sunday … 6=Saturday) — ask which days" }
        if kind == nil || kind == "none", t.recurrence == nil { return "error: \"\(t.name)\" doesn't repeat — nothing changed" }
        let rec: Recurrence?
        switch kind {
        case "daily": rec = .daily(until: until)
        case "weekly": rec = .weekly(daysOfWeek: days, until: until)
        case "monthly": rec = .monthly(until: until)
        default: rec = nil
        }
        // The editor's rule (audit 2026-09-22, C3): "stop repeating" carries a
        // ticked today onto the task, and a repeat turned on never leaves a
        // DONE template (an ended series).
        let before = t
        t = taskAfterSettingRecurrence(t, recurrence: rec, blocks: api.getBlocks(), todayIso: api.todayIso(), nowISO: now())
        t.updatedAt = now()
        await api.upsertTask(t)
        scratch.newTasks[t.id] = t
        // Regenerate future blocks off the existing anchor, if scheduled.
        let blocks = api.getBlocks()
        // The earliest LIVE block, never an arbitrary one — see recurrenceAnchor.
        if let anchor = recurrenceAnchor(taskId: t.id, blocks: blocks, todayIso: api.todayIso()) {
            let plan = regenerateForTask(task: t, recurrence: rec, existingBlocks: blocks, todayIso: api.todayIso(),
                                         startTime: anchor.startTime, startDate: LocalDate.parse(anchor.date))
            for b in plan.toUpsert { await api.upsertBlock(b) }
            for id in plan.toDelete { await api.deleteBlock(id) }
        }
        // A done task made to repeat keeps the day it was done ticked, and the
        // done flip reaches a loop-promoted task's shared-list row — as in the
        // editor (AppModel.setRecurrence).
        for b in occurrencesCarryingTaskDone(before, recurrence: rec, blocks: blocks, todayIso: api.todayIso(), nowISO: now()) {
            await api.upsertBlock(b)
        }
        if before.done != t.done {
            if t.done { api.notifyTaskCompletedIfShared(t) } else { api.notifyTaskReopenedIfShared(t) }
        }
        let todays = api.getBlocks().filter { $0.taskId == t.id && isTaskBlock($0) && $0.date == api.todayIso() && !$0.skipped }
        let todayDone = !todays.isEmpty && todays.allSatisfy(\.done)
        let doneNote: String
        if !before.done && t.done {
            doneNote = " — today's occurrence was already done, so the task is now marked done"
        } else if before.done && !t.done {
            // Never "open again" over a day that stays ticked: the user would
            // be told to do today's again.
            doneNote = todayDone ? " (it was done — today's occurrence stays done)" : " (it was done — now open again)"
        } else {
            doneNote = ""
        }
        let anchored = blocks.contains { $0.taskId == t.id }
        guard let kind, kind != "none" else { return "ok: \"\(t.name)\" no longer repeats\(anchored ? " (future occurrences removed)" : "")\(doneNote)" }
        let how = kind == "weekly" ? "weekly on \(weekdayNames(days))" : kind
        let till = until.map { " until \($0)" } ?? ""
        return "ok: \"\(t.name)\" now repeats \(how)\(till)\(doneNote)\(anchored ? "" : " — it has no calendar slot yet; schedule_task it to place the first one")"

    case "complete_task":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        // A repeating series: today's occurrence, never the series (C3). The
        // result is complete_occurrence's line, whose receipt has no Undo —
        // a name-matched Undo could reopen some other task of that name.
        if t.recurrence != nil {
            let day = api.todayIso()
            switch await completeSeriesToday(t, api: api) {
            case .ticked:
                return "ok: marked \"\(t.name)\" done for \(day) (series continues)"
            case .alreadyDone:
                return "error: \"\(t.name)\" is already done on \(day) — nothing changed"
            case .nothingToday:
                return "error: \"\(t.name)\" repeats and has nothing on \(day) — nothing changed. complete_task only ticks TODAY's occurrence of a repeating task and never ends the series; use complete_occurrence with the day, or set_task_recurrence kind none to stop it repeating"
            }
        }
        // Already done → error, not ok: an "ok: completed" receipt's Undo would
        // REOPEN something the user finished earlier (web parity).
        if t.done { return "error: \"\(t.name)\" is already done — nothing changed" }
        // Stamped + shared-list notice, like the UI's tick (audit 2026-09-22, C6).
        _ = await markTaskDone(t, api: api, scratch: scratch)
        // id in the result: the receipt's undo must target THIS task.
        return "ok: completed \"\(t.name)\" id=\(t.id)"

    case "create_tasks":
        // Bulk brain-dump — ten spoken tasks must land as ONE call. Cap 50
        // (was 25); whatever is NOT created is named in the result (rules §1).
        guard let items = args.objList("tasks"), !items.isEmpty else { return "error: tasks required" }
        let cap = 50
        var made: [(id: String, name: String)] = []
        var needsTime: [String] = []
        var notCreated: [String] = []
        for (i, it) in items.enumerated() {
            guard let nm = it.str("name") else { notCreated.append("item \(i + 1) (no name)"); continue }
            if made.count >= cap { notCreated.append("\"\(nm)\" (over the \(cap) limit — call create_tasks again for the rest)"); continue }
            let t = TaskItem(id: newUUID(), name: nm, estimateMin: it.int("estimateMin") ?? 25, totalFocused: 0, done: false,
                             tags: it.strList("tags"), lifeArea: it.str("lifeArea"),
                             firstPhysicalAction: it.str("firstPhysicalAction"), later: it.bool("later") ?? false,
                             createdAt: now(), updatedAt: now(), dueAt: it.str("dueAt"))
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
        if made.isEmpty { return "error: no tasks created — \(notCreated.isEmpty ? "no valid tasks in the list" : notCreated.joined(separator: ", "))" }
        let ask = needsTime.isEmpty ? "" :
            " NOTE: \(needsTime.joined(separator: ", ")) \(needsTime.count == 1 ? "has" : "have") a day but no time — left unscheduled. Ask ONE question suggesting a time for them, then schedule_task each."
        let missed = notCreated.isEmpty ? "" : " Not created: \(notCreated.joined(separator: ", ")) — say so."
        return "ok: created \(made.count) tasks ids=\(made.map(\.id).joined(separator: ",")) — \(made.map { "\"\($0.name)\"" }.joined(separator: ", ")).\(missed)\(ask)"

    case "complete_tasks":
        // Bulk close — "close all my tasks" must be ONE reliable call.
        let ids = args.strList("taskIds") ?? []
        if ids.isEmpty { return "error: taskIds required" }
        // Report only the ids we ACTUALLY flipped — the receipt's undo re-opens
        // exactly these — and name every id that was NOT (already done / not
        // found), so the model repeats it instead of saying "all done".
        var flipped: [TaskItem] = []
        // Repeating series whose TODAY was ticked (C3) — named, but kept out
        // of ids=, so the receipt's Undo reopens only plain tasks and never
        // targets a series.
        var ticked: [String] = []
        var notDone: [String] = []
        for id in ids {
            guard let t = findTask(id, api: api, scratch: scratch) else { notDone.append("\(id) (not found)"); continue }
            if t.recurrence != nil {
                switch await completeSeriesToday(t, api: api) {
                case .ticked: ticked.append(t.name)
                case .alreadyDone: notDone.append("\"\(t.name)\" (already done today)")
                case .nothingToday: notDone.append("\"\(t.name)\" (repeats — nothing today)")
                }
                continue
            }
            if t.done { notDone.append("\"\(t.name)\" (already done)"); continue }
            // Stamped + shared-list notice (audit 2026-09-22, C6). The store
            // is re-read per id, so a repeated id is "already done" the second
            // time and never sends a second notice.
            flipped.append(await markTaskDone(t, api: api, scratch: scratch))
        }
        if flipped.isEmpty && ticked.isEmpty { return "error: none completed — \(notDone.joined(separator: ", "))" }
        let skipped = notDone.isEmpty ? "" : ". Not done: \(notDone.joined(separator: ", "))"
        let names = flipped.map { "\"\($0.name)\"" } + ticked.map { "\"\($0)\" (today — series continues)" }
        return "ok: completed \(flipped.count + ticked.count) tasks ids=\(flipped.map(\.id).joined(separator: ",")) — \(names.joined(separator: ", "))\(skipped)"

    case "delete_task":
        guard let t = findTask(args.str("taskId"), api: api, scratch: scratch) else { return "error: task not found" }
        for b in api.getBlocks() where b.taskId == t.id { await api.deleteBlock(b.id) }
        // Mirror the UI: a deleted task takes its captures with it (else orphans).
        for c in api.getCaptures() where c.taskId == t.id { await api.removeCapture(c.id) }
        await api.removeTask(t.id)
        scratch.newTasks.removeValue(forKey: t.id)
        return "ok: deleted \"\(t.name)\""

    case "find_tasks":
        // READ (2026-09-20): fuzzy title search — every word of the query must
        // appear in the title (partial words match). The model calls this
        // when it has a name but no id; "several match" is reported HERE so
        // it asks which, never picks.
        guard let q = args.str("query") else { return "error: query required" }
        let words = q.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init).filter { !$0.isEmpty }
        if words.isEmpty { return "error: query required" }
        let includeDone = args.bool("includeDone") ?? false
        let tasks = api.getTasks()
        // A task created THIS turn may not have echoed through the store yet.
        var pool = tasks
        for t in scratch.newTasks.values where !pool.contains(where: { $0.id == t.id }) { pool.append(t) }
        let hits = pool.filter { t in (includeDone || !t.done) && words.allSatisfy { t.name.lowercased().contains($0) } }
        if hits.isEmpty {
            return "ok: no task matches \"\(q)\"\(includeDone ? "" : " (completed tasks not searched — includeDone=true to include them)") — tell the user, and offer to create it"
        }
        let lines = hits.prefix(15).map { t -> String in
            var line = "- \(t.name) [id=\(t.id)] \(t.estimateMin)m"
            if let area = t.lifeArea, !area.isEmpty { line += " · \(area)" }
            if let b = nextLiveBlock(api, taskId: t.id) { line += " · \(b.date) \(b.startTime)" }
            if t.recurrence != nil { line += " · repeats" }
            if t.later == true { line += " · Later" }
            if t.done { line += " · done" }
            return line
        }
        let head = hits.count == 1
            ? "ok: 1 task matches \"\(q)\":"
            : "ok: \(hits.count) tasks match \"\(q)\" — several match: ask which one, never pick:"
        return head + "\n" + lines.joined(separator: "\n") + (hits.count > 15 ? "\n… and \(hits.count - 15) more — narrow the query" : "")

    case "create_list":
        guard let nm = args.str("name") else { return "error: name required" }
        let color = (args.str("color") ?? "indigo").lowercased()
        if !LIST_COLORS.contains(color) { return "error: unknown colour \"\(color)\" — use \(LIST_COLORS.joined(separator: ", "))" }
        guard let id = api.addCollection(name: nm, color: color) else { return "error: could not create list" }
        scratch.newLists[id] = ItemCollection(id: id, name: nm, color: color, items: [], sortOrder: 0)
        return "ok: created list id=\(id) name=\"\(nm)\""

    case "add_to_list":
        guard let c = findList(args.str("listId"), api: api, scratch: scratch) else { return "error: list not found" }
        if scratch.newLists[c.id] == nil && !api.canEditCollection(c.id) {
            return "error: you only have view access to \"\(c.name)\" — can't add to it"
        }
        guard let body = args.str("body") else { return "error: body required" }
        guard let itemId = await api.addCollectionItem(collectionId: c.id, body: body) else { return "error: couldn't add to \"\(c.name)\" — try again" }
        refreshScratchList(c.id, api: api, scratch: scratch)
        return "ok: added to \"\(c.name)\" item id=\(itemId)"

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
        let wantLoop = args.str("mode") == "loop"
        let loop = wantLoop && shared
        let dueAt = loop ? args.str("dueAt") : nil
        guard let taskId = api.promoteItemToTask(collectionId: c.id, itemId: item.id, loop: loop, dueAt: dueAt) else {
            return "error: couldn't promote \"\(item.body)\" — try again"
        }
        refreshScratchList(c.id, api: api, scratch: scratch)
        if let made = api.getTasks().first(where: { $0.id == taskId }) { scratch.newTasks[made.id] = made }
        // The registry promises "the result says which of the two happened":
        // a loop request on an unshared list is downgraded to self — SAID here.
        if loop { return "ok: promoted \"\(item.body)\" to task id=\(taskId) — the list's members can see the user took it\(dueAt.map { " by \($0)" } ?? "")" }
        if wantLoop { return "ok: promoted \"\(item.body)\" to task id=\(taskId) as the user's own task — the list isn't shared, so loop mode became self (say so)" }
        return "ok: promoted \"\(item.body)\" to task id=\(taskId)"

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

    case "share_list":
        // STAGED exactly like share_task (2026-09-20): resolve the person,
        // stage the card, never share. Owner-only, like the Share screen.
        guard let c = findList(args.str("listId"), api: api, scratch: scratch) else { return "error: list not found — ask which list they mean" }
        if scratch.newLists[c.id] == nil && !api.ownsCollection(c.id) {
            return "error: \"\(c.name)\" is shared with you by its owner — only they can share it"
        }
        let res = resolveListShareRequest(listId: c.id, listName: c.name, person: args.str("person"), role: args.str("role"),
                                          people: api.getShareCandidates(), newId: { newUUID() })
        if let pending = res.pending { api.stageShare(pending) }
        return res.message

    default:
        return nil
    }
}

/// The server CHECK is `estimate_min between 1 and 1440` (migration 001). An
/// out-of-range value is accepted locally, rejected by PostgREST on flush,
/// retried five times and then quarantined — the row lives on that one phone
/// for ever and the user is never told (audit 2026-09-21). Clamp instead.
func clampEstimateMin(_ raw: Int?) -> Int { min(1440, max(1, raw ?? 25)) }

/// `duration_minutes between 5 and 1440` (migration 001), so a 2-minute task
/// would otherwise mint a block the server refuses.
func clampDurationMin(_ raw: Int?, fallback: Int = 25) -> Int { min(1440, max(5, raw ?? fallback)) }

/// A task with this exact name (case- and space-insensitive), still open, made
/// within the last few minutes — including one created earlier in THIS turn.
@MainActor
func recentDuplicateTask(named name: String, api: AssistantAppState, scratch: TurnScratch,
                         now: Date, within: TimeInterval = 600) -> TaskItem? {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !key.isEmpty else { return nil }
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
    // The committed rows first, scratch only for what the store lacks: a
    // stale scratch copy (done=false after finish_focus completed it, or a
    // completion from the web) blocked a new task as a "duplicate" of a
    // finished one (audit 2026-09-22, C5).
    let store = api.getTasks()
    let stored = Set(store.map(\.id))
    let candidates = store + scratch.newTasks.values.filter { !stored.contains($0.id) }
    return candidates.first { t in
        guard !t.done, t.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key else { return false }
        guard let made = iso.date(from: t.createdAt) ?? plain.date(from: t.createdAt) else { return false }
        return now.timeIntervalSince(made) <= within && now.timeIntervalSince(made) >= -within
    }
}
