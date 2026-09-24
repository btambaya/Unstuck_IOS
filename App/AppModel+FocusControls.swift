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
        armPausedCheckin(taskName: taskName, sessionId: paused.id)
        noteLiveSessionChangedOffScreen()
    }

    /// The live session was changed OFF the Focus screen (the paused check-in's
    /// Resume, Today's Pause / Resume, the assistant's pause / resume /
    /// extend): an open FocusView re-reads the store instead of acting on —
    /// and re-saving — its own stale copy (audit 2026-09-22, C37).
    func noteLiveSessionChangedOffScreen() {
        liveSessionOffScreenTick &+= 1
    }

    // MARK: - captures of a session that writes no Session row

    /// A live session ended WITHOUT its Session row (cancelled / discarded, a
    /// task shared with me, its task deleted meanwhile): the captures queued
    /// behind it go up without the session — and without `deadTaskId`, when
    /// the task is gone — instead of waiting for a row that never comes
    /// (audit 2026-09-22, C44; WriteThrough.detachCapturesFromSession).
    func releaseCaptures(ofSession sessionId: String?, unlinkingTaskId deadTaskId: String? = nil) {
        guard let sessionId, let write else { return }
        let now = Self.isoNow()
        Task { _ = try? await write.detachCapturesFromSession(sessionId, unlinkingTaskId: deadTaskId, nowISO: now) }
    }

    /// Launch: captures an earlier run (up to build 85) left held behind a
    /// session that never wrote its row are released (audit 2026-09-22, C44;
    /// WriteThrough.releaseCapturesOfEndedSessions). Ops queued from now on
    /// are left to the paths above.
    func releaseStrandedCaptures() {
        guard let write else { return }
        let liveId = cachedLiveSession?.id
        let now = Self.isoNow()
        Task { _ = try? await write.releaseCapturesOfEndedSessions(liveSessionId: liveId, queuedBefore: now, nowISO: now) }
    }

    // MARK: - sign-out finalize (Android parity)

    /// Finalize whatever focus session is live at sign-out — the account is
    /// going away, so:
    ///  • the pending paused check-in is dropped (no budget settlement — the
    ///    JWT is on its way out);
    ///  • an OWN session (no `sharedFocusLevel`) is finished the way the
    ///    displaced-session path finishes one: Session row + totalFocused (or
    ///    the exactly-once shared ledger for a partner-shared task), no recap,
    ///    never marked done; the store is cleared and the cache refreshed
    ///    (which also broadcasts `ended` on a partner channel);
    ///  • a PARTNER/recipient session (`sharedFocusLevel` set) is not ours to
    ///    finalize — it may still be running on the owner's side and the
    ///    sync sign-out wipes the local row; only its Live Activity ends;
    ///  • the Live Activity ALWAYS ends (also with no session — an orphan
    ///    rebound on launch), so the previous account's task name never
    ///    survives on the lock screen / Dynamic Island.
    /// Returns the ledger accrual still to land (partner-shared own task) so
    /// the caller can attempt it with the JWT (button) or queue it (reactive)
    /// BEFORE the pending ledger is parked under this user. Idempotent.
    @discardableResult
    func finalizeLiveSessionForSignOut() -> PendingSharedFocusLog? {
        PausedCheckinBudget.disarm()
        defer { LiveActivityController.shared.end() }
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil, cur.sessionStart != nil else { return nil }
        guard cur.sharedFocusLevel == nil else {
            // A recipient's session — not ours to finalize, and no Session row
            // comes from this phone: its captures go up without one before the
            // outbox is parked (audit 2026-09-22, C44).
            releaseCaptures(ofSession: cur.id)
            return nil
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        // Finalized off the Focus screen: a forgotten running session is capped
        // at its estimate + grace like the shared paths (audit 2026-09-22, C43).
        let elapsed = Self.cappedSharedElapsedSec(rawSec: FocusTimer.elapsedSec(cur, now: nowMs),
                                                  estimateMin: cur.sessionEstimateMin)
        try? liveStore.set(nil)
        refreshLiveSession()
        let sessionId = cur.id ?? newUUID()
        guard let task = (try? taskRepo?.fetch(id: cur.taskId)) ?? nil else {
            // Row gone (deleted elsewhere mid-session): keep the minutes in
            // insights under a generic name, as the notification-end path does.
            saveSession(Self.goneTaskSession(cur, elapsedSec: elapsed))
            return nil
        }
        saveSession(Session(id: sessionId, taskId: task.id, taskName: task.name,
                            estimateMin: cur.sessionEstimateMin, actualSec: elapsed, completedAt: Self.isoNow()))
        if accruesViaSharedLedger(cur, taskId: task.id) {
            // Partner-shared own task: the exactly-once ledger (same session id
            // as the partner's finalize) — capped like every resurrected path.
            guard elapsed > 0 else { return nil }
            return PendingSharedFocusLog(sessionId: sessionId, taskId: task.id,
                                         sec: elapsed, estimateMin: cur.sessionEstimateMin)
        }
        var bumped = task
        bumped.totalFocused += elapsed
        bumped.updatedAt = Self.isoNow()
        saveTask(bumped)
        return nil
    }

    // MARK: - paused check-in: budget at FIRE time (web / Android parity)

    /// Arm the local ~14-min "did you step away?" nag and PEEK the shared daily
    /// push cap (mute / preference / remaining slots) — nothing is consumed
    /// yet. Cancelled when the server says no. The budget slot is claimed only
    /// once the nag has actually fired (`consumePausedCheckinBudget`), exactly
    /// when web and Android claim it: a quick pause/resume used to burn one of
    /// the 3 daily slots per pause, silently suppressing the afternoon recap
    /// and later genuine check-ins on EVERY device.
    func armPausedCheckin(taskName: String, sessionId: String?) {
        PausedCheckinBudget.arm(taskName: taskName, sessionId: sessionId)
        peekPausedCheckinAllowed { allowed in
            if !allowed { PausedCheckinBudget.disarm() }
        }
    }

    /// The session left the paused state (resume / end / cancel / a remote
    /// resume): settle the budget for a nag that already FIRED, drop a still
    /// pending one un-consumed.
    func cancelPausedCheckin() {
        PausedCheckinBudget.cancel(consume: { [weak self] in self?.consumePausedCheckinBudget() })
    }

    /// Foreground / relaunch: a nag that fired while the app was away claims
    /// its slot now (the phone can't run code at local-notification fire time).
    func settlePausedCheckinBudgetIfFired() {
        guard PausedCheckinBudget.hasFired() else { return }
        PausedCheckinBudget.clearMarker()
        consumePausedCheckinBudget()
    }

    /// Ask (main actor) whether a paused check-in may fire — the PEEK mode of
    /// send-paused-checkin. Offline / transport failure → `true` DELIBERATELY:
    /// the local nag is still worth having with no server, and nothing was
    /// consumed; the claim happens at fire time and simply fails closed if the
    /// server is still unreachable then.
    func peekPausedCheckinAllowed(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let n = coordinator?.notifications else { completion(true); return }
        Task {
            let allowed = (try? await n.pausedCheckin(mode: .peek)) ?? true
            await MainActor.run { completion(allowed) }
        }
    }

    /// Claim the day's paused-check-in slot (`try_consume_push_budget`). Best-
    /// effort, fire-and-forget: the notification is already on the lock screen.
    func consumePausedCheckinBudget() {
        guard let n = coordinator?.notifications else { return }
        Task { _ = try? await n.pausedCheckin(mode: .consume) }
    }

    // MARK: - programmatic start (assistant `start_focus`): join-or-mint

    /// Start focus on `taskId` the way the Focus SCREEN does — join-or-mint
    /// (one true shared session): finalize a displaced session, PROBE the
    /// co-focus channel for a partner's in-flight session and ADOPT it (its
    /// id / start / paused / estimate, prior accumulation 0 so both rings show
    /// the same clock), else MINT. The assistant's `start_focus` used to call
    /// FocusTimer.start directly, minting a SECOND sessionId on a task the
    /// partner was already running — every partner control was then dropped
    /// (sessionId mismatch) and the two clocks finalized separately.
    func startFocusJoinOrMint(taskId: String, estimateMin: Int?, occurrenceBlockId: String?) async {
        guard let store = liveStore else { return }
        let task = (try? taskRepo?.fetch(id: taskId)) ?? nil
        let partnerShared = shareState.badges[taskId]?.contains { $0.level == .partner } ?? false
        finalizeDisplacedFocus(forNewTaskId: taskId)
        let adopted = await probeSharedSession(taskId: taskId, partnerShared: partnerShared)
        let existing: LiveSession? = (try? store.get()) ?? nil
        let now = Date().timeIntervalSince1970 * 1000
        var session: LiveSession
        if let adopted {
            finalizeDisplacedForAdoption(adopted, taskId: taskId)
            session = FocusTimer.adopt(existing ?? .empty, taskId: taskId, state: adopted,
                                       priorAccumulatedSec: 0, now: now, occurrenceBlockId: occurrenceBlockId)
        } else {
            // `task` is the series TEMPLATE for an occurrence (or a series
            // with no open day): its totalFocused is the series' lifetime
            // focus, never this sitting's — seeded, the ring opened over its
            // estimate (web/Android audit 2026-09-23, W10/A13).
            let prior = FocusModel.seededPriorSec(task: task, isOccurrence: occurrenceBlockId != nil,
                                                  partnerShared: partnerShared)
            session = FocusTimer.start(existing ?? .empty, taskId: taskId,
                                       estimateMin: estimateMin ?? task?.estimateMin,
                                       priorAccumulatedSec: prior,
                                       now: now, occurrenceBlockId: occurrenceBlockId)
        }
        let isFresh = existing?.sessionStart == nil || existing?.taskId != taskId
        if isFresh { session = FocusTimer.setTreatment(session, settings.defaultTreatment) }
        // A paused session this start did not keep paused as-is — resumed
        // (same task, or the series re-pointed to another day), or adopted
        // over — takes its "Did you step away?" nag with it, as on the Focus
        // screen: finalizeDisplacedFocus skips the same task, so the nag fired
        // during the running session (audit 2026-09-22, C38).
        if let existing, existing.paused, !(session.id == existing.id && session.paused) {
            cancelPausedCheckin()
        }
        try? store.set(session)
        refreshLiveSession()
        // The same session continued (resumed / re-pointed): an open Focus
        // screen follows it instead of showing PAUSED (C37). A different one
        // is opened by the caller's navigation.
        if existing?.sessionStart != nil, existing?.id == session.id { noteLiveSessionChangedOffScreen() }
    }

    /// Reap focus Live Activities left dangling by a kill/crash mid-session.
    /// If the persisted live session is still active, the controller rebinds to
    /// its activity (so updates keep flowing); otherwise it ends every orphan so
    /// no ghost lock-screen timer survives. Called on launch + foreground.
    func reapStaleLiveActivities() {
        let cur = (try? liveStore?.get()) ?? nil
        // A SHARED (recipient) live session is finalized here ONLY when it is
        // TRULY stale — elapsed past the estimate + grace window. One true
        // shared session: the session is task-scoped and may still be running
        // on the partner's side; a fresh one is kept + rebound, resumable from
        // the Today live card (which synthesizes the row-less shared task) and
        // steerable by remote controls. A stale one is consumed: accrue the
        // CAPPED elapsed onto the owner (idempotent per session id, migration
        // 046 — the ledger id freezes on first write) and end its Live
        // Activity. When the shared Focus screen IS up (router.focusTask set),
        // it owns the session; leave it alone.
        if let cur, cur.sessionStart != nil, let level = cur.sharedFocusLevel,
           levelCanComplete(level), router.focusTask == nil {
            let raw = FocusTimer.elapsedSec(cur, now: Date().timeIntervalSince1970 * 1000)
            let staleAfterSec = max(1, cur.sessionEstimateMin) * 60 + AppModel.sharedFocusCapGraceSec
            if raw > staleAfterSec {
                let capped = AppModel.cappedSharedElapsedSec(rawSec: raw, estimateMin: cur.sessionEstimateMin)
                let (taskId, sessionId) = (cur.taskId, cur.id ?? newUUID())
                let estimate = cur.sessionEstimateMin
                try? liveStore?.set(nil)
                refreshLiveSession()
                Task { await self.logSharedFocusDurable(taskId: taskId, actualSec: capped,
                                                        estimateMin: estimate, sessionId: sessionId) }
                releaseCaptures(ofSession: cur.id)   // no own Session row (C44)
                LiveActivityController.shared.reapOrphans(hasActiveSession: false)
                return
            }
            // Still fresh — fall through: rebind + keep it resumable.
        }
        LiveActivityController.shared.reapOrphans(hasActiveSession: cur?.sessionStart != nil)
    }

    /// Resume the paused live session from Today (Android `resumeFocus`). Shifts
    /// sessionStart by the pause gap (so elapsed continues, not double-counts),
    /// un-freezes the Live Activity, and cancels the pending paused check-in.
    func resumeFocus() {
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil, cur.paused else { return }
        let now = Date().timeIntervalSince1970 * 1000
        // The pause's reason log gets how long the pause lasted (Insights P0-3).
        if let closed = FocusTimer.closedPauseLog(cur, now: now) { saveReasonLog(closed) }
        let resumed = FocusTimer.resume(cur, now: now)
        try? liveStore.set(resumed)
        refreshLiveSession()
        LiveActivityController.shared.update(
            sessionStartMs: resumed.sessionStart ?? 0, paused: false,
            estimateMin: resumed.sessionEstimateMin)
        cancelPausedCheckin()
        noteLiveSessionChangedOffScreen()
    }
}

