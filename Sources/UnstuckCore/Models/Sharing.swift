// Sharing + collaboration domain models — the iOS port of the web sharing hooks
// (lib/use-circle.ts + lib/use-task-shares.ts). Pure data, no Supabase: the
// networked transport lives in UnstuckSync's CircleClient, which decodes the
// SECURITY DEFINER RPC rows (snake_case) into these camelCase models.
//
// Two orthogonal concepts:
//   • Trusted circle — "people you share with" (a CircleMember roster). A
//     member's `level` here is the circle-invite grade ("view" | "comment"),
//     kept as a raw String to match the web (it is NOT a task ShareLevel).
//   • Per-task sharing — a task shared with a circle member at a capability
//     ShareLevel (view / partner / assign). Every level projects title + done.

import Foundation

/// Per-task capability grade (migration 044). All three READ the task
/// (title + done); the old existence/status/co_owner privacy tiers are gone.
///   view    — read + notified when the owner starts & finishes it.
///   partner — view + either party can start/complete.
///   assign  — handed to the recipient as THEIR task; owner keeps view.
public enum ShareLevel: String, Codable, Sendable, CaseIterable, Equatable {
    case view
    case partner
    case assign
}

/// A member of your trusted circle (an active connection or a pending invite).
/// Mirrors web `CircleMember` (use-circle.ts) 1:1.
public struct CircleMember: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var relationshipLabel: String?
    /// Circle-invite grade ("view" | "comment"), NOT a task ShareLevel.
    public var level: String
    /// "invited" | "active" | "revoked" (kept as String for forward-compat).
    public var status: String
    /// Present only for pending invites (so the UI can re-copy the join link).
    public var inviteCode: String?
    /// The member's auth user id — set for active members, nil while invited.
    public var memberUserId: String?
    /// Server-resolved display name for active members.
    public var memberName: String?
    public var createdAt: String

    public init(id: String, relationshipLabel: String?, level: String, status: String,
                inviteCode: String?, memberUserId: String?, memberName: String?, createdAt: String) {
        self.id = id
        self.relationshipLabel = relationshipLabel
        self.level = level
        self.status = status
        self.inviteCode = inviteCode
        self.memberUserId = memberUserId
        self.memberName = memberName
        self.createdAt = createdAt
    }
}

/// One share ON a task I own — drives the share sheet's current state.
/// Mirrors web `ShareForTask`.
public struct ShareForTask: Codable, Equatable, Sendable, Identifiable {
    public var shareId: String
    public var recipientUserId: String
    public var recipientName: String
    public var level: ShareLevel

    public var id: String { shareId }

    public init(shareId: String, recipientUserId: String, recipientName: String, level: ShareLevel) {
        self.shareId = shareId
        self.recipientUserId = recipientUserId
        self.recipientName = recipientName
        self.level = level
    }
}

/// A task someone else has shared WITH me. Mirrors web `SharedWithMe`.
public struct SharedWithMe: Codable, Equatable, Sendable, Identifiable {
    public var shareId: String
    public var taskId: String
    public var ownerName: String
    public var level: ShareLevel
    public var title: String
    /// All levels project the done state (v3). Coalesced from a nullable column.
    public var done: Bool

    public var id: String { shareId }

    public init(shareId: String, taskId: String, ownerName: String, level: ShareLevel, title: String, done: Bool) {
        self.shareId = shareId
        self.taskId = taskId
        self.ownerName = ownerName
        self.level = level
        self.title = title
        self.done = done
    }
}

/// The read-only detail of a task shared WITH me — the ONLY window a recipient
/// has into a shared task's contents (RLS blocks the raw `tasks` row). Built from
/// the `shared_task_detail(p_task_id)` RPC (migration 045), which returns the
/// detail for a share the caller holds at ANY level (view/partner/assign). Every
/// field is display-only: the recipient never edits the owner's task.
public struct SharedTaskDetail: Equatable, Sendable, Identifiable {
    public var taskId: String
    public var ownerName: String
    public var level: ShareLevel
    public var name: String
    public var done: Bool
    public var estimateMin: Int
    /// The OWNER's cumulative focus on the task (incl. any partner/assign minutes
    /// a recipient contributed via log_shared_focus).
    public var totalFocused: Int
    public var lifeArea: String?
    public var priority: Priority?
    public var tags: [String]
    /// The task's steps / subtasks (the `objectives` jsonb).
    public var objectives: [Objective]
    public var dueAt: String?
    public var createdAt: String?

