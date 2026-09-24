// Today — 1:1 with the Android TodayScreen: Orbit + bell + avatar header, a
// date eyebrow + ONE-line "<greeting> <first name>." serif line ("Unstuck."
// when no name is set — web greeting-header parity), a "This week · focused"
// pill, the assistant input pill (the way into the assistant + Talk), the
// Today/Backlog + area filter pills, and the filtered today list. Live store
// via GRDB. The gradient "Start next" hero (and its "Nothing to start" twin)
// is gone (2026-09-18): Focus starts from a row's context menu or the task
// editor; the list carries every open Today row.

import SwiftUI
import UIKit
import UserNotifications
import WidgetKit
import UnstuckCore
import UnstuckData
import UnstuckDesign
import UnstuckShared

/// Shared, configured-once DateFormatter for the Today date eyebrow's weekday —
/// hoisted to file scope so the header doesn't allocate a fresh DateFormatter
/// on every render. Read-only after the fixed config; `nonisolated(unsafe)`
/// documents that to the Swift 6 concurrency checker. The time is NOT in it:
/// it follows the phone's 12/24-hour clock through `ClockFormat` (a fixed
/// "h:mm a" said "THURSDAY · 2:02 PM" on a 24-hour phone; Ahmad, 2026-09-24).
enum TodayFmt {
    nonisolated(unsafe) static let weekday: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEEE"; return f
    }()

    /// "Thursday · 14:02" / "Thursday · 2:02 PM".
    static func eyebrow(_ now: Date, clock: ClockFormat = .device) -> String {
        "\(weekday.string(from: now)) · \(clock.time(now))"
    }
}

/// Pure first-name derivation for the Today greeting — mirrors the web
/// `firstName()` in components/dashboard/greeting-header.tsx: first token of
/// the display name split on whitespace / "." / "_" / "-" (so an email
/// local-part fallback like "maya.chen" still greets as "maya"). nil, empty,
/// or separator-only input → nil, so the caller falls back to the brand
/// "Unstuck." line. Internal (not private) for UnstuckAppTests.
enum GreetingName {
    static func firstName(_ full: String?) -> String? {
        guard let full else { return nil }
        let first = full.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" }).first
        return first.map(String.init)
    }

    /// The ONE-line greeting: "Good evening Maya." — no line break (it used
    /// to stack the name on a second line); no name → the brand "… Unstuck."
    /// line. The view clamps it to one line and scales a long name down.
    static func line(greeting: String, firstName: String?) -> String {
        "\(greeting) \(firstName ?? "Unstuck")."
    }
}

@MainActor
@Observable
final class TodayModel {
    var all: [TaskItem] = [] { didSet { recomputeSnapshot() } }
    var blocks: [CalBlock] = [] { didSet { recomputeSnapshot() } }
    var areas: [LifeArea] = [] {
        didSet {
            // The selected pill follows an area rename (Settings, the
            // assistant, another device) and falls back to All on a delete
            // (audit 2026-09-22, C19).
            let next = areaFilterFollowing(areaFilter, from: oldValue, to: areas)
            if next != areaFilter { areaFilter = next }
        }
    }
    /// The selected area pill, by name (nil = All). Lives here, not in view
    /// state, so it can follow the area rows as they change.
    var areaFilter: String?
    var sessions: [Session] = []
    var captures: [Capture] = []
    private let repo: TaskRepository
    init(_ repo: TaskRepository) { self.repo = repo }

    // MARK: - snapshot-derived caches (recomputed only when tasks/blocks change)

    /// Ids of rows that are recurring OCCURRENCES (id = cal_block id),
    /// precomputed once per snapshot. taskRow looks this up with `.contains`
    /// instead of running two full-table DB reads + a JSON decode PER ROW in body.
    private(set) var occurrenceIds: Set<String> = []

    /// The Today bucket (area-agnostic open rows) — the base for the list.
    /// Cached per snapshot so the per-render passes don't each rebuild it.
    private var todayBase: [TaskItem] = []
    /// Today's completions kept as struck-through wins (sorted last), cached.
    private var doneTodayBase: [TaskItem] = []
    /// The Backlog bucket, cached per snapshot (drives backlogCount + the
    /// Backlog list).
    private var backlogBase: [TaskItem] = []

    /// How many tasks sit in the Backlog (perf soak assertions).
    private(set) var backlogCount: Int = 0

    func observe() async {
        async let tb: Void = observeTasksAndBlocks()
        async let cap: Void = observeCaptures()
        _ = await (tb, cap)
    }

    private func observeTasksAndBlocks() async {
        do {
            // areas/sessions come from the same tracked snapshot, so an area
            // rename or a realtime session arrival refreshes the pills and
            // the week-focused stat without waiting for a task edit.
            for try await snap in repo.observeTasksAndBlocks() {
                areas = snap.areas
                sessions = snap.sessions
                weekPillCache = nil   // new sessions / ticks → recount on the next read
                // all/blocks assignment triggers recomputeSnapshot via didSet;
                // set blocks last so the final recompute sees both.
                all = snap.tasks
                blocks = snap.blocks
                writeWidgetSnapshot()
            }
        } catch {}
    }

