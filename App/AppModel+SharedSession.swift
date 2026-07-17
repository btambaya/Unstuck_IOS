// One true shared session (partner co-focus v2) — the app-layer orchestration
// of docs/shared-session-spec.md. A partner-shared task has AT MOST ONE live
// session; pause / resume / extend / finish from either side applies to both.
//
//   • The co-focus channel is SESSION-lifetime, owned here by AppModel (not the
//     focus screen), keyed on `cachedLiveSession` being a partner co-focus
//     candidate — so remote controls arrive while the user sits on Today or
//     closed the screen.
//   • Every LOCAL control flows through refreshLiveSession() (the existing
//     choke point every mutator already calls) → syncSharedSessionChannel()
//     detects the state change and broadcasts a FULL-state snapshot with rev+1.
//   • INCOMING `timer` messages run the pure LWW reducer (UnstuckCore
//     sharedSessionStep): apply-iff-newer, REPLACE the shared fields, persist
//     WITHOUT bumping rev, drive the Live Activity / check-in side effects —
//     and never open the pause-reason sheet or arm the local pause nag for a
//     REMOTE pause.
//   • Start = join-or-mint: probeSharedSession() asks the channel for an
//     adoptable in-flight session before FocusModel mints one.
//   • Accrual is ledger-only for partner sessions: log_shared_focus with the
//     ONE shared sessionId (PK, exactly-once — migration 046/047), owner
//     included. Stored state lives in AppModel.swift (extensions can't add
//     storage).

import Foundation
import UnstuckCore
import UnstuckData
import UnstuckSync

extension AppModel {

    // MARK: - candidacy

    /// True when `live` is a LIVE session on a partner-shared task — the
    /// condition for owning the session-lifetime co-focus channel. Either side:
    /// the RECIPIENT focusing a task shared WITH them at partner
    /// (sharedFocusLevel), or the OWNER focusing a task they shared out at
    /// partner (an outgoing badge). Reads `_shareState` (never builds it) so an
    /// idle/signed-out app never joins anything.
    func isPartnerCoFocusCandidate(_ live: LiveSession?) -> Bool {
        guard let live, live.sessionStart != nil else { return false }
        if live.sharedFocusLevel == .partner { return true }
        guard live.sharedFocusLevel == nil else { return false }   // assign/view recipient: no co-focus
        return _shareState?.badges[live.taskId]?.contains { $0.level == .partner } ?? false
    }

    /// True when a session's focus time accrues via the shared ledger
    /// (log_shared_focus, exactly-once per sessionId) INSTEAD of a direct
    /// `totalFocused` bump — any owner session on a partner-shared task, or one
    /// that was adopted / remote-controlled over the channel (the rev fields
    /// only exist on shared-broadcast sessions). The recipient path keeps its
    /// own marker (sharedFocusLevel) and is unchanged.
    func accruesViaSharedLedger(_ live: LiveSession?, taskId: String) -> Bool {
        if let live, live.sharedSessionRev != nil || live.lastAppliedRev != nil { return true }
        return _shareState?.badges[taskId]?.contains { $0.level == .partner } ?? false
    }

    // MARK: - channel lifecycle + local-control broadcast (the choke point)

