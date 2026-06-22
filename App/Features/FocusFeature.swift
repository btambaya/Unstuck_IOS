// P3 — Focus (core). Drives the well-tested UnstuckCore.FocusTimer engine
// with a TimelineView tick, persists every transition to LiveSessionStore
// (so a relaunch resumes), and writes a Session on finish via WriteThrough.
//
// Visual reskin: 1:1 with the Android FocusScreen — a dark indigo radial
// background (for every treatment), a "← Out" pill, the FOCUSING/PAUSED
// eyebrow, white-on-dark treatment chips (always shown, incl. Monk so you
// can step back out), the ambient progress ring with a white Orbit, the
// serif task name + first-physical-action + estimate, a big light timer with
// "<remaining> left", the overrun check-in (+10 / In the zone / Stop here),
// and the Capture / Pause·Resume / Done action row plus the Save-for-later /
// End-for-now secondary row. The FocusModel + AppModel wiring is unchanged.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

@MainActor
@Observable
final class FocusModel {
    var live: LiveSession
    let task: TaskItem
    /// When focusing a recurring occurrence: the (template id/name, day's block
    /// id). The session runs on the TEMPLATE; completion marks the block.
    let occurrence: (templateId: String, templateName: String, blockId: String)?
    private let store: LiveSessionStore?
    /// Notified after every persist so AppModel can refresh its in-memory
    /// live-session cache (the Today LiveSessionCard reads that cache, not the
    /// store, on each 1s tick). Set by FocusView, which holds the AppModel.
    var onPersist: (@MainActor () -> Void)?

    init(task: TaskItem, store: LiveSessionStore?,
         defaultTreatment: FocusTreatment = .ambient,
         occurrence: (templateId: String, templateName: String, blockId: String, priorFocused: Int)? = nil) {
        self.task = task
        self.store = store
        self.occurrence = occurrence.map { ($0.templateId, $0.templateName, $0.blockId) }
        let existing: LiveSession? = (try? store?.get()) ?? nil
        // The live session is keyed to the TEMPLATE when focusing an occurrence
        // (so totalFocused accrues on the series), and carries the block id so
        // finish marks just this day. Display still uses the occurrence's name/
        // estimate (which it inherits from the template).
        let focusId = occurrence?.templateId ?? task.id
        let prior = occurrence?.priorFocused ?? task.totalFocused
        // Resume-aware: start() continues a paused session for the same task.
        // priorAccumulatedSec seeds the displayed timer so reopening after
        // "Just finish" continues from the accumulated total, not 0 (Android parity).
        var session = FocusTimer.start(existing ?? .empty, taskId: focusId, estimateMin: task.estimateMin,
                                priorAccumulatedSec: prior, now: Self.now(),
                                occurrenceBlockId: occurrence?.blockId)
        // Seed a FRESH session's treatment from the Settings default (Android
        // parity). start() carries the prior treatment for a resume of the same
        // task, so only override when this is a brand-new session (no existing
        // live session for this task).
        let isFresh = (existing?.sessionStart == nil) || (existing?.taskId != focusId)
        if isFresh { session = FocusTimer.setTreatment(session, defaultTreatment) }
        live = session
        persist()
        LiveActivityController.shared.start(taskName: task.name, sessionStartMs: live.sessionStart ?? Self.now(), estimateMin: task.estimateMin)
        // start() hardcodes paused:false. Reopening a PAUSED session (resumed via
        // start()) would otherwise show a running Dynamic Island timer until the
        // next transition — immediately reflect the paused state.
        if live.paused {
            LiveActivityController.shared.update(sessionStartMs: live.sessionStart ?? Self.now(), paused: true, estimateMin: task.estimateMin)
        }
    }

    func pause() {
        live = FocusTimer.pause(live, now: Self.now()); persist()
        LiveActivityController.shared.update(sessionStartMs: live.sessionStart ?? 0, paused: true, estimateMin: task.estimateMin)
        PausedCheckinScheduler.schedule(taskName: task.name)
    }
    func resume() {
        live = FocusTimer.resume(live, now: Self.now()); persist()
        LiveActivityController.shared.update(sessionStartMs: live.sessionStart ?? 0, paused: false, estimateMin: task.estimateMin)
        PausedCheckinScheduler.cancel()
    }

