// Thin repositories over the local store. Reads expose GRDB
// ValueObservation so SwiftUI views update reactively; writes are
// optimistic upserts (the sync layer enqueues the matching outbox op
// alongside). TaskRepository is the worked example; the other entities
// follow the identical shape.

import Foundation
import GRDB
import UnstuckCore

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
}
