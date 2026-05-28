// The 5-item bottom bar from the iOS design: Today · Tasks · [+FAB] ·
// Calendar · Lists. The center "+" is a floating coral FAB overlaid on a
// 4-tab TabView; it opens the New-Task sheet via the shared router.

import SwiftUI
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

/// Placeholder New-Task sheet (filled out in P2).
struct NewTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme
    var body: some View {
        VStack(spacing: 16) {
            SectionLabel("New task")
            Text("Task capture lands in P2.")
                .font(UFont.sans(15)).foregroundStyle(theme.palette.ink2)
            UButton("Close") { dismiss() }.padding(.horizontal, 40)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}
