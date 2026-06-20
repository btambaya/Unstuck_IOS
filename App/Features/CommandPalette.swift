// Quick "jump to" palette: search open tasks + a few actions. Selecting a
// task starts a focus session; actions route via the shared AppRouter.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var tasks: [TaskItem] = []
    @State private var blocks: [CalBlock] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Actions") {
                    Button { dismiss(); model.router.present(.newTask) } label: { Label("New task", systemImage: "plus") }
                    if let next = pickStartNext(tasks: tasks, blocks: blocks, liveTaskId: model.liveSession?.taskId) {
                        Button { dismiss(); model.router.beginFocus(next) } label: { Label("Focus: \(next.name)", systemImage: "timer") }
                    }
                    Button { dismiss(); model.router.select(.today) } label: { Label("Go to Today", systemImage: "sun.max") }
                    Button { dismiss(); model.router.select(.tasks) } label: { Label("Go to Tasks", systemImage: "checklist") }
                    Button { dismiss(); model.router.select(.calendar) } label: { Label("Go to Calendar", systemImage: "calendar") }
                    Button { dismiss(); model.router.select(.lists) } label: { Label("Go to Lists", systemImage: "tray.full") }
                }
                if !filtered.isEmpty {
                    // Tapping a task ESCALATES to a full-screen focus session — label
                    // the section so that's expected, not a surprise (these rows look
                    // like navigation otherwise). Mirrors the explicit "Focus:" action.
                    Section("Start focus on…") {
                        ForEach(filtered) { task in
                            Button { dismiss(); model.router.beginFocus(task) } label: {
                                Label(task.name, systemImage: "timer").foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search tasks or jump to…")
            .navigationTitle("Jump to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        // Live snapshot so the task list (and the "Focus:" pick) stays fresh while
        // the palette is open — was loaded once via all() with no blocks.
        .task {
            guard let repo = model.taskRepo else { return }
            do {
                for try await snap in repo.observeTasksAndBlocks() {
                    tasks = snap.tasks
                    blocks = snap.blocks
                }
            } catch {}
        }
    }

    private var filtered: [TaskItem] {
        let open = tasks.filter { !$0.done }
        guard !query.isEmpty else { return Array(open.prefix(8)) }
        return open.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
