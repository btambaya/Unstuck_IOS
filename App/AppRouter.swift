// Navigation state shared across the app so the FAB + command palette
// can drive tab + sheet from anywhere. (Port of the web's router intent.)

import SwiftUI
import UnstuckCore

@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable, CaseIterable { case today, tasks, calendar, lists }
    enum Sheet: Identifiable, Hashable {
        case newTask, quickCapture, inbox
        /// Insights/Analytics presented router-side (the guided tour drives
        /// this; Today's week-pill keeps its local sheet).
        case insights
        /// Settings presented router-side, optionally deep-linked to a section
        /// ("Notifications" / "Interface") — the tour's settings steps.
        case settings(section: String?)
        var id: Int { hashValue }
    }

    var tab: Tab = .today
    var activeSheet: Sheet?
    /// The Assistant panel, driven by the bottom-trailing ✦ launcher. Assistant
    /// ONLY since the redesign — feedback moved to Settings → Account → "Send
    /// feedback" (matching the web). Never set this directly: go through
    /// `AppModel.openAssistant()`, which honours the AI kill-switch.
    var showAssistant = false
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
        activeSheet != nil || showAssistant || detailTask != nil || focusTask != nil
    }

    /// Tear down every active modal so a deferred deep-link can present cleanly
    /// once they finish dismissing (each host's onDismiss flushes the pending link).
    func dismissAllPresentations() {
        activeSheet = nil
        showAssistant = false
        detailTask = nil
        focusTask = nil
        sharedFocus = nil
    }

    /// The guided tour's dismiss: closes only the modals the TOUR can have
    /// opened (router sheet, task detail, assistant bubble). `focusTask` is
    /// deliberately left alone — the tour never presents Focus (its focus
    /// steps stay on Today), so a live focus cover can only be a session the
    /// USER started, and tour navigation must never tear that down.
    func dismissTourPresentations() {
        activeSheet = nil
        showAssistant = false
        detailTask = nil
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
