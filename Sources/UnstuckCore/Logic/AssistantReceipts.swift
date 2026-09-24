// Action receipts — deterministic ✓-cards for what the agent ACTUALLY did.
// Derived client-side from each successful tool call (name + args + the
// executor's structured "ok: …" result), never from model prose — so a
// receipt can't claim something that didn't happen. Undo (where offered) is
// PLANNED here and applied by the app layer's write methods at tap time.
//
// Port of lib/assistant/receipts.ts. The web hands the executor an `api` and
// mutates through it; Swift keeps this layer pure (UnstuckCore has no store),
// so `planReceiptUndo` returns the mutation for AssistantModel to apply.

import Foundation

/// What an Undo would do. Codable so it round-trips with the persisted thread.
/// Cases mirror the web's `ReceiptUndo.kind` one for one.
public enum ReceiptUndo: Codable, Equatable, Sendable {
    case deleteTask(id: String)
    case uncompleteTask(id: String)
    case uncompleteTasks(ids: [String])
    case deleteTasks(ids: [String])
    case forgetFact(id: String)
    case deleteCapture(id: String)
    case completeTask(id: String)
    /// Part B ("Unstuck calls you"): undo of `request_call`.
    case cancelCall(id: String)

    /// The task ids this undo touches (empty for a fact / capture / call undo).
    public var taskIds: [String] {
        switch self {
        case .deleteTask(let id), .uncompleteTask(let id), .completeTask(let id): return [id]
        case .uncompleteTasks(let ids), .deleteTasks(let ids): return ids
        case .forgetFact, .deleteCapture, .cancelCall: return []
        }
    }

    /// First task id (kept for the pre-2026-09 call sites); nil for non-task undos.
    public var taskId: String? { taskIds.first }
}

/// Small glyph for the card. Raw values are the web's icon names, so the two
/// platforms stay describable in one vocabulary.
public enum ReceiptIcon: String, Codable, Equatable, Sendable {
    case plus, calendar, check, pencil, trash, list
}

public struct Receipt: Codable, Equatable, Sendable {
    public var icon: ReceiptIcon
    public var label: String
    public var undo: ReceiptUndo?
    /// Set once Undo has been used (persisted so the button doesn't return).
    public var undone: Bool?

    public init(icon: ReceiptIcon, label: String, undo: ReceiptUndo? = nil, undone: Bool? = nil) {
        self.icon = icon
        self.label = label
        self.undo = undo
        self.undone = undone
    }

    /// True while this receipt still offers a working Undo.
    public var isUndoable: Bool { undo != nil && !(undone ?? false) }
}

/// The subset of a tool call's arguments a receipt reads. The app layer builds
/// this from its `[String: AnyJSON]` args, keeping the Supabase SDK out of
/// UnstuckCore (and the derivation trivially testable).
public struct ReceiptArgs: Equatable, Sendable {
    public var taskId: String?
    public var date: String?
    public var startTime: String?
    public var later: Bool?
    public var kind: String?

    public init(taskId: String? = nil, date: String? = nil, startTime: String? = nil,
                later: Bool? = nil, kind: String? = nil) {
        self.taskId = taskId
        self.date = date
        self.startTime = startTime
        self.later = later
        self.kind = kind
    }
}

/// The OUTERMOST `"…"` span in a result string — how the executor names the
/// entity. The name-bearing results each carry exactly ONE quoted segment, so
/// spanning the outermost quotes keeps names that contain their own quote
/// chars intact (web `quoted`, audit 2026-08-29).
func quotedFragment(_ s: String) -> String? {
    guard let open = s.firstIndex(of: "\""), let close = s.lastIndex(of: "\""), open < close else { return nil }
    return String(s[s.index(after: open)..<close])
}

/// The `id=…` token in a result string (up to the next whitespace).
private func idFragment(_ s: String) -> String? {
    guard let r = s.range(of: "id=") else { return nil }
    let rest = s[r.upperBound...].prefix { !$0.isWhitespace }
    return rest.isEmpty ? nil : String(rest)
}

/// The `ids=a,b,c` token in a bulk result, split and emptied of blanks.
private func idsFragment(_ s: String) -> [String] {
    guard let r = s.range(of: "ids=") else { return [] }
    let rest = s[r.upperBound...].prefix { !$0.isWhitespace }
    return rest.split(separator: ",").map(String.init).filter { !$0.isEmpty }
}

