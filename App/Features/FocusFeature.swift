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

    init(task: TaskItem, store: LiveSessionStore?,
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
        live = FocusTimer.start(existing ?? .empty, taskId: focusId, estimateMin: task.estimateMin,
                                priorAccumulatedSec: prior, now: Self.now(),
                                occurrenceBlockId: occurrence?.blockId)
        persist()
        LiveActivityController.shared.start(taskName: task.name, sessionStartMs: live.sessionStart ?? Self.now(), estimateMin: task.estimateMin)
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
    }

    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }
}

struct FocusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme
    let task: TaskItem
    @State private var fm: FocusModel?
    @State private var showReasons = false
    @State private var showCapture = false
    @State private var showFinish = false
    @State private var captureText = ""
    @State private var soundOn = true

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
            if fm == nil {
                // Recurring occurrence? Run the session on the template, mark the
                // day's block on finish. Resolve before finalize/start so the
                // displaced-session check compares against the TEMPLATE id.
                let occ = model.occurrenceFocusTarget(task.id)
                model.finalizeDisplacedFocus(forNewTaskId: occ?.template.id ?? task.id)
                fm = FocusModel(task: task, store: model.liveStore,
                                occurrence: occ.map { ($0.template.id, $0.template.name, $0.block.id, $0.template.totalFocused) })
            }
        }
        .confirmationDialog("Why are you pausing?", isPresented: $showReasons, titleVisibility: .visible) {
            ForEach(reasons, id: \.self) { reason in
                Button(reason) { pauseWith(reason) }
            }
            Button("Just pause", role: .cancel) { fm?.pause(); coordinateCheckin() }
        }
        .confirmationDialog("Wrap up this session?", isPresented: $showFinish, titleVisibility: .visible) {
            Button("Mark task complete") { finishSession(markDone: true) }
            Button("Just finish") { finishSession(markDone: false) }
            Button("Keep going", role: .cancel) {}
        }
        .sheet(isPresented: $showCapture) { captureSheet }
        .onDisappear { AmbientAudio.shared.stop() }
    }

    private func updateAudio(_ fm: FocusModel) {
        if soundOn && fm.treatment == .ambient { AmbientAudio.shared.start() }
        else { AmbientAudio.shared.stop() }
    }

    @ViewBuilder
    private func content(_ fm: FocusModel) -> some View {
        @Bindable var fm = fm
        VStack(spacing: 0) {
            // ── "← Out" leaves focus (current iOS behavior: cancels the live
            //    session then dismisses). Styled as Android's white-on-dark pill.
            HStack {
                Button { fm.cancel(); dismiss() } label: {
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
                    treatmentChip(t, selected: fm.treatment == t) { fm.setTreatment(t) }
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
            .font(UFont.mono(11, .medium)).tracking(0.8)
            .foregroundStyle(.white.opacity(0.55))
    }

    private func treatmentChip(_ t: FocusTreatment, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(treatmentName(t))
                .font(UFont.sans(12, .medium))
                .foregroundStyle(selected ? OKLCH(0.18, 0.05, 280).color : .white.opacity(0.7))
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
            let state = FocusTimer.deriveState(fm.live, now: now, overrunGraceSec: 1)
            let isPaused = fm.live.paused

            VStack(spacing: 0) {
                if fm.treatment == .ambient {
                    ProgressRing(progress: progress, paused: isPaused)
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
            }
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
                    if isPaused { fm.resume() }
                    else { fm.pause(); showReasons = true }
                }
                focusBtn("Done", soft: false) { showFinish = true }
            }
            // Secondary actions: "Save for later" pauses (resumable from Today);
            // "End for now" records the session without completing the task.
            HStack(spacing: 14) {
                secondaryBtn("Save for later") { fm.pause(); coordinateCheckin(); dismiss() }
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

    /// Finish the live session, accumulate focused time, and optionally complete
    /// the task (fires the shared-collection done notification for promoted tasks).
    private func finishSession(markDone: Bool) {
        guard let fm else { return }
        let result = fm.finish()
        // For an occurrence focus the Session is attributed to the template; pass
        // its id as the focus `task` so totalFocused accrues there, and the block
        // id so a "Mark complete" marks just this day done.
        let focusTask = fm.occurrence.flatMap { occ in
            (try? model.taskRepo?.all())?.first(where: { $0.id == occ.templateId })
        } ?? task
        model.finishFocus(task: focusTask, session: result.session, elapsedSec: result.elapsedSec,
                          markDone: markDone, occurrenceBlockId: fm.occurrence?.blockId)
        dismiss()
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
        model.saveCapture(Capture(id: newUUID(), taskId: captureTaskId, sessionId: fm?.sessionId, tag: .idea, body: text, at: AppModel.isoNow()))
    }
}

/// Ambient progress ring with a white Orbit mark in the center.
/// Background arc = white 10%; the progress arc sweeps from 12 o'clock
/// (amber while paused, white while running) — 1:1 with the Android Canvas.
private struct ProgressRing: View {
    let progress: Double
    let paused: Bool

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
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(.white, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .frame(width: ring, height: ring)
            Circle().fill(.white).frame(width: anchor, height: anchor)
            Circle().fill(coral).frame(width: dot, height: dot)
                .offset(x: ring / 2)
        }
        .frame(width: size, height: size)
    }
}
