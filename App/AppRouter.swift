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

    /// Calendar's Day / Week / Month mode. Router-owned (not CalendarView
    /// @State) so the assistant's `open_screen: week|month` actually switches
    /// the mode instead of just landing on the tab.
    enum CalendarMode: String, Hashable, CaseIterable { case day = "Day", week = "Week", month = "Month" }

    /// Backing storage for `tab` — go through `tab`, never this.
    private var storedTab: Tab = .today
    /// The selected tab. Writing it is ALSO the moment the old surface is left,
    /// so it retracts what that surface published (`collectionsSurface`, which
    /// only ListsView can republish and only while it is mounted) and drops a
    /// `+` request the outgoing surface never got to consume. Every tab change
    /// in the app goes through here — `select(_:)`, the bottom nav, the command
    /// palette, the assistant, the tour, deep links — so the retraction is part
    /// of the state change itself and does not wait on an `onDisappear`.
    var tab: Tab {
        get { storedTab }
        set {
            guard newValue != storedTab else { return }
            storedTab = newValue
            collectionsSurface = nil
            collectionFabRequest = nil
        }
    }
    var activeSheet: Sheet?
    var calendarMode: CalendarMode = .day
    /// Realtime Talk presented from Today's gateway mic (a full-screen cover on
    /// TodayView's host). Router-owned so a navigation the assistant drives
    /// while Talk is up counts as an active presentation: the deferred
    /// deep-link path dismisses it and presents the target on its onDismiss.
    var showTalk = false
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
    /// When set, the read-only SHARED-task detail is presented for this task
    /// (a `task_share` / `invite_claimed` push tap on a task someone shared
    /// WITH me — its id is not in my local store, RLS keeps the row away, so
    /// the owner editor can't open it; the shared sheet reads the
    /// `shared_task_detail` projection instead).
    var sharedDetail: SharedDetailTarget?
    /// A collection id parked by `unstuck://collections/<id>` (a share push
    /// tap): the Collections tab pushes its detail once the row exists
    /// locally and clears this.
    var openCollectionId: String?

    /// A deep link captured INSIDE a presented sheet (Inbox "Open", Notification
    /// Center tap) to route AFTER that sheet finishes dismissing. SwiftUI can't
    /// present a second sheet from the same host while the first is still
    /// dismissing, so the host flushes this on its sheet's `onDismiss`.
    var pendingDeepLink: String?

    // MARK: - the bottom-bar + (context-sensitive)

    /// What the Collections tab is showing RIGHT NOW. The Collections detail is
    /// a `NavigationLink` destination INSIDE that tab, so `tab` alone can't tell
    /// the scaffold a collection is open, nor which one.
    ///
    /// ListsView publishes this, and every part of it is DERIVED rather than
    /// remembered: the id comes from the NavigationStack path ListsView owns —
    /// which the stack itself rewrites on every push and pop, Back button and
    /// swipe-back included — and the rights come from the live row. So it cannot
    /// say "a collection is open" while the grid is showing, and it cannot keep
    /// claiming edit rights a sync just took away. `nil` means the surface isn't
    /// there to answer: the tab isn't mounted, or its store hasn't come up yet
    /// (see `fabAction` — an unbuilt shelf is offered no create it can't do).
    ///
    /// Three independent mechanisms keep it honest, so no single callback is
    /// load-bearing: ListsView republishes it from its own state on every
    /// update; `tab`'s setter clears it on the way out of the tab; and sign-out
    /// clears it via `clearCollectionsSurface()`, since that tears the whole
    /// scaffold down without a tab change.
    var collectionsSurface: CollectionsSurface?

    enum CollectionsSurface: Equatable, Sendable {
        /// The grid, with the store observed — a new collection can be created.
        case grid
        /// A collection detail is pushed. `canEdit` is false on a share I can
        /// only VIEW: the + must not offer an add the server would refuse.
        case detail(id: String, canEdit: Bool)
    }

    /// A + tap that only the Collections surface can carry out: the
    /// New-collection sheet and the detail's add-field focus are view-local
    /// (`@State` / `@FocusState`) and out of the router's reach, so the
    /// scaffold parks the resolved action here and the owning view consumes
    /// and clears it. Identified rather than a Bool so two taps in a row both
    /// register. Each action has exactly ONE consumer (grid → .newCollection,
    /// detail → .addToCollection), so neither can swallow the other's request.
    var collectionFabRequest: CollectionFabRequest?

    struct CollectionFabRequest: Equatable, Identifiable, Sendable {
        let id = UUID()
        let action: FabAction
    }

    /// What the bottom bar's coral + does on the surface you're looking at.
    /// The button itself never changes — same coral square, same position;
    /// only this and its VoiceOver label move with context.
    enum FabAction: Equatable, Sendable {
        case newTask
        case newCollection
        /// Put the cursor in THIS collection's inline "Add to this collection…"
        /// field. Deliberately NOT a second add sheet — both apps already have
        /// that one field, and one add path is the whole point.
        case addToCollection(id: String)

        var accessibilityLabel: String {
            switch self {
            case .newTask: return "New task"
            case .newCollection: return "New collection"
            case .addToCollection: return "Add to this collection"
            }
        }
    }

    /// Resolve the + for the current surface. Pure and `nonisolated` so the
    /// routing decision itself is unit-tested (FabActionTests) instead of being
    /// inferred from the UI:
    ///   • Today / Tasks / Calendar → New task (unchanged — the guided tour's
    ///     first-action step falls back to this anchor on the Tasks tab).
    ///   • The Collections grid → New collection.
    ///   • Inside a collection I can edit → its inline add field.
    ///   • Inside a collection I can only VIEW → New collection: a useful
    ///     fallback beats an "add" I'd be refused.
    ///   • The Collections tab with NO surface published (its store hasn't been
    ///     built yet, so the shelf is still a spinner) → New task. Creating a
    ///     collection there would be a tap into the void — the sheet's Create
    ///     needs the store this surface hasn't got — so the + offers the one
    ///     thing that does work, and says so in its label.
    nonisolated static func fabAction(tab: Tab, surface: CollectionsSurface?) -> FabAction {
        // Off the Collections tab the surface is irrelevant by construction, so
        // read it nowhere else — belt-and-braces on top of the retractions.
        guard tab == .lists else { return .newTask }
        switch surface {
        case .detail(let id, canEdit: true): return .addToCollection(id: id)
        case .detail, .grid: return .newCollection
        case nil: return .newTask
        }
    }

    func select(_ tab: Tab) { self.tab = tab }
    func present(_ sheet: Sheet) { activeSheet = sheet }

    /// Sign-out: the whole scaffold is torn down without a tab change, so the
    /// Collections surface (and any unconsumed + request) is retracted here too
    /// — it described the account that just left.
    func clearCollectionsSurface() {
        collectionsSurface = nil
        collectionFabRequest = nil
    }

    /// Start a normal own-task focus (clears any stale shared marker so this
    /// session never inherits a prior shared context).
    func beginFocus(_ task: TaskItem) { sharedFocus = nil; focusTask = task }

    /// Any modal currently up on the single MainTabScaffold host. SwiftUI can't
    /// present a second sheet/cover from one host while another is up (the new
    /// one silently no-ops), so a push deep-link arriving now must dismiss first
    /// and present after (see AppModel.routeDeepLink).
    var hasActivePresentation: Bool {
        activeSheet != nil || showAssistant || detailTask != nil || sharedDetail != nil || focusTask != nil || showTalk
    }

    /// Tear down every active modal so a deferred deep-link can present cleanly
    /// once they finish dismissing (each host's onDismiss flushes the pending link).
    func dismissAllPresentations() {
        activeSheet = nil
        showAssistant = false
        showTalk = false
        detailTask = nil
        sharedDetail = nil
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
        showTalk = false
        detailTask = nil
        sharedDetail = nil
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
