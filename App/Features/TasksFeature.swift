// P2 — Tasks. The first full vertical slice: the local GRDB store drives
// the list via ValueObservation, the view filter runs UnstuckCore's
// visibleTasks, and create / done-toggle write through WriteThrough
// (optimistic local + server outbox). Backlog/Today/Upcoming bucketing
// will sharpen once cal_blocks are observed here too (P4).

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

@MainActor
@Observable
final class TasksModel {
    var all: [TaskItem] = []
    var view: TaskListView = .all
    private let repo: TaskRepository

    init(_ repo: TaskRepository) { self.repo = repo }

    func observe() async {
        do {
            for try await rows in repo.observeAllValues() { all = rows }
        } catch { /* observation ended */ }
    }

    var visible: [TaskItem] {
        visibleTasks(view: view, tasks: all, blocks: [],
                     now: Date().timeIntervalSince1970 * 1000,
                     activeArea: nil, slipMode: false)
    }
}

struct TasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: TasksModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm { list(vm) } else { loading }
            }
            .background(theme.palette.bg.ignoresSafeArea())
        }
        .task {
            guard vm == nil, let repo = model.taskRepo else { return }
            let m = TasksModel(repo)
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
                            TaskRowView(task: task) { toggleDone(task) }
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

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(task.done ? theme.palette.green : theme.palette.ink4)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(UFont.sans(15))
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? theme.palette.ink3 : theme.palette.ink)
                HStack(spacing: 6) {
                    if let area = task.lifeArea { AreaDot(area); Text(area).font(UFont.mono(10)).foregroundStyle(theme.palette.ink3) }
                    Text("\(task.estimateMin)m").font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
                }
            }
            Spacer()
            if let p = task.priority, p == .urgent || p == .high {
                Text(p.rawValue.uppercased()).font(UFont.mono(9, .bold)).foregroundStyle(theme.palette.coralDeep)
            }
        }
        .padding(12)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(theme.palette.line))
    }
}