/// The integer right after `"<word> "` in a result ("created 3 tasks" → "3"), as the web's `/created (\d+)/`.
private func countAfter(_ word: String, in s: String) -> String {
    guard let r = s.range(of: word + " ") else { return "?" }
    let digits = s[r.upperBound...].prefix { $0.isNumber }
    return digits.isEmpty ? "?" : String(digits)
}

/// `result` minus its leading "ok: ".
private func stripOk(_ s: String) -> String {
    s.hasPrefix("ok: ") ? String(s.dropFirst(4)) : s
}

/// `result` minus a trailing " (…)" parenthetical — the web's `/\s*\(.*\)$/`
/// (greedy: from the FIRST "(" when the string ends in ")").
private func stripTrailingParenthetical(_ s: String) -> String {
    guard s.hasSuffix(")"), let open = s.firstIndex(of: "(") else { return s }
    var head = String(s[..<open])
    while let last = head.last, last.isWhitespace { head.removeLast() }
    return head
}

/// `result` minus everything from the first " — " (the web's `/ — .*$/`).
private func stripAfterDash(_ s: String) -> String {
    guard let r = s.range(of: " — ") else { return s }
    return String(s[..<r.lowerBound])
}

/// The tail of an `ok:` line whose wish was ALREADY true, so nothing was
/// written: stopping a repeat on a task that doesn't repeat, scheduling a task
/// into the very slot it already has (AssistantTools, 2026-09-24; web
/// receipts.ts `NOTHING_TO_CHANGE`). A success for the model to say plainly —
/// and no receipt, which would claim a change.
public let NOTHING_TO_CHANGE = " — nothing to change"