    /// Runs after EVERY live-session mutation (hooked into refreshLiveSession)
    /// and on every badge refresh:
    ///  1. the session we were broadcasting ended/switched → broadcast its
    ///     final state (`ended: true`, rev+1) on the old channel, then release;
    ///  2. no partner candidate → quiet teardown (candidacy lapse ≠ ended);
    ///  3. candidate → ensure the channel is bound, and broadcast any local
    ///     state change (sessionStart | paused | pausedAt | estimate) as a
    ///     full-state snapshot with rev+1. Remote applies pre-seed
    ///     `lastSharedBroadcast`, so they never echo.
    func syncSharedSessionChannel() {
        let live = cachedLiveSession
        let activeId: String? = live?.sessionStart != nil ? live?.id : nil

        // 1) Previously-broadcast session is gone (finish / cancel / reap /
        //    displaced): its end is OURS to announce. Best-effort — a
        //    backgrounded process may have no socket; the 12h adoptable window
        //    + the stale-reap bound the damage on the other side.
        if let last = lastSharedBroadcast, last.sessionId != activeId {
            lastSharedBroadcast = nil
            var final = last
            final.rev += 1
            final.atMs = (Date().timeIntervalSince1970 * 1000).rounded()
            final.ended = true
            if let cf = liveCoFocus {
                liveCoFocus = nil
                liveCoFocusTaskId = nil
                cf.endSession(final)   // chained: ended → stop; self-registers
            }
            setSharedAttribution(nil, transient: false)
        }

        guard let live, let id = activeId, let start = live.sessionStart,
              isPartnerCoFocusCandidate(live) else {
            // 2) Not a candidate (idle, unshared, or the partner badge went
            //    away mid-session): drop the channel QUIETLY — never `ended`,
            //    the session itself may still be running locally.
            if let cf = liveCoFocus {
                liveCoFocus = nil
                liveCoFocusTaskId = nil
                cf.stopTask()   // chained + self-registering
            }
            lastSharedBroadcast = nil
            return
        }

        // 3) Candidate: seed a pending ADOPTION (join-or-mint's join — the
        //    adopted wire state is our baseline, no rev bump), then detect a
        //    local control by signature.
        // While DIVERGED (an offline control never delivered) the rev/baseline
        // BOOKKEEPING keeps running — the chain must stay monotonic for the
        // convergence rev = max(local, incoming) + 1 — but every SEND below is
        // suppressed: a diverged client doesn't fight the channel with stale
        // state (spec §Offline & reconnect convergence).
        let diverged = live.divergedOffline == true
        if let pending = pendingAdoptionSeed {
            if pending.sessionId == id {
                var seed = pending
                // Adoption clamps a future (partner-skewed) start to `now` for
                // local display — mirror the STORED value into the baseline so
                // the clamp isn't mistaken for a local control below (no rev
                // bump, no broadcast that would shift the shared clock).
                seed.sessionStartMs = start.rounded()
                lastSharedBroadcast = seed
            }
            pendingAdoptionSeed = nil   // consumed or superseded either way
        }

        // Rebind after a relaunch / candidacy flap: the in-memory baseline is
        // gone but the persisted session still carries the rev bookkeeping —
        // seed the baseline FROM it (SAME rev + the persisted atMs floor)
        // instead of letting the change detector mint a spurious rev+1 with
        // atMs=now, which could beat a genuine partner control on the atMs
        // tiebreak. Rev bumps are for genuine LOCAL user controls only.
        // Rejoin reconciliation v2: this seed marks the bind below as a
        // REJOIN of an existing session — hello-only, NO state re-announce
        // (the build-28 idempotent rebind announce imposed unflagged offline
        // state on the healthy partner by rev authority); the channel arms
        // `rejoinPending` and the first same-session exchange reconciles.
        var rebindOfExisting = false
        if lastSharedBroadcast == nil,
           live.sharedSessionRev != nil || live.lastAppliedRev != nil {
            lastSharedBroadcast = SharedSessionState(
                sessionId: id, sessionStartMs: start.rounded(), paused: live.paused,
                pausedAtMs: live.pausedAt.map { $0.rounded() },
                estimateMin: live.sessionEstimateMin,
                rev: max(live.sharedSessionRev ?? 0, live.lastAppliedRev ?? 0),
                atMs: max(live.sharedSessionAtMs ?? 0, live.lastAppliedAtMs ?? 0),
                ended: false)
            rebindOfExisting = true
        }

        let changed: Bool = {
            guard let b = lastSharedBroadcast else { return true }
            return b.sessionId != id
                || b.sessionStartMs != start.rounded()
                || b.paused != live.paused
                || b.pausedAtMs != live.pausedAt.map { $0.rounded() }
                || b.estimateMin != live.sessionEstimateMin
        }()

        if changed {
            // A local control (mint / pause / resume / extend / shade action):
            // next rev on top of everything we've seen, sender clock as the
            // LWW tiebreak. Persist the rev AND the atMs so a relaunch keeps
            // the chain monotonic and the LWW floor intact — direct store
            // write, NOT refreshLiveSession (we're inside it).
            let rev = max(live.sharedSessionRev ?? 0, live.lastAppliedRev ?? 0) + 1
            let state = SharedSessionState(
                sessionId: id, sessionStartMs: start.rounded(), paused: live.paused,
                pausedAtMs: live.pausedAt.map { $0.rounded() },
                estimateMin: live.sessionEstimateMin,
                rev: rev, atMs: (Date().timeIntervalSince1970 * 1000).rounded(), ended: false)
            lastSharedBroadcast = state
            var bumped = live
            bumped.sharedSessionRev = rev
            bumped.sharedSessionAtMs = state.atMs
            try? liveStore?.set(bumped)
            setCachedLiveSession(bumped)
            // A local control supersedes any remote attribution line.
            setSharedAttribution(nil, transient: false)
        }

        let timer = CoFocusTimerState(sessionStartMs: start, paused: live.paused,
                                      pausedAtMs: live.pausedAt,
                                      estimateMin: live.sessionEstimateMin)

        if liveCoFocus == nil || liveCoFocusTaskId != live.taskId {
            // Safety: a stale binding on ANOTHER topic (task switch that never
            // passed idle) is released first — chained, so order holds.
            if let stale = liveCoFocus {
                liveCoFocus = nil
                liveCoFocusTaskId = nil
                stale.stopTask()
            }
            // (Re)bind the channel for this task. Every channel op runs on the
            // app-wide co-focus chain (chainCoFocusOp), so this join lands
            // strictly after any in-flight teardown of the SAME topic
            // (supabase-swift dedupes channels by topic — a stop() racing a
            // start() would otherwise unsubscribe the fresh channel). A
            // diverged rebind (relaunch mid-divergence) joins RECEIVE-only;
            // a rebind of an EXISTING session (the seed above) joins as a v2
            // REJOIN (hello-only — a fresh mint/adopt keeps the full
            // first-subscribe announce).
            let cf = makeCoFocusModel(taskId: live.taskId)
            cf.start(track: .focusing, timer: timer, shared: lastSharedBroadcast,
                     suppressControls: diverged,
                     rejoin: rebindOfExisting,
                     onControl: { [weak self] msg, rejoinPending in
                         Task { @MainActor in
                             self?.handleSharedControl(msg, rejoinPending: rejoinPending)
                         }
                     },
                     onDeliveryFailure: { [weak self] sid in
                         Task { @MainActor in self?.handleSharedDeliveryFailure(sessionId: sid) }
                     },
                     // Socket-down ALONE marks divergence (same sessionId-guarded
                     // handler): the offline RUNNER must not be rewound by the
                     // partner's mid-outage pause on rejoin — even when no local
                     // control happens while offline.
                     onSocketDown: { [weak self] sid in
                         Task { @MainActor in self?.handleSharedDeliveryFailure(sessionId: sid) }
                     },
                     onDivergedAlone: { [weak self] sid in
                         Task { @MainActor in self?.handleSharedDivergedAlone(sessionId: sid) }
                     })
            liveCoFocus = cf
            liveCoFocusTaskId = live.taskId
        } else if changed {
            if diverged {
                // Suppressed, but keep the channel's retained announce state
                // CURRENT (no wire traffic): a forced diverged-hello reply must
                // carry the TRUE local state (an offline pause included), not
                // the pre-divergence snapshot.
                liveCoFocus?.syncLocalState(timer: timer, shared: lastSharedBroadcast)
            } else {
                liveCoFocus?.updateTimer(timer, shared: lastSharedBroadcast)
            }
        }
    }

