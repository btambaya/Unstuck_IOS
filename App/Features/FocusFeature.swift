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
    }

    func pause() { live = FocusTimer.pause(live, now: Self.now()); persist() }
    func resume() { live = FocusTimer.resume(live, now: Self.now()); persist() }

    func finish() {
        let elapsed = FocusTimer.elapsedSec(live, now: Self.now())
        onComplete(Session(id: newUUID(), taskId: task.id, taskName: task.name,
                           estimateMin: task.estimateMin, actualSec: elapsed, completedAt: AppModel.isoNow()))
        live = FocusTimer.done(live)
        persist()
    }

    func cancel() {
        live = FocusTimer.cancel(live)
        persist()
    }

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

    var body: some View {
        ZStack {
            theme.palette.bg.ignoresSafeArea()
            if let fm { content(fm) } else { ProgressView() }
        }
        .task {
            if fm == nil {
                fm = FocusModel(task: task, store: model.liveStore, onComplete: { model.saveSession($0) })
            }
        }
    }

    @ViewBuilder
    private func content(_ fm: FocusModel) -> some View {
        VStack(spacing: 28) {
            HStack {
                Button { fm.cancel(); dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .medium)).foregroundStyle(theme.palette.ink3)
                }.buttonStyle(.plain)
                Spacer()
                SectionLabel("Focus")
                Spacer()
                Color.clear.frame(width: 20, height: 20)
            }
            Spacer()

            Text(task.name)
                .font(UFont.serifItalic(26))
                .foregroundStyle(theme.palette.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = ctx.date.timeIntervalSince1970 * 1000
                let elapsed = FocusTimer.displayedElapsedSec(fm.live, now: now)
                let state = FocusTimer.deriveState(fm.live, now: now, overrunGraceSec: 1)
                VStack(spacing: 6) {
                    Text(formatMMSS(elapsed))
                        .font(UFont.mono(56, .medium))
                        .foregroundStyle(state == .overrun ? theme.palette.coralDeep : theme.palette.ink)
                        .monospacedDigit()
                    Text(label(for: state))
                        .font(UFont.mono(12))
                        .foregroundStyle(theme.palette.ink3)
                }
            }

            Spacer()
            controls(fm)
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
                UButton("Pause", kind: .ghost) { fm.pause() }
            }
            UButton("Done") { fm.finish(); dismiss() }
        }
        .padding(.horizontal, 32)
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