    /// Stop the session + return the Session row (reusing the live id so
    /// captures taken during the session join back) + elapsed seconds, for the
    /// view to hand to AppModel.finishFocus.
    @discardableResult
    func finish() -> (session: Session, elapsedSec: Int) {
        let elapsed = FocusTimer.elapsedSec(live, now: Self.now())
        // Attribute the Session to the TEMPLATE for an occurrence focus (so the
        // analytics + totalFocused continuity stay on the series, never a row
        // whose id is a block id — which would mint a phantom task).
        let sTaskId = occurrence?.templateId ?? task.id
        let sName = occurrence?.templateName ?? task.name
        let session = Session(id: live.id ?? newUUID(), taskId: sTaskId, taskName: sName,
                              estimateMin: task.estimateMin, actualSec: elapsed, completedAt: AppModel.isoNow())
        live = FocusTimer.done(live)
        persist()
        LiveActivityController.shared.end()
        PausedCheckinScheduler.cancel()
        return (session, elapsed)
    }

    func cancel() {
        live = FocusTimer.cancel(live)
        persist()
        LiveActivityController.shared.end()
        PausedCheckinScheduler.cancel()
    }

    var treatment: FocusTreatment { live.treatment }
    func setTreatment(_ t: FocusTreatment) { live = FocusTimer.setTreatment(live, t); persist() }
    var sessionId: String? { live.id }

    /// Extend the session estimate (overrun check-in: "+10" / "in the zone").
    func extendFocus(_ minutes: Int) { live = FocusTimer.extend(live, minutes: minutes); persist() }

    private func persist() {
        try? store?.set(live.sessionStart == nil ? nil : live)
        onPersist?()
    }

    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }
}

