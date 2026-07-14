// Navigation state shared across the app so the FAB + command palette
// can drive tab + sheet from anywhere. (Port of the web's router intent.)

import SwiftUI
import UnstuckCore

@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable, CaseIterable { case today, tasks, calendar, lists }
    enum Sheet: Identifiable {
        case newTask, quickCapture, inbox
        var id: Int { hashValue }
    }

    var tab: Tab = .today
    var activeSheet: Sheet?
    /// The floating bubble's dual-purpose sheet (Assistant chat + Feedback),
    /// driven by the bottom-trailing bubble. Matches Android's bubble, which
    /// exposes both surfaces behind one entry point.
    var showBubble = false
    /// Which tab the bubble sheet opens on. The bubble itself opens Assistant;
    /// kept here so a future "report a bug" entry can deep-link to Feedback.
    var bubbleStartTab: BubbleTab = .assistant
    enum BubbleTab { case assistant, feedback }
    /// When set, the Focus surface is presented full-screen for this task.
    var focusTask: TaskItem?
    /// Set ALONGSIDE `focusTask` when the presented Focus session is on a task
    /// shared WITH me (partner/assign). Carries the shared identity into the live
    /// session so finalize accrues onto the OWNER's task via log_shared_focus
    /// (Option B) instead of writing my own Session/totalFocused. nil for a
    /// normal own-task focus.
    var sharedFocus: SharedFocusContext?
    /// When set, the task editor is presented for this task (notification
    /// deep links: unstuck://task/<id> — Android Route.Detail).
    var detailTask: TaskItem?
    /// A deep link captured INSIDE a presented sheet (Inbox "Open", Notification
    /// Center tap) to route AFTER that sheet finishes dismissing. SwiftUI can't
    /// present a second sheet from the same host while the first is still
    /// dismissing, so the host flushes this on its sheet's `onDismiss`.
    var pendingDeepLink: String?

    func select(_ tab: Tab) { self.tab = tab }
    func present(_ sheet: Sheet) { activeSheet = sheet }
    /// Start a normal own-task focus (clears any stale shared marker so this
    /// session never inherits a prior shared context).
    func beginFocus(_ task: TaskItem) { sharedFocus = nil; focusTask = task }

    /// Any modal currently up on the single MainTabScaffold host. SwiftUI can't
    /// present a second sheet/cover from one host while another is up (the new
    /// one silently no-ops), so a push deep-link arriving now must dismiss first
    /// and present after (see AppModel.routeDeepLink).
    var hasActivePresentation: Bool {
        activeSheet != nil || showBubble || detailTask != nil || focusTask != nil
    }

    /// Tear down every active modal so a deferred deep-link can present cleanly
    /// once they finish dismissing (each host's onDismiss flushes the pending link).
    func dismissAllPresentations() {
        activeSheet = nil
        showBubble = false
        detailTask = nil
        focusTask = nil
        sharedFocus = nil
    }
}

/// The shared identity carried into a Focus session on a task shared WITH me
/// (partner/assign). The recipient doesn't own the task (no local row), so the
/// live session is seeded from this instead of the own store, and finalize logs
/// the elapsed onto the OWNER's task via log_shared_focus (T3, Option B).
struct SharedFocusContext: Equatable {
    let taskId: String
    let title: String
    let estimateMin: Int
    let level: ShareLevel
}
