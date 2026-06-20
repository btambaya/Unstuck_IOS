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
    /// True between `end()` and the next `start()`. While ending, `update()`
    /// no-ops: the update + end Tasks are unordered, so a rapid pause→finish
    /// could otherwise deliver a stale `update` AFTER the `end` and flash a
    /// ghost frame on the lock screen / Dynamic Island.
    private var ending = false

    /// (activityId, hex push token) — set by AppModel to register the token.
    var onPushToken: ((String, String) -> Void)?

    /// A focus Live Activity that out-stays the session by this long fades
    /// itself out — the backstop so a killed/crashed app can't leave a ghost
    /// timer running forever (it also gets reaped on next launch via
    /// `reapOrphans`). Generous so a long legitimate session never goes stale.
    private static let staleAfter: TimeInterval = 12 * 60 * 60

    private func staleDate(for sessionStartMs: Double) -> Date {
        Date(timeIntervalSince1970: sessionStartMs / 1000).addingTimeInterval(Self.staleAfter)
    }

    func start(taskName: String, sessionStartMs: Double, estimateMin: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        ending = false   // a new session re-opens the lifecycle window
        let attributes = FocusSessionAttributes(taskName: taskName)
        let state = FocusSessionAttributes.ContentState(
            startedAt: Date(timeIntervalSince1970: sessionStartMs / 1000), paused: false, estimateMin: estimateMin)
        activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: staleDate(for: sessionStartMs)),
            pushType: .token)
        observePushToken()
    }

    /// Reap orphaned focus Live Activities left over from a previous run (app
    /// killed/crashed mid-session). Call on launch/foreground: if the live
    /// session store still has an active session, REBIND to its activity so
    /// updates keep working; otherwise END every dangling activity so no ghost
    /// timer survives. (`activity == nil` after a relaunch means `end()` alone
    /// would no-op and a fresh `start()` wouldn't clear the orphan.)
    func reapOrphans(hasActiveSession: Bool) {
        let live = Activity<FocusSessionAttributes>.activities
        guard !live.isEmpty else { return }
        if hasActiveSession, activity == nil, let first = live.first {
            // Rebind to the surviving activity (keep its push-token stream) and
            // end any extras so only one remains.
            activity = first
            ending = false
            observePushToken()
            for a in live.dropFirst() {
                Task { await a.end(nil, dismissalPolicy: .immediate) }
            }
        } else if !hasActiveSession {
            for a in live {
                Task { await a.end(nil, dismissalPolicy: .immediate) }
            }
            activity = nil
        }
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
        // Drop updates once we've started ending: an in-flight update delivered
        // after the end would resurrect a stale frame.
        guard !ending, let activity else { return }
        let state = FocusSessionAttributes.ContentState(
            startedAt: Date(timeIntervalSince1970: sessionStartMs / 1000), paused: paused, estimateMin: estimateMin)
        Task { await activity.update(ActivityContent(state: state, staleDate: staleDate(for: sessionStartMs))) }
    }

    func end() {
        tokenTask?.cancel(); tokenTask = nil
        guard let finished = activity else { return }
        // Latch ending BEFORE clearing `activity` so any update() racing in now
        // no-ops; cleared by the next start().
        ending = true
        activity = nil
        Task { await finished.end(nil, dismissalPolicy: .immediate) }
    }
}