    /// Rebuild every snapshot-derived cache (occurrence ids + the Today/Backlog
    /// base buckets + backlogCount). Runs once per tasks/blocks change instead of
    /// re-running the O(tasks+blocks) passes on every render access.
    private func recomputeSnapshot() {
        let now = Date().timeIntervalSince1970 * 1000
        // Same rule as the pure `occurrenceBlockFor`: a task-block whose task is a
        // recurring template. Computed in O(tasks+blocks), not O(blocks²).
        let templateIds = Set(all.filter { $0.recurrence != nil }.map { $0.id })
        occurrenceIds = Set(
            blocks.filter { isTaskBlock($0) && templateIds.contains($0.taskId ?? "") }.map { $0.id })
        // ONE shared prep for both views: the occurrence projections and the
        // scheduled-id sets are view-independent and are the whole cost of the
        // pass, so building them twice doubled this recompute for nothing.
        let prep = VisibleTasksPrep(tasks: all, blocks: blocks)
        todayBase = visibleTasks(view: .today, prep: prep, now: now, activeArea: nil, slipMode: false)
        backlogBase = visibleTasks(view: .backlog, prep: prep, now: now, activeArea: nil, slipMode: false)
        backlogCount = backlogBase.count
        // Today's completions kept as struck-through wins until tomorrow, minus
        // anything still open — 1:1 with Android TodayScreen.kt:127-136.
        let today = Clock.todayISO()
        let openIds = Set(todayBase.map { $0.id })
        doneTodayBase = (all.filter { !isTemplate($0) } + projectOccurrences(all, blocks, fromISO: today))
            .filter { isCompletedToday($0, now: now) && !openIds.contains($0.id) }
    }

    private func observeCaptures() async {
        do {
            for try await snap in repo.observeCaptures() { captures = snap }
        } catch {}
    }

    /// Captures still awaiting triage (not device-local archived) — drives the
    /// coral dot on the header Inbox icon (Android `inboxCount`).
    func openCaptureCount(archivedIds: Set<String>) -> Int {
        captures.filter { !archivedIds.contains($0.id) }.count
    }

    /// The content of the last widget snapshot we wrote (everything but
    /// updatedAt). The observed stream carries areas + sessions too, so an area
    /// rename / session insert re-emits a snapshot whose Start-Next content is
    /// unchanged — debounce those: only write + reload WidgetKit when the
    /// content actually differs.
    private var lastWidgetContent: StartNextSnapshot?

    private func writeWidgetSnapshot() {
        // Never once the sign-out scrub has run (it clears this flag and the
        // App Group together): the store still holds the signed-out account's
        // rows until the sync engine wipes it, and Today stays mounted through
        // the Sign-out button's drain — an emission then (the scrub's own
        // focus finalize, a realtime edit) put that account's next task back
        // on the home / lock widget (audit 2026-09-22, C35).
        guard PushRegistrar.accountSignedIn != false else { return }
        // The widget's pick is today-scoped (next scheduled by time → else the
        // shortest unscheduled → else nothing) — the same rule the on-screen
        // hero used before it was removed; the home/lock "Start Next" tile
        // keeps it.
        let next = pickTodayHero(tasks: all, blocks: blocks, now: Date().timeIntervalSince1970 * 1000)
        let openCount = all.filter { !$0.done && !($0.later ?? false) }.count
        // Compare on a fixed updatedAt so only the meaningful fields drive the
        // Equatable check (the real write stamps the current time).
        let content = StartNextSnapshot(
            taskName: next?.name, estimateMin: next?.estimateMin, lifeArea: next?.lifeArea,
            openCount: openCount, taskId: next?.id, updatedAt: Date(timeIntervalSince1970: 0))
        guard content != lastWidgetContent else { return }
        lastWidgetContent = content
        AppGroup.writeStartNext(StartNextSnapshot(
            taskName: next?.name, estimateMin: next?.estimateMin, lifeArea: next?.lifeArea,
            openCount: openCount, taskId: next?.id, updatedAt: Date()))
        WidgetCenter.shared.reloadAllTimelines()
    }

    func rows(backlog: Bool, area: String?, liveTaskId: String?) -> [TaskItem] {
        if backlog {
            // backlogBase is cached per snapshot — just subtract the live task.
            return backlogBase.filter { $0.id != liveTaskId }
        }
        // Today: cached open rows (area-agnostic bucket) PLUS cached today's
        // completions kept as struck-through wins (sorted last) until tomorrow,
        // then area-filtered and with the live task subtracted (it sits in the
        // live-session card above the rows) — 1:1 with Android
        // TodayScreen.kt:127-136.
        return (todayBase + doneTodayBase).filter {
            (area == nil || $0.lifeArea == area) && $0.id != liveTaskId
        }
    }

