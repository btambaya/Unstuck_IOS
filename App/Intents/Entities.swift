// App Intent entities — let Siri resolve a spoken name ("Groceries", "the taxes
// task") to a real id, with disambiguation when several match. Backed by the
// App-Group UnstuckSnapshot the app keeps current (no DB access from the intent
// process). Used by the write/query intents (add-to-list, complete, count).

import AppIntents
import UnstuckShared

// MARK: - Collections

struct CollectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "List")
    static let defaultQuery = CollectionEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CollectionEntityQuery: EntityQuery, EntityStringQuery {
    /// Resolve by id (Shortcuts re-hydrating a saved parameter).
    func entities(for identifiers: [String]) async throws -> [CollectionEntity] {
        let ids = Set(identifiers)
        return AppGroup.readSnapshot().collections
            .filter { ids.contains($0.id) }
            .map { CollectionEntity(id: $0.id, name: $0.name) }
    }

    /// Match a spoken/typed name (case-insensitive contains) → Siri picks or
    /// disambiguates among the results.
    func entities(matching string: String) async throws -> [CollectionEntity] {
        let q = string.lowercased()
        return AppGroup.readSnapshot().collections
            .filter { $0.name.lowercased().contains(q) }
            .map { CollectionEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [CollectionEntity] {
        AppGroup.readSnapshot().collections.map { CollectionEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - Tasks

struct TaskEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task")
    static let defaultQuery = TaskEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TaskEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        let ids = Set(identifiers)
        return AppGroup.readSnapshot().tasks
            .filter { ids.contains($0.id) }
            .map { TaskEntity(id: $0.id, name: $0.name) }
    }

    func entities(matching string: String) async throws -> [TaskEntity] {
        let q = string.lowercased()
        return AppGroup.readSnapshot().tasks
            .filter { $0.name.lowercased().contains(q) }
            .map { TaskEntity(id: $0.id, name: $0.name) }
    }

    /// Surface today's tasks first as suggestions (most likely targets).
    func suggestedEntities() async throws -> [TaskEntity] {
        let tasks = AppGroup.readSnapshot().tasks
        let ordered = tasks.filter { $0.today } + tasks.filter { !$0.today }
        return ordered.map { TaskEntity(id: $0.id, name: $0.name) }
    }
}