    /// A control broadcast could not be delivered (socket down / channel not
    /// joined / send error — reported by the channel's delivery gate), OR the
    /// realtime socket dropped under the live shared session (`onSocketDown` —
    /// divergence without any local control): mark the live session DIVERGED.
    /// Guarded on the reported sessionId so a finish + new start racing the
    /// async hop can't flag the wrong session. Direct store write + cache
    /// overwrite via `setCachedLiveSession` — NOT refreshLiveSession, whose
    /// choke point owns the broadcast that just failed (re-entering it would
    /// re-send). While set, choke-point re-broadcasts are suppressed on both
    /// the app side (no updateTimer) and the transport side
    /// (controlsSuppressed), and the next same-session state received runs
    /// most-ahead convergence.
    ///
    /// Echo-guard integrity (spec §Convergence amendments): the choke point
    /// records `lastSharedBroadcast` BEFORE delivery is known — it is NOT
    /// rolled back here, because every convergence exit re-announces PAST it
    /// (keepAndBroadcast at max+1, within-slack local-win at the same rev,
    /// diverged-alone at the already-monotonic rev, adopt replaces it), so a
    /// failed send can never leave the catch-up broadcast suppressed. Rolling
    /// it back would instead re-mint rev+1 for the SAME state on every
    /// refresh while offline.
    func handleSharedDeliveryFailure(sessionId: String) {
        guard let liveStore, var cur = (try? liveStore.get()) ?? nil,
              cur.sessionStart != nil, cur.id == sessionId,
              cur.divergedOffline != true else { return }
        cur.divergedOffline = true
        try? liveStore.set(cur)
        setCachedLiveSession(cur)
        liveCoFocus?.setControlsSuppressed(true)
    }

