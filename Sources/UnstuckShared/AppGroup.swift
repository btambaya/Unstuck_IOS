// Shared between the app and the widget / Live-Activity extension. The app
// writes a small snapshot to the App Group container on task changes; the
// widget + lock-screen read it. Keeping this dependency-free (Foundation
// only) keeps the widget extension lean.

import Foundation

/// The "Start Next" snapshot the home/lock widgets render.
public struct StartNextSnapshot: Codable, Sendable, Equatable {
    public var taskName: String?
    public var estimateMin: Int?
    public var lifeArea: String?
    public var openCount: Int
    /// Id of the shown task — lets the widget's Complete button target it.
    /// Optional (older payloads decode with nil) so it's backward-compatible.
    public var taskId: String?
    public var updatedAt: Date

    public init(taskName: String?, estimateMin: Int?, lifeArea: String?, openCount: Int,
                taskId: String? = nil, updatedAt: Date) {
        self.taskName = taskName
        self.estimateMin = estimateMin
        self.lifeArea = lifeArea
        self.openCount = openCount
        self.taskId = taskId
        self.updatedAt = updatedAt
    }

    public static let empty = StartNextSnapshot(
        taskName: nil, estimateMin: nil, lifeArea: nil, openCount: 0,
        taskId: nil, updatedAt: Date(timeIntervalSince1970: 0))
}

/// Richer snapshot the Siri layer reads — counts + the open-task and list names
/// the "ask" intents speak and the App Intent entities resolve against. Written
/// by the app (AppModel.refreshWidgetSnapshot) on launch, every foreground sync,
/// background-entry, and the BG-refresh task. Distinct from StartNextSnapshot so
/// the widget's small payload stays unchanged. Foundation-only.
public struct UnstuckSnapshot: Codable, Sendable, Equatable {
    /// An open task — id lets a write intent (complete) target it later.
    public struct TaskRef: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var today: Bool
        public init(id: String, name: String, today: Bool) {
            self.id = id; self.name = name; self.today = today
        }
    }
    /// A non-archived list/collection + its count of un-handled items.
    public struct CollectionRef: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var openCount: Int
        public init(id: String, name: String, openCount: Int) {
            self.id = id; self.name = name; self.openCount = openCount
        }
    }
    public var pendingCount: Int          // open, actionable, non-template tasks
    public var todayCount: Int            // Today bucket (incl. today's occurrences)
    public var overdueCount: Int          // slipping backlog items
    public var nextTaskName: String?
    public var nextEstimateMin: Int?
    public var tasks: [TaskRef]           // open tasks (capped), for entity resolution
    public var collections: [CollectionRef]
    public var updatedAt: Date

    public init(pendingCount: Int, todayCount: Int, overdueCount: Int,
                nextTaskName: String?, nextEstimateMin: Int?,
                tasks: [TaskRef], collections: [CollectionRef], updatedAt: Date) {
        self.pendingCount = pendingCount
        self.todayCount = todayCount
        self.overdueCount = overdueCount
        self.nextTaskName = nextTaskName
        self.nextEstimateMin = nextEstimateMin
        self.tasks = tasks
        self.collections = collections
        self.updatedAt = updatedAt
    }

    public static let empty = UnstuckSnapshot(
        pendingCount: 0, todayCount: 0, overdueCount: 0,
        nextTaskName: nil, nextEstimateMin: nil, tasks: [], collections: [],
        updatedAt: Date(timeIntervalSince1970: 0))
}

/// A hands-free write a Siri intent queued while the app was closed. The app
/// drains these into its REAL outbox (via the validated AppModel mutators) on
/// next launch / foreground / background-entry / BG-refresh — one write
/// authority, so no row/sync logic is duplicated in the intent process. Eventual
/// consistency: the op lands when the app next runs. Foundation-only; fields are
/// interpreted per `kind`.
public struct PendingWrite: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case createTask     // text = name, estimateMin?
        case completeTask   // taskId
        case addToList      // collectionId, text = item body
        case capture        // text = body
    }
    public var id: String          // client op id (idempotent drain)
    public var kind: Kind
    public var text: String?
    public var taskId: String?
    public var collectionId: String?
    public var estimateMin: Int?
    public var createdAt: Date

    public init(id: String, kind: Kind, text: String? = nil, taskId: String? = nil,
                collectionId: String? = nil, estimateMin: Int? = nil, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.text = text
        self.taskId = taskId
        self.collectionId = collectionId
        self.estimateMin = estimateMin
        self.createdAt = createdAt
    }
}

