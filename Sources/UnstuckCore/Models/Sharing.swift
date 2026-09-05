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
///
/// Since migration 052 the projection also carries the OWNER's schedule: the
/// task's estimate + life area and its NEXT block — the owner's earliest live
/// block (not done, not skipped, on/after the owner's local today), or, when
/// there is none, the most recent past block. Every `next*` field is nil when
/// nothing is scheduled, and ALL the schedule fields are nil against a pre-052
/// server (the visibility rules then treat the task as unscheduled → Today).
public struct SharedWithMe: Codable, Equatable, Sendable, Identifiable {
    public var shareId: String
    public var taskId: String
    public var ownerName: String
    public var level: ShareLevel
    public var title: String
    /// All levels project the done state (v3). Coalesced from a nullable column.
    public var done: Bool
    /// When it was completed (migration 049). nil against an older projection —
    /// the visibility rules (SharedTaskVisibility) degrade gracefully.
    public var completedAt: String?
    /// The owner's estimate (migration 052). nil against an older projection.
    public var estimateMin: Int?
    /// The owner's life area (migration 052) — the shared group honours the
    /// active area filter with it, like Delegated does for assigned-out rows.
    public var lifeArea: String?
    /// The owner's next block (migration 052) — see the type doc.
    public var nextBlockId: String?
    /// 'YYYY-MM-DD' (the owner's block date).
    public var nextDate: String?
    /// 'HH:MM'.
    public var nextStartTime: String?
    public var nextDurationMinutes: Int?
    /// Whether that block is done (only ever true for a PAST block — a live
    /// block is by definition not done).
    public var nextDone: Bool?

    public var id: String { shareId }

    public init(shareId: String, taskId: String, ownerName: String, level: ShareLevel,
                title: String, done: Bool, completedAt: String? = nil,
                estimateMin: Int? = nil, lifeArea: String? = nil,
                nextBlockId: String? = nil, nextDate: String? = nil, nextStartTime: String? = nil,
                nextDurationMinutes: Int? = nil, nextDone: Bool? = nil) {
        self.shareId = shareId
        self.taskId = taskId
        self.ownerName = ownerName
        self.level = level
        self.title = title
        self.done = done
        self.completedAt = completedAt
        self.estimateMin = estimateMin
        self.lifeArea = lifeArea
        self.nextBlockId = nextBlockId
        self.nextDate = nextDate
        self.nextStartTime = nextStartTime
        self.nextDurationMinutes = nextDurationMinutes
        self.nextDone = nextDone
    }

    // Hand-written Codable so the optional projections are FORGIVING: each key
    // may be absent entirely (pre-049 / pre-052 RPC), null, or arrive in either
    // the camelCase shape we encode or the raw snake_case the RPC projects.
    // Every original (required) field keeps its synthesized strictness.
    private enum CodingKeys: String, CodingKey {
        case shareId, taskId, ownerName, level, title, done, completedAt
        case estimateMin, lifeArea, nextBlockId, nextDate, nextStartTime, nextDurationMinutes, nextDone
        case completedAtSnake = "completed_at"
        case estimateMinSnake = "estimate_min"
        case lifeAreaSnake = "life_area"
        case nextBlockIdSnake = "next_block_id"
        case nextDateSnake = "next_date"
        case nextStartTimeSnake = "next_start_time"
        case nextDurationMinutesSnake = "next_duration_minutes"
        case nextDoneSnake = "next_done"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shareId = try c.decode(String.self, forKey: .shareId)
        taskId = try c.decode(String.self, forKey: .taskId)
        ownerName = try c.decode(String.self, forKey: .ownerName)
        level = try c.decode(ShareLevel.self, forKey: .level)
        title = try c.decode(String.self, forKey: .title)
        done = try c.decode(Bool.self, forKey: .done)
        func either<T: Decodable>(_ type: T.Type, _ camel: CodingKeys, _ snake: CodingKeys) throws -> T? {
            try c.decodeIfPresent(T.self, forKey: camel) ?? c.decodeIfPresent(T.self, forKey: snake)
        }
        completedAt = try either(String.self, .completedAt, .completedAtSnake)
        estimateMin = try either(Int.self, .estimateMin, .estimateMinSnake)
        lifeArea = try either(String.self, .lifeArea, .lifeAreaSnake)
        nextBlockId = try either(String.self, .nextBlockId, .nextBlockIdSnake)
        nextDate = try either(String.self, .nextDate, .nextDateSnake)
        nextStartTime = try either(String.self, .nextStartTime, .nextStartTimeSnake)
        nextDurationMinutes = try either(Int.self, .nextDurationMinutes, .nextDurationMinutesSnake)
        nextDone = try either(Bool.self, .nextDone, .nextDoneSnake)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shareId, forKey: .shareId)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(ownerName, forKey: .ownerName)
        try c.encode(level, forKey: .level)
        try c.encode(title, forKey: .title)
        try c.encode(done, forKey: .done)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(estimateMin, forKey: .estimateMin)
        try c.encodeIfPresent(lifeArea, forKey: .lifeArea)
        try c.encodeIfPresent(nextBlockId, forKey: .nextBlockId)
        try c.encodeIfPresent(nextDate, forKey: .nextDate)
        try c.encodeIfPresent(nextStartTime, forKey: .nextStartTime)
        try c.encodeIfPresent(nextDurationMinutes, forKey: .nextDurationMinutes)
        try c.encodeIfPresent(nextDone, forKey: .nextDone)
    }
}