    /// The diverged re-exchange grace expired with nobody (focusing) left in
    /// presence — there is no state to converge with; ours IS the session
    /// (spec §Convergence amendments: a solo channel blip must not mute the
    /// client's broadcasts forever). The channel only reports this after at
    /// least one presence SYNC since the last rejoin (v2 §4 — an unsynced map
    /// counts as a focusing peer, so a stale-presence race can't fake
    /// "alone"). Clear the flag, un-suppress the transport, and re-announce
    /// the current state at its ALREADY-monotonic rev (the offline bumps made
    /// it strictly newer than anything delivered pre-outage — no extra bump;
    /// receivers already at it LWW-ignore). The catch-up `updateTimer` below
    /// is a CONTROL send, so it runs the channel's delivery gate: if it can't
    /// be delivered, `onDeliveryFailure` → handleSharedDeliveryFailure
    /// RE-FLAGS divergence + re-suppresses instead of leaking the state.
    func handleSharedDivergedAlone(sessionId: String) {
        guard let liveStore, var cur = (try? liveStore.get()) ?? nil,
              cur.sessionStart != nil, cur.id == sessionId,
              cur.divergedOffline == true else { return }
        cur.divergedOffline = nil
        try? liveStore.set(cur)
        setCachedLiveSession(cur)   // direct — don't re-enter the choke point
        let timer = CoFocusTimerState(sessionStartMs: cur.sessionStart ?? 0,
                                      paused: cur.paused, pausedAtMs: cur.pausedAt,
                                      estimateMin: cur.sessionEstimateMin)
        let snapshot: SharedSessionState
        if let b = lastSharedBroadcast, b.sessionId == sessionId {
            snapshot = b
        } else {
            // Baseline lost (relaunch mid-divergence before any control):
            // rebuild from the persisted bookkeeping, same as the rebind seed.
            snapshot = SharedSessionState(
                sessionId: sessionId, sessionStartMs: (cur.sessionStart ?? 0).rounded(),
                paused: cur.paused, pausedAtMs: cur.pausedAt.map { $0.rounded() },
                estimateMin: cur.sessionEstimateMin,
                rev: max(cur.sharedSessionRev ?? 0, cur.lastAppliedRev ?? 0),
                atMs: max(cur.sharedSessionAtMs ?? 0, cur.lastAppliedAtMs ?? 0),
                ended: false)
            lastSharedBroadcast = snapshot
        }
        liveCoFocus?.setControlsSuppressed(false)
        liveCoFocus?.updateTimer(timer, shared: snapshot)
    }

    // MARK: - incoming controls (the reducer + side effects)

    /// Apply a received `timer` message to the live session. Old-build messages
    /// (no sessionId) are display-only — the channel's peer overlay already
    /// renders them; nothing to do here. `rejoinPending` (Rejoin
    /// reconciliation v2) is the channel's per-message flag: true ⇒ this is
    /// the FIRST same-session exchange after a rejoin.
    func handleSharedControl(_ msg: SharedSessionMsg, rejoinPending: Bool = false) {
        guard msg.sessionId != nil else { return }
        guard let liveStore, let cur = (try? liveStore.get()) ?? nil,
              cur.sessionStart != nil, let curId = cur.id else { return }
        // The LWW floor: everything we've broadcast or applied for this session —
        // the PERSISTED local-control atMs included, so the floor survives a
        // relaunch (max(local, lastApplied), plus the in-memory baseline).
        let local = SharedSessionState(
            sessionId: curId, sessionStartMs: cur.sessionStart ?? 0, paused: cur.paused,
            pausedAtMs: cur.pausedAt, estimateMin: cur.sessionEstimateMin,
            rev: max(cur.sharedSessionRev ?? 0, cur.lastAppliedRev ?? 0),
            atMs: max(lastSharedBroadcast?.atMs ?? 0,
                      max(cur.sharedSessionAtMs ?? 0, cur.lastAppliedAtMs ?? 0)),
            ended: false)
        // Most-ahead reconciliation gate (v2 §2 — `sharedSessionReconcilesMostAhead`):
        // while DIVERGED, or on the first same-session exchange after ANY
        // rejoin, a live same-session state runs MOST-AHEAD reconciliation
        // instead of plain LWW (a dead socket goes unnoticed for up to ~2
        // heartbeats, so an outage's controls can bump rev UNFLAGGED — the
        // rejoin gate reconciles flag or no flag; the resolution itself is
        // asymmetric unless genuinely flagged). `ended` stays terminal — it
        // falls through to the normal step below. Steady-state non-diverged
        // behavior is COMPLETELY unchanged: the elapsed comparison never
        // applies to live controls (a stale running re-announce cannot
        // un-pause an online pause).
        let flagged = cur.divergedOffline == true
        if sharedSessionReconcilesMostAhead(divergedOffline: flagged, rejoinPending: rejoinPending),
           let inc = msg.state, inc.sessionId == curId, !inc.ended {
            resolveDivergedControl(cur: cur, local: local, inc: inc, msg: msg, flagged: flagged)
            return
        }

        let step = sharedSessionStep(local: local, incoming: msg)
        guard step.apply else { return }
        let inc = step.next
        let by = sharedAttributionName(for: msg.userId)

        if inc.ended {
            applyRemoteEnded(cur: cur, state: inc, by: by)
            return
        }
        applyRemoteSnapshot(cur: cur, inc: inc, by: by)
    }

