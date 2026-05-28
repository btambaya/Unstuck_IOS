// DbRowCodec — the PostgREST boundary. Explicit per-entity row structs
// that map the UnstuckCore models to/from the exact Supabase row shape
// the web app uses (see lib/use-tasks.ts `taskToDbRow` et al.).
//
// Why explicit rows + custom encoders:
//  1. Top-level columns are snake_case (estimate_min, …) but JSONB blobs
//     keep camelCase keys (recurrence.daysOfWeek, objectives, …). The
//     CodingKeys rename ONLY the top-level column; nested JSONB encodes
//     via each value's own camelCase Codable. A blanket
//     .convertToSnakeCase encoder would corrupt `daysOfWeek`.
//  2. Nil optionals must serialize as explicit `null` (NOT be omitted) so
//     an upsert CLEARS a field the user removed (e.g. un-completing →
//     completed_at: null). Swift's synthesized Encodable omits nil
//     optionals, so each row writes its columns explicitly. The lone
//     exception is reason_logs.duration_sec, which is omitted so an
//     upsert never clobbers a server-set value (matches the web writer).
// `user_id` is NOT included — the write layer attaches it. Defaults match
// the web (tags ?? [], move_count ?? 0, later ?? false). Foreign-key
// columns drop to null when not a valid UUID (web `uuidOrNull`).

import Foundation
import UnstuckCore

func uuidOrNull(_ s: String?) -> String? {
    guard let s, isUUID(s) else { return nil }
    return s
}

struct TaskRow: Codable, Sendable {
    var id: String
    var name: String
    var estimateMin: Int
    var totalFocused: Int
    var done: Bool
    var priority: Priority?
    var tags: [String]?
    var objectives: [Objective]?
    var comments: [Comment]?
    var intentWhen: String?
    var intentThen: String?
    var lifeArea: String?
    var firstPhysicalAction: String?
    var moveCount: Int
    var completedAt: String?
    var later: Bool
    var recurrence: Recurrence?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case estimateMin = "estimate_min"
        case totalFocused = "total_focused"
        case done, priority, tags, objectives, comments
        case intentWhen = "intent_when"
        case intentThen = "intent_then"
        case lifeArea = "life_area"
        case firstPhysicalAction = "first_physical_action"
        case moveCount = "move_count"
        case completedAt = "completed_at"
        case later, recurrence
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(_ t: TaskItem) {
        id = t.id; name = t.name; estimateMin = t.estimateMin; totalFocused = t.totalFocused
        done = t.done; priority = t.priority; tags = t.tags ?? []; objectives = t.objectives ?? []
        comments = t.comments ?? []; intentWhen = t.intentWhen; intentThen = t.intentThen
        lifeArea = t.lifeArea; firstPhysicalAction = t.firstPhysicalAction; moveCount = t.moveCount ?? 0
        completedAt = t.completedAt; later = t.later ?? false; recurrence = t.recurrence
        createdAt = t.createdAt; updatedAt = t.updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(estimateMin, forKey: .estimateMin)
        try c.encode(totalFocused, forKey: .totalFocused)
        try c.encode(done, forKey: .done)
        try c.encode(priority, forKey: .priority)
        try c.encode(tags, forKey: .tags)
        try c.encode(objectives, forKey: .objectives)
        try c.encode(comments, forKey: .comments)
        try c.encode(intentWhen, forKey: .intentWhen)
        try c.encode(intentThen, forKey: .intentThen)
        try c.encode(lifeArea, forKey: .lifeArea)
        try c.encode(firstPhysicalAction, forKey: .firstPhysicalAction)
        try c.encode(moveCount, forKey: .moveCount)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encode(later, forKey: .later)
        try c.encode(recurrence, forKey: .recurrence)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    func model() -> TaskItem {
        TaskItem(id: id, name: name, estimateMin: estimateMin, totalFocused: totalFocused, done: done,
                 priority: priority, tags: tags, objectives: objectives, comments: comments,
                 intentWhen: intentWhen, intentThen: intentThen, lifeArea: lifeArea,
                 firstPhysicalAction: firstPhysicalAction, moveCount: moveCount, completedAt: completedAt,
                 later: later, recurrence: recurrence, createdAt: createdAt, updatedAt: updatedAt)
    }
}

struct SessionRow: Codable, Sendable {
    var id: String
    var taskId: String?
    var taskName: String
    var tags: [String]?
    var estimateMin: Int?
    var actualSec: Int
    var completedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case taskName = "task_name"
        case tags
        case estimateMin = "estimate_min"
        case actualSec = "actual_sec"
        case completedAt = "completed_at"
    }

    init(_ s: Session) {
        id = s.id; taskId = uuidOrNull(s.taskId); taskName = s.taskName
        tags = s.tags ?? []; estimateMin = s.estimateMin; actualSec = s.actualSec; completedAt = s.completedAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(taskName, forKey: .taskName)
        try c.encode(tags, forKey: .tags)
        try c.encode(estimateMin, forKey: .estimateMin)
        try c.encode(actualSec, forKey: .actualSec)
        try c.encode(completedAt, forKey: .completedAt)
    }

    func model() -> Session {
        Session(id: id, taskId: taskId, taskName: taskName, tags: tags, estimateMin: estimateMin,
                actualSec: actualSec, completedAt: completedAt)
    }
}

