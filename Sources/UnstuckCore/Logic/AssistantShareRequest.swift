// Assistant share requests — the ONE agent action that sends a user's content
// to another person, so it never executes on the model's say-so. The tool
// RESOLVES and STAGES a request (task + circle member + level); the panel
// renders a confirm card; only the user's tap performs the share RPC.
//
// Port of lib/assistant/share-request.ts, matching the assistant guardrail
// rule that high-impact actions ask first.

import Foundation

/// A person in the user's trusted circle who can actually receive a share.
public struct ShareCandidate: Equatable, Sendable, Identifiable {
    public let userId: String
    public let name: String

    public var id: String { userId }

    public init(userId: String, name: String) {
        self.userId = userId
        self.name = name
    }
}

/// What became of a staged share once the user answered.
public enum PendingShareOutcome: String, Codable, Equatable, Sendable {
    case shared, dismissed, failed
}

/// What a staged share is FOR. `share_list` (2026-09-20 tooling rewrite)
/// stages through the same confirm card as `share_task`; the card runs the
/// collection share RPC instead of the task one.
public enum PendingShareTarget: String, Equatable, Sendable {
    case task, list
}

public struct PendingShare: Equatable, Sendable, Identifiable {
    /// Stable id so the confirm card can key/dedupe.
    public let id: String
    /// The task's id — or, when `target == .list`, the LIST's id (the field
    /// predates list shares; every consumer switches on `target`).
    public let taskId: String
    /// The task's (or list's) name, for the card.
    public let taskName: String
    /// Empty when the request targets an email (see `recipientEmail`).
    public let recipientUserId: String
    public let recipientName: String
    /// Task shares only (`view` / `partner` / `assign`); a list share carries
    /// its role in `listRole` and leaves this at `.view`.
    public let level: ShareLevel
    /// Set once the user confirms or dismisses — the card stops offering.
    public var outcome: PendingShareOutcome?
    /// Unified sharing v1: the user named an email address instead of a
    /// connection. The confirm card then calls `share-task add` (existing
    /// account → shared at once; no account → invite by email) instead of the
    /// by-id RPC. nil for a circle member.
    public var recipientEmail: String?
    /// `.task` (the default) or `.list`.
    public var target: PendingShareTarget
    /// List shares only: "editor" (can add and tick items) or "viewer".
    public var listRole: String?

    public init(id: String, taskId: String, taskName: String, recipientUserId: String,
                recipientName: String, level: ShareLevel, outcome: PendingShareOutcome? = nil,
                recipientEmail: String? = nil, target: PendingShareTarget = .task, listRole: String? = nil) {
        self.id = id
        self.taskId = taskId
        self.taskName = taskName
        self.recipientUserId = recipientUserId
        self.recipientName = recipientName
        self.level = level
        self.outcome = outcome
        self.recipientEmail = recipientEmail
        self.target = target
        self.listRole = listRole
    }
}

/// Loose name match: exact (case-insensitive), then first-name, then prefix.
/// Every fuzzy tier must be UNAMBIGUOUS — with two Anas in the circle, "Ana"
/// resolves to nobody and the agent has to ask which one. Sharing to the
/// wrong person is unrecoverable, so silence beats a confident guess.
public func matchCandidate(_ who: String, _ people: [ShareCandidate]) -> ShareCandidate? {
    let q = who.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return nil }
    func norm(_ p: ShareCandidate) -> String {
        p.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    let exact = people.filter { norm($0) == q }
    if exact.count == 1 { return exact[0] }
    if exact.count > 1 { return nil }
    let first = people.filter { norm($0).split(whereSeparator: \.isWhitespace).first.map(String.init) == q }
    if first.count == 1 { return first[0] }
    if first.count > 1 { return nil }
    let starts = people.filter { norm($0).hasPrefix(q) }
    return starts.count == 1 ? starts[0] : nil
}

/// Anything that isn't one of the three real levels falls back to the
/// least-permissive `view`.
public func normalizeLevel(_ raw: String?) -> ShareLevel {
    let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return ShareLevel(rawValue: v) ?? .view
}

public struct ResolveShareResult: Equatable, Sendable {
    /// Staged request awaiting the user's tap.
    public var pending: PendingShare?
    /// Result string handed back to the model.
    public var message: String

    public init(pending: PendingShare? = nil, message: String) {
        self.pending = pending
        self.message = message
    }
}