    /// REPLACE the shared fields (full-state snapshot — peers never
    /// recompute the resume shift); keep local-only fields (treatment,
    /// priorAccumulatedSec, shared markers, nudge flags); persist WITHOUT
    /// bumping rev; remember the applied (rev, atMs) as the new floor. Also
    /// clears `divergedOffline` — applying a remote state IS convergence.
    ///
    /// `resetRevFloor` (the divergence ADOPT arm): also overwrite the LOCAL
    /// control bookkeeping (`sharedSessionRev/AtMs`) with the incoming pair —
    /// adopting is wholesale, cursors included. The offline-inflated local rev
    /// must not keep out-flooring the partner's post-convergence controls
    /// (they'd be rejected here and then reverted on their side by our next
    /// re-announce). Web parity: the adopt arm writes `sharedSessionRev:
    /// msg.rev` too.
    private func applyRemoteSnapshot(cur: LiveSession, inc: SharedSessionState, by: String,
                                     resetRevFloor: Bool = false) {
        let wasPaused = cur.paused
        let prevEstimate = cur.sessionEstimateMin
        var next = cur
        next.sessionStart = inc.sessionStartMs
        next.paused = inc.paused
        next.pausedAt = inc.pausedAtMs
        next.sessionEstimateMin = inc.estimateMin
        next.lastAppliedRev = inc.rev
        next.lastAppliedAtMs = inc.atMs
        if resetRevFloor {
            next.sharedSessionRev = inc.rev
            next.sharedSessionAtMs = inc.atMs
        }
        next.divergedOffline = nil
        // Pre-seed the echo detector: the refresh below must see this state as
        // already-on-the-wire (we applied it; we don't own it).
        lastSharedBroadcast = inc
        try? liveStore?.set(next)
        refreshLiveSession()

        // Remote-control side effects are first-class: the Live Activity
        // reflects pause/resume/extend; a remote RESUME clears our pending
        // paused check-in; a remote PAUSE must NOT arm the local pause nag or
        // open the pause-reason sheet (the acting device owns those).
        LiveActivityController.shared.update(sessionStartMs: inc.sessionStartMs,
                                             paused: inc.paused, estimateMin: inc.estimateMin)
        if wasPaused, !inc.paused { PausedCheckinScheduler.cancel() }

        if inc.paused != wasPaused {
            setSharedAttribution(inc.paused ? "\(by) paused" : "\(by) resumed",
                                 transient: !inc.paused)
        } else if inc.estimateMin != prevEstimate {
            setSharedAttribution("\(by) extended the session", transient: true)
        }
        sharedSessionRemoteTick &+= 1
    }

    /// Most-ahead reconciliation for a DIVERGED or rejoin-pending local
    /// session receiving a live same-session state (pure `resolveRejoin` —
    /// v2 §3 asymmetric — ~3s slack, both elapsed at OUR clock):
    ///  • incoming ahead → adopt it wholesale + clear the flag (allowed with
    ///    or without the flag — a rejoiner may always take the fresher clock);
    ///  • local ahead + GENUINELY FLAGGED → keep local, clear the flag,
    ///    broadcast local as a GENUINE convergence control at rev =
    ///    max(local, incoming) + 1 — the partner applies it via normal LWW
    ///    (criterion 4: the online side needs no special logic);
    ///  • local ahead + UN-flagged (rejoin blip) → plain (rev, atMs) LWW,
    ///    NOTHING announced — a blip must never bulldoze the partner's
    ///    genuine online pause by rev authority (v2 §3);
    ///  • within slack → the clocks agree: fall back to plain LWW; when
    ///    FLAGGED and LOCAL wins that LWW, idempotently re-announce it at the
    ///    SAME rev so the partner's floor catches up to the rev bumps made
    ///    offline (receivers already at it ignore non-newer).
    private func resolveDivergedControl(cur: LiveSession, local: SharedSessionState,
                                        inc: SharedSessionState, msg: SharedSessionMsg,
                                        flagged: Bool) {
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        let localShared = SharedSessionState(
            sessionId: local.sessionId, sessionStartMs: cur.sessionStart ?? 0,
            paused: cur.paused, pausedAtMs: cur.pausedAt,
            estimateMin: cur.sessionEstimateMin, rev: local.rev, atMs: local.atMs,
            ended: false)
        let by = sharedAttributionName(for: msg.userId)
        let timer = CoFocusTimerState(sessionStartMs: cur.sessionStart ?? 0,
                                      paused: cur.paused, pausedAtMs: cur.pausedAt,
                                      estimateMin: cur.sessionEstimateMin)

        switch resolveRejoin(local: localShared, incoming: inc, now: now,
                             flaggedDiverged: flagged) {
        case .adopt:
            // The partner's clock is ahead — theirs is THE session now,
            // cursors included (resetRevFloor: the offline-inflated local rev
            // must not out-floor their post-convergence controls).
            liveCoFocus?.setControlsSuppressed(false)
            applyRemoteSnapshot(cur: cur, inc: inc, by: by, resetRevFloor: true)
            // Sync the channel's announce state to the adopted snapshot (the
            // suppressed actor still holds the stale pre-divergence timer, and
            // a hello reply would otherwise re-display it). Same rev — a no-op
            // for anyone who already has it.
            liveCoFocus?.updateTimer(CoFocusTimerState(
                sessionStartMs: inc.sessionStartMs, paused: inc.paused,
                pausedAtMs: inc.pausedAtMs, estimateMin: inc.estimateMin), shared: inc)

        case .keepAndBroadcast(let rev):
            var next = cur
            next.divergedOffline = nil
            next.sharedSessionRev = rev
            next.sharedSessionAtMs = now
            let snapshot = SharedSessionState(
                sessionId: local.sessionId, sessionStartMs: (cur.sessionStart ?? 0).rounded(),
                paused: cur.paused, pausedAtMs: cur.pausedAt.map { $0.rounded() },
                estimateMin: cur.sessionEstimateMin, rev: rev, atMs: now, ended: false)
            lastSharedBroadcast = snapshot   // baseline = what we now announce
            try? liveStore?.set(next)
            setCachedLiveSession(next)       // direct — don't re-enter the choke point
            liveCoFocus?.setControlsSuppressed(false)
            liveCoFocus?.updateTimer(timer, shared: snapshot)

        case .lww:
            guard flagged else {
                // Un-flagged rejoin (v2 §3): plain LWW only — apply a strictly
                // newer incoming, and when LOCAL wins say NOTHING (no flag to
                // clear, no state debt; announcing here would impose the local
                // state by rev authority — the exact build-28 bulldoze).
                let step = sharedSessionStep(local: local, incoming: msg)
                if step.apply { applyRemoteSnapshot(cur: cur, inc: step.next, by: by) }
                return
            }
            var next = cur
            next.divergedOffline = nil
            try? liveStore?.set(next)
            setCachedLiveSession(next)
            liveCoFocus?.setControlsSuppressed(false)
            let step = sharedSessionStep(local: local, incoming: msg)
            if step.apply {
                applyRemoteSnapshot(cur: next, inc: step.next, by: by)
            } else {
                let snapshot = SharedSessionState(
                    sessionId: local.sessionId, sessionStartMs: (cur.sessionStart ?? 0).rounded(),
                    paused: cur.paused, pausedAtMs: cur.pausedAt.map { $0.rounded() },
                    estimateMin: cur.sessionEstimateMin, rev: local.rev, atMs: local.atMs,
                    ended: false)
                lastSharedBroadcast = snapshot
                liveCoFocus?.updateTimer(timer, shared: snapshot)
            }
        }
    }

