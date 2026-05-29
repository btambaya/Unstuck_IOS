// P2 — Today. Start Next (UnstuckCore.pickStartNext) + Up Next
// (pickUpNext) + today's open tasks, all from the live GRDB store. The
// "Begin focus" action is a placeholder until the Focus surface (P3).

import SwiftUI
import WidgetKit
import UnstuckCore
import UnstuckData
import UnstuckDesign
import UnstuckShared

@MainActor
@Observable
final class TodayModel {
    var all: [TaskItem] = []
    var blocks: [CalBlock] = []
    private let repo: TaskRepository
    init(_ repo: TaskRepository) { self.repo = repo }

    func observe() async {
        do {
            for try await snap in repo.observeTasksAndBlocks() {
                all = snap.tasks
                blocks = snap.blocks
                writeWidgetSnapshot()
            }
        } catch {}
    }

    /// Mirror Start Next into the App Group so the home/lock widgets render
    /// it without the network, and nudge WidgetKit to reload.
    private func writeWidgetSnapshot() {
        let next = startNext
        let openCount = all.filter { !$0.done && !($0.later ?? false) }.count
        AppGroup.writeStartNext(StartNextSnapshot(
            taskName: next?.name, estimateMin: next?.estimateMin, lifeArea: next?.lifeArea,
            openCount: openCount, updatedAt: Date()))
        WidgetCenter.shared.reloadAllTimelines()
    }

    var startNext: TaskItem? { pickStartNext(tasks: all, blocks: [], liveTaskId: nil) }
    var upNext: [TaskItem] { pickUpNext(tasks: all, blocks: [], liveTaskId: nil, startNextId: startNext?.id) }
    var today: [TaskItem] {
        visibleTasks(view: .today, tasks: all, blocks: blocks,
                     now: Date().timeIntervalSince1970 * 1000, activeArea: nil, slipMode: false)
    }
}

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: TodayModel?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionLabel("Today")
                    Text("What's next.").font(UFont.serifItalic(34)).foregroundStyle(theme.palette.ink)

                    if let vm {
                        startNextCard(vm)
                        if !vm.upNext.isEmpty { upNextSection(vm) }
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .task {
            guard vm == nil, let repo = model.taskRepo else { return }
            let m = TodayModel(repo); vm = m; await m.observe()
        }
    }

    @ViewBuilder
    private func startNextCard(_ vm: TodayModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Start next")
                if let t = vm.startNext {
                    Text(t.name).font(UFont.sans(20, .medium)).foregroundStyle(theme.palette.ink)
                    HStack(spacing: 8) {
                        if let area = t.lifeArea { AreaDot(area); Text(area).font(UFont.mono(11)).foregroundStyle(theme.palette.ink3) }
                        Text("\(t.estimateMin) min").font(UFont.mono(11)).foregroundStyle(theme.palette.ink3)
                    }
                    UButton("Begin focus") { model.router.beginFocus(t) }
                } else {
                    Text("All clear. Add a task to get going.")
                        .font(UFont.sans(15)).foregroundStyle(theme.palette.ink2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func upNextSection(_ vm: TodayModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Up next")
            ForEach(vm.upNext) { t in
                HStack(spacing: 10) {
                    AreaDot(t.lifeArea)
                    Text(t.name).font(UFont.sans(15)).foregroundStyle(theme.palette.ink)
                    Spacer()
                    Text("\(t.estimateMin)m").font(UFont.mono(11)).foregroundStyle(theme.palette.ink3)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(theme.palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
        }
    }
}