    /// The header's week pill (UnstuckCore.weekPill): this week's focus, else
    /// what got done this week, else "Your week" — always there, the way into
    /// Insights. The SAME counts the Insights page shows for "This week"
    /// (D1-filtered sessions, periodFacts, rounded minutes): the old rolling
    /// 7 days showed "This week · 1h 35m" over a Week tab reading nothing
    /// (cross-check P0-8).
    /// Counted once per store snapshot AND local day (not per render — Today
    /// redraws often): keyed on the day too, so a Today left open over Sunday
    /// night doesn't carry last week's total into Monday as "This week".
    func weekPill(now: Date = Date()) -> WeekPill {
        // Read the rows on every call, cache hit or not, so the view that
        // shows the pill stays subscribed to new sessions and ticks
        // (Observation).
        let (tasks, blocks, sessions) = (all, blocks, sessions)
        let day = Clock.dateISO(now)
        if let c = weekPillCache, c.day == day { return c.value }
        let value = UnstuckCore.weekPill(tasks: tasks, blocks: blocks, sessions: sessions, now: now)
        weekPillCache = (day, value)
        return value
    }
    @ObservationIgnored private var weekPillCache: (day: String, value: WeekPill)?

    // MARK: nudges (quiet, in-app — Android AppViewModel.nudges parity)