    /// A partner finished/cancelled the shared session: finalize quietly with
    /// the SAME sessionId + the canonical elapsed (frozen at the ender's
    /// clock, so both sides log ~identical numbers into the exactly-once
    /// ledger), and show the normal recap with "<name> ended the session".
    /// Fires NO session_end ping (the ender's device already did).
    private func applyRemoteEnded(cur: LiveSession, state: SharedSessionState, by: String) {
        let elapsed = canonicalElapsedSec(state, now: state.atMs)
        let taskId = cur.taskId
        let sessionId = state.sessionId
        let isRecipient = cur.sharedFocusLevel != nil

        suppressNextSessionEndSignal()
        // The end is not ours to re-announce — clear the echo detector BEFORE
        // the refresh so the choke point doesn't broadcast a second `ended`.
        lastSharedBroadcast = nil
        pendingAdoptionSeed = nil
        try? liveStore?.set(nil)
        refreshLiveSession()   // tears the channel down (no candidate)
        LiveActivityController.shared.end()
        PausedCheckinScheduler.cancel()

        // Exactly-once accrual via the ledger — owner included (migration 047);
        // durable: a failed RPC lands in the pending ledger and is drained on
        // foreground/relaunch (idempotent per sessionId).
        let estimate = state.estimateMin
        Task { await self.logSharedFocusDurable(taskId: taskId, actualSec: elapsed,
                                                estimateMin: estimate, sessionId: sessionId) }

        // The OWNER still writes their own Session row (insights) — single
        // writer, id = the shared session id, so session captures keep their FK.
        var taskName = "your shared task"
        if !isRecipient, let task = (try? taskRepo?.fetch(id: taskId)) ?? nil {
            saveSession(Session(id: sessionId, taskId: task.id, taskName: task.name,
                                estimateMin: task.estimateMin, actualSec: elapsed,
                                completedAt: Self.isoNow()))
            taskName = task.name
        } else if let title = _shareState?.sharedWithMe.first(where: { $0.taskId == taskId })?.title {
            taskName = title
        }
        lastRecap = RecapState(taskName: taskName, focusedSec: elapsed,
                               at: Date().timeIntervalSince1970 * 1000, endedBy: by)
        setSharedAttribution(nil, transient: false)
        sharedSessionRemoteTick &+= 1
    }

    // MARK: - adoption (join-or-mint)

    /// Serialize a co-focus channel op behind every in-flight one and register
    /// it as the new chain head. ALL ops (start / stop / endSession / the
    /// adoption probe) funnel through this ONE chain — a strict FIFO — so a
    /// stop() can never race a start() on the same (topic-deduped) channel.
    /// The head is read + re-registered synchronously on the main actor, so
    /// nothing can interleave between the read and the registration.
    @discardableResult
    func chainCoFocusOp(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let prior = coFocusTeardown
        let t = Task { @MainActor in
            await prior?.value
            await op()
        }
        coFocusTeardown = t
        return t
    }

