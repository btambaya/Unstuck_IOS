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
            .fullScreenCover(item: $router.focusTask, onDismiss: { router.sharedFocus = nil; model.flushPendingDeepLink() }) { task in
                // `sharedFocus` (set alongside focusTask by beginSharedFocus) makes
                // this a recipient's shared focus (T3); nil = a normal own-task focus.
                FocusView(task: task, shared: router.sharedFocus)
            }
            // Invite-link flow (universal link → confirmed join → visible outcome).
            // Alerts, not sheets, so they present over whatever is up. The tester's
            // note on the old silent auto-redeem: "no way to accept or decline,
            // when it auto accepts this isn't visible."
            .alert("Join their circle?", isPresented: confirmInviteShown, presenting: confirmInviteCode) { code in
                Button("Accept") { model.acceptCircleInvite(code: code) }
                Button("Not now", role: .cancel) {}
            } message: { _ in
                Text("You opened an invite link. Accept to connect — you’ll see each other under Settings → People, and tasks they share with you appear in “Shared with you”.")
            }
            .alert(inviteResultOK ? "You’re in 🤝" : "Couldn’t join", isPresented: inviteResultShown, presenting: inviteResultMessage) { _ in
                Button("OK") { model.circleInvitePrompt = nil }
            } message: { msg in
                Text(msg)
            }
    }

    // MARK: - invite-prompt bindings (confirm + result over circleInvitePrompt)

    private var confirmInviteCode: String? {
        if case .confirm(let code) = model.circleInvitePrompt { return code }
        return nil
    }
    private var confirmInviteShown: Binding<Bool> {
        Binding(
            get: { confirmInviteCode != nil },
            // Only clear if still on the confirm case — Accept swaps the state to
            // .result asynchronously and the dismissal must not clobber it.
            set: { shown in
                if !shown, case .confirm = model.circleInvitePrompt { model.circleInvitePrompt = nil }
            })
    }
    private var inviteResultOK: Bool {
        if case .result(let ok, _) = model.circleInvitePrompt { return ok }
        return true
    }
    private var inviteResultMessage: String? {
        if case .result(_, let message) = model.circleInvitePrompt { return message }
        return nil
    }
    private var inviteResultShown: Binding<Bool> {
        Binding(
            get: { inviteResultMessage != nil },
            set: { shown in
                if !shown, case .result = model.circleInvitePrompt { model.circleInvitePrompt = nil }
            })
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