struct CalBlockRow: Codable, Sendable {
    var id: String
    var taskId: String?
    var taskName: String
    var startTime: String
    var durationMinutes: Int
    var date: String
    var externalEventId: String?
    var externalConnectionId: String?
    var kind: CalBlockKind

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case taskName = "task_name"
        case startTime = "start_time"
        case durationMinutes = "duration_minutes"
        case date
        case externalEventId = "external_event_id"
        case externalConnectionId = "external_connection_id"
        case kind
    }

    init(_ b: CalBlock) {
        id = b.id; taskId = uuidOrNull(b.taskId); taskName = b.taskName; startTime = b.startTime
        durationMinutes = b.durationMinutes; date = b.date; externalEventId = b.externalEventId
        externalConnectionId = uuidOrNull(b.externalConnectionId); kind = b.kind ?? .task
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(taskName, forKey: .taskName)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(durationMinutes, forKey: .durationMinutes)
        try c.encode(date, forKey: .date)
        try c.encode(externalEventId, forKey: .externalEventId)
        try c.encode(externalConnectionId, forKey: .externalConnectionId)
        try c.encode(kind, forKey: .kind)
    }

    func model() -> CalBlock {
        CalBlock(id: id, taskId: taskId, taskName: taskName, startTime: startTime,
                 durationMinutes: durationMinutes, date: date, externalEventId: externalEventId,
                 externalConnectionId: externalConnectionId, kind: kind)
    }
}

struct CaptureRow: Codable, Sendable {
    var id: String
    var taskId: String?
    var sessionId: String?
    var tag: CaptureTag
    var body: String
    var at: String

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case sessionId = "session_id"
        case tag, body, at
    }

    init(_ c: Capture) {
        id = c.id; taskId = uuidOrNull(c.taskId); sessionId = uuidOrNull(c.sessionId)
        tag = c.tag; body = c.body; at = c.at
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(tag, forKey: .tag)
        try c.encode(body, forKey: .body)
        try c.encode(at, forKey: .at)
    }

    func model() -> Capture {
        Capture(id: id, taskId: taskId, sessionId: sessionId, tag: tag, body: body, at: at)
    }
}

struct ReasonLogRow: Codable, Sendable {
    var id: String
    var taskId: String?
    var reason: String
    var action: ReasonAction
    var at: String
    var durationSec: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case reason, action, at
        case durationSec = "duration_sec"
    }

    init(_ r: ReasonLog) {
        id = r.id; taskId = uuidOrNull(r.taskId); reason = r.reason
        action = r.action; at = r.at; durationSec = r.durationSec
    }

    // duration_sec is OMITTED when nil (the lone encodeIfPresent) so an
    // upsert never clobbers a server-set value — matches the web writer.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(reason, forKey: .reason)
        try c.encode(action, forKey: .action)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(durationSec, forKey: .durationSec)
    }

    func model() -> ReasonLog {
        ReasonLog(id: id, taskId: taskId, reason: reason, action: action, at: at, durationSec: durationSec)
    }
}

struct CollectionRow: Codable, Sendable {
    var id: String
    var name: String
    var color: String
    var subtitle: String?
    var items: [CollectionItem]?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, color, subtitle, items
        case sortOrder = "sort_order"
    }

    init(_ c: ItemCollection) {
        id = c.id; name = c.name; color = c.color; subtitle = c.subtitle ?? ""
        items = c.items; sortOrder = c.sortOrder
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encode(subtitle, forKey: .subtitle)
        try c.encode(items, forKey: .items)
        try c.encode(sortOrder, forKey: .sortOrder)
    }

    func model() -> ItemCollection {
        ItemCollection(id: id, name: name, color: color,
                       subtitle: (subtitle?.isEmpty == true) ? nil : subtitle,
                       items: items ?? [], sortOrder: sortOrder)
    }
}

struct TagDbRow: Codable, Sendable {
    var id: String
    var name: String
    var color: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case sortOrder = "sort_order"
    }

    init(_ t: TagRow) { id = t.id; name = t.name; color = t.color; sortOrder = t.sortOrder }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encode(sortOrder, forKey: .sortOrder)
    }

    func model() -> TagRow { TagRow(id: id, name: name, color: color, sortOrder: sortOrder) }
}

struct LifeAreaDbRow: Codable, Sendable {
    var id: String
    var name: String
    var color: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case sortOrder = "sort_order"
    }

    init(_ a: LifeArea) { id = a.id; name = a.name; color = a.color; sortOrder = a.sortOrder }
    func model() -> LifeArea { LifeArea(id: id, name: name, color: color, sortOrder: sortOrder) }
}

struct CalendarConnectionRow: Codable, Sendable {
    var id: String
    var provider: CalendarProvider
    var accountEmail: String
    var displayName: String
    var selectedCalendarIds: [String]
    var colorSlot: Int
    var lastSyncCursor: String?
    var connectedAt: String

    enum CodingKeys: String, CodingKey {
        case id, provider
        case accountEmail = "account_email"
        case displayName = "display_name"
        case selectedCalendarIds = "selected_calendar_ids"
        case colorSlot = "color_slot"
        case lastSyncCursor = "last_sync_cursor"
        case connectedAt = "connected_at"
    }

    init(_ c: CalendarConnection) {
        id = c.id; provider = c.provider; accountEmail = c.accountEmail; displayName = c.displayName
        selectedCalendarIds = c.selectedCalendarIds; colorSlot = c.colorSlot
        lastSyncCursor = c.lastSyncCursor; connectedAt = c.connectedAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encode(accountEmail, forKey: .accountEmail)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(selectedCalendarIds, forKey: .selectedCalendarIds)
        try c.encode(colorSlot, forKey: .colorSlot)
        try c.encode(lastSyncCursor, forKey: .lastSyncCursor)
        try c.encode(connectedAt, forKey: .connectedAt)
    }

    func model() -> CalendarConnection {
        CalendarConnection(id: id, provider: provider, accountEmail: accountEmail, displayName: displayName,
                           selectedCalendarIds: selectedCalendarIds, colorSlot: colorSlot,
                           lastSyncCursor: lastSyncCursor, connectedAt: connectedAt)
    }
}
