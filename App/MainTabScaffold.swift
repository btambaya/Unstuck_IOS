// The 5-item bottom bar from the iOS design: Today · Tasks · [+FAB] ·
// Calendar · Lists. The center "+" is a floating coral FAB overlaid on a
// 4-tab TabView; it opens the New-Task sheet via the shared router.

import SwiftUI
import UnstuckCore
import UnstuckDesign

struct MainTabScaffold: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    var body: some View {
        @Bindable var router = model.router
        ZStack(alignment: .bottom) {
            TabView(selection: $router.tab) {
                TodayView()
                    .tabItem { Label("Today", systemImage: "sun.max") }.tag(AppRouter.Tab.today)
                TasksView()
                    .tabItem { Label("Tasks", systemImage: "checklist") }.tag(AppRouter.Tab.tasks)
                CalendarView()
                    .tabItem { Label("Calendar", systemImage: "calendar") }.tag(AppRouter.Tab.calendar)
                ListsView()
                    .tabItem { Label("Lists", systemImage: "tray.full") }.tag(AppRouter.Tab.lists)
            }
            .tint(theme.palette.primary)

            fab
        }
        .sheet(item: $router.activeSheet) { sheet in
            switch sheet {
            case .newTask: NewTaskSheet()
            case .quickCapture: NewTaskSheet()   // placeholder until capture lands
            }
        }
    }

    private var fab: some View {
        Button { model.router.present(.newTask) } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(theme.palette.coralDeep)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .offset(y: -28)
        .accessibilityLabel("New task")
    }
}

/// New-Task capture. Writes through WriteThrough (optimistic local +
/// outbox); the Tasks list updates instantly via ValueObservation.
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    @State private var name = ""
    @State private var estimate = 25
    @State private var priority: Priority = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("New task")
            TextField("What needs doing?", text: $name)
                .font(UFont.sans(17))
                .textFieldStyle(.plain)
                .padding(12)
                .background(theme.palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))

            HStack(spacing: 8) {
                SectionLabel("Estimate")
                Stepper("\(estimate)m", value: $estimate, in: 5...240, step: 5)
                    .font(UFont.sans(14))
            }

            Picker("Priority", selection: $priority) {
                ForEach(Priority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)

            UButton("Add task") { create() }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = AppModel.isoNow()
        let task = TaskItem(id: newUUID(), name: trimmed, estimateMin: estimate,
                            priority: priority, createdAt: now, updatedAt: now)
        model.saveTask(task)
        dismiss()
    }
}
