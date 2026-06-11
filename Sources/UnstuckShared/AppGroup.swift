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
    public var updatedAt: Date

    public init(taskName: String?, estimateMin: Int?, lifeArea: String?, openCount: Int, updatedAt: Date) {
        self.taskName = taskName
        self.estimateMin = estimateMin
        self.lifeArea = lifeArea
        self.openCount = openCount
        self.updatedAt = updatedAt
    }

    public static let empty = StartNextSnapshot(
        taskName: nil, estimateMin: nil, lifeArea: nil, openCount: 0,
        updatedAt: Date(timeIntervalSince1970: 0))
}

public enum AppGroup {
    public static let id = "group.io.unstucknow.app"
    private static let startNextKey = "startNextSnapshot"
    private static let focusFilterKey = "focusFilter.hideNonToday"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: id) }

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
}