    public var id: String { taskId }

    public init(taskId: String, ownerName: String, level: ShareLevel, name: String, done: Bool,
                estimateMin: Int, totalFocused: Int, lifeArea: String?, priority: Priority?,
                tags: [String], objectives: [Objective], dueAt: String?, createdAt: String?) {
        self.taskId = taskId
        self.ownerName = ownerName
        self.level = level
        self.name = name
        self.done = done
        self.estimateMin = estimateMin
        self.totalFocused = totalFocused
        self.lifeArea = lifeArea
        self.priority = priority
        self.tags = tags
        self.objectives = objectives
        self.dueAt = dueAt
        self.createdAt = createdAt
    }
}

/// One outgoing share for the row badges on my own task list. Mirrors web
/// `ShareBadge`, plus `taskId` so a flat list can be grouped by task.
public struct ShareBadge: Codable, Equatable, Sendable {
    public var taskId: String
    public var level: ShareLevel
    public var recipientName: String

    public init(taskId: String, level: ShareLevel, recipientName: String) {
        self.taskId = taskId
        self.level = level
        self.recipientName = recipientName
    }
}

// MARK: - Pure sharing-level logic (port of lib/share-levels.ts)

/// The three capability grades in order, with their picker label + explainer
/// blurb — mirrors the web `SHARE_LEVELS`.
public let SHARE_LEVELS: [(value: ShareLevel, label: String, blurb: String)] = [
    (.view, "View", "They see the task and get notified when you start and finish it."),
    (.partner, "Partner", "Either of you can start or complete it — and you can focus together, live."),
    (.assign, "Assign", "Hand it off — it becomes their task to do. You keep view + updates."),
]

/// Can the recipient act on the task (start / complete it)? View cannot.
public func levelCanComplete(_ level: ShareLevel) -> Bool {
    level == .partner || level == .assign
}

/// The quiet chip on a "shared with you" row, from the RECIPIENT's side.
public func shareStatusLabel(_ level: ShareLevel, done: Bool) -> String {
    if done { return "done" }
    switch level {
    case .view: return "watching"
    case .assign: return "yours"
    case .partner: return "partner"
    }
}

/// The focus-action label inside a shared-task detail — partner "focus together,
/// live"; assign is theirs to do. Only shown for focus-capable levels (the
/// log_shared_focus gate is the same partner+assign rule as levelCanComplete).
public func sharedFocusActionLabel(_ level: ShareLevel) -> String {
    level == .partner ? "Focus with them" : "Focus"
}

/// The chip on the OWNER's own task row / "shared with" line — the level granted.
public func shareLevelLabel(_ level: ShareLevel) -> String {
    switch level {
    case .view: return "view"
    case .assign: return "assigned"
    case .partner: return "partner"
    }
}

// MARK: - Delegation derivation (port of lib/delegated-group helpers)

/// taskId → assignee name, for tasks the current user has shared at 'assign'.
/// Derives from the share badges (my_task_share_badges).
public func assignedOutMap(_ byTask: [String: [ShareBadge]]) -> [String: String] {
    var out: [String: String] = [:]
    for (taskId, badges) in byTask {
        if let a = badges.first(where: { $0.level == .assign }) { out[taskId] = a.recipientName }
    }
    return out
}

/// The set of task ids the current user has assigned away — for excluding them
/// from "Start Next" / "Up Next" recommendations (they're someone else's now).
public func assignedOutIds(_ byTask: [String: [ShareBadge]]) -> Set<String> {
    var ids = Set<String>()
    for (taskId, badges) in byTask where badges.contains(where: { $0.level == .assign }) {
        ids.insert(taskId)
    }
    return ids
}