    /// Probe `cofocus:<taskId>` for an adoptable in-flight session BEFORE
    /// minting one (join ≤1.5s: hello → any focuser re-broadcasts). On a hit,
    /// seeds the pending-adoption baseline (no rev bump, no echo) and registers
    /// the sid as already-started so NO session_start ping fires (only the
    /// minter announces). Returns nil ⇒ mint as usual.
    ///
    /// Runs ON the co-focus op chain: it waits for any in-flight teardown on
    /// this topic (a PartnerPresence row leaving as the focus cover opens) and,
    /// by registering itself as the head, no later start/stop can remove the
    /// topic's channel out from under the ≤1.5s window. The probe itself never
    /// removeChannels a pre-existing topic instance (it piggybacks).
    func probeSharedSession(taskId: String, partnerShared: Bool) async -> SharedSessionState? {
        guard partnerShared else { return nil }
        // Our own live session on this task is already current (the channel is
        // bound and applying remote controls) — nothing to adopt.
        if let live = cachedLiveSession, live.sessionStart != nil, live.taskId == taskId,
           liveCoFocusTaskId == taskId { return nil }
        guard let client = coordinator?.coFocus,
              let uid = coordinator?.auth.currentUserId else { return nil }
        let prior = coFocusTeardown
        let probe = Task { () -> SharedSessionMsg? in
            await prior?.value
            return await client.probe(taskId: taskId, selfId: uid)
        }
        coFocusTeardown = Task { _ = await probe.value }   // chain ops behind the probe
        guard let msg = await probe.value, let state = msg.state else { return nil }
        pendingAdoptionSeed = state
        markSessionSignalAdopted(sid: state.sessionId)
        return state
    }

    /// Adopting an in-flight partner session OVER a live local session with a
    /// DIFFERENT id on the SAME task (the partner minted separately while the
    /// devices were apart): finalize the displaced local clock FIRST so its
    /// elapsed isn't silently lost — a capped ledger write under the OLD
    /// sessionId (idempotent, mirrors finalizeDisplacedFocus's shared branch);
    /// an owner also keeps the Session row for insights. Called by FocusView
    /// between the probe hit and the FocusModel adopt.
    func finalizeDisplacedForAdoption(_ adopt: SharedSessionState, taskId: String) {
        guard let cur = (try? liveStore?.get()) ?? nil, cur.sessionStart != nil,
              cur.taskId == taskId, let oldId = cur.id, oldId != adopt.sessionId else { return }
        let raw = FocusTimer.elapsedSec(cur, now: Date().timeIntervalSince1970 * 1000)
        let capped = Self.cappedSharedElapsedSec(rawSec: raw, estimateMin: cur.sessionEstimateMin)
        let estimate = cur.sessionEstimateMin
        // Owner (no shared marker + a local row): keep the displaced clock's
        // Session row — single writer, id = the displaced session id.
        if cur.sharedFocusLevel == nil, let task = (try? taskRepo?.fetch(id: cur.taskId)) ?? nil {
            saveSession(Session(id: oldId, taskId: task.id, taskName: task.name,
                                estimateMin: task.estimateMin, actualSec: raw,
                                completedAt: Self.isoNow()))
        }
        Task { await self.logSharedFocusDurable(taskId: taskId, actualSec: capped,
                                                estimateMin: estimate, sessionId: oldId) }
    }

    // MARK: - Today live-card resume (shared sessions have no local task row)

    /// A synthesized display TaskItem for a LIVE session on a task with no
    /// local row (a recipient's shared focus) so the Today live card can render
    /// and resume it — under one-true-session the session is task-scoped and
    /// keeps running when the screen closes. nil for own-task sessions.
    func sharedLiveTaskFallback() -> TaskItem? {
        guard let live = cachedLiveSession, live.sessionStart != nil,
              live.sharedFocusLevel != nil else { return nil }
        let title = _shareState?.sharedWithMe.first { $0.taskId == live.taskId }?.title
            ?? "Shared focus"
        let now = Self.isoNow()
        return TaskItem(id: live.taskId, name: title,
                        estimateMin: live.sessionEstimateMin, totalFocused: 0,
                        createdAt: now, updatedAt: now)
    }

    /// Reopen Focus for the LIVE session (Today live-card tap). A shared
    /// (recipient) session RE-CARRIES its level via the router so every
    /// finalize path stays on the shared ledger; an own session opens normally.
    func reopenLiveFocus(_ task: TaskItem) {
        if let live = cachedLiveSession, live.sessionStart != nil,
           live.taskId == task.id, let level = live.sharedFocusLevel {
            router.sharedFocus = SharedFocusContext(taskId: task.id, title: task.name,
                                                    estimateMin: live.sessionEstimateMin,
                                                    level: level)
            router.focusTask = task
        } else {
            router.beginFocus(task)
        }
    }

    // MARK: - attribution ("<name> paused" — calm, never a modal)