    /// Device-local dismissed-nudge ids (so a dismissed nudge stays dismissed
    /// across relaunch). Android persists these in SettingsStore; we use the
    /// same shape in UserDefaults. Held in an observed set (seeded from
    /// UserDefaults in init) so a dismissal drops the card immediately.
    private static let dismissedNudgesKey = "unstuck.dismissedNudges"
    private var dismissedNudgeIds: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: TodayModel.dismissedNudgesKey) ?? [])

    /// The quiet Today nudges (things slipping / follow-ups). Off entirely at the
    /// Calm level (NotificationLevel.nudges == false) and with dismissed ids
    /// filtered out — 1:1 with Android `nudges`.
    var nudges: [Nudge] {
        guard NotificationPrefs.level.nudges else { return [] }
        let now = Date().timeIntervalSince1970 * 1000
        return computeNudges(tasks: all, captures: captures, now: now)
            .filter { !dismissedNudgeIds.contains($0.id) }
    }

    /// Persist a nudge dismissal (Android `dismissNudge`) — drops the card now
    /// and keeps it dismissed across relaunch.
    func dismissNudge(_ id: String) {
        dismissedNudgeIds.insert(id)
        UserDefaults.standard.set(Array(dismissedNudgeIds), forKey: Self.dismissedNudgesKey)
    }

    /// Whole CALENDAR days since a task was created (0 = today), coerced ≥ 1 for
    /// the Backlog "Nd" badge — mirrors Android `ageDays` (calendar-day diff so a
    /// task made late yesterday reads "1d", not "today").
    func ageDays(_ t: TaskItem) -> Int {
        guard let created = Time.parseMillis(t.createdAt) else { return 1 }
        let now = Date().timeIntervalSince1970 * 1000
        let days = Int((Time.startOfDayMillis(now) - Time.startOfDayMillis(created)) / DAY_MS)
        return max(1, days)
    }
}

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: TodayModel?
    @State private var showSettings = false
    @State private var showNotifCenter = false
    @State private var showInsights = false
    /// 1 when the pill opened Insights on LAST week (early in a quiet week).
    @State private var insightsWeekOffset = 0
    /// The row whose "Share…" context action opened the Share screen.
    @State private var shareTarget: ShareTarget?
    @State private var notifsEnabled = true
    @State private var confirmDiscardStuck = false
    @State private var backlogActive = false
    /// Realtime "Talk" mode from the assistant input pill's mic — the same
    /// VoiceModeScreen cover the Assistant sheet presents for its Talk button.
    /// Router-owned (`AppRouter.showTalk`) so the assistant navigating from
    /// Talk goes through the deferred deep-link path: Talk counts as an active
    /// presentation, is dismissed, and its onDismiss presents the target.
    private var showTalk: Binding<Bool> {
        Binding(get: { model.router.showTalk }, set: { model.router.showTalk = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned top bar — the logo, inbox/notifications, and avatar stay
            // fixed; only the greeting + filters + task list scroll.
            topBar
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let vm {
                    if !notifsEnabled { notificationsOffBanner.padding(.horizontal, 18).padding(.top, 8) }
                    if model.stuckChanges > 0 { stuckChangesBanner.padding(.horizontal, 18).padding(.top, 8) }
                    // "Just now" session recap — shows for 6h after a finished
                    // focus session, between the header and the list
                    // (Android TodayScreen recap parity).
                    if let recap = model.lastRecap,
                       Date().timeIntervalSince1970 * 1000 - recap.at < 6 * 3_600_000 {
                        recapCard(recap).padding(.horizontal, 18).padding(.top, 8)
                    }
                    // The quiet nudge card is not rendered on Today; the
                    // `computeNudges` path + `nudgeCard` stay for parity/tests.
                    filterBar(vm)
                    list(vm)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.bottom, BottomNavBar.clearance)   // clear the bottom nav
            }
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNotifCenter, onDismiss: { model.flushPendingDeepLink() }) { NotificationCenterView() }
        .sheet(isPresented: $showInsights) { NavigationStack { AnalyticsView(initialWeekOffset: insightsWeekOffset) } }
        // Row context menu "Share…" → the ONE Share screen.
        .sheet(item: $shareTarget) { target in ShareScreen(target: target) }
        // Input-pill mic → realtime Talk. Same cover the Assistant sheet uses.
        // onDismiss flushes a deep link the assistant parked while Talk was
        // up (open_screen → insights / inbox / settings) so it presents once
        // the cover is fully gone.
        .fullScreenCover(isPresented: showTalk, onDismiss: { model.flushPendingDeepLink() }) { VoiceModeScreen() }
        // The AI-consent ask for Talk from the pill's mic.
        .aiConsentSheet(.today)
        .assistantLauncher()
        // The guided tour is about to navigate — close the locally-presented
        // sheets (they live on this view's @State, out of the router's reach).
        .onReceive(NotificationCenter.default.publisher(for: .unstuckTourWillNavigate)) { _ in
            showSettings = false; showNotifCenter = false; showInsights = false
            model.router.showTalk = false
        }
        .task {
            model.shareState.start()   // live "shared with you" + delegation state
            guard vm == nil, let repo = model.taskRepo else { return }
            let m = TodayModel(repo); vm = m; await m.observe()
        }
        .task { await refreshNotifStatus() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotifStatus() }
        }
    }

    // MARK: header

    // Pinned top bar — logo + inbox/notifications/avatar. Lives OUTSIDE the
    // Today ScrollView so it stays fixed while the content scrolls beneath it.
    private var topBar: some View {
        HStack {
                // The ring fills the same 32-pt box as the avatar (Mark draws its
                // ring at ~72 % of its size, so 44 → a 32-pt ring), and both sit on
                // the page's 18-pt margins — logo and avatar mirror each other.
                Mark(size: 44).frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Spacer()
                HStack(spacing: 2) {
                    // Inbox (MoveToInbox) → the capture triage tray; the coral dot
                    // marks open (untriaged) captures (Android Today header parity).
                    Button { model.router.present(.inbox) } label: {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 20))
                            .foregroundStyle(theme.palette.ink2).frame(width: 40, height: 40)
                            .overlay(alignment: .topTrailing) {
                                if (vm?.openCaptureCount(archivedIds: model.archivedCaptureIds) ?? 0) > 0 {
                                    Circle().fill(theme.palette.coral).frame(width: 7, height: 7)
                                        .offset(x: -9, y: 9)
                                }
                            }
                    }.buttonStyle(.plain).accessibilityLabel("Captures")
                    // Bell → in-app Notification Center; the dot is the unread
                    // badge (newest log entry vs lastSeen — spec 10 §1.9).
                    Button { showNotifCenter = true } label: {
                        Image(systemName: "bell").font(.system(size: 20)).foregroundStyle(theme.palette.ink2).frame(width: 40, height: 40)
                            .overlay(alignment: .topTrailing) {
                                if NotificationLog.shared.hasUnread {
                                    Circle().fill(theme.palette.coral).frame(width: 7, height: 7)
                                        .offset(x: -9, y: 9)
                                }
                            }
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Notifications")
                        .accessibilityValue(NotificationLog.shared.hasUnread ? "Unread" : "")
                    Button { showSettings = true } label: {
                        Text(model.avatarInitials)
                            .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.greenInk)
                            .frame(width: 32, height: 32).background(theme.palette.greenSoft, in: Circle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Account and settings")
                }
            }
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 4)
    }

    // Greeting block — scrolls with the content (only topBar is pinned).
    // Greets by first name on ONE line ("Good evening Maya."); no name → the
    // brand "Unstuck." line. Reads the CACHED identity (currentUserName →
    // cachedUserName — the same source Settings · Account shows), never the
    // keychain-backed session in body (T4). The assistant input pill sits
    // directly under the week pill — the way into the assistant and Talk.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(dateEyebrow)
            Text(GreetingName.line(greeting: greeting, firstName: GreetingName.firstName(model.currentUserName)))
                .font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            weekPill
            if model.assistantEnabled {
                // Talk sends their voice to OpenAI — the first time, it asks.
                AssistantInputPill(onTalk: {
                    model.withAIConsent(.talk, from: .today) { model.router.showTalk = true }
                }).padding(.top, 10)
                AIConsentNoteLine(host: .today).padding(.top, 6).padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 4)
    }

    /// The week pill → Insights, ALWAYS shown (it is the way into Insights
    /// from home): "This week · 1h 35m focused", else "3 done this week", else
    /// "Your week". Early in the week (Mon/Tue) with nothing yet this week but
    /// a last week that had focus, it reads "Last week · …" and opens Insights
    /// on last week. The words and counts are UnstuckCore.weekPill's.
    private var weekPill: some View {
        let pill = vm?.weekPill() ?? WeekPill(.empty)
        let label = pill.runs.reduce(Text("")) { text, run in
            text + Text(run.text).font(UFont.sans(12, run.strong ? .semibold : .regular))
                .foregroundStyle(run.strong ? theme.palette.ink : theme.palette.ink2)
        }
        // Opens INSIGHTS, not Settings — Android parity (TodayScreen pill → Route.Insights).
        return Button { insightsWeekOffset = pill.insightsWeekOffset; showInsights = true } label: {
            HStack(spacing: 8) {
                Circle().fill(theme.palette.coral).frame(width: 6, height: 6)
                label
                Text("→").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(theme.palette.bg2, in: Capsule())
        }.buttonStyle(.plain).padding(.top, 2)
            .accessibilityIdentifier("week-pill")
            .accessibilityLabel(pill.label)
            .accessibilityHint("Opens Insights")
    }

    // MARK: filter pills

    @ViewBuilder
    private func filterBar(_ vm: TodayModel) -> some View {
        Text(backlogActive ? "Backlog" : "Today")
            .font(UFont.sans(15, .semibold)).foregroundStyle(theme.palette.ink)
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { backlogActive.toggle(); if backlogActive { vm.areaFilter = nil } } label: {
                    HStack(spacing: 5) {
                        if !backlogActive { Circle().fill(theme.palette.amber).frame(width: 6, height: 6) }
                        Text("Backlog").font(UFont.sans(12, .medium))
                            .foregroundStyle(backlogActive ? theme.palette.amberInk : theme.palette.ink2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(backlogActive ? theme.palette.amberSoft : theme.palette.bg2, in: Capsule())
                }.buttonStyle(.plain)
                pill("All", selected: !backlogActive && vm.areaFilter == nil, dot: nil) { backlogActive = false; vm.areaFilter = nil }
                ForEach(vm.areas) { a in
                    pill(a.name, selected: !backlogActive && vm.areaFilter == a.name, dot: theme.palette.areaColor(a.color)) {
                        backlogActive = false; vm.areaFilter = (vm.areaFilter == a.name) ? nil : a.name
                    }
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 8)
        }
    }

    private func pill(_ title: String, selected: Bool, dot: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(title).font(UFont.sans(12, .medium))
                    .foregroundStyle(selected ? theme.palette.bg : theme.palette.ink2)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? theme.palette.ink : theme.palette.bg2, in: Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: today list

    @ViewBuilder
    private func list(_ vm: TodayModel) -> some View {
        let liveId = model.liveTaskId
        // Tasks I've assigned away leave the active buckets (they show in the
        // Delegated group instead) — mirrors the web today-list filter.
        let assignedOut = model.shareState.assignedOut
        let rows = vm.rows(backlog: backlogActive, area: vm.areaFilter, liveTaskId: liveId)
            .filter { assignedOut[$0.id] == nil }
        // The in-progress focus session, surfaced at the top of the list (Android
        // TodayScreen LiveSessionCard) — resolved by liveTaskId from observed
        // tasks; a SHARED (recipient) session has no local row, so a display
        // task is synthesized — one true shared session keeps it running +
        // resumable after leaving the focus screen.
        let liveTask = liveId.flatMap { id in vm.all.first { $0.id == id } }
            ?? model.sharedLiveTaskFallback()
        // LazyVStack (not VStack): the whole Today/dashboard screen — header,
        // filter bar, AND these rows — lives in ONE outer ScrollView
        // (body), so the entire screen scrolls as a single unit. Lazy keeps a
        // long Today/Backlog list from rendering every row eagerly inside that
        // single scroll container. Matches the Tasks list.
        LazyVStack(spacing: 6) {
            if let liveTask, let live = model.liveSession {
                liveSessionCard(liveTask, live)
            }
            // Company sits atop the list, placed like your own tasks: Today
            // shows shares scheduled today / unscheduled, Backlog the overdue
            // ones — by the owner's next block (migration 052). Honours the
            // active area pill like the rows + Delegated do. Renders nothing
            // when empty; a completed share leaves Today at once.
            SharedWithYouGroup(items: model.shareState.sharedWithMe,
                               mode: backlogActive ? .backlog : .today,
                               activeArea: vm.areaFilter,
                               makeCoFocus: { model.makeCoFocusModel(taskId: $0) },
                               suppressPresenceTaskId: liveId) { taskId, done in
                Task { try? await model.shareState.completeSharedTask(taskId: taskId, done: done) }
            }
            // Delegation stays a Today-only group, 1:1 with the web today-list.
            if !backlogActive {
                DelegatedGroup(tasks: vm.all, assignedOut: assignedOut, activeArea: vm.areaFilter,
                               now: Date().timeIntervalSince1970 * 1000) { t in
                    model.router.detailTask = t
                }
            }
            ForEach(rows) { t in taskRow(t) }
        }
        .padding(.horizontal, 18)
        // Tour anchor: the today/finish steps spotlight the list section
        // (the ringed Start-Next hero is gone; the list is the subject now).
        .tourTarget(.todayList)
        // Per-view empty note — only when nothing else is on screen (the live
        // card counts as content, and so do shared rows — "Nothing in Work
        // right now" under five shared rows was the bug), and only inside
        // Backlog or an area filter (matches Android's displayRows.isEmpty &&
        // liveTask == null gate).
        let sharedShown = visibleShares(model.shareState.sharedWithMe,
                                        mode: backlogActive ? .backlog : .today,
                                        todayISO: Clock.todayISO(), activeArea: vm.areaFilter).count
        if rows.isEmpty && liveTask == nil && sharedShown == 0 && (backlogActive || vm.areaFilter != nil) {
            Text(backlogActive ? "Backlog's clear — nothing waiting."
                 : "Nothing in \(vm.areaFilter ?? "") right now.")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                .padding(.horizontal, 18).padding(.vertical, 28)
        } else if rows.isEmpty && liveTask == nil && sharedShown == 0 {
            // Plain Today with nothing scheduled (no live card) — keep the
            // existing prompt rather than a silent blank.
            Text("Nothing scheduled. Tap + to add.")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                .padding(.horizontal, 18).padding(.vertical, 28)
        }
    }

    // MARK: live focus-session card (Android TodayScreen LiveSessionCard)

    /// Surfaces the in-progress focus session on Today: a progress ring + live
    /// elapsed timer (1s TimelineView tick), an "In focus · {task}" /
    /// "Paused · {task}" label, tap-to-return to Focus, and an inline
    /// Pause/Resume. Running → coral ring + border; paused → amber ring.
    ///
    /// The dynamic bits re-read `model.liveSession` on each 1s tick (not a
    /// captured snapshot) so pausing/resuming from this card reflects within a
    /// second. `model.liveSession` is now an in-memory cache (kept current by
    /// every live-session mutator via refreshLiveSession), so the tick no longer
    /// hits the GRDB store + a fresh JSONDecoder every second. `initial` is the
    /// parent's snapshot, used as the fallback if the cache is momentarily nil.
    private func liveSessionCard(_ task: TaskItem, _ initial: LiveSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let live = model.liveSession ?? initial
            let now = ctx.date.timeIntervalSince1970 * 1000
            let paused = live.paused
            let estimateSec = max(1, (live.sessionEstimateMin > 0 ? live.sessionEstimateMin : task.estimateMin)) * 60
            let elapsed = FocusTimer.displayedElapsedSec(live, now: now)
            let progress = min(1, max(0, Double(elapsed) / Double(estimateSec)))
            let accent = paused ? theme.palette.amber : theme.palette.coral
            HStack(spacing: 11) {
                // Tapping the card body returns to the Focus screen for this
                // task; a shared (recipient) session re-carries its level so
                // finalize stays on the shared ledger.
                Button { model.reopenLiveFocus(task) } label: {
                    HStack(spacing: 11) {
                        ZStack {
                            Circle().stroke(theme.palette.line, lineWidth: 3)
                            Circle().trim(from: 0, to: progress)
                                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(elapsed >= 3600
                                 ? "\(elapsed / 3600)h\(String(format: "%02d", (elapsed % 3600) / 60))"
                                 : formatMMSS(elapsed))
                                .font(UFont.mono(7, .bold)).foregroundStyle(theme.palette.ink2)
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(paused ? "Paused · \(task.name)" : "In focus · \(task.name)")
                                .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink).lineLimit(1)
                            Text(paused ? "\(task.estimateMin)m · paused" : "running for \(formatMMSS(elapsed))")
                                .font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                        }
                        Spacer(minLength: 0)
                    }
                }.buttonStyle(.plain)
                // Inline Pause/Resume — running → "Pause" (bg2), paused → "Resume" (ink).
                Button { if paused { model.resumeFocus() } else { model.pauseFocus() } } label: {
                    Text(paused ? "Resume" : "Pause")
                        .font(UFont.sans(12, .semibold))
                        .foregroundStyle(paused ? theme.palette.bg : theme.palette.ink)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(paused ? theme.palette.ink : theme.palette.bg2, in: Capsule())
                }.buttonStyle(.plain)
            }
            .padding(12)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(paused ? theme.palette.line2 : theme.palette.coral.opacity(0.55)))
        }
    }

    private func taskRow(_ t: TaskItem) -> some View {
        // Precomputed once per snapshot (vm.occurrenceIds) — was two full-table
        // DB reads + a JSON decode PER ROW in body.
        let isOccurrence = vm?.occurrenceIds.contains(t.id) ?? false
        // PRIMARY tap opens the task detail (router.detailTask → TaskEditor),
        // matching Android's onOpen → Route.Detail; toggle-done moved to the
        // leading circle affordance (+ kept in the context menu).
        return Button { model.router.detailTask = t } label: {
            HStack(spacing: 12) {
                // Leading checkbox/circle — the done-toggle affordance. Done rows
                // stay visible as wins (green check + struck-through name); open
                // rows show an empty circle. Tapping it toggles without opening
                // the detail (its own Button intercepts the tap).
                Button { model.toggleDone(t) } label: {
                    Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(t.done ? theme.palette.green : theme.palette.ink3)
                }.buttonStyle(.plain)
                    .accessibilityLabel(t.done ? "Mark not done" : "Mark done")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(t.name).font(UFont.sans(14, .medium))
                            .strikethrough(t.done)
                            .foregroundStyle(t.done ? theme.palette.ink3 : theme.palette.ink).lineLimit(1)
                        if isOccurrence { Text("↻").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3) }
                    }
                    HStack(spacing: 5) {
                        Circle().fill(theme.palette.areaColor(t.lifeArea)).frame(width: 5, height: 5)
                        Text(t.lifeArea ?? "—").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        // Tags inline on the same line as the area (matches Android + the Tasks list).
                        ForEach(Array((t.tags ?? []).prefix(3)), id: \.self) { tn in
                            Text("#\(tn)").font(UFont.sans(10, .medium)).foregroundStyle(theme.palette.ink2)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(theme.palette.bg2, in: Capsule())
                                .overlay(Capsule().strokeBorder(theme.palette.line2, lineWidth: 1))
                        }
                        // "Shared with N" — my outgoing view/partner shares on this row.
                        ShareWithPill(names: (model.shareState.badges[t.id] ?? []).map(\.recipientName))
                    }
                }
                Spacer()
                // Backlog rows carry an amber "Nd" age badge before the estimate
                // (Android TaskRow ageDays badge) — how long the task has sat.
                if backlogActive, let vm {
                    Text("\(vm.ageDays(t))d").font(UFont.sans(10, .medium))
                        .foregroundStyle(theme.palette.amberInk)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(theme.palette.amberSoft, in: Capsule())
                }
                Text("\(t.estimateMin)m").font(UFont.mono(11)).foregroundStyle(theme.palette.ink3)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.palette.line))
        }.buttonStyle(.plain)
        .contextMenu {
            Button { model.router.detailTask = t } label: { Label("Open", systemImage: "square.and.pencil") }
            Button { model.toggleDone(t) } label: {
                Label(t.done ? "Mark not done" : "Mark done",
                      systemImage: t.done ? "circle" : "checkmark.circle")
            }
            Button { model.router.beginFocus(t) } label: { Label("Focus", systemImage: "play.fill") }
            // "Share…" straight from the row (unified sharing v1). An occurrence
            // row is a projection (id = block id) — share its series from the editor.
            if !isOccurrence {
                Button { shareTarget = .task(id: t.id, name: t.name) } label: {
                    Label("Share…", systemImage: "person.badge.plus")
                }
            }
            if isOccurrence {
                Button(role: .destructive) { model.skipOccurrence(t.id) } label: {
                    Label("Skip this day", systemImage: "calendar.badge.minus")
                }
            }
        }
    }

    // MARK: recap card (Android "Just now" parity)

    private func recapCard(_ recap: AppModel.RecapState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                SectionLabel("Just now").foregroundStyle(theme.palette.coral)
                Spacer()
                Button { model.lastRecap = nil } label: {
                    Text("✕").font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                        // Grow the hit area to 44pt without shifting the card body:
                        // the ✕ stays drawn at 13pt; the larger frame is centered &
                        // transparent, and the negative top padding keeps the HStack
                        // (and the text below it) at its original height.
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        .padding(.vertical, -14)
                }.buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
            }
            Text("You did the thing.").font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
                .padding(.top, 4)
            Text("\(max(1, recap.focusedSec / 60)) MIN FOCUSED · \(recap.taskName)")
                .font(UFont.mono(11)).foregroundStyle(theme.palette.ink2)
                .lineLimit(1).truncationMode(.tail).padding(.top, 6)
            // One true shared session: a partner finishing the session ends it
            // for both — quietly attribute who did (never a modal).
            if let by = recap.endedBy {
                Text("\(by) ended the session")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    .padding(.top, 4)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.coralSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: quiet nudge card (Android TodayScreen nudge row parity)

    /// A bordered card: the nudge title, an action (SLIPPING → open the task's
    /// detail; CAPTURE → promote the capture), and an ✕ that persists a
    /// device-local dismissal. Both action + ✕ dismiss the nudge (Android parity).
    private func nudgeCard(_ vm: TodayModel, _ n: Nudge) -> some View {
        HStack(spacing: 10) {
            Text(n.title).font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                switch n.kind {
                case .slipping:
                    if let t = vm.all.first(where: { $0.id == n.taskId }) { model.router.detailTask = t }
                case .capture:
                    if let c = vm.captures.first(where: { $0.id == n.captureId }) { model.promoteCapture(c) }
                }
                vm.dismissNudge(n.id)
            } label: {
                Text(n.action).font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.ink)
            }.buttonStyle(.plain)
            Button { vm.dismissNudge(n.id) } label: {
                Text("✕").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    // 44pt hit area; negative padding keeps the nudge-card row height
                    // unchanged so the drawn layout is identical.
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    .padding(.vertical, -14)
            }.buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.palette.line))
    }

    // MARK: notifications banner + helpers

    private var notificationsOffBanner: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bell.slash").font(.system(size: 16)).foregroundStyle(theme.palette.amberInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications are off").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.amberInk)
                    Text("Reminders won't reach your phone. Tap to turn them on.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.amberInk.opacity(0.85))
                }
                Spacer()
                Text("→").font(UFont.sans(14)).foregroundStyle(theme.palette.amberInk)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.amberSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.buttonStyle(.plain)
    }

    /// Changes the server refused are on this phone only (audit 2026-09-22,
    /// C28): say so, and offer the two ways out.
    private var stuckChangesBanner: some View {
        let n = model.stuckChanges
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.icloud").font(.system(size: 16)).foregroundStyle(theme.palette.amberInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(n) change\(n == 1 ? "" : "s") couldn't be saved")
                        .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.amberInk)
                    Text("\(n == 1 ? "It's" : "They're") only on this phone. Try again, or discard to keep what your other devices have.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.amberInk.opacity(0.85))
                }
            }
            HStack(spacing: 16) {
                Spacer()
                Button("Discard") { confirmDiscardStuck = true }
                    .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.amberInk.opacity(0.85))
                Button("Try again") { model.retryStuckChanges() }
                    .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.amberInk)
            }
            .buttonStyle(.plain)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.amberSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .alert("Discard \(n == 1 ? "this change" : "these changes")?", isPresented: $confirmDiscardStuck) {
            Button("Discard", role: .destructive) { model.discardStuckChanges() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This phone goes back to what your account has on the server.")
        }
    }

    private func refreshNotifStatus() async {
        #if DEBUG
        // Demo boot (UITEST_SEED): the banner only reflects the simulator's
        // permission state — hide it so screenshots show the product.
        if ProcessInfo.processInfo.environment["UITEST_SEED"] == "1" { notifsEnabled = true; return }
        #endif
        let s = await UNUserNotificationCenter.current().notificationSettings()
        notifsEnabled = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional || s.authorizationStatus == .ephemeral
    }

    private var greeting: String {
        let h = Time.calendar.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Still up"
        }
    }
    private var dateEyebrow: String {
        TodayFmt.eyebrow(Date())
    }
}