/// The paused check-in's local notification + its FIRE-TIME marker. iOS can't
/// run code when a local notification is delivered, so the marker (the
/// instant it was scheduled to fire, UserDefaults) is what tells a later
/// resume / end / foreground whether the nag actually reached the lock screen
/// — and therefore whether the shared daily push budget must be claimed
/// (`consume`) or nothing happened (`disarm`). Pure over an injected clock +
/// defaults so the decision is unit-tested.
enum PausedCheckinBudget {
    static let fireAtKey = "unstuck.pausedCheckin.fireAt"
    /// Must match PausedCheckinScheduler's trigger interval.
    static let delay: TimeInterval = 14 * 60

    /// Schedule the local nag and remember when it fires. Nothing is armed on
    /// the Calm level (the scheduler posts nothing there, so nothing can fire).
    static func arm(taskName: String, sessionId: String?, now: Date = Date(), defaults: UserDefaults = .standard) {
        guard NotificationPrefs.level.pausedCheckin else { return }
        PausedCheckinScheduler.schedule(taskName: taskName, sessionId: sessionId)
        defaults.set(now.timeIntervalSince1970 + delay, forKey: fireAtKey)
    }

    /// Drop the pending nag WITHOUT settling (cap said no / sign-out).
    static func disarm(defaults: UserDefaults = .standard) {
        PausedCheckinScheduler.cancel()
        clearMarker(defaults: defaults)
    }

    /// The session left the paused state: a nag that already FIRED claims its
    /// budget slot via `consume`; a still-pending one is dropped un-consumed.
    static func cancel(consume: (() -> Void)?, now: Date = Date(), defaults: UserDefaults = .standard) {
        if hasFired(now: now, defaults: defaults) { consume?() }
        disarm(defaults: defaults)
    }

    static func hasFired(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        Self.fired(fireAt: defaults.object(forKey: fireAtKey) as? Double, now: now.timeIntervalSince1970)
    }

    static func clearMarker(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: fireAtKey)
    }

    /// Pure: an armed marker whose fire instant has passed means the nag was
    /// delivered (local notifications fire even with the app killed).
    nonisolated static func fired(fireAt: Double?, now: Double) -> Bool {
        guard let fireAt, fireAt > 0 else { return false }
        return now >= fireAt
    }
}
