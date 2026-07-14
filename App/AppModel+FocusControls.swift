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
    /// The live focus session, or nil when idle. Lets Today render the
    /// LiveSessionCard (progress ring + elapsed + Pause/Resume) without owning a
    /// FocusModel. Mirrors Android `vm.liveSession`. Reads the in-memory cache
    /// (kept current by `refreshLiveSession`) so the 1s LiveSessionCard tick
    /// doesn't hit the GRDB store + a fresh JSONDecoder every second.
    var liveSession: LiveSession? { cachedLiveSession }

    /// Pause the running live session from Today (Android `pauseFocus`). Persists
    /// the paused state, freezes the Live Activity, and pre-schedules the
    /// paused-too-long check-in (coordinated against the daily cap, like the
    /// in-Focus Pause button — cancelled if the server declines).
    func pauseFocus() {
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil,
              cur.sessionStart != nil, !cur.paused else { return }
        let paused = FocusTimer.pause(cur, now: Date().timeIntervalSince1970 * 1000)
        try? liveStore.set(paused)
        refreshLiveSession()
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
        let cur = (try? liveStore?.get()) ?? nil
        // A SHARED live session with NO Focus screen currently up is an ORPHAN:
        // it's a recipient's focus on a task they don't own, so Today can't
        // resolve/resume it (no local row) — leaving it live would let a later
        // focus dump the whole app-closed time onto the OWNER (T2). Finalize it
        // here — accrue the CAPPED elapsed onto the owner (idempotent per session
        // id, migration 046) — and end its Live Activity rather than rebind a
        // timer nobody can return to. When the shared Focus screen IS up
        // (router.focusTask set), it still owns the session; leave it running.
        if let cur, cur.sessionStart != nil, let level = cur.sharedFocusLevel,
           levelCanComplete(level), router.focusTask == nil {
            let raw = FocusTimer.elapsedSec(cur, now: Date().timeIntervalSince1970 * 1000)
            let capped = AppModel.cappedSharedElapsedSec(rawSec: raw, estimateMin: cur.sessionEstimateMin)
            let (taskId, sessionId) = (cur.taskId, cur.id ?? newUUID())
            try? liveStore?.set(nil)
            refreshLiveSession()
            Task { await shareState.logSharedFocus(taskId: taskId, actualSec: capped, sessionId: sessionId) }
            LiveActivityController.shared.reapOrphans(hasActiveSession: false)
            return
        }
        LiveActivityController.shared.reapOrphans(hasActiveSession: cur?.sessionStart != nil)
    }

    /// Resume the paused live session from Today (Android `resumeFocus`). Shifts
    /// sessionStart by the pause gap (so elapsed continues, not double-counts),
    /// un-freezes the Live Activity, and cancels the pending paused check-in.
    func resumeFocus() {
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil, cur.paused else { return }
        let resumed = FocusTimer.resume(cur, now: Date().timeIntervalSince1970 * 1000)
        try? liveStore.set(resumed)
        refreshLiveSession()
        LiveActivityController.shared.update(
            sessionStartMs: resumed.sessionStart ?? 0, paused: false,
            estimateMin: resumed.sessionEstimateMin)
        PausedCheckinScheduler.cancel()
    }
}
