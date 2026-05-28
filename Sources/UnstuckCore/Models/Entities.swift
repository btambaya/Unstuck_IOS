// Remaining domain entities. Mirror lib/types.ts.

import Foundation

public struct Session: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskId: String?
    public var taskName: String
    public var tags: [String]?
    public var estimateMin: Int?
    public var actualSec: Int
    public var completedAt: String

    public init(id: String, taskId: String? = nil, taskName: String, tags: [String]? = nil, estimateMin: Int? = nil, actualSec: Int, completedAt: String) {
        self.id = id
        self.taskId = taskId
        self.taskName = taskName
        self.tags = tags
        self.estimateMin = estimateMin
        self.actualSec = actualSec
        self.completedAt = completedAt
    }
}

public struct CalBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Nullable since migration 009 — "Block time" events carry no task.
    /// Use `isTaskBlock(_:)` to gate task operations rather than checking
    /// taskId directly.
    public var taskId: String?
    public var taskName: String
    public var startTime: String      // 'HH:MM'
    public var durationMinutes: Int
    public var date: String           // 'YYYY-MM-DD'
    public var externalEventId: String?
    public var externalConnectionId: String?
    /// Backed by migration 006; falls back to a derived kind in
    /// `blockKind(_:)` when the column isn't populated.
    public var kind: CalBlockKind?

    public init(id: String, taskId: String?, taskName: String, startTime: String, durationMinutes: Int, date: String, externalEventId: String? = nil, externalConnectionId: String? = nil, kind: CalBlockKind? = nil) {
        self.id = id
        self.taskId = taskId
        self.taskName = taskName
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.date = date
        self.externalEventId = externalEventId
        self.externalConnectionId = externalConnectionId
        self.kind = kind
    }
}

public struct ReasonLog: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskId: String?
    public var reason: String
    public var action: ReasonAction
    public var at: String
    /// Seconds spent on this reason before resolving the pause.
    public var durationSec: Int?

    public init(id: String, taskId: String? = nil, reason: String, action: ReasonAction, at: String, durationSec: Int? = nil) {
        self.id = id
        self.taskId = taskId
        self.reason = reason
        self.action = action
        self.at = at
        self.durationSec = durationSec
    }
}

public struct Capture: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskId: String?
    public var sessionId: String?
    public var tag: CaptureTag
    public var body: String
    public var at: String

    public init(id: String, taskId: String? = nil, sessionId: String? = nil, tag: CaptureTag, body: String, at: String) {
        self.id = id
        self.taskId = taskId
        self.sessionId = sessionId
        self.tag = tag
        self.body = body
        self.at = at
    }
}

public struct CalendarConnection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: CalendarProvider
    public var accountEmail: String
    public var displayName: String
    public var selectedCalendarIds: [String]
    public var colorSlot: Int         // 0..5, maps to palette
    public var lastSyncCursor: String?
    public var connectedAt: String

    public init(id: String, provider: CalendarProvider, accountEmail: String, displayName: String, selectedCalendarIds: [String], colorSlot: Int, lastSyncCursor: String? = nil, connectedAt: String) {
        self.id = id
        self.provider = provider
        self.accountEmail = accountEmail
        self.displayName = displayName
        self.selectedCalendarIds = selectedCalendarIds
        self.colorSlot = colorSlot
        self.lastSyncCursor = lastSyncCursor
        self.connectedAt = connectedAt
    }
}

public struct ExternalEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var connectionId: String
    public var calendarId: String
    public var summary: String
    public var start: String          // ISO
    public var end: String            // ISO

    public init(id: String, connectionId: String, calendarId: String, summary: String, start: String, end: String) {
        self.id = id
        self.connectionId = connectionId
        self.calendarId = calendarId
        self.summary = summary
        self.start = start
        self.end = end
    }
}

/// Live focus session, persisted on every pause/start so a reload
/// survives. Device-local (not synced) — mirrors the web `unstuck-session`
/// localStorage record.
public struct LiveSession: Codable, Equatable, Sendable {
    /// Stable id for THIS live session — minted on start() and reused by
    /// every Capture created during the session. Cleared on done()/cancel().
    public var id: String?
    public var taskId: String
    public var sessionStart: Double?   // epoch ms
    public var paused: Bool
    public var pausedAt: Double?        // epoch ms
    public var sessionEstimateMin: Int
    public var nudge80Fired: Bool
    public var overrunPromptFired: Bool
    public var treatment: FocusTreatment
    /// Seconds of cumulative focus this task already had at session start.
    public var priorAccumulatedSec: Int?

    public init(id: String?, taskId: String, sessionStart: Double? = nil, paused: Bool = false, pausedAt: Double? = nil, sessionEstimateMin: Int, nudge80Fired: Bool = false, overrunPromptFired: Bool = false, treatment: FocusTreatment, priorAccumulatedSec: Int? = nil) {
        self.id = id
        self.taskId = taskId
        self.sessionStart = sessionStart
        self.paused = paused
        self.pausedAt = pausedAt
        self.sessionEstimateMin = sessionEstimateMin
        self.nudge80Fired = nudge80Fired
        self.overrunPromptFired = overrunPromptFired
        self.treatment = treatment
        self.priorAccumulatedSec = priorAccumulatedSec
    }
}
