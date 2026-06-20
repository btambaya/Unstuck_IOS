// Tasks — 1:1 with the Android TasksScreen: the shared AppBar ("Tasks" +
// search + avatar), a "Your tasks" serif-italic title, ROW 1 bucket pills
// (Backlog/All/Today/Upcoming/Later/Completed, each a per-tab accent with a
// colored dot when inactive, tinted-filled when active), ROW 2 area filter
// pills (All + each life area, selected = inverted ink), then the task rows
// (card: name + area-dot + area + recurrence + tags, estimate on the right,
// a backlog-age badge in the Backlog view). Only the list scrolls; the
// header is pinned. Live store via GRDB.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign
import UnstuckShared

@MainActor
@Observable
final class TasksModel {
    var all: [TaskItem] = [] { didSet { recomputeSnapshot() } }
    var blocks: [CalBlock] = [] { didSet { recomputeSnapshot() } }
    var areas: [LifeArea] = []
    var view: TaskListView = .all { didSet { recomputeVisible() } }
    var activeArea: String? { didSet { recomputeVisible() } }
    var activeTag: String? { didSet { recomputeVisible() } }
    var slipMode = false { didSet { recomputeVisible() } }
    private let repo: TaskRepository

    /// The visible task rows for the current view + filters. Derived state,
    /// recomputed ONLY when an input (all/blocks/view/filters) changes — not on
    /// every access. Previously `visible` re-ran a full visibleTasks pass
    /// (Sets + projectOccurrences, O(tasks+blocks)) on every read.
    private(set) var visible: [TaskItem] = []

    /// Ids of the rows that are recurring OCCURRENCES (id = cal_block id),
    /// precomputed once per snapshot from the pure `occurrenceBlockFor` over the
    /// already-observed tasks+blocks. Rows look this up with `.contains` instead
    /// of each row running two full-table DB reads + a JSON decode in `body`.
    private(set) var occurrenceIds: Set<String> = []

    init(_ repo: TaskRepository) { self.repo = repo }

    func observe() async {
        do {
            // areas come from the same tracked snapshot, so an area rename
            // refreshes the filter pills without waiting for a task edit.
            for try await snap in repo.observeTasksAndBlocks() {
                areas = snap.areas
                // Assigning all/blocks triggers recomputeSnapshot via didSet;
                // set blocks last so the recompute sees both (each didSet rebuilds
                // from the current stored values, so the final assignment wins).
                all = snap.tasks
                blocks = snap.blocks
            }
        } catch { /* observation ended */ }
    }

    /// Snapshot inputs (tasks/blocks) changed: rebuild the occurrence-id set
    /// (same rule as the pure `occurrenceBlockFor`: a task-block whose task is a
    /// recurring template), then the visible rows. O(tasks+blocks).
    private func recomputeSnapshot() {
        let templateIds = Set(all.filter { $0.recurrence != nil }.map { $0.id })
        occurrenceIds = Set(
            blocks.filter { isTaskBlock($0) && templateIds.contains($0.taskId ?? "") }.map { $0.id })
        recomputeVisible()
    }

    /// View/filter (or snapshot) changed: rebuild the visible rows.
    private func recomputeVisible() {
        // Today is area-agnostic on purpose (web/Android parity) — the area
        // filter only bites on the other tabs. The tag filter applies to
        // every view. The slip filter still applies.
        visible = visibleTasks(view: view, tasks: all, blocks: blocks,
                               now: Date().timeIntervalSince1970 * 1000,
                               activeArea: view == .today ? nil : activeArea,
                               activeTag: activeTag,
                               slipMode: slipMode)
    }

    func blocks(forTask id: String) -> [CalBlock] { blocks.filter { $0.taskId == id } }

    func ageDays(_ task: TaskItem) -> Int {
        daysSinceCreated(task, now: Date().timeIntervalSince1970 * 1000)
    }
}

