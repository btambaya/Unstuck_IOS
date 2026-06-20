// Root scaffold matching the Android design: a custom bottom nav
// (Today · Tasks · [coral FAB] · Calendar · Collections) with a pill active
// indicator + a floating rounded-square coral FAB. The selected tab's screen
// fills the area above the bar; each screen keeps its own NavigationStack.

import SwiftUI
import UnstuckCore
import UnstuckDesign

struct MainTabScaffold: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    var body: some View {
        @Bindable var router = model.router
        ZStack(alignment: .bottom) {
            tabContent(router.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            BottomNavBar(active: router.tab,
                         onSelect: { router.tab = $0 },
                         onFab: { router.present(.newTask) })
        }
            .background(theme.palette.bg.ignoresSafeArea())
            .sheet(item: $router.activeSheet, onDismiss: { model.flushPendingDeepLink() }) { sheet in
                switch sheet {
                case .newTask: NewTaskSheet(defaultEstimate: model.settings.focusDefaultMin)
                case .quickCapture: NewTaskSheet(defaultEstimate: model.settings.focusDefaultMin)
                case .inbox: InboxView()
                }
            }
            .sheet(isPresented: $router.showBubble, onDismiss: { model.flushPendingDeepLink() }) {
                BubbleSheet(screen: screenLabel(router.tab), startTab: router.bubbleStartTab)
            }
            // Notification deep links (unstuck://task/<id>) open the task
            // editor from anywhere — Android's Route.Detail push. onDismiss
            // flushes a deferred deep-link so a push tap arriving while THIS
            // sheet was open presents cleanly once it's gone (bug-8 guard).
            .sheet(item: $router.detailTask, onDismiss: { model.flushPendingDeepLink() }) { task in
                TaskEditor(task: task)
            }
            .fullScreenCover(item: $router.focusTask, onDismiss: { model.flushPendingDeepLink() }) { task in
                FocusView(task: task)
            }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppRouter.Tab) -> some View {
        switch tab {
        case .today: TodayView()
        case .tasks: TasksView()
        case .calendar: CalendarView()
        case .lists: ListsView()
        }
    }

    private func screenLabel(_ tab: AppRouter.Tab) -> String {
        switch tab {
        case .today: return "today"
        case .tasks: return "tasks"
        case .calendar: return "calendar"
        case .lists: return "lists"
        }
    }
}
