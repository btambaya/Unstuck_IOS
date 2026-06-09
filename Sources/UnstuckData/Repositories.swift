// Thin repositories over the local store. Reads expose GRDB
// ValueObservation so SwiftUI views update reactively; writes are
// optimistic upserts (the sync layer enqueues the matching outbox op
// alongside). TaskRepository is the worked example; the other entities
// follow the identical shape.

import Foundation
import GRDB
import UnstuckCore

/// Generic read/observe repository for any synced entity. Writes go
/// through WriteThrough (UnstuckSync); this is the read side the SwiftUI
/// surfaces observe.
public struct Repository<Row: FetchableRecord & PersistableRecord & TableRecord & Sendable>: Sendable {
    let db: AppDatabase
    let orderColumn: String

    public init(_ db: AppDatabase, orderColumn: String) {
        self.db = db
        self.orderColumn = orderColumn
    }

    public func all() throws -> [Row] {
        try db.writer.read { try Row.order(Column(orderColumn)).fetchAll($0) }
    }

    public func observeValues() -> AsyncValueObservation<[Row]> {
        let col = orderColumn
        return ValueObservation.tracking { try Row.order(Column(col)).fetchAll($0) }.values(in: db.writer)
    }
}

public struct TaskRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func upsert(_ task: TaskItem) throws {
        try db.writer.write { try task.upsert($0) }
    }

    public func all() throws -> [TaskItem] {
        try db.writer.read { try TaskItem.order(Column("createdAt")).fetchAll($0) }
    }

    public func fetch(id: String) throws -> TaskItem? {
        try db.writer.read { try TaskItem.fetchOne($0, key: id) }
    }

    public func delete(id: String) throws {
        _ = try db.writer.write { try TaskItem.deleteOne($0, key: id) }
    }

    /// Live stream of all tasks (createdAt order) for the UI.
    public func observeAll() -> ValueObservation<ValueReducers.Fetch<[TaskItem]>> {
        ValueObservation.tracking { db in
            try TaskItem.order(Column("createdAt")).fetchAll(db)
        }
    }

    /// Async sequence of all-tasks snapshots — convenient for SwiftUI
    /// `.task { for await tasks in repo.observeAllValues() { ... } }`.
    public func observeAllValues() -> AsyncValueObservation<[TaskItem]> {
        observeAll().values(in: db.writer)
    }

    /// Tasks + cal_blocks + life_areas + sessions in one tracked snapshot.
    /// The list needs blocks to bucket Backlog/Today/Upcoming exactly
    /// (visibleTasks), and areas/sessions must be tracked too so an area
    /// rename in Areas & Tags or a session arriving via realtime refreshes
    /// the filter pills and the week-focused stat — not just task edits.
    public func observeTasksAndBlocks() -> AsyncValueObservation<TasksAndBlocks> {
        ValueObservation.tracking { db in
            TasksAndBlocks(
                tasks: try TaskItem.order(Column("createdAt")).fetchAll(db),
                blocks: try CalBlock.fetchAll(db),
                areas: try LifeArea.order(Column("sortOrder")).fetchAll(db),
                sessions: try Session.order(Column("completedAt")).fetchAll(db))
        }.values(in: db.writer)
    }

    /// Everything the ReminderScheduler re-syncs on: blocks + tasks (the
    /// alarm inputs) AND the live focus session — so completing a task or
    /// starting Focus on it cancels its pending ATSTART/DRIFTED requests
    /// (spec 10 gotcha 8 inversion). Mirrors Android's
    /// `store.blocks() combine store.tasks()` observe loop.
    public func observeReminderInputs() -> AsyncValueObservation<ReminderInputs> {
        ValueObservation.tracking { db in
            let payload = try String.fetchOne(
                db, sql: "SELECT payload FROM live_session WHERE slot = 'current'")
            let live = payload.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(LiveSession.self, from: $0) }
            return ReminderInputs(
                tasks: try TaskItem.fetchAll(db),
                blocks: try CalBlock.fetchAll(db),
                liveTaskId: live?.sessionStart != nil ? live?.taskId : nil)
        }.values(in: db.writer)
    }
}

public struct ReminderInputs: Sendable {
    public let tasks: [TaskItem]
    public let blocks: [CalBlock]
    public let liveTaskId: String?
}

public struct TasksAndBlocks: Sendable {
    public let tasks: [TaskItem]
    public let blocks: [CalBlock]
    public let areas: [LifeArea]
    public let sessions: [Session]
}
