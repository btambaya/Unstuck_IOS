// Capture Inbox — the triage tray reached from the Today header (the
// MoveToInbox icon left of the bell). 1:1 with the Android InboxScreen.
//
// Every thought you've captured (during focus, from a task, or on the fly)
// lands here so it can be turned into a task ("Promote"), opened in context
// ("Open", task-linked captures only), archived out of the inbox without
// deleting ("Done"/"Restore" — device-local), or removed for good ("Discard").
//
// Two views toggled by the header link: the open inbox ("To process") and the
// "Archived (n)" set. The open inbox = captures whose id is NOT in the
// device-local archived set; the archived view = captures whose id IS in it —
// both newest-first by `at`. Mirrors Android's inboxCaptures / archived filters.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

@MainActor
@Observable
final class CapturesModel {
    var all: [Capture] = []
    var tasks: [TaskItem] = []
    private let repo: TaskRepository
    init(_ repo: TaskRepository) { self.repo = repo }

    /// Observe captures + tasks. Captures drive the inbox/archived lists; tasks
    /// resolve a capture's `taskId` to a "from <task>" label (Android parity).
    func observe() async {
        async let caps: Void = observeCaptures()
        async let tsk: Void = observeTasks()
        _ = await (caps, tsk)
    }

    private func observeCaptures() async {
        do {
            for try await snap in repo.observeCaptures() { all = snap }
        } catch {}
    }

    private func observeTasks() async {
        do {
            for try await snap in repo.observeAllValues() { tasks = snap }
        } catch {}
    }

    /// Open inbox: captures not archived, newest first. Mirrors Android's
    /// `inboxCaptures` (cs.filter { it.id !in archived }.sortedByDescending { at }).
    func inbox(archivedIds: Set<String>) -> [Capture] {
        all.filter { !archivedIds.contains($0.id) }
    }

    /// Archived view: captures archived device-locally, newest first. Mirrors
    /// Android's `allCaptures.filter { it.id in archivedIds }.sortedByDescending { at }`.
    func archived(archivedIds: Set<String>) -> [Capture] {
        all.filter { archivedIds.contains($0.id) }
    }

    func taskName(_ id: String?) -> String? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }?.name
    }
}

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    @State private var vm: CapturesModel?
    @State private var showArchived = false
    // The capture pending a Discard confirm — gates the irreversible delete
    // behind a destructive dialog (consistent with confirmed deletes elsewhere).
    @State private var discardTarget: Capture?
    // Re-tick ~every 30s so the "Xm ago" ages don't freeze at screen-open time
    // (Android refreshes `now` on a 30s loop). `Date()` is read per render.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                if let vm {
                    let archivedIds = model.archivedCaptureIds
                    let archived = vm.archived(archivedIds: archivedIds)
                    let visible = showArchived ? archived : vm.inbox(archivedIds: archivedIds)
                    VStack(alignment: .leading, spacing: 0) {
                        header(archivedCount: archived.count)
                        if visible.isEmpty {
                            Text(showArchived
                                 ? "No archived captures."
                                 : "All clear. Capture a thought during a focus session — it keeps the task it came from.")
                                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(visible) { cap in card(vm, cap) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Captures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                "Discard this capture?",
                isPresented: Binding(get: { discardTarget != nil }, set: { if !$0 { discardTarget = nil } }),
                titleVisibility: .visible,
                presenting: discardTarget
            ) { cap in
                Button("Discard", role: .destructive) { model.discardCapture(cap.id); discardTarget = nil }
                Button("Cancel", role: .cancel) { discardTarget = nil }
            } message: { _ in
                Text("This removes it for good. Use “Done” to archive without deleting.")
            }
        }
        .task {
            guard vm == nil, let repo = model.taskRepo else { return }
            let m = CapturesModel(repo); vm = m; await m.observe()
        }
        .onReceive(ticker) { now = $0 }
    }

    // MARK: header (section label + archived/back toggle)

    private func header(archivedCount: Int) -> some View {
        HStack {
            SectionLabel(showArchived ? "Archived" : "To process")
            Spacer()
            if showArchived || archivedCount > 0 {
                Button { showArchived.toggle() } label: {
                    Text(showArchived ? "← Back to captures" : "Archived (\(archivedCount))")
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.ink3)
                        .padding(4)
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 4).padding(.bottom, 8)
    }

    // MARK: capture card

    private func card(_ vm: CapturesModel, _ cap: Capture) -> some View {
        let nowMs = now.timeIntervalSince1970 * 1000
        let capMs = Time.parseMillis(cap.at) ?? nowMs
        let rel = relPast(nowMs - capMs)
        let sourceTaskName = vm.taskName(cap.taskId)
        let canOpen = cap.taskId != nil

        return VStack(alignment: .leading, spacing: 0) {
            // tag dot + tag label + age + optional "from <task>"
            HStack(spacing: 8) {
                Circle().fill(tagColor(cap.tag)).frame(width: 7, height: 7)
                Text(cap.tag.rawValue.uppercased()).font(UFont.mono(10, .bold)).foregroundStyle(tagColor(cap.tag))
                Text(rel).font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
                if let sourceTaskName {
                    Text("· from \(sourceTaskName)").font(UFont.sans(11))
                        .foregroundStyle(theme.palette.ink3).lineLimit(1)
                }
            }
            Text(cap.body).font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)
                .padding(.top, 5)
            actions(cap, canOpen: canOpen)
                .padding(.top, 9)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.palette.line))
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func actions(_ cap: Capture, canOpen: Bool) -> some View {
        HStack(spacing: 0) {
            if !showArchived {
                action("Promote →", color: theme.palette.primaryDeep, weight: .bold) {
                    // Android: promoteCapture THEN archiveCapture (capture preserved).
                    model.promoteCapture(cap)
                    model.archiveCapture(cap.id)
                }
                if canOpen {
                    Spacer().frame(width: 16)
                    action("Open", color: theme.palette.ink2, weight: .semibold) { openTask(cap.taskId) }
                }
            } else if canOpen {
                action("Open", color: theme.palette.ink2, weight: .semibold) { openTask(cap.taskId) }
            }
            Spacer(minLength: 16)
            action(showArchived ? "Restore" : "Done", color: theme.palette.ink2, weight: .semibold) {
                if showArchived { model.unarchiveCapture(cap.id) } else { model.archiveCapture(cap.id) }
            }
            Spacer().frame(width: 16)
            action("Discard", color: theme.palette.ink3, weight: .regular) { discardTarget = cap }
        }
    }

    private func action(_ label: String, color: Color, weight: Font.Weight, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(label).font(UFont.sans(12, weight)).foregroundStyle(color)
                .padding(.vertical, 2)
        }.buttonStyle(.plain)
    }

    private func openTask(_ id: String?) {
        guard let id else { return }
        // Defer the present until THIS sheet finishes dismissing — the host
        // (MainTabScaffold) flushes it on the inbox sheet's onDismiss. Presenting
        // the task editor here (a second sheet on the same host) while we dismiss
        // would silently no-op in SwiftUI.
        model.routeDeepLinkAfterDismiss("unstuck://task/\(id)")
        dismiss()
    }

    // MARK: tag color (Android tagColor parity)

    private func tagColor(_ tag: CaptureTag) -> Color {
        switch tag {
        case .followUp: return theme.palette.primaryDeep
        case .idea: return theme.palette.amber
        case .edit: return theme.palette.blue
        case .question: return theme.palette.green
        case .distraction: return theme.palette.coral
        }
    }
}
