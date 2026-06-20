// Today live-session controls — the inline Pause/Resume on the Today
// LiveSessionCard (Android AppViewModel.pauseFocus / resumeFocus). These mutate
// the persisted live session directly (the Focus screen re-reads the store when
// reopened, so the timer keeps counting true focus time) and mirror
// FocusModel.pause / resume: the same FocusTimer transition + LiveActivity
// update + paused-check-in coordination.
//
// Extension only — methods + a computed accessor, no stored properties (the
// live session lives in liveStore; nudge dismissals persist in UserDefaults
// from the Today view).

import Foundation
import UnstuckCore
import UnstuckData

extension AppModel {
    /// The persisted live focus session, or nil when idle. Lets Today render the
    /// LiveSessionCard (progress ring + elapsed + Pause/Resume) without owning a
    /// FocusModel. Mirrors Android `vm.liveSession`.
    var liveSession: LiveSession? { (try? liveStore?.get()) ?? nil }

    /// Pause the running live session from Today (Android `pauseFocus`). Persists
    /// the paused state, freezes the Live Activity, and pre-schedules the
    /// paused-too-long check-in (coordinated against the daily cap, like the
    /// in-Focus Pause button — cancelled if the server declines).
    func pauseFocus() {
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil,
              cur.sessionStart != nil, !cur.paused else { return }
        let paused = FocusTimer.pause(cur, now: Date().timeIntervalSince1970 * 1000)
        try? liveStore.set(paused)
        LiveActivityController.shared.update(
            sessionStartMs: paused.sessionStart ?? 0, paused: true,
            estimateMin: paused.sessionEstimateMin)
        let taskName = ((try? taskRepo?.fetch(id: paused.taskId)) ?? nil)?.name ?? "your task"
        PausedCheckinScheduler.schedule(taskName: taskName)
        requestPausedCheckin { allowed in
            if !allowed { PausedCheckinScheduler.cancel() }
        }
    }

    /// Reap focus Live Activities left dangling by a kill/crash mid-session.
    /// If the persisted live session is still active, the controller rebinds to
    /// its activity (so updates keep flowing); otherwise it ends every orphan so
    /// no ghost lock-screen timer survives. Called on launch + foreground.
    func reapStaleLiveActivities() {
        let active = ((try? liveStore?.get()) ?? nil)?.sessionStart != nil
        LiveActivityController.shared.reapOrphans(hasActiveSession: active)
    }

    /// Resume the paused live session from Today (Android `resumeFocus`). Shifts
    /// sessionStart by the pause gap (so elapsed continues, not double-counts),
    /// un-freezes the Live Activity, and cancels the pending paused check-in.
    func resumeFocus() {
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil, cur.paused else { return }
        let resumed = FocusTimer.resume(cur, now: Date().timeIntervalSince1970 * 1000)
        try? liveStore.set(resumed)
        LiveActivityController.shared.update(
            sessionStartMs: resumed.sessionStart ?? 0, paused: false,
            estimateMin: resumed.sessionEstimateMin)
        PausedCheckinScheduler.cancel()
    }
}
