// P3 — Focus (core). Drives the well-tested UnstuckCore.FocusTimer engine
// with a TimelineView tick, persists every transition to LiveSessionStore
// (so a relaunch resumes), and writes a Session on finish via WriteThrough.
// Treatments (ambient/cockpit/monk), pause reasons, and mid-session
// captures are P3 follow-ups.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

@MainActor
@Observable
final class FocusModel {
    var live: LiveSession
    let task: TaskItem
    private let store: LiveSessionStore?

    init(task: TaskItem, store: LiveSessionStore?) {
        self.task = task
        self.store = store
        let existing: LiveSession? = (try? store?.get()) ?? nil
        // Resume-aware: start() continues a paused session for the same task.
        // priorAccumulatedSec seeds the displayed timer so reopening after
        // "Just finish" continues from the accumulated total, not 0 (Android parity).
        live = FocusTimer.start(existing ?? .empty, taskId: task.id, estimateMin: task.estimateMin,
                                priorAccumulatedSec: task.totalFocused, now: Self.now())
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
        let session = Session(id: live.id ?? newUUID(), taskId: task.id, taskName: task.name,
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

    private let reasons = ["Bathroom", "Distracted", "Switching tasks", "Quick break", "Interrupted"]

    var body: some View {
        ZStack {
            backgroundFor(fm?.treatment ?? .ambient).ignoresSafeArea()
            if let fm { content(fm) } else { ProgressView() }
        }
        .task {
            if fm == nil {
                // Finalize a different task's in-flight session before this one
                // overwrites the live session (so its elapsed time isn't lost).
                model.finalizeDisplacedFocus(forNewTaskId: task.id)
                fm = FocusModel(task: task, store: model.liveStore)
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
    private func backgroundFor(_ treatment: FocusTreatment) -> some View {
        switch treatment {
        case .ambient:
            LinearGradient(colors: [theme.palette.primarySoft, theme.palette.bg], startPoint: .top, endPoint: .bottom)
        case .cockpit:
            theme.palette.bg2
        case .monk:
            theme.palette.bg
        }
    }

    @ViewBuilder
    private func content(_ fm: FocusModel) -> some View {
        @Bindable var fm = fm
        VStack(spacing: 24) {
            HStack {
                Button { fm.cancel(); dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .medium)).foregroundStyle(theme.palette.ink3)
                }.buttonStyle(.plain)
                Spacer()
                SectionLabel("Focus")
                Spacer()
                HStack(spacing: 16) {
                    Button { soundOn.toggle(); updateAudio(fm) } label: {
                        Image(systemName: soundOn ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 16)).foregroundStyle(theme.palette.ink3)
                    }.buttonStyle(.plain)
                    Button { showCapture = true } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 17)).foregroundStyle(theme.palette.ink3)
                    }.buttonStyle(.plain)
                }
            }

            if fm.treatment != .monk {
                Picker("Treatment", selection: Binding(get: { fm.treatment }, set: { fm.setTreatment($0) })) {
                    Text("Ambient").tag(FocusTreatment.ambient)
                    Text("Cockpit").tag(FocusTreatment.cockpit)
                    Text("Monk").tag(FocusTreatment.monk)
                }
                .pickerStyle(.segmented)
            }

            Spacer()

            if fm.treatment != .monk {
                Text(task.name)
                    .font(UFont.serifItalic(26)).foregroundStyle(theme.palette.ink)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = ctx.date.timeIntervalSince1970 * 1000
                let elapsed = FocusTimer.displayedElapsedSec(fm.live, now: now)
                let state = FocusTimer.deriveState(fm.live, now: now, overrunGraceSec: 1)
                VStack(spacing: 6) {
                    Text(formatMMSS(elapsed))
                        .font(UFont.mono(56, .medium))
                        .foregroundStyle(state == .overrun ? theme.palette.coralDeep : theme.palette.ink)
                        .monospacedDigit()
                    Text(label(for: state)).font(UFont.mono(12)).foregroundStyle(theme.palette.ink3)
                    if fm.treatment == .cockpit {
                        Text("Estimate \(task.estimateMin)m").font(UFont.mono(11)).foregroundStyle(theme.palette.ink3)
                    }
                }
            }

            Spacer()
            controls(fm)
            // From monk, let the user step back up to a richer treatment.
            if fm.treatment == .monk {
                Button("Treatments") { fm.setTreatment(.ambient) }
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3).buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(20)
        .onAppear { updateAudio(fm) }
        .onChange(of: fm.treatment) { updateAudio(fm) }
    }

    @ViewBuilder
    private func controls(_ fm: FocusModel) -> some View {
        VStack(spacing: 12) {
            if fm.live.paused {
                UButton("Resume") { fm.resume() }
            } else {
                UButton("Pause", kind: .ghost) { showReasons = true }
            }
            UButton("Done") { showFinish = true }
        }
        .padding(.horizontal, 32)
    }

    /// Finish the live session, accumulate focused time, and optionally complete
    /// the task (fires the shared-collection done notification for promoted tasks).
    private func finishSession(markDone: Bool) {
        guard let fm else { return }
        let result = fm.finish()
        model.finishFocus(task: task, session: result.session, elapsedSec: result.elapsedSec, markDone: markDone)
        dismiss()
    }

    private var captureSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Capture")
            Text("Park a thought without losing focus.").font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
            TextField("Note to self…", text: $captureText, axis: .vertical)
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
        model.saveCapture(Capture(id: newUUID(), taskId: task.id, sessionId: fm?.sessionId, tag: .idea, body: text, at: AppModel.isoNow()))
    }

    private func label(for state: UnstuckCore.FocusState) -> String {
        switch state {
        case .running: return "FOCUSING"
        case .pause: return "PAUSED"
        case .overrun: return "OVERTIME"
        case .done: return "DONE"
        default: return ""
        }
    }
}