/// One block of a task shared WITH me, inside a calendar window — the
/// `shared_task_blocks(p_from, p_to)` projection (migration 052): every block
/// (any share level) of every task shared with me, dated within the window.
/// Read-only on the recipient's calendar: it sits at the OWNER's slot and is
/// never dragged, resized, edited, or deleted from here. External (calendar-
/// import) blocks are never projected; skipped ones arrive flagged.
public struct SharedBlock: Codable, Equatable, Sendable, Identifiable {
    public var blockId: String
    public var taskId: String
    public var shareId: String
    public var level: ShareLevel
    public var ownerName: String
    public var title: String
    /// 'YYYY-MM-DD'
    public var date: String
    /// 'HH:MM'
    public var startTime: String
    public var durationMinutes: Int
    public var done: Bool
    public var skipped: Bool
    /// The block kind ("task" | "time" | …) — never "external".
    public var kind: String

    public var id: String { blockId }

    public init(blockId: String, taskId: String, shareId: String, level: ShareLevel, ownerName: String,
                title: String, date: String, startTime: String, durationMinutes: Int,
                done: Bool = false, skipped: Bool = false, kind: String = "task") {
        self.blockId = blockId
        self.taskId = taskId
        self.shareId = shareId
        self.level = level
        self.ownerName = ownerName
        self.title = title
        self.date = date
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.done = done
        self.skipped = skipped
        self.kind = kind
    }

    // Forgiving Codable: accepts the camelCase shape we encode OR the raw
    // snake_case RPC row; nullable booleans coalesce to false; a missing kind
    // defaults to "task".
    private enum CodingKeys: String, CodingKey {
        case blockId, taskId, shareId, level, ownerName, title, date, startTime, durationMinutes, done, skipped, kind
        case blockIdSnake = "block_id"
        case taskIdSnake = "task_id"
        case shareIdSnake = "share_id"
        case ownerNameSnake = "owner_name"
        case startTimeSnake = "start_time"
        case durationMinutesSnake = "duration_minutes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func either<T: Decodable>(_ type: T.Type, _ camel: CodingKeys, _ snake: CodingKeys) throws -> T {
            if let v = try c.decodeIfPresent(T.self, forKey: camel) { return v }
            return try c.decode(T.self, forKey: snake)
        }
        blockId = try either(String.self, .blockId, .blockIdSnake)
        taskId = try either(String.self, .taskId, .taskIdSnake)
        shareId = try either(String.self, .shareId, .shareIdSnake)
        level = ShareLevel(rawValue: try c.decode(String.self, forKey: .level)) ?? .view
        ownerName = try either(String.self, .ownerName, .ownerNameSnake)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        date = try c.decode(String.self, forKey: .date)
        startTime = try either(String.self, .startTime, .startTimeSnake)
        durationMinutes = try either(Int.self, .durationMinutes, .durationMinutesSnake)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        skipped = try c.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "task"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(blockId, forKey: .blockId)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(shareId, forKey: .shareId)
        try c.encode(level, forKey: .level)
        try c.encode(ownerName, forKey: .ownerName)
        try c.encode(title, forKey: .title)
        try c.encode(date, forKey: .date)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(durationMinutes, forKey: .durationMinutes)
        try c.encode(done, forKey: .done)
        try c.encode(skipped, forKey: .skipped)
        try c.encode(kind, forKey: .kind)
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
    /// The owner's next block (migration 052) — same semantics as
    /// `SharedWithMe.next*`: nil when nothing is scheduled / pre-052 server.
    public var nextBlockId: String?
    public var nextDate: String?
    public var nextStartTime: String?
    public var nextDurationMinutes: Int?
    public var nextDone: Bool?

    public var id: String { taskId }

    public init(taskId: String, ownerName: String, level: ShareLevel, name: String, done: Bool,
                estimateMin: Int, totalFocused: Int, lifeArea: String?, priority: Priority?,
                tags: [String], objectives: [Objective], dueAt: String?, createdAt: String?,
                nextBlockId: String? = nil, nextDate: String? = nil, nextStartTime: String? = nil,
                nextDurationMinutes: Int? = nil, nextDone: Bool? = nil) {
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
        self.nextBlockId = nextBlockId
        self.nextDate = nextDate
        self.nextStartTime = nextStartTime
        self.nextDurationMinutes = nextDurationMinutes
        self.nextDone = nextDone
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
