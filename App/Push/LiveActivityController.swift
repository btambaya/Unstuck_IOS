// Starts / updates / ends the focus Live Activity (Dynamic Island + lock
// screen). The timer self-ticks in the widget via Text(timerInterval:),
// so we only push state transitions (start / pause / resume / end)
// locally. The per-activity APNs push token is captured + handed to
// `onPushToken` so the server can update it as a backstop when the app is
// suspended/killed.

import Foundation
import ActivityKit
import UnstuckShared

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<FocusSessionAttributes>?
    private var tokenTask: Task<Void, Never>?

    /// (activityId, hex push token) — set by AppModel to register the token.
    var onPushToken: ((String, String) -> Void)?

    func start(taskName: String, sessionStartMs: Double, estimateMin: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = FocusSessionAttributes(taskName: taskName)
        let state = FocusSessionAttributes.ContentState(
            startedAt: Date(timeIntervalSince1970: sessionStartMs / 1000), paused: false, estimateMin: estimateMin)
        activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: .token)
        observePushToken()
    }

    private func observePushToken() {
        tokenTask?.cancel()
        guard let activity else { return }
        let id = activity.id
        if #available(iOS 17.2, *) {
            tokenTask = Task { [weak self] in
                for await tokenData in activity.pushTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    await MainActor.run { self?.onPushToken?(id, hex) }
                }
            }
        }
    }

    func update(sessionStartMs: Double, paused: Bool, estimateMin: Int) {
        guard let activity else { return }
        let state = FocusSessionAttributes.ContentState(
            startedAt: Date(timeIntervalSince1970: sessionStartMs / 1000), paused: paused, estimateMin: estimateMin)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        tokenTask?.cancel(); tokenTask = nil
        guard let finished = activity else { return }
        Task { await finished.end(nil, dismissalPolicy: .immediate) }
        activity = nil
    }
}
