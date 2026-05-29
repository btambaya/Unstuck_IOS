// Starts / updates / ends the focus Live Activity (Dynamic Island + lock
// screen). The timer self-ticks in the widget via Text(timerInterval:),
// so we only push state transitions (start / pause / resume / end). Local
// updates only; APNs push-to-update is a later backstop.

import Foundation
import ActivityKit
import UnstuckShared

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<FocusSessionAttributes>?

    func start(taskName: String, sessionStartMs: Double, estimateMin: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = FocusSessionAttributes(taskName: taskName)
        let state = FocusSessionAttributes.ContentState(
            startedAt: Date(timeIntervalSince1970: sessionStartMs / 1000), paused: false, estimateMin: estimateMin)
        activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil)
    }

    func update(sessionStartMs: Double, paused: Bool, estimateMin: Int) {
        guard let activity else { return }
        let state = FocusSessionAttributes.ContentState(
            startedAt: Date(timeIntervalSince1970: sessionStartMs / 1000), paused: paused, estimateMin: estimateMin)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        guard let finished = activity else { return }
        Task { await finished.end(nil, dismissalPolicy: .immediate) }
        activity = nil
    }
}