struct TasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: TasksModel?
    @State private var editing: TaskItem?
    @State private var showSettings = false
    @State private var showPalette = false
    @State private var showNotifCenter = false

    // Tab order mirrors the web TaskListPane / Android: Backlog first (the
    // triage stack), then All / Today / Upcoming / Later / Recurring / Completed.
    // "Recurring" lists the repeating TEMPLATES (their per-day occurrences
    // surface in Today/All/Upcoming as independent rows).
    private let tabOrder: [TaskListView] = [.backlog, .all, .today, .upcoming, .later, .recurring, .completed]

    var body: some View {
        Group {
            if let vm { content(vm) } else { loading }
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .sheet(item: $editing) { task in
            TaskEditor(task: task, existingBlocks: vm?.blocks(forTask: task.id) ?? [])
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPalette) { CommandPalette() }
        .sheet(isPresented: $showNotifCenter, onDismiss: { model.flushPendingDeepLink() }) { NotificationCenterView() }
        .feedbackBubble()
        .task {
            guard vm == nil, let repo = model.taskRepo else { return }
            let m = TasksModel(repo)
            // Honor an active iOS Focus Filter (reconcile on appear — iOS 18
            // perform() can be flaky, so reading the App-Group flag here too).
            if AppGroup.focusFilterActive(), AppGroup.focusFilterHideNonToday() { m.view = .today }
            vm = m
            await m.observe()
        }
    }

    private var loading: some View {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: pinned header + scrolling list

    @ViewBuilder
    private func content(_ vm: TasksModel) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 0) {
            AppBar(title: "Tasks", onSearch: { showPalette = true }, onAvatar: { showSettings = true },
                   onNotifications: { showNotifCenter = true }, notifUnread: NotificationLog.shared.hasUnread)

            VStack(alignment: .leading, spacing: 0) {
                // Long-press the title to toggle slip mode (the "tasks that are
                // slipping" lens) — preserved behavior, kept out of the way to
                // match Android's chrome-free header.
                Text("Your tasks")
                    .font(UFont.serifItalic(26))
                    .foregroundStyle(theme.palette.ink)
                    .padding(.top, 4).padding(.bottom, 12)
                    .onLongPressGesture { vm.slipMode.toggle() }

                bucketPills(vm)
                areaPills(vm)
                tagFilterBanner(vm)
                slipModeBanner(vm)
            }
            .padding(.horizontal, 18)

            list(vm)
        }
    }

    // MARK: ROW 1 — bucket pills (per-tab accent + dot)

    @ViewBuilder
    private func bucketPills(_ vm: TasksModel) -> some View {
        @Bindable var vm = vm
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabOrder, id: \.self) { v in
                    bucketPill(v, selected: vm.view == v) { vm.view = v }
                }
            }
        }
        .padding(.bottom, 10)
    }

    /// Per-tab accent (web parity: Backlog=amber, Today=coral, Upcoming=blue,
    /// Later=primary, Completed=green; All has no accent). Selected = tinted
    /// soft fill + ink; inactive = bg2 with a leading accent dot.
    private func bucketPill(_ v: TaskListView, selected: Bool, action: @escaping () -> Void) -> some View {
        let accent = accentPair(v)
        let bg = selected ? (accent?.soft ?? theme.palette.ink) : theme.palette.bg2
        let fg = selected ? (accent?.ink ?? theme.palette.bg) : theme.palette.ink2
        return Button(action: action) {
            HStack(spacing: 5) {
                if let accent, !selected {
                    Circle().fill(accent.ink).frame(width: 6, height: 6)
                }
                Text(v.rawValue)
                    .font(UFont.sans(12, .medium))
                    .foregroundStyle(fg)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(bg, in: Capsule())
        }.buttonStyle(.plain)
    }

    private func accentPair(_ v: TaskListView) -> (soft: Color, ink: Color)? {
        switch v {
        case .backlog:   return (theme.palette.amberSoft, theme.palette.amberInk)
        case .today:     return (theme.palette.coralSoft, theme.palette.coralDeep)
        case .upcoming:  return (theme.palette.blueSoft, theme.palette.blueInk)
        case .later:     return (theme.palette.primarySoft, theme.palette.primaryDeep)
        case .recurring: return (theme.palette.blueSoft, theme.palette.blueInk)
        case .completed: return (theme.palette.greenSoft, theme.palette.greenInk)
        case .all:       return nil
        }
    }

    // MARK: ROW 2 — area filter pills (selected = inverted ink)

    @ViewBuilder
    private func areaPills(_ vm: TasksModel) -> some View {
        @Bindable var vm = vm
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                areaPill("All", selected: vm.activeArea == nil, dot: nil) { vm.activeArea = nil }
                ForEach(vm.areas) { a in
                    areaPill(a.name, selected: vm.activeArea == a.name, dot: theme.palette.areaColor(a.color)) {
                        vm.activeArea = (vm.activeArea == a.name) ? nil : a.name
                    }
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func areaPill(_ title: String, selected: Bool, dot: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(title)
                    .font(UFont.sans(12, .medium))
                    .foregroundStyle(selected ? theme.palette.bg : theme.palette.ink2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? theme.palette.ink : theme.palette.bg2, in: Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: dismissible tag-filter banner (Android parity)

    /// "Filtering by tag #x ✕" — shown in the pinned header when a tag chip is
    /// tapped; tapping the banner clears the filter. Matches TasksScreen.kt.
    @ViewBuilder
    private func tagFilterBanner(_ vm: TasksModel) -> some View {
        @Bindable var vm = vm
        if let tag = vm.activeTag {
            Button { vm.activeTag = nil } label: {
                HStack(spacing: 6) {
                    Text("Filtering by tag ")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.primaryDeep)
                        + Text("#\(tag)")
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.ink)
                    Text("✕").font(UFont.sans(12)).foregroundStyle(theme.palette.primaryDeep)
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(theme.palette.primarySoft, in: Capsule())
            }.buttonStyle(.plain)
                .padding(.bottom, 12)
        }
    }

    // MARK: dismissible slip-mode banner

    /// "Showing slipping tasks ✕" — surfaces the otherwise-hidden long-press
    /// slip filter so it has a visible indicator and an escape (tap to clear).
    /// Mirrors the tag-filter banner above.
    @ViewBuilder
    private func slipModeBanner(_ vm: TasksModel) -> some View {
        @Bindable var vm = vm
        if vm.slipMode {
            Button { vm.slipMode = false } label: {
                HStack(spacing: 6) {
                    Text("Showing slipping tasks")
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.amberInk)
                    Text("✕").font(UFont.sans(12)).foregroundStyle(theme.palette.amberInk)
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(theme.palette.amberSoft, in: Capsule())
            }.buttonStyle(.plain)
                .padding(.bottom, 12)
        }
    }

    // MARK: task list

    @ViewBuilder
    private func list(_ vm: TasksModel) -> some View {
        let rows = vm.visible
        ScrollView {
            LazyVStack(spacing: 6) {
                if rows.isEmpty {
                    Text("No \(vm.view.rawValue.lowercased()) tasks.")
                        .font(UFont.sans(14)).foregroundStyle(theme.palette.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 32)
                } else {
                    ForEach(rows) { task in
                        // Precomputed once per snapshot (vm.occurrenceIds) — was
                        // two full-table DB reads + a JSON decode PER ROW in body.
                        let isOccurrence = vm.occurrenceIds.contains(task.id)
                        TaskRowView(
                            task: task,
                            areaColor: areaColor(task.lifeArea, vm.areas),
                            ageDays: vm.view == .backlog ? vm.ageDays(task) : nil,
                            isRecurring: task.recurrence != nil || isOccurrence,
                            // A repeating TEMPLATE row (Recurring tab) has no per-day
                            // done — hide the circle and open it to edit the series.
                            // Occurrence + plain rows get the leading done-circle.
                            canToggleDone: task.recurrence == nil,
                            // Open the row as-is (incl. a projected occurrence,
                            // id = block id). TaskEditor resolves the template for
                            // field edits and routes done/skip to the occurrence —
                            // so this must NOT pre-resolve to the template (that
                            // would drop occurrence mode: Skip-today, per-day done).
                            onOpen: { editing = task },
                            // Leading done-circle (matches Today) — toggles without
                            // opening the row; for an occurrence it marks that day.
                            onToggleDone: { model.toggleDone(task) },
                            // Tag chips set the active tag filter (Android parity)
                            // instead of opening the row.
                            onTagTap: { vm.activeTag = $0 }
                        )
                        // Android's row has no checkbox (completion lives in the
                        // detail sheet). Preserve the iOS toggleDone path via a
                        // long-press menu so the resting look stays 1:1. For a
                        // recurring OCCURRENCE row, toggleDone marks just that day's
                        // block, plus a "Skip this day" that cancels the one day
                        // without ending the series.
                        .contextMenu {
                            // A template row (Recurring tab) has no per-day done —
                            // open it to edit the series instead.
                            if task.recurrence == nil {
                                Button {
                                    model.toggleDone(task)
                                } label: {
                                    Label(task.done ? "Mark not done" : "Mark done",
                                          systemImage: task.done ? "circle" : "checkmark.circle")
                                }
                            }
                            if isOccurrence {
                                Button(role: .destructive) {
                                    model.skipOccurrence(task.id)
                                } label: {
                                    Label("Skip this day", systemImage: "calendar.badge.minus")
                                }
                            }
                            Button { editing = task } label: {
                                Label(task.recurrence != nil ? "Edit series" : "Edit", systemImage: "pencil")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 96)   // clear the floating bottom nav
        }
    }

    /// Resolve a task's life-area NAME to its color via the areas list
    /// (Android's areaColorFor): falls back to a muted dot if unknown.
    private func areaColor(_ name: String?, _ areas: [LifeArea]) -> Color {
        if let a = areas.first(where: { $0.name == name }) { return theme.palette.areaColor(a.color) }
        return theme.palette.ink4
    }
}

struct TaskRowView: View {
    @Environment(\.uTheme) private var theme
    let task: TaskItem
    let areaColor: Color
    let ageDays: Int?
    var isRecurring: Bool = false
    /// Whether to show the leading done-circle (false for repeating templates,
    /// which have no per-day done — those open to edit the series instead).
    var canToggleDone: Bool = true
    let onOpen: () -> Void
    /// Toggle the row's done state (for an occurrence, marks that day's block).
    var onToggleDone: () -> Void = {}
    /// Tapping an inline #tag chip filters by that tag instead of opening
    /// the row (Android TasksScreen parity).
    var onTagTap: (String) -> Void = { _ in }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                // Leading done-circle — the visible completion affordance, 1:1
                // with Today's task row (its own Button intercepts the tap so it
                // toggles without opening the detail). Hidden for template rows.
                if canToggleDone {
                    Button(action: onToggleDone) {
                        Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(task.done ? theme.palette.green : theme.palette.ink3)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(task.done ? "Mark not done" : "Mark done")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name)
                        .font(UFont.sans(14, .medium))
                        .strikethrough(task.done)
                        .foregroundStyle(task.done ? theme.palette.ink3 : theme.palette.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        Circle().fill(areaColor).frame(width: 5, height: 5)
                        Text(task.lifeArea ?? "—")
                            .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        if isRecurring {
                            Text("· ↻").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        }
                        ForEach(Array((task.tags ?? []).prefix(3)), id: \.self) { tag in
                            Button { onTagTap(tag) } label: {
                                Text("#\(tag)")
                                    .font(UFont.sans(10, .medium))
                                    .foregroundStyle(theme.palette.primaryDeep)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(theme.palette.primarySoft, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if let ageDays {
                    Text("\(max(ageDays, 1))d")
                        .font(UFont.sans(10, .medium))
                        .foregroundStyle(theme.palette.amberInk)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(theme.palette.amberSoft, in: Capsule())
                }
                Text("\(task.estimateMin)m")
                    .font(UFont.mono(11)).foregroundStyle(theme.palette.ink3)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.palette.line))
        }.buttonStyle(.plain)
    }
}
