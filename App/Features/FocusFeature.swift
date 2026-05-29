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
    private let onComplete: (Session) -> Void

    init(task: TaskItem, store: LiveSessionStore?, onComplete: @escaping (Session) -> Void) {
        self.task = task
        self.store = store
        self.onComplete = onComplete
        let existing: LiveSession? = (try? store?.get()) ?? nil
        // Resume-aware: start() continues a paused session for the same task.
        live = FocusTimer.start(existing ?? .empty, taskId: task.id, estimateMin: task.estimateMin, now: Self.now())
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

    func finish() {
        let elapsed = FocusTimer.elapsedSec(live, now: Self.now())
        onComplete(Session(id: newUUID(), taskId: task.id, taskName: task.name,
                           estimateMin: task.estimateMin, actualSec: elapsed, completedAt: AppModel.isoNow()))
        live = FocusTimer.done(live)
        persist()
        LiveActivityController.shared.end()
        PausedCheckinScheduler.cancel()
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
    @State private var captureText = ""

    private let reasons = ["Bathroom", "Distracted", "Switching tasks", "Quick break", "Interrupted"]

    var body: some View {
        ZStack {
            backgroundFor(fm?.treatment ?? .ambient).ignoresSafeArea()
            if let fm { content(fm) } else { ProgressView() }
        }
        .task {
            if fm == nil {
                fm = FocusModel(task: task, store: model.liveStore, onComplete: { model.saveSession($0) })
            }
        }
        .confirmationDialog("Why are you pausing?", isPresented: $showReasons, titleVisibility: .visible) {
            ForEach(reasons, id: \.self) { reason in
                Button(reason) { pauseWith(reason) }
            }
            Button("Just pause", role: .cancel) { fm?.pause(); coordinateCheckin() }
        }
        .sheet(isPresented: $showCapture) { captureSheet }
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
                Button { showCapture = true } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 17)).foregroundStyle(theme.palette.ink3)
                }.buttonStyle(.plain)
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
    }

    @ViewBuilder
    private func controls(_ fm: FocusModel) -> some View {
        VStack(spacing: 12) {
            if fm.live.paused {
                UButton("Resume") { fm.resume() }
            } else {
                UButton("Pause", kind: .ghost) { showReasons = true }
            }
            UButton("Done") { fm.finish(); dismiss() }
        }
        .padding(.horizontal, 32)
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