// MARK: - assistant input pill

/// The way into the assistant from Today: ONE pill directly under the week
/// pill — "✦ Ask, plan, or brain-dump…" with the mic on the right — drawn
/// exactly like the composer the old gateway card carried (surface capsule,
/// coral ring, ✦ leading glyph, mic + send affordances). Tapping the field
/// (or the arrow) opens the Assistant sheet with focus in ITS composer;
/// the mic starts realtime Talk. No typing happens here. Renders nothing
/// while the AI kill-switch is off (the caller gates on `assistantEnabled`).
struct AssistantInputPill: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    /// Talk-mode entry — the host presents VoiceModeScreen, exactly as the
    /// Assistant sheet does for its Talk button.
    let onTalk: () -> Void

    static let placeholder = "Ask, plan, or brain-dump…"

    var body: some View {
        HStack(spacing: 2) {
            Button { model.openAssistant(focusComposer: true) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.palette.coral)
                        .accessibilityHidden(true)
                    Text(Self.placeholder)
                        .font(UFont.sans(14.5)).foregroundStyle(theme.palette.ink3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 13).padding(.vertical, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Ask the assistant")
                .accessibilityHint("Opens the assistant")
                .accessibilityIdentifier("home-ask-pill")
            if model.voiceConfigured {
                // 44pt hit targets (HIG) — the glyphs stay 34pt visually.
                Button(action: onTalk) {
                    Image(systemName: "mic")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.palette.coral)
                        .frame(width: 44, height: 44).contentShape(Circle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Talk to your assistant")
            }
            // The send affordance of the composer it replaces — the empty-field
            // look (nothing to send yet); it opens the assistant like the field.
            Button { model.openAssistant(focusComposer: true) } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(theme.palette.coral.opacity(0.3), in: Circle())
                    .frame(width: 44, height: 44).contentShape(Circle())
            }.buttonStyle(.plain)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .background(theme.palette.surface, in: Capsule())
        .overlay(Capsule().stroke(theme.palette.coral.opacity(0.55), lineWidth: 1.5))
    }
}