    /// Resolve a peer's display first-name from the live channel; falls back
    /// to a neutral label when the sender isn't (or is no longer) present.
    func sharedAttributionName(for userId: String?) -> String {
        guard let userId,
              let peer = liveCoFocus?.peers.first(where: { $0.userId == userId })
        else { return "Your partner" }
        return coFocusFirstName(peer.name)
    }

    /// Set/clear the attribution line. `transient` auto-clears after a few
    /// seconds (remote resume/extend); a remote PAUSE stays until the state
    /// changes.
    func setSharedAttribution(_ text: String?, transient: Bool) {
        sharedAttributionClearTask?.cancel()
        sharedAttributionClearTask = nil
        guard sharedSessionAttribution != text else { return }
        sharedSessionAttribution = text
        if text != nil, transient {
            sharedAttributionClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.sharedSessionAttribution = nil
            }
        }
    }

    // MARK: - durable ledger accrual (offline finish must never lose it)

    /// A shared-focus accrual that couldn't reach the server — persisted so a
    /// finish while offline (or a transient RPC failure) is retried on
    /// foreground + relaunch until it lands. Safe to re-fire: the ledger is
    /// idempotent per sessionId (migration 046 PK, on conflict do nothing).
    struct PendingSharedFocusLog: Codable, Equatable {
        let sessionId: String
        let taskId: String
        let sec: Int
        let estimateMin: Int
    }

    private static let pendingSharedFocusKey = "unstuck.pendingSharedFocusLedger"

    /// The persisted pending-ledger queue (UserDefaults-backed; tiny — one
    /// record per unlanded session, deduped by sessionId).
    var pendingSharedFocusLogs: [PendingSharedFocusLog] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.pendingSharedFocusKey)
            else { return [] }
            return (try? JSONDecoder().decode([PendingSharedFocusLog].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.pendingSharedFocusKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.pendingSharedFocusKey)
            }
        }
    }

    /// The ONE way shared-session accrual reaches log_shared_focus. Attempts
    /// the RPC now and, instead of dropping the outcome:
    ///  • `.failure` (offline / transient / can't run) → persist a pending
    ///    record, drained on foreground + relaunch (idempotent per sessionId);
    ///  • `.notAllowed` (share revoked mid-session) → an OWNER falls back to
    ///    the direct outbox-durable totalFocused bump on their own row (always
    ///    allowed); a recipient has no row — nothing left to accrue to.
    func logSharedFocusDurable(taskId: String, actualSec: Int, estimateMin: Int, sessionId: String) async {
        guard actualSec > 0 else { return }
        switch await shareState.logSharedFocus(taskId: taskId, actualSec: actualSec, sessionId: sessionId) {
        case .ok:
            break
        case .notAllowed:
            applySharedFocusNotAllowedFallback(taskId: taskId, sec: actualSec)
        case .failure:
            var queue = pendingSharedFocusLogs.filter { $0.sessionId != sessionId }
            queue.append(PendingSharedFocusLog(sessionId: sessionId, taskId: taskId,
                                               sec: actualSec, estimateMin: estimateMin))
            pendingSharedFocusLogs = queue
        }
    }

    /// Share revoked mid-session (`not_allowed`): the ledger will never admit
    /// this write. An OWNER still owns the task row, so accrue via the direct
    /// outbox-durable totalFocused bump instead (their own row — no share
    /// required). A recipient has no local row (access is gone) → no-op.
    private func applySharedFocusNotAllowedFallback(taskId: String, sec: Int) {
        guard sec > 0, let task = (try? taskRepo?.fetch(id: taskId)) ?? nil else { return }
        var bumped = task
        bumped.totalFocused += sec
        bumped.updatedAt = Self.isoNow()
        saveTask(bumped)
    }

    /// Drain the pending ledger (called on foreground + relaunch): retry each
    /// record until it lands — a record that actually landed but lost its
    /// response no-ops server-side (idempotent per sessionId). Stops at the
    /// first transport failure (still offline) and retries next trigger.
    /// Single-flight via `sharedLedgerDrainTask`.
    func drainPendingSharedFocusLedger() {
        guard sharedLedgerDrainTask == nil, !pendingSharedFocusLogs.isEmpty else { return }
        sharedLedgerDrainTask = Task { [weak self] in
            drain: while true {
                guard let self, let next = self.pendingSharedFocusLogs.first else { break }
                switch await self.shareState.logSharedFocus(
                    taskId: next.taskId, actualSec: next.sec, sessionId: next.sessionId) {
                case .failure:
                    break drain   // still unreachable — keep the queue, retry next trigger
                case .notAllowed:
                    self.applySharedFocusNotAllowedFallback(taskId: next.taskId, sec: next.sec)
                    fallthrough
                case .ok:
                    var queue = self.pendingSharedFocusLogs
                    queue.removeAll { $0.sessionId == next.sessionId }
                    self.pendingSharedFocusLogs = queue
                }
            }
            self?.sharedLedgerDrainTask = nil
        }
    }
}