struct FocusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    let task: TaskItem
    @State private var fm: FocusModel?
    @State private var showReasons = false
    /// "Save for later" exits AFTER the pause reason is logged (Android's
    /// `exitAfterReason`). When set, picking a reason (or dismissing the sheet)
    /// dismisses the focus screen; otherwise the reason sheet just records why.
    @State private var exitAfterReason = false
    @State private var showCapture = false
    /// Captures parked during focus, observed live so the Cockpit rail reflects
    /// new captures as they're saved. Ordered newest-first (matches the repo).
    @State private var captures: [Capture] = []
    @State private var captureTag: CaptureTag = .followUp
    @State private var captureText = ""
    /// Header mute toggle. Seeded from the Settings ambient choice in .task so
    /// the speaker starts in the state the user picked (off → muted).
    @State private var soundOn = true
    @State private var soundSeeded = false
    /// Soft-exit confirm ("Leave focus?") — Android parity: the timer keeps
    /// running and stays resumable from Today; we just stop showing it.
    @State private var showLeaveConfirm = false
    // End-of-session reflection (Android ReflectSheet) — shown after Done /
    // End for now; momentary, nothing is stored.
    @State private var showReflect = false
    @State private var reflectMin = 0
    @State private var reflectSel: String?

    // Hands-Free Focus Copilot (Phase 1). The VoiceController is the same
    // on-device $0 STT/TTS layer the assistant uses (no LLM/network here). The
    // controller is created on first session start when "Spoken focus coach" is
    // on; `lastTickSec` de-dupes the per-second tick.
    @State private var copilotVoice = VoiceController()
    @State private var copilot: FocusCopilotController?
    @State private var lastTickSec = -1

    private let reasons = ["Bathroom", "Drink", "Quick question", "Stuck — need a moment", "Other"]

    // The Android focus screen is dark for every treatment: a deep indigo
    // radial gradient. We render the whole screen on this regardless of the
    // system color scheme, so the chrome/colors are hand-picked white-on-dark.
    private let bgTop = OKLCH(0.30, 0.10, 280).color
    private let bgBottom = OKLCH(0.16, 0.02, 280).color

    var body: some View {
        ZStack {
            RadialGradient(colors: [bgTop, bgBottom], center: .top, startRadius: 0, endRadius: 900)
                .ignoresSafeArea()
            if let fm { content(fm) } else { ProgressView().tint(.white) }
        }
        .task {
            // Seed the mute toggle from the Settings ambient choice (off →
            // start muted) once, before the first audio update.
            if !soundSeeded { soundOn = model.settings.ambient != .off; soundSeeded = true }
            if fm == nil {
                // Recurring occurrence? Run the session on the template, mark the
                // day's block on finish. Resolve before finalize/start so the
                // displaced-session check compares against the TEMPLATE id.
                let occ = model.occurrenceFocusTarget(task.id)
                model.finalizeDisplacedFocus(forNewTaskId: occ?.template.id ?? task.id)
                let newFM = FocusModel(task: task, store: model.liveStore,
                                defaultTreatment: model.settings.defaultTreatment,
                                occurrence: occ.map { ($0.template.id, $0.template.name, $0.block.id, $0.template.totalFocused) })
                // Keep AppModel's live-session cache in sync with every FocusModel
                // transition (start/pause/resume/finish/cancel) so Today's
                // LiveSessionCard reflects it without re-reading the store.
                newFM.onPersist = { [weak model] in model?.refreshLiveSession() }
                fm = newFM
                // The init's persist() ran before onPersist was wired — seed once.
                model.refreshLiveSession()
                startCopilotIfEnabled(newFM)
            }
        }
        // Live captures for the Cockpit rail. Observe regardless of treatment so
        // switching into Cockpit mid-session already has the list (Android's
        // CapturesRail collects vm.captures the same way).
        .task {
            guard let repo = model.taskRepo else { return }
            do { for try await snap in repo.observeCaptures() { captures = snap } } catch {}
        }
        .confirmationDialog("Why are you pausing?", isPresented: $showReasons, titleVisibility: .visible) {
            ForEach(reasons, id: \.self) { reason in
                // For the "Save for later" flow the session is already paused; we
                // just record the reason and then exit after it lands.
                Button(reason) {
                    if exitAfterReason { model.saveReasonLog(ReasonLog(id: newUUID(), taskId: task.id, reason: reason, action: .pause, at: AppModel.isoNow())); exitAfterReason = false; dismiss() }
                    else { pauseWith(reason) }
                }
            }
            Button("Just pause", role: .cancel) {
                // Save-for-later already paused + coordinated the check-in, so here
                // we only need to exit; the Pause-button flow still pauses now.
                if exitAfterReason { exitAfterReason = false; dismiss() }
                else { fm?.pause(); coordinateCheckin() }
            }
        }
        .confirmationDialog("Leave focus?", isPresented: $showLeaveConfirm, titleVisibility: .visible) {
            Button("Leave") { dismiss() }
            Button("Stay", role: .cancel) {}
        } message: {
            Text("Your timer keeps running — you can pick it back up from Today.")
        }
        .sheet(isPresented: $showCapture) { captureSheet }
        .sheet(isPresented: $showReflect, onDismiss: { dismiss() }) { reflectSheet }
        .onDisappear { teardownCopilot(); AmbientAudio.shared.stop() }
        // .onDisappear does NOT fire when the phone locks/backgrounds while the
        // Focus screen stays "appeared" — the .playback engine would keep
        // rendering (and draining battery) in the background. Stop on leaving
        // .active; restart on return if the user still wants the bed playing.
        // (VoiceModeScreen tears down on scenePhase the same way.)
        .onChange(of: scenePhase) { _, phase in
            // Background / inactive: tear the copilot down (mic must never run
            // off-screen) alongside the existing ambient-audio teardown.
            if phase != .active { teardownCopilot(); AmbientAudio.shared.stop() }
            else if let fm { updateAudio(fm) }
        }
    }

    /// Ambient loop plays while focusing when the Settings ambient bed is on
    /// (off | brown | pink — iOS generates one procedural brown bed; pink reuses
    /// it) AND the header mute toggle is on. Android plays it for every
    /// treatment, so we no longer gate on treatment == .ambient.
    private func updateAudio(_ fm: FocusModel) {
        if soundOn && model.settings.ambient != .off { AmbientAudio.shared.start() }
        else { AmbientAudio.shared.stop() }
    }

    // MARK: - Hands-Free Focus Copilot wiring

    /// Build + start the copilot when "Spoken focus coach" is on. The effects
    /// run the SAME paths the on-screen buttons use (extend / finish / capture)
    /// — no voice command deletes data. Re-created per session.
    private func startCopilotIfEnabled(_ fm: FocusModel) {
        guard model.settings.focusSpokenCoach else { copilot = nil; return }
        let speaker = VoiceControllerSpeaker(copilotVoice)
        let listener = VoiceControllerListener(copilotVoice)
        let effects = CopilotEffects(
            extend: { [weak fm] n in fm?.extendFocus(n) },
            keepGoing: { [weak fm] in
                // Mirror the visual "In the zone": set the no-re-nag flag on the
                // live session so the overrun check-in won't re-escalate.
                guard let fm else { return }
                fm.live.overrunPromptFired = true
            },
            stop: { finishSession(markDone: false) },
            capture: { [weak fm] text in
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty, let fm else { return }
                let captureTaskId = fm.occurrence?.templateId ?? task.id
                model.saveCapture(Capture(id: newUUID(), taskId: captureTaskId,
                                          sessionId: fm.sessionId, tag: .followUp,
                                          body: body, at: AppModel.isoNow()))
            }
        )
        let c = FocusCopilotController(
            speaker: speaker,
            listener: listener,
            effects: effects,
            estimateMin: { [weak fm] in fm?.live.sessionEstimateMin ?? task.estimateMin },
            level: { NotificationPrefs.level },
            voiceRepliesEnabled: { model.settings.focusVoiceReplies }
        )
        c.startSession()
        copilot = c
    }

    /// Tear the copilot down (stops any speech/mic, restores ducked audio).
    private func teardownCopilot() {
        copilot?.endSession()
        lastTickSec = -1
    }

    private var listeningIndicator: some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.fill").font(.system(size: 11))
            Text("listening…").font(UFont.mono(11, .medium)).tracking(0.6)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(theme.palette.coral.opacity(0.35), in: Capsule())
        .padding(.bottom, 12)
        .accessibilityLabel("Listening for a voice command")
        .transition(.opacity)
    }

    @ViewBuilder
    private func content(_ fm: FocusModel) -> some View {
        @Bindable var fm = fm
        VStack(spacing: 0) {
            // ── "← Out" leaves focus (current iOS behavior: cancels the live
            //    session then dismisses). Styled as Android's white-on-dark pill.
            HStack {
                Button { leaveFocus(fm) } label: {
                    Text("← Out")
                        .font(UFont.sans(12))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.10), in: Capsule())
                }.buttonStyle(.plain)
                Spacer()
                // Sound toggle (ambient loop) lives where Android's mute-less
                // header has space; keeps the existing soundOn behavior.
                Button { soundOn.toggle(); updateAudio(fm) } label: {
                    Image(systemName: soundOn ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.10), in: Circle())
                }.buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            phaseLabel(fm.live.paused ? "PAUSED" : "FOCUSING")

            // Treatment switcher — always shown (incl. Monk) so picking Monk
            // doesn't trap the user with no way back out.
            HStack(spacing: 8) {
                ForEach([FocusTreatment.ambient, .cockpit, .monk], id: \.self) { t in
                    // Android does both: mutate the live session AND persist the
                    // pick as the default so future fresh sessions seed from it.
                    treatmentChip(t, selected: fm.treatment == t) {
                        fm.setTreatment(t)
                        model.settings.defaultTreatment = t
                    }
                }
            }
            .padding(.top, 8)

            Spacer()

            timeline(fm)

            Spacer()

            actions(fm)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .onAppear { updateAudio(fm) }
        .onChange(of: fm.treatment) { updateAudio(fm) }
    }

    private func phaseLabel(_ text: String) -> some View {
        Text(text)
            .font(UFont.mono(11, .medium)).tracking(0.9)
            .foregroundStyle(.white.opacity(0.55))
    }

    private func treatmentChip(_ t: FocusTreatment, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(treatmentName(t))
                .font(UFont.sans(12, .medium))
                .foregroundStyle(selected ? Color(hex: "#14122A") : .white.opacity(0.7))
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(selected ? AnyShapeStyle(Color.white.opacity(0.92)) : AnyShapeStyle(Color.white.opacity(0.08)),
                            in: Capsule())
        }.buttonStyle(.plain)
    }

    private func treatmentName(_ t: FocusTreatment) -> String {
        switch t {
        case .ambient: return "ambient"
        case .cockpit: return "cockpit"
        case .monk: return "monk"
        }
    }

    // MARK: timer + ring

    @ViewBuilder
    private func timeline(_ fm: FocusModel) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date.timeIntervalSince1970 * 1000
            let elapsed = FocusTimer.displayedElapsedSec(fm.live, now: now)
            let estimateSec = FocusTimer.estimateSec(fm.live)
            let remaining = max(0, estimateSec - elapsed)
            let progress = estimateSec > 0 ? min(1, max(0, Double(elapsed) / Double(estimateSec))) : 0
            // Soft-overrun grace from Settings · Focus (minutes; 0 = Never →
            // .infinity, so the timer never escalates to the overrun check-in).
            let graceSec = model.settings.focusOverrunMin <= 0 ? Double.infinity : Double(model.settings.focusOverrunMin) * 60
            let state = FocusTimer.deriveState(fm.live, now: now, overrunGraceSec: graceSec)
            let isPaused = fm.live.paused

            VStack(spacing: 0) {
                // Drive the copilot once per accumulated-focus second (paused
                // EXCLUDED — `elapsed` here is FocusTimer.displayedElapsedSec,
                // which freezes while paused). Wrapped so it can never affect the
                // timer; de-duped on the whole-second value.
                Color.clear.frame(height: 0)
                    .onChange(of: elapsed) { _, sec in
                        guard !isPaused, sec != lastTickSec else { return }
                        lastTickSec = sec
                        copilot?.tick(focusedSec: sec)
                    }

                // "listening…" indicator while the post-prompt mic window is live.
                if let copilot, copilot.listening {
                    listeningIndicator
                }

                if fm.treatment == .ambient {
                    ProgressRing(progress: progress, paused: isPaused, animated: !model.settings.reduceMotion)
                        .frame(width: 220, height: 220)
                        .padding(.bottom, 20)
                }

                if fm.treatment != .monk {
                    Text(task.name)
                        .font(UFont.serifItalic(24)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                    if let step = task.firstPhysicalAction?.trimmingCharacters(in: .whitespacesAndNewlines), !step.isEmpty {
                        Text("→ \(step)")
                            .font(UFont.sans(13)).foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center).lineLimit(2)
                            .padding(.top, 6).padding(.horizontal, 24)
                    }
                    Text("\(task.estimateMin)m estimate")
                        .font(UFont.sans(13)).foregroundStyle(.white.opacity(0.65))
                        .padding(.top, 6)
                }

                Text(formatMMSS(elapsed))
                    .font(UFont.sans(52, .light))
                    .foregroundStyle(state == .overrun ? theme.palette.coral : .white)
                    .monospacedDigit()
                    .padding(.top, 20)
                Text("\(formatMMSS(remaining)) left")
                    .font(UFont.sans(12)).foregroundStyle(.white.opacity(0.5))

                // Overrun check-in (web/Android parity): past the estimate,
                // offer to extend or stop — not just a recolored timer.
                if state == .overrun && !isPaused {
                    Text("Past your estimate — still going well?")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.coral.opacity(0.9))
                        .padding(.top, 10)
                    HStack(spacing: 8) {
                        focusBtn("+10 min", soft: true) { fm.extendFocus(10) }
                        focusBtn("In the zone", soft: true) { fm.extendFocus(15) }
                        focusBtn("Stop here", soft: false) { finishSession(markDone: false) }
                    }
                    .padding(.top, 8)
                }

                // Cockpit rail: the last 3 captures parked on this task, so
                // recent thoughts stay glanceable while focusing (Android parity).
                if fm.treatment == .cockpit { capturesRail(fm) }
            }
        }
    }

    /// The Cockpit captures rail — last 3 captures for the focus task, listed as
    /// "• <body>". For a recurring occurrence the captures live on the TEMPLATE,
    /// so we match against the template id (mirrors saveCapture's attribution).
    @ViewBuilder
    private func capturesRail(_ fm: FocusModel) -> some View {
        let railTaskId = fm.occurrence?.templateId ?? task.id
        // observeCaptures() is newest-first; take the 3 newest, then reverse to
        // chronological order to match Android's takeLast(3) on its oldest-first
        // stream.
        let recent = Array(captures.filter { $0.taskId == railTaskId }.prefix(3).reversed())
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Captures", color: .white.opacity(0.45))
                ForEach(recent) { cap in
                    Text("• \(cap.body)")
                        .font(UFont.sans(12)).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
        }
    }

    // MARK: actions

    @ViewBuilder
    private func actions(_ fm: FocusModel) -> some View {
        let isPaused = fm.live.paused
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                focusBtn("Capture", soft: true) { showCapture = true }
                focusBtn(isPaused ? "Resume" : "Pause", soft: true) {
                    if isPaused { fm.resume(); copilot?.resumeSession() }
                    // Pause-reasons setting off → pause silently (no "Why are you
                    // pausing?" sheet). Either way coordinate the paused check-in
                    // NOW: pause() pre-schedules the local notif, so the cap/mute
                    // gate must run whether or not a reason is later picked (an
                    // ignored/dismissed reasons sheet must not bypass the cap).
                    // Pausing also stops any copilot mic/speech (it re-arms on
                    // Resume, keeping its already-fired cadence).
                    else if model.settings.focusPauseReasons { fm.pause(); copilot?.pauseSession(); coordinateCheckin(); showReasons = true }
                    else { fm.pause(); copilot?.pauseSession(); coordinateCheckin() }
                }
                // "Done" marks the task complete immediately (records the session
                // + flips done), 1:1 with Android — no extra "complete vs finish"
                // prompt; "End for now" below covers finishing without completing.
                focusBtn("Done", soft: false) { finishSession(markDone: true) }
            }
            // Secondary actions: "Save for later" pauses (resumable from Today);
            // "End for now" records the session without completing the task.
            HStack(spacing: 14) {
                // "Save for later" pauses + exits (resumable from Today). When
                // Pause-reasons is on, prompt for an interruption reason first and
                // exit AFTER it's logged (exitAfterReason); off → exit immediately.
                secondaryBtn("Save for later") {
                    fm.pause(); copilot?.pauseSession(); coordinateCheckin()
                    if model.settings.focusPauseReasons { exitAfterReason = true; showReasons = true }
                    else { dismiss() }
                }
                secondaryBtn("End for now") { finishSession(markDone: false) }
            }
            .padding(.top, 12).padding(.bottom, 6)
        }
    }

    private func focusBtn(_ title: String, soft: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(UFont.sans(14, .medium)).foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(soft ? AnyShapeStyle(Color.white.opacity(0.10)) : AnyShapeStyle(theme.palette.coral),
                            in: Capsule())
        }.buttonStyle(.plain)
    }

    private func secondaryBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(UFont.sans(13, .medium)).foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 14).padding(.vertical, 8)
        }.buttonStyle(.plain)
    }

    /// "← Out" — Android parity: leaving keeps the timer RUNNING (the live
    /// session persists, so Today can resume it); it never discards. With the
    /// Soft-exit setting on, a running, un-paused session asks to confirm first.
    private func leaveFocus(_ fm: FocusModel) {
        if model.settings.focusSoftExit, !fm.live.paused, fm.live.sessionStart != nil {
            showLeaveConfirm = true
        } else {
            dismiss()
        }
    }

    /// Finish the live session, accumulate focused time, and optionally complete
    /// the task (fires the shared-collection done notification for promoted tasks).
    private func finishSession(markDone: Bool) {
        guard let fm else { return }
        teardownCopilot()
        let result = fm.finish()
        // For an occurrence focus the Session is attributed to the template; pass
        // its id as the focus `task` so totalFocused accrues there, and the block
        // id so a "Mark complete" marks just this day done. Resolve the template
        // by primary key (a keyed fetchOne) rather than decoding the whole task
        // table on the main actor.
        let focusTask = fm.occurrence.flatMap { occ in
            (try? model.taskRepo?.fetch(id: occ.templateId)) ?? nil
        } ?? task
        model.finishFocus(task: focusTask, session: result.session, elapsedSec: result.elapsedSec,
                          markDone: markDone, occurrenceBlockId: fm.occurrence?.blockId)
        // Show the momentary reflection (Android parity); its onDismiss closes Focus.
        reflectMin = max(1, Int((Double(result.elapsedSec) / 60.0).rounded()))
        showReflect = true
    }

    // End-of-session reflection (Android ReflectSheet) — momentary; nothing is
    // stored. Both Skip and Done close it; its onDismiss closes the Focus screen.
    private var reflectSheet: some View {
        let opts: [(key: String, label: String, color: Color)] = [
            ("flow", "It flowed.", theme.palette.greenSoft),
            ("okay", "It was OK.", theme.palette.blueSoft),
            ("sticky", "It was sticky.", theme.palette.amberSoft),
            ("stopped", "I had to stop.", theme.palette.coralSoft),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Text("SESSION COMPLETE · \(reflectMin)M").font(UFont.mono(11, .medium)).tracking(0.8)
                .foregroundStyle(theme.palette.primaryDeep)
            Text("How did that land?").font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink)
            ForEach(opts, id: \.key) { o in
                Button { reflectSel = o.key } label: {
                    HStack(spacing: 12) {
                        Circle().stroke(theme.palette.line2, lineWidth: 2).frame(width: 20, height: 20)
                            .overlay(Circle().fill(theme.palette.ink).frame(width: 10, height: 10)
                                .opacity(reflectSel == o.key ? 1 : 0))
                        Text(o.label).font(UFont.sans(15)).foregroundStyle(theme.palette.ink)
                        Spacer()
                    }
                    .padding(12)
                    .background(reflectSel == o.key ? o.color : theme.palette.bg2,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }.buttonStyle(.plain)
            }
            HStack {
                Button("Skip") { showReflect = false }
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3).buttonStyle(.plain)
                Spacer()
                Button { showReflect = false } label: {
                    Text("Done").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.bg)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(theme.palette.ink, in: Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.height(420)])
    }

    private var captureSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Capture · stays attached")
            Text("Park a thought without losing focus.").font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
            TextField("What just popped up?", text: $captureText, axis: .vertical)
                .font(UFont.sans(16)).textFieldStyle(.plain)
                .padding(12).background(theme.palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))
            // Tag chips — Android CaptureSheet has the same five-tag row; we
            // were silently saving everything as `idea` before.
            CaptureTagPicker(selection: $captureTag)
            UButton("Save") { saveCapture() }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func pauseWith(_ reason: String) {
        model.saveReasonLog(ReasonLog(id: newUUID(), taskId: task.id, reason: reason, action: .pause, at: AppModel.isoNow()))
        fm?.pause()
        copilot?.pauseSession()
        coordinateCheckin()
    }

    /// FocusModel.pause() pre-schedules the local paused-too-long notif; ask
    /// the server whether the daily cap allows it, and cancel if not.
    private func coordinateCheckin() {
        model.requestPausedCheckin { allowed in
            if !allowed { PausedCheckinScheduler.cancel() }
        }
    }

    private func saveCapture() {
        let text = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        captureText = ""
        showCapture = false
        guard !text.isEmpty else { return }
        // Attach captures to the TEMPLATE for an occurrence focus (task.id is the
        // block id there) so they show on the series' detail, not a phantom row.
        let captureTaskId = fm?.occurrence?.templateId ?? task.id
        model.saveCapture(Capture(id: newUUID(), taskId: captureTaskId, sessionId: fm?.sessionId, tag: captureTag, body: text, at: AppModel.isoNow()))
        captureTag = .followUp
    }
}