public enum AppGroup {
    public static let id = "group.io.unstucknow.app"
    private static let startNextKey = "startNextSnapshot"
    private static let focusFilterKey = "focusFilter.hideNonToday"
    private static let pendingRouteKey = "siri.pendingRoute"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: id) }

    // MARK: Siri / App-Intent → app hand-off.
    //
    // An "open the app" App Intent (Add task, Start focus, …) runs in a
    // separate process and cannot drive SwiftUI navigation — and a background
    // `perform()` is documented-flaky (see WorkFocusFilter). So the intent
    // writes a deep-link-style route here and returns; the app consumes it on
    // the next launch / scenePhase=.active, the SAME reconcile-on-active pattern
    // the Work Focus Filter already relies on. One-shot: read clears it.
    public static func setPendingRoute(_ route: String?) {
        guard let defaults else { return }
        if let route { defaults.set(route, forKey: pendingRouteKey) }
        else { defaults.removeObject(forKey: pendingRouteKey) }
    }
    /// Read AND clear the pending route (so it routes exactly once).
    public static func consumePendingRoute() -> String? {
        guard let defaults, let route = defaults.string(forKey: pendingRouteKey) else { return nil }
        defaults.removeObject(forKey: pendingRouteKey)
        return route
    }

    // The freeform "Ask Unstuck …" prompt the assistant route carries.
    private static let assistantPromptKey = "siri.assistantPrompt"
    public static func setPendingAssistantPrompt(_ prompt: String?) {
        guard let defaults else { return }
        if let prompt { defaults.set(prompt, forKey: assistantPromptKey) }
        else { defaults.removeObject(forKey: assistantPromptKey) }
    }
    public static func consumePendingAssistantPrompt() -> String? {
        guard let defaults, let p = defaults.string(forKey: assistantPromptKey) else { return nil }
        defaults.removeObject(forKey: assistantPromptKey)
        return p
    }
    /// Peek without clearing — used to decide whether the app is ready to route
    /// (so a cold-launch race doesn't drop the route before repos exist).
    public static func hasPendingRoute() -> Bool {
        defaults?.string(forKey: pendingRouteKey) != nil
    }

    // MARK: Focus Filter state (set by the Work Focus Filter intent; the
    // app reads it to pare the UI down while a Work Focus is on).
    public static func setFocusFilter(hideNonToday: Bool?) {
        guard let defaults else { return }
        if let value = hideNonToday { defaults.set(value, forKey: focusFilterKey) }
        else { defaults.removeObject(forKey: focusFilterKey) }
    }
    public static func focusFilterActive() -> Bool { defaults?.object(forKey: focusFilterKey) != nil }
    public static func focusFilterHideNonToday() -> Bool { defaults?.bool(forKey: focusFilterKey) ?? false }

    public static func writeStartNext(_ snapshot: StartNextSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: startNextKey)
    }

    public static func readStartNext() -> StartNextSnapshot {
        guard let defaults,
              let data = defaults.data(forKey: startNextKey),
              let snapshot = try? JSONDecoder().decode(StartNextSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    // MARK: enriched Siri snapshot
    private static let snapshotKey = "unstuckSnapshot"

    public static func writeSnapshot(_ snapshot: UnstuckSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    public static func readSnapshot() -> UnstuckSnapshot {
        guard let defaults,
              let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(UnstuckSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    // MARK: hands-free write queue (Siri → app handoff)
    private static let writeQueueKey = "siri.writeQueue"

    /// Append a Siri-queued write. Re-reads the current queue so a concurrent
    /// append by the app's drain isn't clobbered.
    public static func enqueueWrite(_ op: PendingWrite) {
        guard let defaults else { return }
        var queue = readWriteQueue()
        queue.append(op)
        if let data = try? JSONEncoder().encode(queue) { defaults.set(data, forKey: writeQueueKey) }
    }

    public static func readWriteQueue() -> [PendingWrite] {
        guard let defaults,
              let data = defaults.data(forKey: writeQueueKey),
              let queue = try? JSONDecoder().decode([PendingWrite].self, from: data)
        else { return [] }
        return queue
    }

    /// Remove the ops the app has applied — re-reads first so an op the intent
    /// appended between the drain's read and this call survives.
    public static func removeWrites(ids: Set<String>) {
        guard let defaults else { return }
        let remaining = readWriteQueue().filter { !ids.contains($0.id) }
        if remaining.isEmpty { defaults.removeObject(forKey: writeQueueKey) }
        else if let data = try? JSONEncoder().encode(remaining) {
            defaults.set(data, forKey: writeQueueKey)
        }
    }

    /// Optimistically reflect a widget "Complete" tap in BOTH snapshots so the
    /// tile updates immediately (the queued op + the app's drain are the source
    /// of truth; this just avoids a stale "still there" flash until the app
    /// reconciles). Drops the task, decrements counts, advances Start-Next.
    public static func optimisticComplete(taskId: String) {
        var snap = readSnapshot()
        let wasToday = snap.tasks.first { $0.id == taskId }?.today ?? false
        snap.tasks.removeAll { $0.id == taskId }
        snap.pendingCount = max(0, snap.pendingCount - 1)
        if wasToday { snap.todayCount = max(0, snap.todayCount - 1) }
        snap.nextTaskName = snap.tasks.first?.name
        snap.nextEstimateMin = nil
        writeSnapshot(snap)

        var widget = readStartNext()
        if widget.taskId == taskId {
            widget.taskName = snap.tasks.first?.name
            widget.taskId = snap.tasks.first?.id
            widget.estimateMin = nil
            widget.lifeArea = nil
        }
        widget.openCount = max(0, widget.openCount - 1)
        writeStartNext(widget)
    }
}
