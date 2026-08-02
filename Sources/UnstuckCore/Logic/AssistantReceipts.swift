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
public enum ReceiptUndo: Codable, Equatable, Sendable {
    case deleteTask(id: String)
    case uncompleteTask(id: String)

    public var taskId: String {
        switch self {
        case .deleteTask(let id), .uncompleteTask(let id): return id
        }
    }
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

/// The first `"…"` run in a result string — how the executor names the entity.
func quotedFragment(_ s: String) -> String? {
    guard let open = s.firstIndex(of: "\"") else { return nil }
    let after = s.index(after: open)
    guard after < s.endIndex, let close = s[after...].firstIndex(of: "\"") else { return nil }
    return String(s[after..<close])
}

/// The `id=…` token in a result string (up to the next whitespace).
private func idFragment(_ s: String) -> String? {
    guard let r = s.range(of: "id=") else { return nil }
    let rest = s[r.upperBound...].prefix { !$0.isWhitespace }
    return rest.isEmpty ? nil : String(rest)
}

/// Build the receipt for one SUCCESSFUL tool call (result starts "ok").
/// `tasks` resolves live entities for undo targets. Returns nil for read-only
/// tools and unrecognized results — no receipt beats a wrong receipt.
public func deriveReceipt(
    name: String,
    args: ReceiptArgs,
    result: String,
    tasks: [TaskItem]
) -> Receipt? {
    guard result.hasPrefix("ok") else { return nil }
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
                           + (time.isEmpty ? "" : " \(time)"))

    case "update_task":
        return Receipt(icon: .pencil, label: "Updated “\(quotedFragment(result) ?? "task")”")

    case "set_task_later":
        let nm = args.taskId.flatMap { id in tasks.first { $0.id == id }?.name }
        // Web: `args.later !== false` — anything but an explicit false is "to Later".
        let toLater = args.later != false
        let verb = toLater ? "Moved to Later" : "Brought back from Later"
        return Receipt(icon: .pencil, label: verb + (nm.map { " — “\($0)”" } ?? ""))

    case "set_task_recurrence":
        let nm = args.taskId.flatMap { id in tasks.first { $0.id == id }?.name }
        let suffix = nm.map { " — “\($0)”" } ?? ""
        if let kind = args.kind {
            return Receipt(icon: .calendar, label: "Repeats \(kind)\(suffix)")
        }
        return Receipt(icon: .calendar, label: "Repeat removed\(suffix)")

    case "complete_task":
        let nm = quotedFragment(result) ?? "task"
        let t = tasks.first { $0.name == nm && $0.done }
        return Receipt(icon: .check, label: "Completed “\(nm)”",
                       undo: t.map { .uncompleteTask(id: $0.id) })

    case "delete_task":
        return Receipt(icon: .trash, label: "Deleted “\(quotedFragment(result) ?? "task")”")

    case "create_list":
        return Receipt(icon: .list, label: "Created list “\(quotedFragment(result) ?? "list")”")

    case "add_to_list":
        return Receipt(icon: .list, label: "Added to “\(quotedFragment(result) ?? "list")”")

    case "promote_item_to_task":
        return Receipt(icon: .plus, label: "Promoted “\(quotedFragment(result) ?? "item")” to a task")

    default:
        return nil
    }
}

/// The mutation an Undo tap performs. The app layer applies it through the same
/// write methods the UI uses (delete / save), so sync + the outbox are honoured.
public enum ReceiptUndoAction: Equatable, Sendable {
    case deleteTask(id: String)
    /// The task with `done` flipped back off (completion stamp cleared).
    case restoreTask(TaskItem)
}

/// Plan a receipt's undo against the live task list. `nil` = nothing to do
/// (the web's `false`): the task the undo targets is already gone.
public func planReceiptUndo(_ undo: ReceiptUndo, tasks: [TaskItem], nowISO: String) -> ReceiptUndoAction? {
    switch undo {
    case .deleteTask(let id):
        // Deleting an id that no longer exists is a harmless no-op, and the web
        // reports success unconditionally here — keep the receipt struck through.
        return .deleteTask(id: id)
    case .uncompleteTask(let id):
        guard var t = tasks.first(where: { $0.id == id }) else { return nil }
        t.done = false
        t.completedAt = nil
        t.updatedAt = nowISO
        return .restoreTask(t)
    }
}
