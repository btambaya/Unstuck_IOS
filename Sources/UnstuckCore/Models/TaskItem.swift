// The central task entity. Web name: `Task` (lib/types.ts) — renamed
// here to `TaskItem` so it never collides with Swift Concurrency's
// `Task` type in the rest of the app.

import Foundation

public struct TaskItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var estimateMin: Int
    public var totalFocused: Int
    public var done: Bool
    public var priority: Priority?
    public var tags: [String]?
    public var objectives: [Objective]?
    public var comments: [Comment]?
    public var intentWhen: String?
    public var intentThen: String?
    public var lifeArea: String?
    public var firstPhysicalAction: String?
    /// Number of times this task has been rescheduled (slip detector).
    public var moveCount: Int?
    /// ISO timestamp the first time `done` flipped false → true. Stays
    /// set on subsequent toggles so we don't lose history.
    public var completedAt: String?
    /// Migration 008 — explicit "deferred" flag. True = parked in Later.
    public var later: Bool?
    /// Migration 008 — repeating schedule. `nil` = does not repeat.
    public var recurrence: Recurrence?
    public var createdAt: String
    public var updatedAt: String
    // Move-to-task / accountability (migration 025). Set when this task was promoted
    // from a shared collection item, so completion/lateness flows back to everyone.
    public var sourceCollectionId: String?
    public var sourceItemId: String?
    /// ISO "by" time for a keep-everyone-in-the-loop promotion.
    public var dueAt: String?

    public init(
        id: String,
        name: String,
        estimateMin: Int,
        totalFocused: Int = 0,
        done: Bool = false,
        priority: Priority? = nil,
        tags: [String]? = nil,
        objectives: [Objective]? = nil,
        comments: [Comment]? = nil,
        intentWhen: String? = nil,
        intentThen: String? = nil,
        lifeArea: String? = nil,
        firstPhysicalAction: String? = nil,
        moveCount: Int? = nil,
        completedAt: String? = nil,
        later: Bool? = nil,
        recurrence: Recurrence? = nil,
        createdAt: String,
        updatedAt: String,
        sourceCollectionId: String? = nil,
        sourceItemId: String? = nil,
        dueAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.estimateMin = estimateMin
        self.totalFocused = totalFocused
        self.done = done
        self.priority = priority
        self.tags = tags
        self.objectives = objectives
        self.comments = comments
        self.intentWhen = intentWhen
        self.intentThen = intentThen
        self.lifeArea = lifeArea
        self.firstPhysicalAction = firstPhysicalAction
        self.moveCount = moveCount
        self.completedAt = completedAt
        self.later = later
        self.recurrence = recurrence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceCollectionId = sourceCollectionId
        self.sourceItemId = sourceItemId
        self.dueAt = dueAt
    }
}