/// Build the receipt for one SUCCESSFUL tool call (result starts "ok").
/// `tasks` resolves live entities for undo targets; `tone` (from
/// `toneFromFacts`) phrases the quiet-win line; `clock` is the user's
/// 12/24-hour clock for the times a card shows (the tool's HH:MM is machine
/// format — the card is what the user reads). Returns nil for read-only
/// tools and unrecognized results — no receipt beats a wrong receipt.
public func deriveReceipt(
    name: String,
    args: ReceiptArgs,
    result: String,
    tasks: [TaskItem],
    tone: Tone = .gentle,
    clock: ClockFormat = .device
) -> Receipt? {
    guard result.hasPrefix("ok") else { return nil }
    if result.hasSuffix(NOTHING_TO_CHANGE) { return nil }
    switch name {
    case "create_task":
        let nm = quotedFragment(result) ?? "task"
        let id = idFragment(result)
        return Receipt(icon: .plus, label: "Created “\(nm)”",
                       undo: id.map { .deleteTask(id: $0) })

    case "schedule_task":
        let nm = quotedFragment(result) ?? "task"
        let date = args.date ?? ""
        let time = args.startTime ?? ""
        return Receipt(icon: .calendar,
                       label: "Scheduled “\(nm)”"
                           + (date.isEmpty ? "" : " · \(date)")
                           + (time.isEmpty ? "" : " \(clock.time(time))"))

    case "update_task":
        return Receipt(icon: .pencil, label: "Updated “\(quotedFragment(result) ?? "task")”")

    case "set_task_later":
        // The 2026-09-20 result names the task ("ok: moved "X" to Later") —
        // prefer that; the store lookup keeps legacy persisted results working.
        let nm = quotedFragment(result) ?? args.taskId.flatMap { id in tasks.first { $0.id == id }?.name }
        // Web: `args.later !== false` — anything but an explicit false is "to Later".
        let toLater = args.later != false
        let verb = toLater ? "Moved to Later" : "Brought back from Later"
        return Receipt(icon: .pencil, label: verb + (nm.map { " — “\($0)”" } ?? ""))

    case "set_task_recurrence":
        let nm = args.taskId.flatMap { id in tasks.first { $0.id == id }?.name }
        let suffix = nm.map { " — “\($0)”" } ?? ""
        // kind "none" is the stop: it read "Repeats none" on the card.
        if let kind = args.kind, kind != "none" {
            // The rhythm from the RESULT, not the args: an omitted
            // intervalWeeks keeps a series' every N weeks (every-n-weeks spec
            // §7.3), and "every week now; it was every 2 weeks" names the old one.
            if let n = repeatsEveryNWeeks(result) { return Receipt(icon: .calendar, label: "Repeats every \(n) weeks\(suffix)") }
            return Receipt(icon: .calendar, label: "Repeats \(kind)\(suffix)")
        }
        return Receipt(icon: .calendar, label: "Repeat removed\(suffix)")

    case "complete_task":
        let nm = quotedFragment(result) ?? "task"
        // A repeating task: complete_task ticked TODAY's occurrence (audit
        // 2026-09-22, C3) — complete_occurrence's card, with no Undo. The
        // name fallback below could otherwise attach an Undo that reopens an
        // unrelated done task of the same name.
        if result.contains("(series continues)") { return Receipt(icon: .check, label: "Done for today: \(nm)") }
        // Prefer the executor's id — resolving by NAME un-completed the wrong
        // duplicate (flow review, 2026-08-30). Name fallback keeps legacy
        // persisted results working.
        let id = idFragment(result)
        let t = id.flatMap { id in tasks.first { $0.id == id } }
            ?? tasks.first { $0.name == nm && $0.done }
        // Quiet win: a task that dodged them 3+ times deserves more than a
        // checkmark — the assistant KNOWS this one was the hard kind of done.
        let win = t.flatMap { quietWinLine(taskName: nm, moveCount: $0.moveCount ?? 0, tone: tone) }
        return Receipt(icon: .check, label: win ?? "Completed “\(nm)”",
                       undo: t.map { .uncompleteTask(id: $0.id) })

    case "create_tasks":
        let n = countAfter("created", in: result)
        let ids = idsFragment(result)
        return Receipt(icon: .plus, label: "Created \(n) tasks",
                       undo: ids.isEmpty ? nil : .deleteTasks(ids: ids))

    case "complete_tasks":
        let n = countAfter("completed", in: result)
        let ids = idsFragment(result)
        return Receipt(icon: .check, label: "Completed \(n) tasks",
                       undo: ids.isEmpty ? nil : .uncompleteTasks(ids: ids))

    case "delete_task":
        return Receipt(icon: .trash, label: "Deleted “\(quotedFragment(result) ?? "task")”")

    case "save_profile_fact":
        // The learning receipt IS the consent UX: every remembered fact is
        // visible the moment it's saved, with a one-tap forget.
        let id = idFragment(result)
        let fact = quotedFragment(result) ?? "that"
        return Receipt(icon: .pencil, label: "Noted: \(fact)", undo: id.map { .forgetFact(id: $0) })

    // ── full app surface (2026-09-02) ──
    case "uncomplete_task":
        let id = idFragment(result)
        return Receipt(icon: .check, label: "Reopened \(quotedFragment(result) ?? "task")",
                       undo: id.map { .completeTask(id: $0) })

    case "unschedule_task":
        return Receipt(icon: .calendar, label: "Unscheduled \(quotedFragment(result) ?? "task")")

    case "skip_occurrence":
        return Receipt(icon: .calendar, label: "Skipped \(quotedFragment(result) ?? "task") today")

    case "complete_occurrence":
        return Receipt(icon: .check, label: "Done for today: \(quotedFragment(result) ?? "task")")

    case "block_time":
        let id = idFragment(result)
        return Receipt(icon: .calendar, label: "Blocked \(quotedFragment(result) ?? "time")",
                       undo: id.map { .deleteTask(id: $0) })

    case "carry_to_tomorrow":
        // 2026-09-20: a task tomorrow already had is SKIPPED today, never
        // counted as moved — with nothing moved the card must say so.
        if result.hasPrefix("ok: moved 0 ") { return Receipt(icon: .calendar, label: "Nothing moved — skipped today instead") }
        return Receipt(icon: .calendar, label: stripAfterDash(stripOk(result)))

    case "start_focus":
        return Receipt(icon: .check, label: "Focus started: \(quotedFragment(result) ?? "task")")

    case "pause_focus":
        return Receipt(icon: .pencil, label: "Focus paused")

    case "resume_focus":
        return Receipt(icon: .pencil, label: "Focus resumed")

    case "extend_focus":
        return Receipt(icon: .pencil, label: stripOk(result))

    case "cancel_focus":
        return Receipt(icon: .pencil, label: "Focus cancelled")

    // ── 2026-09-20 tooling rewrite (docs/assistant-tooling-rules.md §4) — cards
    // for the new write tools, each read off the executor's result string. ──
    case "finish_focus":
        // "ok: finished the session on "X" — 25m logged, task marked done" →
        // "Finished “X” · 25m logged, task marked done" (web parity).
        guard let nm = quotedFragment(result), let tail = result.range(of: "\" — ") else { return Receipt(icon: .check, label: stripOk(result)) }
        return Receipt(icon: .check, label: "Finished “\(nm)” · \(result[tail.upperBound...])")

    case "set_task_reminder":
        // "ok: "X" reminds 10 minutes before" / "ok: no reminder for "X"" /
        // "ok: "X" reminds at the default lead (10 minutes before)"
        return Receipt(icon: .pencil, label: "Reminder: \(stripTrailingParenthetical(stripOk(result)))")

    case "leave_list":
        return Receipt(icon: .trash, label: "Left “\(quotedFragment(result) ?? "list")”")

    case "recolor_list", "pin_list_item", "set_theme", "set_focus_defaults", "set_ambient_sound":
        return Receipt(icon: name == "recolor_list" || name == "pin_list_item" ? .list : .pencil,
                       label: stripTrailingParenthetical(stripOk(result)))

    case "restore_capture":
        return Receipt(icon: .plus, label: "Restored: \(quotedFragment(result) ?? "capture")")

    case "add_capture":
        let id = idFragment(result)
        return Receipt(icon: .plus, label: "Captured: \(quotedFragment(result) ?? "")",
                       undo: id.map { .deleteCapture(id: $0) })

    case "promote_capture":
        let id = idFragment(result)
        return Receipt(icon: .plus, label: "Task from capture: \(quotedFragment(result) ?? "")",
                       undo: id.map { .deleteTask(id: $0) })

    case "resolve_capture":
        return Receipt(icon: .check, label: "Resolved: \(quotedFragment(result) ?? "capture")")

    case "delete_capture":
        return Receipt(icon: .pencil, label: "Deleted capture")

    case "rename_list", "archive_list", "delete_list", "edit_list_item", "remove_list_item", "set_list_item_done",
         "create_area", "rename_area", "delete_area", "create_tag", "rename_tag", "delete_tag",
         "unshare_task", "set_usable_minutes", "set_notification_level", "set_reminder_lead", "set_ritual":
        let icon: ReceiptIcon = name.hasPrefix("create") ? .plus : name.contains("done") ? .check : .pencil
        return Receipt(icon: icon, label: stripTrailingParenthetical(stripOk(result)))

    case "forget_fact":
        return Receipt(icon: .pencil, label: "Forgot: \(quotedFragment(result) ?? "that")")

    case "create_list":
        return Receipt(icon: .list, label: "Created list “\(quotedFragment(result) ?? "list")”")

    case "add_to_list":
        return Receipt(icon: .list, label: "Added to “\(quotedFragment(result) ?? "list")”")

    case "promote_item_to_task":
        return Receipt(icon: .plus, label: "Promoted “\(quotedFragment(result) ?? "item")” to a task")

    // ── calls ("Unstuck calls you", Part B) — "Call booked Thu 14:45 — speak to James · 4 notes" ──
    case "request_call":
        guard let m = callBooked(result) else { return nil }
        return Receipt(icon: .calendar,
                       label: "Call booked \(shortWeekday(m.date)) \(clock.time(m.hm)) — \(m.label) · \(m.n) note\(m.n == "1" ? "" : "s")",
                       undo: .cancelCall(id: m.id))

    case "update_call":
        guard let m = callUpdated(result) else { return nil }
        return Receipt(icon: .pencil,
                       label: "Call updated \(shortWeekday(m.date)) \(clock.time(m.hm)) — \(m.label) · \(m.n) note\(m.n == "1" ? "" : "s")")

    case "cancel_call":
        return Receipt(icon: .trash, label: "Call cancelled — \(quotedFragment(result) ?? "call")")

    default:
        return nil
    }
}

