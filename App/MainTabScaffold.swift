// Root scaffold matching the Android design: a custom bottom nav — one row of
// five equal slots, Today · Tasks · [coral +] · Calendar · Collections — with a
// pill active indicator; the rounded-square coral + sits IN the row (not lifted
// above it). The selected tab's screen fills the area above the bar; each
// screen keeps its own NavigationStack.

import SwiftUI
import UnstuckCore
import UnstuckDesign

struct MainTabScaffold: View {
    @State private var showCallTalk = false
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    var body: some View {
        @Bindable var router = model.router
        ZStack(alignment: .bottom) {
            tabContent(router.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            BottomNavBar(active: router.tab,
                         onSelect: { router.tab = $0 },
                         fabLabel: fabAction.accessibilityLabel,
                         onFab: { tapFab() })
                // Pinned to the bottom of the SCREEN, so the keyboard slides up
                // over it like a system tab bar (and away again on dismiss).
                // As a plain child of this keyboard-avoiding ZStack it rode up
                // to sit ON the keyboard, over the bottom ~60 pt of the tab's
                // scroll view — exactly where a ScrollView parks a focused
                // field (flush with the keyboard), so an item being edited or
                // added at the bottom of a collection vanished under the bar
                // (Ahmad, build 97). The tab content keeps its keyboard
                // avoidance; only the bar opts out. The flexible frame is what
                // lets it opt out: it spans the ZStack down to the keyboard
                // edge, so ignoring the keyboard inset stretches it to the
                // screen's bottom safe edge and the bar aligns there. Its empty
                // area takes no touches.
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
            .background(theme.palette.bg.ignoresSafeArea())
            .sheet(item: $router.activeSheet, onDismiss: { model.flushPendingDeepLink() }) { sheet in
                switch sheet {
                case .newTask: NewTaskSheet(defaultEstimate: model.settings.focusDefaultMin)
                case .quickCapture: NewTaskSheet(defaultEstimate: model.settings.focusDefaultMin)
                case .inbox: InboxView()
                case .insights: NavigationStack { AnalyticsView() }
                case .settings(let section): SettingsView(section: section)
                }
            }
            // The Assistant panel. `showAssistant` is only ever set through
            // AppModel.openAssistant(), which honours the AI kill-switch — the
            // extra guard here means flipping the switch OFF mid-session
            // dismisses whatever is open.
            .sheet(isPresented: assistantSheetShown, onDismiss: { model.flushPendingDeepLink() }) {
                AssistantSheet()
            }
            // Notification deep links (unstuck://task/<id>) open the task
            // editor from anywhere — Android's Route.Detail push. onDismiss
            // flushes a deferred deep-link so a push tap arriving while THIS
            // sheet was open presents cleanly once it's gone (bug-8 guard).
            .sheet(item: $router.detailTask, onDismiss: { model.flushPendingDeepLink() }) { task in
                TaskEditor(task: task)
            }
            // A push tap on a task shared WITH me (`unstuck://task/<id>` whose id
            // is not in my store): the read-only shared detail, not the owner
            // editor (unified sharing v1).
            .sheet(item: $router.sharedDetail, onDismiss: { model.flushPendingDeepLink() }) { target in
                SharedTaskDetailSheet(taskId: target.id, block: target.block)
            }
            .fullScreenCover(isPresented: $showCallTalk) { VoiceModeScreen() }
            // "Unstuck calls you", fallback B: a tapped call alert parks a CallSession on
            // the launcher; present Talk, which takes it and runs the call configuration.
            // If a VoiceModeScreen is ALREADY up (Today's gateway mic / the Assistant
            // sheet's Talk), it takes the call itself — a second cover here would
            // strand the pending session behind the first one.
            .onChange(of: RealtimeCallVoiceLauncher.shared.pendingSession != nil) { _, hasCall in
                if hasCall, !VoiceSessionModel.isPresented { showCallTalk = true }
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
            // App open with Calls on for this account and no AI-consent OK
            // (AppModel.askAboutCallsOnOpenIfNeeded): the ask — and on "Not
            // now", the line that says Calls went off.
            .aiConsentSheet(.root)
            .alert(AIConsent.callsTurnedOffTitle, isPresented: rootConsentNoteShown) {
                Button("OK") { model.aiConsentNote = nil }
            } message: {
                Text(model.aiConsentNote?.text ?? "")
            }
            .task { model.askAboutCallsOnOpenIfNeeded() }
            // Guided product tour — lives in its OWN always-on-top passthrough
            // window so the spotlight + panel render above every sheet and the
            // focus fullScreenCover (a root overlay here would be covered).
            // Mounted from the scaffold = signed-in + onboarded only.
            .background(TourWindowMounter(model: model,
                                          colorSchemeOverride: model.settings.theme.colorScheme))
    }

    // MARK: - the bottom-bar + (creates what you're looking at)

    /// Resolved from router state only (the tab + what the Collections tab says
    /// it is showing) — the FAB's look and position are untouched; only what it
    /// does and its VoiceOver label follow the surface.
    private var fabAction: AppRouter.FabAction {
        AppRouter.fabAction(tab: model.router.tab, surface: model.router.collectionsSurface)
    }

    private func tapFab() {
        let action = fabAction
        switch action {
        case .newTask:
            model.router.present(.newTask)
        case .newCollection, .addToCollection:
            // Both live inside the Collections surface (a local sheet / a
            // focused text field), so hand the resolved action to it.
            model.router.collectionFabRequest = .init(action: action)
        }
    }

    /// Presented only while the assistant is enabled — turning the kill-switch
    /// off closes an open panel instead of leaving it stranded.
    private var assistantSheetShown: Binding<Bool> {
        Binding(
            get: { model.router.showAssistant && model.assistantEnabled },
            set: { model.router.showAssistant = $0 })
    }

    private var rootConsentNoteShown: Binding<Bool> {
        Binding(
            get: { model.aiConsentNote?.host == .root },
            set: { shown in if !shown, model.aiConsentNote?.host == .root { model.aiConsentNote = nil } })
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

}
