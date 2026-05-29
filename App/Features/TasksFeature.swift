// P2 — Tasks. The first full vertical slice: the local GRDB store drives
// the list via ValueObservation, the view filter runs UnstuckCore's
// visibleTasks, and create / done-toggle write through WriteThrough
// (optimistic local + server outbox). Backlog/Today/Upcoming bucketing
// will sharpen once cal_blocks are observed here too (P4).

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign
import UnstuckShared

@MainActor
@Observable
final class TasksModel {
    var all: [TaskItem] = []
    var blocks: [CalBlock] = []
    var view: TaskListView = .all
    var slipMode = false
    private let repo: TaskRepository

    init(_ repo: TaskRepository) { self.repo = repo }

    func observe() async {
        do {
            for try await snap in repo.observeTasksAndBlocks() {
                all = snap.tasks
                blocks = snap.blocks
            }
        } catch { /* observation ended */ }
    }

    var visible: [TaskItem] {
        visibleTasks(view: view, tasks: all, blocks: blocks,
                     now: Date().timeIntervalSince1970 * 1000,
                     activeArea: nil, slipMode: slipMode)
    }

    func blocks(forTask id: String) -> [CalBlock] { blocks.filter { $0.taskId == id } }
}

struct TasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: TasksModel?
    @State private var editing: TaskItem?

    var body: some View {
        NavigationStack {
            Group {
                if let vm { list(vm) } else { loading }
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let vm {
                        Button { vm.slipMode.toggle() } label: {
                            Image(systemName: vm.slipMode ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                        }
                    }
                }
            }
            .sheet(item: $editing) { task in
                TaskEditor(task: task, existingBlocks: vm?.blocks(forTask: task.id) ?? [])
            }
        }
        .task {
            guard vm == nil, let repo = model.taskRepo else { return }
            let m = TasksModel(repo)
            // Honor an active iOS Focus Filter (reconcile on appear — iOS 18
            // perform() can be flaky, so reading the App-Group flag here too).
            if AppGroup.focusFilterActive(), AppGroup.focusFilterHideNonToday() { m.view = .today }
            vm = m
            await m.observe()
        }
    }

    private var loading: some View {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func list(_ vm: TasksModel) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tasks").font(UFont.serifItalic(32)).foregroundStyle(theme.palette.ink)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TaskListView.allCases, id: \.self) { v in
                        Button { vm.view = v } label: { Chip(v.rawValue, selected: vm.view == v) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }

            if vm.visible.isEmpty {
                Card { Text("Nothing here yet. Tap + to add a task.").font(UFont.sans(14)).foregroundStyle(theme.palette.ink2) }
                    .padding(.horizontal, 20).padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.visible) { task in
                            TaskRowView(task: task, onToggle: { toggleDone(task) }, onOpen: { editing = task })
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func toggleDone(_ task: TaskItem) {
        var next = task
        next.done.toggle()
        let stamped = applyCompletion(next, prior: task, nowISO: AppModel.isoNow())
        model.saveTask(stamped)
    }
}

struct TaskRowView: View {
    @Environment(\.uTheme) private var theme
    let task: TaskItem
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(task.done ? theme.palette.green : theme.palette.ink4)
            }
            .buttonStyle(.plain)

            Button(action: onOpen) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.name)
                            .font(UFont.sans(15))
                            .strikethrough(task.done)
                            .foregroundStyle(task.done ? theme.palette.ink3 : theme.palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 6) {
                            if let area = task.lifeArea { AreaDot(area); Text(area).font(UFont.mono(10)).foregroundStyle(theme.palette.ink3) }
                            Text("\(task.estimateMin)m").font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
                            if task.recurrence != nil {
                                Image(systemName: "repeat").font(.system(size: 9)).foregroundStyle(theme.palette.ink3)
                            }
                        }
                    }
                    if let p = task.priority, p == .urgent || p == .high {
                        Text(p.rawValue.uppercased()).font(UFont.mono(9, .bold)).foregroundStyle(theme.palette.coralDeep)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(theme.palette.line))
    }
}