/// 'YYYY-MM-DD' → 'Thu' (local calendar day, no timezone shift).
private func shortWeekday(_ date: String) -> String {
    ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][LocalDate.dayOfWeek(date)]
}

private let CALL_BOOKED_RE = try! NSRegularExpression(
    pattern: "^ok: call booked (\\d{4}-\\d{2}-\\d{2}) (\\d{2}:\\d{2}) \"(.*)\" \\((\\d+) notes?\\) id=(\\S+)")
private let CALL_UPDATED_RE = try! NSRegularExpression(
    pattern: "^ok: updated call \"(.*)\" — (\\d{4}-\\d{2}-\\d{2}) (\\d{2}:\\d{2}), (\\d+) notes?")

private func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
    guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) else { return nil }
    return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
}

private func callBooked(_ s: String) -> (date: String, hm: String, label: String, n: String, id: String)? {
    guard let g = groups(CALL_BOOKED_RE, s) else { return nil }
    return (g[0], g[1], g[2], g[3], g[4])
}

private func callUpdated(_ s: String) -> (label: String, date: String, hm: String, n: String)? {
    guard let g = groups(CALL_UPDATED_RE, s) else { return nil }
    return (g[0], g[1], g[2], g[3])
}

/// The mutation an Undo tap performs. The app layer applies it through the same
/// write methods the UI uses (delete / save), so sync + the outbox are honoured.
public enum ReceiptUndoAction: Equatable, Sendable {
    /// Remove the task AND its calendar blocks (the executor's delete_task
    /// cascade — ghost blocks were a confirmed flow bug, 2026-08-30).
    case deleteTask(id: String)
    /// The task with `done` flipped back off (completion stamp cleared).
    case restoreTask(TaskItem)
    /// Several tasks (+ their blocks) to remove — undo of `create_tasks`.
    case deleteTasks(ids: [String])
    /// Several tasks flipped back open — undo of `complete_tasks` (only the ones still present).
    case restoreTasks([TaskItem])
    /// Soft-delete the remembered fact — undo of `save_profile_fact`.
    case forgetFact(id: String)
    /// Remove the capture — undo of `add_capture`.
    case deleteCapture(id: String)
    /// The task with `done` set (stamped `nowISO`) — undo of `uncomplete_task`.
    case completeTask(TaskItem)
    /// Cancel the booked call — undo of `request_call` (Part B).
    case cancelCall(id: String)
}