/// Resolve a share request into something the user can confirm. Never performs
/// the share. Returns a model-readable message in all paths so the agent can
/// explain itself (e.g. "no one in your circle matches 'Sam'").
public func resolveShareRequest(
    taskId: String? = nil,
    taskName: String? = nil,
    person: String? = nil,
    level: String? = nil,
    tasks: [TaskItem],
    people: [ShareCandidate],
    newId: () -> String
) -> ResolveShareResult {
    let task: TaskItem? = {
        if let taskId { return tasks.first { $0.id == taskId } }
        guard let taskName else { return nil }
        let needle = taskName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tasks.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle }
            ?? tasks.first { $0.name.lowercased().contains(needle) }
    }()
    guard let task else {
        return ResolveShareResult(message: "error: task not found — ask which task they mean")
    }

    // An email address needs no circle: `share-task add` shares with an
    // existing account at once or stores an invite that is claimed when they
    // sign up (unified sharing v1). Still staged — the user confirms on screen.
    if let person, isEmailLike(person) {
        let email = normalizedShareEmail(person)
        let level = normalizeLevel(level)
        return ResolveShareResult(
            pending: PendingShare(id: newId(), taskId: task.id, taskName: task.name,
                                  recipientUserId: "", recipientName: email, level: level,
                                  recipientEmail: email),
            message: "ok: prepared a share of \"\(task.name)\" with \(email) (\(level.rawValue)). If they have an Unstuck account it is shared the moment the user confirms; otherwise they get an invite email. The user must CONFIRM it on screen — tell them it's ready to confirm, and do not claim it is shared.")
    }

    if people.isEmpty {
        return ResolveShareResult(message: "error: the user has nobody in their trusted circle yet — tell them to add someone in Settings → People first")
    }
    let who = person ?? ""
    guard let match = matchCandidate(who, people) else {
        let names = people.map(\.name).joined(separator: ", ")
        return ResolveShareResult(message: "error: no circle member matches \"\(who)\" — their circle is: \(names). Ask which person.")
    }

    let level = normalizeLevel(level)
    return ResolveShareResult(
        pending: PendingShare(id: newId(), taskId: task.id, taskName: task.name,
                              recipientUserId: match.userId, recipientName: match.name, level: level),
        message: "ok: prepared a share of \"\(task.name)\" with \(match.name) (\(level.rawValue)). The user must CONFIRM it on screen — tell them it's ready to confirm, and do not claim it is shared.")
}

// MARK: - share_list (2026-09-20 tooling rewrite)

/// The list-share role vocabulary (`share_list.role`): editor can add and
/// tick items; anything else falls back to the least-permissive `viewer`.
public func normalizeListRole(_ raw: String?) -> String {
    raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "editor" ? "editor" : "viewer"
}

/// Resolve a `share_list` request into a staged `PendingShare` the user can
/// confirm — exactly like `resolveShareRequest`, over a list instead of a
/// task (same person resolution: circle member by name, or an email). Never
/// performs the share. `listName` is resolved by the caller (the executor
/// also owns the owner-only check), so this stays pure over the person.
public func resolveListShareRequest(
    listId: String,
    listName: String,
    person: String?,
    role: String?,
    people: [ShareCandidate],
    newId: () -> String
) -> ResolveShareResult {
    let role = normalizeListRole(role)
    if let person, isEmailLike(person) {
        let email = normalizedShareEmail(person)
        return ResolveShareResult(
            pending: PendingShare(id: newId(), taskId: listId, taskName: listName,
                                  recipientUserId: "", recipientName: email, level: .view,
                                  recipientEmail: email, target: .list, listRole: role),
            message: "ok: prepared a share of list \"\(listName)\" with \(email) (\(role)). If they have an Unstuck account it is shared the moment the user confirms; otherwise they get an invite email. The user must CONFIRM it on screen — tell them it's ready to confirm, and do not claim it is shared.")
    }
    if people.isEmpty {
        return ResolveShareResult(message: "error: the user has nobody in their trusted circle yet — tell them to add someone in Settings → People first, or give an email address")
    }
    let who = person ?? ""
    guard let match = matchCandidate(who, people) else {
        let names = people.map(\.name).joined(separator: ", ")
        return ResolveShareResult(message: "error: no circle member matches \"\(who)\" — their circle is: \(names). Ask which person.")
    }
    return ResolveShareResult(
        pending: PendingShare(id: newId(), taskId: listId, taskName: listName,
                              recipientUserId: match.userId, recipientName: match.name, level: .view,
                              target: .list, listRole: role),
        message: "ok: prepared a share of list \"\(listName)\" with \(match.name) (\(role)). The user must CONFIRM it on screen — tell them it's ready to confirm, and do not claim it is shared.")
}