/// Ambient progress ring with a white Orbit mark in the center.
/// Background arc = white 10%; the progress arc sweeps from 12 o'clock
/// (amber while paused, white while running) — 1:1 with the Android Canvas.
private struct ProgressRing: View {
    let progress: Double
    let paused: Bool
    /// When false (Settings · Accessibility → Reduce motion), the arc snaps to
    /// each per-second value instead of easing between them.
    var animated: Bool = true

    private let pausedColor = OKLCH(0.80, 0.13, 75).color   // amber, matches Android

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.10), lineWidth: 4)
                .padding(10)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(paused ? pausedColor : Color.white,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(10)
                .animation(animated ? .easeInOut(duration: 0.5) : nil, value: progress)
            WhiteOrbit(size: 130)
        }
    }
}

/// White-on-dark Orbit mark (the shared `Mark` reads the theme ink, which is
/// dark on the light theme — but the focus screen is always dark, so we draw
/// the ring + anchor + coral dot in white here). Geometry mirrors `Mark`.
private struct WhiteOrbit: View {
    let size: CGFloat
    private let coral = Color(hex: "#E89077")

    var body: some View {
        let ring = size * 21 / 32
        let stroke = size * 2.2 / 32
        let anchor = size * 6.8 / 32
        let dot = size * 4.2 / 32
        ZStack {
            // ~304° arc with a 56° gap centered at 3 o'clock (where the coral
            // satellite sits) — mirrors Android's Orbit (startAngle 28°, sweep 304°).
            Circle()
                .trim(from: 28.0 / 360.0, to: 332.0 / 360.0)
                .stroke(.white, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .frame(width: ring, height: ring)
            Circle().fill(.white).frame(width: anchor, height: anchor)
            Circle().fill(coral).frame(width: dot, height: dot)
                .offset(x: ring / 2)
        }
        .frame(width: size, height: size)
    }
}