/// Plan a receipt's undo against the live task list. `nil` = nothing to do
/// (the web's `false`): the task the undo targets is already gone.
public func planReceiptUndo(_ undo: ReceiptUndo, tasks: [TaskItem], nowISO: String) -> ReceiptUndoAction? {
    func reopened(_ t: TaskItem) -> TaskItem {
        var t = t
        t.done = false
        t.completedAt = nil
        t.updatedAt = nowISO
        return t
    }
    switch undo {
    case .deleteTask(let id):
        // Deleting an id that no longer exists is a harmless no-op, and the web
        // reports success unconditionally here — keep the receipt struck through.
        return .deleteTask(id: id)
    case .uncompleteTask(let id):
        guard let t = tasks.first(where: { $0.id == id }) else { return nil }
        return .restoreTask(reopened(t))
    case .deleteTasks(let ids):
        return .deleteTasks(ids: ids)
    case .uncompleteTasks(let ids):
        let present = ids.compactMap { id in tasks.first { $0.id == id } }.map(reopened)
        return present.isEmpty ? nil : .restoreTasks(present)
    case .forgetFact(let id):
        return .forgetFact(id: id)
    case .deleteCapture(let id):
        return .deleteCapture(id: id)
    case .completeTask(let id):
        // Never onto a repeating series' template: its done ENDS the series
        // (audit 2026-09-22, C3). New results for a series carry no id=, so
        // only an older persisted "Reopened" receipt can land here.
        guard var t = tasks.first(where: { $0.id == id }), t.recurrence == nil else { return nil }
        t.done = true
        t.completedAt = nowISO
        t.updatedAt = nowISO
        return .completeTask(t)
    case .cancelCall(let id):
        return .cancelCall(id: id)
    }
}

/// N from a set_task_recurrence ok line's "now repeats every N weeks", or nil.
func repeatsEveryNWeeks(_ result: String) -> Int? {
    guard let r = result.range(of: "now repeats every ") else { return nil }
    let digits = result[r.upperBound...].prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty, result[r.upperBound...].dropFirst(digits.count).hasPrefix(" weeks") else { return nil }
    return Int(digits)
}
