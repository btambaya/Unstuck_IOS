// Live Activity attributes for a focus session — shared so the app starts/
// updates the activity and the widget extension renders it. ActivityKit is
// iOS-only, so this is gated for cross-platform (macOS test) builds.

#if os(iOS)
import ActivityKit
import Foundation

public struct FocusSessionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var startedAt: Date     // for Text(timerInterval:) self-ticking
        public var paused: Bool
        public var estimateMin: Int
        public init(startedAt: Date, paused: Bool, estimateMin: Int) {
            self.startedAt = startedAt
            self.paused = paused
            self.estimateMin = estimateMin
        }
    }

    public var taskName: String
    public init(taskName: String) { self.taskName = taskName }
}
#endif
