// Calendar — 1:1 with the Android CalendarScreen: the shared AppBar, a
// Day/Week/Month segmented control, a Google connect/sync bar, and per-mode
// grids (a draggable Day hour grid with a NOW line + unscheduled tray, a
// Monday-anchored Week rollup + 7-column hour grid, and a Month focus-density
// heatmap + per-day planned marks). Block-time creation, drag-to-schedule, and
// Google two-way sync preserved from the prior iOS slice. Live store via GRDB.
// Tasks shared WITH me render as read-only blocks at the owner's slot on every
// mode (Calendar+Shared.swift) — never draggable/editable from here.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

/// Shared, configured-once DateFormatters for the calendar labels. Hoisted to
/// file scope so view bodies (week range / month title / day header) don't
/// allocate + configure a fresh DateFormatter on every render. DateFormatter is
/// thread-safe for reading once configured; `nonisolated(unsafe)` documents the
/// fixed-config, read-only use to the Swift 6 concurrency checker.
enum CalFmt {
    nonisolated(unsafe) static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMM d"; return f
    }()
    nonisolated(unsafe) static let monthYear: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMMM yyyy"; return f
    }()
    nonisolated(unsafe) static let weekdayMonthDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEE, MMM d"; return f
    }()
}

@MainActor
@Observable
final class CalendarModel {
    var tasks: [TaskItem] = [] { didSet { recomputeTaskDerived() } }
    var blocks: [CalBlock] = [] { didSet { recomputeBlockDerived() } }
    var areas: [LifeArea] = []
    var sessions: [Session] = [] { didSet { recomputeFocusByDay() } }
    var connections: [CalendarConnection] = []
    private let repo: TaskRepository
    private let connRepo: Repository<CalendarConnection>
    init(_ repo: TaskRepository, _ connRepo: Repository<CalendarConnection>) {
        self.repo = repo
        self.connRepo = connRepo
    }
    func observe() async {
        async let a: Void = observeData()
        async let b: Void = observeConnections()
        _ = await (a, b)
    }
    private func observeData() async {
        do {
            // areas/sessions come from the same tracked snapshot, so an area
            // rename or a realtime session arrival refreshes the pills and
            // the Month heatmap without waiting for a task edit.
            for try await snap in repo.observeTasksAndBlocks() {
                areas = snap.areas
                tasks = snap.tasks
                blocks = snap.blocks
                sessions = snap.sessions
            }
        } catch {}
    }
    private func observeConnections() async {
        do { for try await rows in connRepo.observeValues() { connections = rows } } catch {}
    }
    var connected: Bool { !connections.isEmpty }

    // MARK: - snapshot-derived caches (recomputed only when the inputs change)

    /// Per-day blocks with skipped occurrences dropped + sorted by start —
    /// the `blocks(on:)` semantics, precomputed once per snapshot. WeekView calls
    /// blocks(on:) 7× per render (one per column); this turns each into an O(1)
    /// dictionary lookup instead of a full filter+sort over all blocks.
    private(set) var blocksByDate: [String: [CalBlock]] = [:]
    /// Per-day lane layout (greedy interval colouring), precomputed once per
    /// snapshot. WeekView ran layoutLanes 7× per render; this caches it so each
    /// column is an O(1) lookup.
    private(set) var laidByDate: [String: [LaidBlock]] = [:]
    /// Blocks grouped by date (ascending, NOT skipped-filtered), each day's
    /// blocks sorted by start — cached per snapshot.
    private(set) var byDate: [(date: String, blocks: [CalBlock])] = []
    /// Open tasks with no block anywhere — the day grid's drag tray. Cached;
    /// depends on both tasks + blocks (recomputed by recomputeTaskDerived, which
    /// recomputeBlockDerived also calls so the scheduled-id set stays fresh).
    private(set) var unscheduledTasks: [TaskItem] = []
    /// Focused seconds per ISO date, for the Month heatmap — cached per snapshot.
    private(set) var focusByDay: [String: Int] = [:]

    private func recomputeBlockDerived() {
        var byDay: [String: [CalBlock]] = [:]
        var byDayRaw: [String: [CalBlock]] = [:]
        for b in blocks {
            byDayRaw[b.date, default: []].append(b)
            if !b.skipped { byDay[b.date, default: []].append(b) }
        }
        blocksByDate = byDay.mapValues { $0.sorted { $0.startTime < $1.startTime } }
        laidByDate = blocksByDate.mapValues { layoutLanes($0) }
        byDate = byDayRaw
            .map { ($0.key, $0.value.sorted { $0.startTime < $1.startTime }) }
            .sorted { $0.date < $1.date }
        // unscheduled depends on the block set (scheduled ids), so refresh it too.
        recomputeTaskDerived()
    }

    private func recomputeTaskDerived() {
        let scheduledIds = Set(blocks.filter { isTaskBlock($0) }.compactMap { $0.taskId })
        // recurrence == nil: never offer a recurring TEMPLATE in the schedule tray
        // — it's a hidden definition that generates occurrences, not a schedulable
        // task. Mirrors the Android DayGrid `it.recurrence == null` filter.
        unscheduledTasks = tasks.filter {
            !$0.done && !($0.later ?? false) && $0.recurrence == nil && !scheduledIds.contains($0.id)
        }
    }

    private func recomputeFocusByDay() {
        var out: [String: Int] = [:]
        for s in sessions {
            guard let ms = Time.parseMillis(s.completedAt) else { continue }
            let k = Clock.dateISO(millis: ms)
            out[k, default: 0] += s.actualSec
        }
        focusByDay = out
    }

    /// Blocks for a day (skipped dropped, sorted by start) — O(1) cache lookup.
    func blocks(on iso: String) -> [CalBlock] { blocksByDate[iso] ?? [] }
    /// Lane-laid blocks for a day — O(1) cache lookup (was layoutLanes per call).
    func laidBlocks(on iso: String) -> [LaidBlock] { laidByDate[iso] ?? [] }

    /// Open tasks with no block anywhere — the day grid's drag tray (matches
    /// Android: scheduled-anywhere tasks drop out of the tray so dragging one
    /// MOVES its block rather than re-adding it).
    func unscheduled() -> [TaskItem] { unscheduledTasks }
}

struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: CalendarModel?
    @State private var showSettings = false
    @State private var showPalette = false
    /// Tap-to-create prefill: the day + snapped time of an empty grid slot. A
    /// local sheet (the AppRouter's Sheet enum can't carry a prefill payload).
    @State private var createAt: CreateAt?

    /// Day / Week / Month — router-owned (AppRouter.calendarMode) so the
    /// assistant's `open_screen: week|month` switches it from anywhere.
    typealias CalMode = AppRouter.CalendarMode
    private var mode: CalMode { model.router.calendarMode }

    /// One tap-to-create intent: the date (YYYY-MM-DD) + snapped time (HH:mm).
    struct CreateAt: Identifiable, Equatable {
        let date: String
        let time: String
        var id: String { "\(date)T\(time)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppBar(title: "Calendar", onSearch: { showPalette = true }, onAvatar: { showSettings = true })

            // Day / Week / Month segmented control (MdSegment).
            segment
                .padding(.horizontal, 18).padding(.vertical, 4)

            if let vm {
                CalendarSyncBar(vm: vm)
                Group {
                    switch mode {
                    case .day: DayGridView(vm: vm, onCreateAt: presentCreate)
                    case .week: WeekView(vm: vm, onCreateAt: presentCreate)
                    case .month: MonthView(vm: vm)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPalette) { CommandPalette() }
        // Tap an empty grid slot → create a task prefilled at that day + time.
        // Mirrors the Android onCreateAt(date, time) → NewTaskSheet prefill.
        .sheet(item: $createAt) { at in
            NewTaskSheet(defaultEstimate: model.settings.focusDefaultMin,
                         prefillDate: at.date, prefillTime: at.time)
        }
        // The assistant ✦ launcher, like every other tab. The grids pad their
        // content 96pt at the bottom (and the Day tray's chip row scrolls past
        // it) so it never covers the last hour rows or a drop target.
        .assistantLauncher()
        // The guided tour is about to navigate — close the locally-presented
        // sheets (they live on this view's @State, out of the router's reach).
        .onReceive(NotificationCenter.default.publisher(for: .unstuckTourWillNavigate)) { _ in
            showSettings = false; showPalette = false; createAt = nil
        }
        .task {
            // Subscribe the share state to the live shares-changed signal (+ an
            // initial fetch) — the Calendar may be the first tab to need the
            // shared layer after launch. Idempotent on the subscribe.
            model.shareState.start()
            guard vm == nil, let db = model.db, let taskRepo = model.taskRepo else { return }
            let m = CalendarModel(taskRepo, Repository<CalendarConnection>(db, orderColumn: "connectedAt"))
            vm = m; await m.observe()
        }
    }

    private func presentCreate(_ date: String, _ time: String) {
        createAt = CreateAt(date: date, time: time)
    }

    // MARK: segmented control (MdSegment)

    private var segment: some View {
        HStack(spacing: 2) {
            ForEach(CalMode.allCases, id: \.self) { m in
                let on = mode == m
                Button { model.router.calendarMode = m } label: {
                    Text(m.rawValue)
                        // ink2 (not ink3) for inactive labels: 11pt on bg2 needs ≥4.5:1 AA contrast.
                        .font(UFont.sans(11, .semibold))
                        .foregroundStyle(on ? theme.palette.bg : theme.palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(on ? theme.palette.ink : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(m.rawValue)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Connect / sync / disconnect Google Calendar — mirrors the Android
/// CalendarSyncBar. Not connected: a "＋ Connect Google Calendar" pill.
/// Connected: the synced account(s) + a "Sync now" action (pulls via
/// AppModel.pullGoogleCalendar) + a destructive "Disconnect" behind a confirm
/// alert (drops all synced events — AppModel.disconnectCalendar). Connect and
/// Reconnect first say what connecting does (GoogleConnectCopy), then open
/// Google's consent.
private struct CalendarSyncBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let vm: CalendarModel
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDisconnect = false
    @State private var disconnecting = false
    /// Connect / Reconnect asked for: the disclosure is up (`reconnecting`
    /// picks its title).
    @State private var showDisclosure = false
    @State private var reconnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.calendarNeedsReauth && !vm.connections.isEmpty {
                reauthCard
            } else {
                syncRow
            }
            // Only this bar's own, already plain-worded failures. The server's
            // raw lastError ("invalid_grant (400)") is never shown — the card
            // above says what it means (Ahmad, 2026-09-23).
            if let caption = error {
                Text(caption).font(UFont.sans(11)).foregroundStyle(theme.palette.red)
                    .padding(.horizontal, 18).padding(.bottom, 6)
            }
        }
        .alert("Disconnect Google Calendar?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Synced events are removed from your calendar. Your tasks are unaffected.")
        }
        // Said BEFORE Google's consent: every task block is written to the
        // PRIMARY Google Calendar under the task's name (AppModel
        // .mirrorBlockToGoogle, calendarId "primary"), and nothing on iOS
        // said so — the pill went straight to consent (web/Android audit
        // 2026-09-23, W14/A19; owner call: honest copy now, no toggle).
        .alert(GoogleConnectCopy.title(reconnect: reconnecting), isPresented: $showDisclosure) {
            Button("Continue to Google") { connect() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(GoogleConnectCopy.disclosure)
        }
    }

    /// The refresh token is dead (401 / invalid_grant, or the server's
    /// needs_reauth flag): "Sync now" can only fail, so the bar becomes a card
    /// that says so in plain words and offers the re-consent — the ordinary
    /// connect flow over the SAME account (the server returns the same
    /// connection id and clears the flag).
    private var reauthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GoogleConnectCopy.reauthTitle)
                .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
            Text(GoogleConnectCopy.reauthBody(account: vm.connections.first?.accountEmail))
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button { reconnecting = true; showDisclosure = true } label: {
                    Text(busy && !disconnecting ? "Connecting…" : "Reconnect")
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(theme.palette.ink, in: Capsule())
                }.buttonStyle(.plain).disabled(busy)
                // Destructive — confirm first (it drops all synced events).
                Button { confirmDisconnect = true } label: {
                    Text("Disconnect").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                }.buttonStyle(.plain).disabled(busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 18).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var syncRow: some View {
        HStack(spacing: 8) {
            if vm.connections.isEmpty {
                Button { reconnecting = false; showDisclosure = true } label: {
                    Text(GoogleConnectCopy.connectPill(busy: busy, disconnecting: disconnecting))
                        .font(UFont.sans(12, .medium)).foregroundStyle(theme.palette.ink2)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(theme.palette.bg2, in: Capsule())
                }.buttonStyle(.plain).disabled(busy)
            } else {
                Text(busy ? (disconnecting ? "Disconnecting…" : "Syncing…")
                     : vm.connections.map { "Synced · \($0.accountEmail)" }.joined(separator: ", "))
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button { sync() } label: {
                    Text("Sync now")
                        .font(UFont.sans(12, .medium))
                        .foregroundStyle(busy ? theme.palette.ink3 : theme.palette.primaryDeep)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }.buttonStyle(.plain).disabled(busy)
                // Destructive — confirm first (it drops all synced events).
                Button { confirmDisconnect = true } label: {
                    Text("Disconnect")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }.buttonStyle(.plain).disabled(busy)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 4)
    }

    private func sync() {
        busy = true; error = nil
        // A failed "Sync now" used to end silently (audit 2026-09-22, C18).
        Task {
            if !(await model.pullGoogleCalendar()) {
                error = model.calendarSyncStatus?.backoffUntil != nil
                    ? "Google is busy right now. Try again in a few minutes."
                    : "Couldn't sync with Google. Check your connection and try again."
            }
            busy = false
        }
    }

    /// The bar flips to "Connect" only once the server has revoked access; a
    /// failed revoke keeps the connection and says so, instead of looking
    /// done while the server still holds the token (audit 2026-09-22, C26).
    private func disconnect() {
        busy = true; disconnecting = true; error = nil
        Task {
            if !(await model.disconnectCalendar()) {
                error = "Couldn't disconnect Google. Check your connection and try again."
            }
            busy = false; disconnecting = false
        }
    }

    private func connect() {
        guard let calendar = model.calendar else { error = "Sign in first."; return }
        busy = true; error = nil
        Task {
            let controller = GoogleConnectController(calendar)
            let result = await controller.connect()
            switch result {
            // Save the connection locally (the bar flips to "Synced" and new
            // blocks mirror to Google at once), drop the stale needs-reauth
            // verdict + back-off, then pull — `busy` holds until the first sync
            // lands (audit 2026-09-22, C18).
            case .success(let connection):
                if !(await model.calendarDidConnect(connection)) {
                    error = "Google is connected, but the first sync didn't finish. Tap Sync now."
                }
            case .failure(let err): error = "Couldn't connect. \(err.localizedDescription)"
            }
            busy = false
        }
    }
}

// MARK: - Week view (Monday-anchored rollup + 7-column hour grid)

private struct WeekView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let vm: CalendarModel
    /// Tap an empty slot → create a task prefilled at that day + snapped time.
    let onCreateAt: (String, String) -> Void
    @State private var weekOffset = 0
    /// Tap a task block → reschedule/resize/unschedule (same sheet as the Day grid).
    @State private var editingBlock: CalBlock?
    /// Tap a SHARED block → the read-only shared-task detail (never the edit sheet).
    @State private var sharedDetail: SharedDetailTarget?

    private let wStart = 0
    private let wEnd = 24
    private let wHour: CGFloat = 44
    private let dows = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let cal = Time.calendar
        let weekdaySun1 = cal.component(.weekday, from: Date())          // 1=Sun … 7=Sat
        let thisMonday = cal.date(byAdding: .day, value: -((weekdaySun1 + 5) % 7), to: cal.startOfDay(for: Date()))!
        let monday = cal.date(byAdding: .day, value: weekOffset * 7, to: thisMonday)!
        let days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }
        let planned = days.map { d in vm.blocks(on: Clock.dateISO(d)).filter { isTaskBlock($0) }.reduce(0) { $0 + $1.durationMinutes } }
        let total = planned.reduce(0, +)
        let maxP = planned.max() ?? 0, minP = planned.min() ?? 0
        let flat = maxP == minP
        let busiest = flat ? "—" : dayLabels[planned.firstIndex(of: maxP) ?? 0]
        let lightest = flat ? "—" : dayLabels[planned.firstIndex(of: minP) ?? 0]
        let todayISO = Clock.todayISO()

        // The week title + paging, the rollup and the weekday row stay PINNED
        // above the grid (like Month and the Day view's date header) — only the
        // hour grid scrolls, so scrolling to an early or late hour never hides
        // which day a column is (tester, 2026-09-07: "can't see the days").
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Header: This week / range + ‹ Today ›
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(weekOffset == 0 ? "This week" : "Week").foregroundStyle(theme.palette.primaryDeep)
                        Text(weekRangeLabel(days.first!, days.last!))
                            .font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink)
                    }
                    Spacer()
                    Button { weekOffset -= 1 } label: {
                        Text("‹").font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 12).padding(.vertical, 2)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()).padding(.vertical, -6)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Previous week")
                    if weekOffset != 0 {
                        Button { weekOffset = 0 } label: {
                            Text("Today").font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .frame(minHeight: 44).contentShape(Rectangle()).padding(.vertical, -10)
                        }.buttonStyle(.plain)
                            .accessibilityLabel("This week")
                    }
                    Button { weekOffset += 1 } label: {
                        Text("›").font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 12).padding(.vertical, 2)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()).padding(.vertical, -6)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Next week")
                }
                .padding(.top, 8)

                // Rollup stats
                HStack(spacing: 8) {
                    rollup("Focus planned", total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m",
                           theme.palette.primarySoft, theme.palette.primaryDeep)
                    rollup("Busiest", busiest, theme.palette.amberSoft, theme.palette.amberInk)
                    rollup("Lightest", lightest, theme.palette.greenSoft, theme.palette.greenInk)
                }
                .padding(.top, 10).padding(.bottom, 12)

                // Weekday header (gutter + 7 day labels)
                HStack(spacing: 0) {
                    Color.clear.frame(width: 26, height: 1)
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        let isToday = Clock.dateISO(d) == todayISO
                        VStack(spacing: 1) {
                            Text(dows[i]).font(UFont.mono(9, .medium)).foregroundStyle(isToday ? theme.palette.coral : theme.palette.ink3)
                            Text("\(cal.component(.day, from: d))").font(UFont.sans(13, .semibold)).foregroundStyle(isToday ? theme.palette.coral : theme.palette.ink)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

            }
            .padding(.horizontal, 18)

            // Hour grid — the only part that scrolls.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                // Hour grid: time gutter + 7 day columns with positioned blocks.
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        // Hour gutter in the phone's clock — "14:00" / "2 PM",
                        // the same labels as the Day grid (a bare "14" read
                        // 24-hour on a 12-hour phone; 2026-09-24).
                        ForEach(wStart..<wEnd, id: \.self) { h in
                            Text(ClockFormat.device.hourLabel(h)).font(UFont.mono(8))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(theme.palette.ink4)
                                .frame(width: 26, height: wHour, alignment: .topLeading)
                        }
                    }
                    ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                        dayColumn(Clock.dateISO(d))
                    }
                }
                .frame(height: wHour * CGFloat(wEnd - wStart))
                .padding(.top, 6)

                Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 96)
            }
        }
        // Tap a task block → reschedule / resize / unschedule.
        .sheet(item: $editingBlock) { block in
            CalBlockEditSheet(vm: vm, block: block)
        }
        // Tap a shared block → its read-only detail.
        .sheet(item: $sharedDetail) { target in
            SharedTaskDetailSheet(taskId: target.id)
        }
        // Load the shared layer for the visible week (cached per window;
        // re-read on the shares-changed signal by ShareModel).
        .task(id: weekOffset) {
            let w = CalWindow.week(offset: weekOffset)
            await model.shareState.loadSharedBlocks(from: w.from, to: w.to)
        }
    }

    private func dayColumn(_ iso: String) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(wStart..<wEnd, id: \.self) { _ in
                        Rectangle().fill(.clear)
                            .frame(height: wHour)
                            .overlay(Rectangle().stroke(theme.palette.line.opacity(0.6), lineWidth: 0.5))
                    }
                }
                // Tap an empty slot → create a task prefilled at this day + snapped
                // time. Blocks layer on top below, so a tap on a block doesn't fall
                // through to create. Mirrors the Android WeekView detectTapGestures.
                .contentShape(Rectangle())
                .onTapGesture { location in
                    onCreateAt(iso, snappedTime(location.y))
                }
                // Own + shared blocks in one lane pass (side-by-side on overlap).
                let laid = dayLanes(vm, iso: iso, shared: model.shareState.sharedBlocks(on: iso))
                ForEach(laid, id: \.item.id) { laidItem in
                    let top = laidItem.startMin - wStart * 60
                    if top >= 0 && top <= (wEnd - wStart) * 60 {
                        let laneW = laidItem.lanes > 1 ? geo.size.width / CGFloat(laidItem.lanes) : geo.size.width
                        let w = max(5, laneW - 1)
                        let h = max(13, CGFloat(laidItem.item.durationMinutes) / 60 * wHour)
                        let off = CGSize(width: laneW * CGFloat(laidItem.lane), height: wHour * CGFloat(top) / 60)
                        switch laidItem.item {
                        case .own(let b):
                            weekBlock(b)
                                .frame(width: w, height: h)
                                // Task blocks open the edit sheet; external/placeholder
                                // blocks just swallow the tap so it doesn't fall through
                                // to the create-task gesture underneath.
                                .onTapGesture { if isTaskBlock(b) { editingBlock = b } }
                                .offset(off)
                        case .shared(let sb):
                            // READ-ONLY: tap → the shared-task detail. Never the
                            // edit sheet (it takes a CalBlock — a shared block
                            // can't even be passed to it).
                            SharedWeekBlock(block: sb, height: h)
                                .frame(width: w, height: h)
                                .onTapGesture { sharedDetail = SharedDetailTarget(id: sb.taskId, block: sb) }
                                .offset(off)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Map a y-offset in the day column to a snapped HH:mm, 15-min steps,
    /// clamped 00:00–23:45. Mirrors the Android snap math.
    private func snappedTime(_ y: CGFloat) -> String {
        let totalMin = wStart * 60 + Int((Double(y) / Double(wHour) * 60).rounded())
        let snapped = min(wEnd * 60 - 15, max(wStart * 60, (totalMin / 15) * 15))
        return String(format: "%02d:%02d", snapped / 60, snapped % 60)
    }

    private func weekBlock(_ b: CalBlock) -> some View {
        let bt = isTaskBlock(b) ? vm.tasks.first(where: { $0.id == b.taskId }) : nil
        // For a recurring occurrence the completion lives on the block.
        let done = b.done || bt?.done == true
        let fill = isTaskBlock(b) ? theme.palette.areaColor(bt?.lifeArea) : theme.palette.blueSoft
        return Text(b.taskName)
            .font(UFont.sans(8, .medium))
            .foregroundStyle(done ? theme.palette.ink3 : theme.palette.ink)
            .strikethrough(done)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(1)
            .background(isTaskBlock(b) ? fill.opacity(0.5) : fill)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func rollup(_ label: String, _ value: String, _ bg: Color, _ fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(UFont.mono(9, .medium)).foregroundStyle(fg)
            Text(value).font(UFont.sans(14, .semibold)).foregroundStyle(fg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private func weekRangeLabel(_ start: Date, _ end: Date) -> String {
        let df = CalFmt.monthDay
        let cal = Time.calendar
        if cal.component(.month, from: start) == cal.component(.month, from: end) {
            return "\(df.string(from: start))–\(cal.component(.day, from: end))"
        }
        return "\(df.string(from: start)) – \(df.string(from: end))"
    }

    private func minutesOf(_ hhmm: String) -> Int {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }
}

// MARK: - Month view (focus-density heatmap + planned / shared marks)

private struct MonthView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let vm: CalendarModel
    @State private var ym = Date()
    /// Tap a day with a shared block → the first one's read-only detail.
    @State private var sharedDetail: SharedDetailTarget?
    /// Tap ANY day → everything on it, in a peek sheet (tester, 2026-09-08:
    /// a shared day opened something and a planned day didn't).
    @State private var dayPeek: MonthDayPeek?
    /// What the peek asked for, acted on once it has finished dismissing —
    /// SwiftUI drops a second sheet presented while the first is still going.
    @State private var pendingPeek: MonthPeekAction?

    private let dows = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let cal = Time.calendar
        let comps = cal.dateComponents([.year, .month], from: ym)
        let firstOfMonth = cal.date(from: comps)!
        let monthName = monthLabel(firstOfMonth)
        let daysInMonth = cal.range(of: .day, in: .month, for: firstOfMonth)!.count
        // Monday-leading offset (Mon=0 … Sun=6)
        let weekdaySun1 = cal.component(.weekday, from: firstOfMonth)
        let lead = (weekdaySun1 + 5) % 7
        let cells: [Date?] = Array(repeating: nil, count: lead) + (1...daysInMonth).map { day in
            cal.date(byAdding: .day, value: day - 1, to: firstOfMonth)!
        }
        // Heat = how BUSY the day is: scheduled minutes (my blocks + shared),
        // which is readable for days still ahead. It used to be focus density
        // (minutes actually focused), so every future day rendered empty.
        let byDay: [String: Int] = cells.reduce(into: [:]) { acc, cell in
            guard let d = cell else { return }
            let iso = Clock.dateISO(d)
            let own = vm.blocks(on: iso).filter { !$0.skipped }.reduce(0) { $0 + $1.durationMinutes }
            let shr = model.shareState.sharedBlocks(on: iso).filter { !$0.skipped }.reduce(0) { $0 + $1.durationMinutes }
            if own + shr > 0 { acc[iso] = own + shr }
        }
        // A floor so one 8-hour day doesn't flatten a normal week to nothing.
        let maxV = max(180, byDay.values.max() ?? 0)
        let todayISO = Clock.todayISO()
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        let monthWindow = CalWindow.month(containing: firstOfMonth)

        // The month title + paging, the legend and the weekday row stay PINNED
        // above the grid (like the Day view's date header) — only the grid
        // scrolls, so paging months or reading a weekday column never needs a
        // scroll back up. (Was one ScrollView around everything: the header
        // scrolled away with the grid.)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Header: month + year, ‹ Today ›
                HStack(alignment: .center) {
                    Text(monthName).font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink)
                    Spacer()
                    Button { ym = cal.date(byAdding: .month, value: -1, to: ym)! } label: {
                        Text("‹").font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 10).padding(.vertical, 2)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()).padding(.vertical, -8)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Previous month")
                    Button { ym = Date() } label: {
                        Text("Today").font(UFont.sans(12, .medium)).foregroundStyle(theme.palette.primaryDeep)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(minHeight: 44).contentShape(Rectangle()).padding(.vertical, -10)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("This month")
                    Button { ym = cal.date(byAdding: .month, value: 1, to: ym)! } label: {
                        Text("›").font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 10).padding(.vertical, 2)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()).padding(.vertical, -8)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Next month")
                }
                .padding(.top, 8)

                // Legend: the fill is how busy the day is (scheduled minutes); the marks under the day
                // number are MY planned blocks (dots) + anything shared (ring).
                HStack(spacing: 10) {
                    Text("How busy").font(UFont.mono(10, .medium))
                    HStack(spacing: 3) {
                        Circle().fill(theme.palette.ink3).frame(width: 3.5, height: 3.5)
                        Text("planned").font(UFont.mono(10, .medium))
                    }
                    HStack(spacing: 3) {
                        Circle().strokeBorder(theme.palette.primaryDeep, style: StrokeStyle(lineWidth: 1, dash: [1.5, 1]))
                            .frame(width: 5, height: 5)
                        Text("shared").font(UFont.mono(10, .medium))
                    }
                }
                .foregroundStyle(theme.palette.ink3)
                .padding(.top, 2).padding(.bottom, 10)

                // Weekday header
                HStack(spacing: 4) {
                    ForEach(Array(dows.enumerated()), id: \.offset) { _, d in
                        Text(d).font(UFont.mono(10)).foregroundStyle(theme.palette.ink4)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 18)

            // Day grid card — the only part that scrolls.
            ScrollView {
                VStack(spacing: 0) {
                    Card {
                        VStack(spacing: 4) {
                            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                                HStack(spacing: 4) {
                                    ForEach(0..<7, id: \.self) { i in
                                        if i < week.count, let d = week[i] {
                                            monthCell(d, byDay: byDay, maxV: maxV, todayISO: todayISO)
                                        } else {
                                            Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Clear the floating bottom nav (96pt, like every tab) AND the
                    // assistant launcher docked above it (46pt + a gap), so the last
                    // week's Sat/Sun cells scroll fully out from under both.
                    Color.clear.frame(height: 56)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 96)
            }
        }
        // Tap a day → everything on it; a row then opens the task (mine) or
        // the read-only shared detail, once this sheet is fully gone.
        .sheet(item: $dayPeek, onDismiss: flushPeek) { peek in
            MonthDayPeekSheet(iso: peek.id, vm: vm) { action in
                pendingPeek = action
                dayPeek = nil
            }
        }
        // Tap a day carrying a shared block → its read-only detail.
        .sheet(item: $sharedDetail) { target in
            SharedTaskDetailSheet(taskId: target.id, block: target.block)
        }
        // Load the shared layer for the visible month (≤ 31 days, under the
        // server's 62-day cap; cached per window).
        .task(id: monthWindow) {
            await model.shareState.loadSharedBlocks(from: monthWindow.from, to: monthWindow.to)
        }
    }

    /// Act on the peek's choice after it has closed: my task opens the editor
    /// through the router (the Inbox pattern), a shared one its read-only sheet.
    private func flushPeek() {
        guard let action = pendingPeek else { return }
        pendingPeek = nil
        switch action {
        case .task(let id): model.routeDeepLink("unstuck://task/\(id)")
        case .shared(let target): sharedDetail = target
        }
    }

    private func monthCell(_ d: Date, byDay: [String: Int], maxV: Int, todayISO: String) -> some View {
        let iso = Clock.dateISO(d)
        let v = byDay[iso] ?? 0
        let t = min(1, max(0, Double(v) / Double(maxV)))
        let isToday = iso == todayISO
        let day = Time.calendar.component(.day, from: d)
        // Heat fill: today = coral, empty = bg2, else lerp bg2→primary.
        let fill: Color = isToday ? theme.palette.coral
            : (v == 0 ? theme.palette.bg2 : lerpColor(theme.palette.bg2, theme.palette.primary, 0.2 + 0.6 * t))
        let textColor: Color = (isToday || t > 0.5) ? theme.palette.bg : theme.palette.ink2
        // Planned marks — MY task blocks that day (from the cached
        // blocksByDate) + shared ones — separate from the focus-density fill.
        let sharedHere = model.shareState.sharedBlocks(on: iso)
        let marks = monthDayMarks(own: vm.blocks(on: iso), shared: sharedHere)
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill)
            VStack(spacing: 2) {
                Text("\(day)").font(UFont.sans(11, .semibold)).foregroundStyle(textColor)
                if !marks.isEmpty { MonthMarksRow(marks: marks, tint: textColor) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // EVERY day opens the same peek — what is on it, and a way into each
        // item. (Shared days used to open a sheet and planned days did nothing.)
        .onTapGesture { dayPeek = MonthDayPeek(id: iso) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(monthCellLabel(day: day, focusedSec: v, marks: marks, isToday: isToday))
    }

    private func monthCellLabel(day: Int, focusedSec: Int, marks: MonthDayMarks, isToday: Bool) -> String {
        var parts = [isToday ? "Today, \(day)" : "\(day)"]
        if marks.planned > 0 { parts.append("\(marks.planned) planned") }
        if marks.shared > 0 { parts.append("\(marks.shared) shared") }
        if focusedSec > 0 { parts.append("\(focusedSec) minutes scheduled") }
        return parts.joined(separator: ", ")
    }

    private func monthLabel(_ d: Date) -> String {
        CalFmt.monthYear.string(from: d)
    }

    private func lerpColor(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = UIColor(a); let cb = UIColor(b)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        ca.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        cb.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let f = CGFloat(t)
        return Color(red: Double(ar + (br - ar) * f), green: Double(ag + (bg - ag) * f), blue: Double(ab + (bb - ab) * f))
    }
}

// MARK: - Lane layout (overlapping blocks split into side-by-side columns)

/// One block's column placement so time-overlapping blocks render side-by-side.
struct LaidBlock {
    let block: CalBlock
    let startMin: Int
    let endMin: Int
    var lane: Int = 0
    var lanes: Int = 1
}

/// Greedy interval colouring — mirrors the Android layoutLanes / web calendar.
/// The pass itself is the generic `layoutLanes(_:startTime:durationMinutes:)`
/// (Calendar+Shared.swift), which the merged own+shared layout also uses.
func layoutLanes(_ blocks: [CalBlock]) -> [LaidBlock] {
    layoutLanes(blocks, startTime: \.startTime, durationMinutes: \.durationMinutes).map {
        LaidBlock(block: $0.item, startMin: $0.startMin, endMin: $0.endMin, lane: $0.lane, lanes: $0.lanes)
    }
}

// MARK: - Day grid (draggable hour grid + NOW line + unscheduled tray)

/// Day view with a draggable unscheduled-task tray + a time grid + a NOW line.
/// Dropping a task creates a block at the dropped time; dragging a block
/// reschedules it. Both push to Google when connected. 1:1 with the Android
/// DayGridScreen.
struct DayGridView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let vm: CalendarModel
    /// Tap an empty slot → create a task prefilled at the viewed day + snapped time.
    let onCreateAt: (String, String) -> Void
    @State private var date = Date()
    @State private var now = Date()
    /// Tap a task block → the reschedule/resize/unschedule sheet.
    @State private var editingBlock: CalBlock?
    /// Tap a SHARED block → the read-only shared-task detail (never the edit sheet).
    @State private var sharedDetail: SharedDetailTarget?

    private let firstHour = 0
    private let lastHour = 24
    private let pxPerHour: CGFloat = 56
    private var gridHeight: CGFloat { CGFloat(lastHour - firstHour) * pxPerHour }
    private var iso: String { Clock.dateISO(date) }

    private let nowTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            dateHeader
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geo in grid(width: geo.size.width) }
                        .frame(height: gridHeight)
                    // Let the last hour rows scroll clear of the tray + the
                    // floating assistant launcher.
                    Color.clear.frame(height: 96)
                }
                .onAppear { scrollToNow(proxy) }
                .onChange(of: date) { _, _ in scrollToNow(proxy) }
            }
            Divider()
            tray
        }
        .onReceive(nowTick) { _ in
            let prevWasToday = (iso == Clock.todayISO())
            now = Date()
            // Roll the viewed day forward across midnight if the user is still
            // on "today", so the NOW line + "Today" label don't stick on yesterday.
            if prevWasToday && iso != Clock.todayISO() {
                date = Date()
            }
        }
        // Tap a task block → reschedule / resize / unschedule.
        .sheet(item: $editingBlock) { block in
            CalBlockEditSheet(vm: vm, block: block)
        }
        // Tap a shared block → its read-only detail.
        .sheet(item: $sharedDetail) { target in
            SharedTaskDetailSheet(taskId: target.id)
        }
        // Load the shared layer for the week around the viewed day (one RPC
        // per week window, cached; re-read on the shares-changed signal).
        .task(id: iso) {
            let w = CalWindow.week(containing: iso)
            await model.shareState.loadSharedBlocks(from: w.from, to: w.to)
        }
    }

    /// Map a y-offset on the grid to a snapped HH:mm, 15-min steps, clamped
    /// 00:00–23:45. Mirrors the Android DayGrid snap math.
    private func snappedTime(_ y: CGFloat) -> String {
        let totalMin = firstHour * 60 + Int((Double(y) / Double(pxPerHour) * 60).rounded())
        let snapped = min(lastHour * 60 - 15, max(firstHour * 60, (totalMin / 15) * 15))
        return String(format: "%02d:%02d", snapped / 60, snapped % 60)
    }

    private var dateHeader: some View {
        HStack {
            Button { shift(-1) } label: {
                Text("‹").font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink2)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()).padding(.vertical, -6)
            }.buttonStyle(.plain)
                .accessibilityLabel("Previous day")
            Spacer()
            Text(iso == Clock.todayISO() ? "Today" : dayLabel).font(UFont.sans(15, .medium)).foregroundStyle(theme.palette.ink)
            Spacer()
            Button { shift(1) } label: {
                Text("›").font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink2)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()).padding(.vertical, -6)
            }.buttonStyle(.plain)
                .accessibilityLabel("Next day")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    @ViewBuilder
    private var tray: some View {
        let items = vm.unscheduled()
        VStack(alignment: .leading, spacing: 6) {
            Text("Drag onto the grid to schedule")
                .font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items.prefix(20)) { task in
                        Text("\(task.name) · \(task.estimateMin)m")
                            .font(UFont.sans(12)).lineLimit(1)
                            .foregroundStyle(theme.palette.ink)
                            .padding(.vertical, 8).padding(.horizontal, 10)
                            .background(theme.palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.palette.line))
                            .draggable("task:\(task.id)")
                    }
                }
                // Trailing room so the last chip can scroll out from under
                // the floating assistant launcher (bottom-trailing, 46pt).
                .padding(.leading, 12).padding(.trailing, 76).padding(.bottom, 12)
            }
        }
        .padding(.bottom, 84)   // clear the floating bottom nav
    }

    private func grid(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(firstHour..<lastHour, id: \.self) { hour in
                    HStack(alignment: .top, spacing: 0) {
                        // "14:00" / "2 PM" — the phone's 12/24-hour clock (2026-09-24).
                        Text(ClockFormat.device.hourLabel(hour)).font(UFont.mono(10)).foregroundStyle(theme.palette.ink4)
                            .frame(width: 64, alignment: .leading)
                            .padding(.leading, 12).padding(.top, 2)
                        Rectangle().fill(.clear).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(Rectangle().stroke(theme.palette.line, lineWidth: 0.5))
                    }
                    .frame(height: pxPerHour, alignment: .top)
                    .id("hour-\(hour)")
                }
            }
            // Tap an empty grid area → create a task prefilled at the snapped time.
            // Ignore the hour-label gutter (x < 64). Blocks layer on top below with
            // their own taps, so a tap on a block opens its edit sheet instead of
            // creating. Mirrors the Android DayGrid detectTapGestures.
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard location.x >= 64 else { return }
                onCreateAt(iso, snappedTime(location.y))
            }
            // Blocks for the day, positioned by start time, lane-split on overlap
            // — my own AND the shared layer in one lane pass. Only my own TASK
            // blocks are draggable/editable (CalLaneItem.isEditable) —
            // external/Google + placeholder blocks are display-only (they mirror
            // the remote calendar; moving one would enqueue a non-UUID g_ row
            // Postgres rejects forever, and only changes local state that
            // reverts on the next sync), and SHARED blocks are the owner's
            // (tap → read-only detail; never drag / edit / delete). Mirrors the
            // Android DayGrid gating.
            ForEach(dayLanes(vm, iso: iso, shared: model.shareState.sharedBlocks(on: iso)), id: \.item.id) { item in
                let laneW = item.lanes > 1 ? (width - 82) / CGFloat(item.lanes) : (width - 82)
                let x = 70 + laneW * CGFloat(item.lane)
                switch item.item {
                case .own(let b):
                    let card = blockCard(b, width: max(20, laneW - 3))
                        .offset(x: x, y: yFor(b))
                    if item.item.isEditable {
                        // Tap to edit (reschedule/resize/unschedule) + drag to move.
                        card
                            .onTapGesture { editingBlock = b }
                            .draggable("block:\(b.id)")
                    } else {
                        // External/placeholder blocks are display-only — swallow the tap
                        // so it doesn't fall through to the grid's create handler.
                        card.onTapGesture { }
                    }
                case .shared(let sb):
                    // Read-only: tap opens the shared-task detail; NO .draggable,
                    // NO context menu, NO edit sheet.
                    SharedBlockCard(block: sb, width: max(20, laneW - 3),
                                    height: max(24, CGFloat(sb.durationMinutes) / 60 * pxPerHour))
                        .offset(x: x, y: yFor(startTime: sb.startTime))
                        .onTapGesture { sharedDetail = SharedDetailTarget(id: sb.taskId, block: sb) }
                }
            }
            // NOW line on today's grid.
            if iso == Clock.todayISO() {
                let cal = Time.calendar
                let nm = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now) - firstHour * 60
                if nm >= 0 && nm <= (lastHour - firstHour) * 60 {
                    let y = CGFloat(nm) / 60 * pxPerHour
                    Rectangle().fill(theme.palette.coral).frame(height: 1.5)
                        .padding(.leading, 64).padding(.trailing, 12)
                        .offset(y: y)
                    Text("NOW").font(UFont.mono(8, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(theme.palette.coral, in: Capsule())
                        .padding(.leading, 8)
                        .offset(y: max(0, y - 8))
                }
            }
        }
        .frame(width: width, height: gridHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, location in handleDrop(items, location) }
    }

    private func blockCard(_ block: CalBlock, width: CGFloat) -> some View {
        let h = max(24, CGFloat(block.durationMinutes) / 60 * pxPerHour)
        let bt = isTaskBlock(block) ? vm.tasks.first(where: { $0.id == block.taskId }) : nil
        // For a recurring occurrence the completion lives on the block.
        let done = block.done || bt?.done == true
        let fill: Color = isExternalBlock(block) ? theme.palette.blueSoft
            : (isTaskBlock(block) ? theme.palette.areaColor(bt?.lifeArea).opacity(0.5) : theme.palette.bg2)
        return VStack(alignment: .leading, spacing: 1) {
            Text(block.taskName).font(UFont.sans(12, .medium)).lineLimit(1)
                .strikethrough(done)
                .foregroundStyle(done ? theme.palette.ink3 : theme.palette.ink)
            if h > 34 { Text(ClockFormat.device.time(block.startTime)).font(UFont.mono(9)).foregroundStyle(theme.palette.ink3) }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .frame(width: width, height: h, alignment: .topLeading)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.palette.line))
        .contextMenu {
            // External/Google blocks can't be deleted from here — they mirror
            // the remote calendar (delete them in Google; the next pull drops
            // the local copy). Spec 02-sync-engine §1.6.
            if !isExternalBlock(block) {
                Button(role: .destructive) { model.deleteBlock(block) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func yFor(_ block: CalBlock) -> CGFloat { yFor(startTime: block.startTime) }
    private func yFor(startTime: String) -> CGFloat {
        CGFloat(minutesOf(startTime) - firstHour * 60) / 60 * pxPerHour
    }

    /// Drop handler — accepts ONLY my own payloads: "task:<id>" (schedule from
    /// the tray) and "block:<id>" (move my own block; resolved against
    /// vm.blocks, so a shared block id — which lives in ShareModel, never in
    /// vm.blocks — can't match). Shared blocks are never made `.draggable`, so
    /// no "shared:" payload exists; anything else is refused.
    private func handleDrop(_ items: [String], _ location: CGPoint) -> Bool {
        guard let payload = items.first, !payload.hasPrefix("shared:") else { return false }
        let minutesFromTop = Double(location.y) / Double(pxPerHour) * 60
        let snapped = max(0, (minutesFromTop / 15).rounded() * 15)
        let total = firstHour * 60 + Int(snapped)
        let clamped = min((lastHour * 60) - 15, total)
        let startTime = String(format: "%02d:%02d", clamped / 60, clamped % 60)
        if payload.hasPrefix("task:") {
            let id = String(payload.dropFirst(5))
            guard let task = vm.tasks.first(where: { $0.id == id }) else { return false }
            model.scheduleTaskAt(task, date: iso, startTime: startTime)
            return true
        }
        if payload.hasPrefix("block:") {
            let id = String(payload.dropFirst(6))
            guard let block = vm.blocks.first(where: { $0.id == id }) else { return false }
            model.moveBlock(block, toDate: iso, startTime: startTime)
            return true
        }
        return false
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        guard iso == Clock.todayISO() else { return }
        let h = max(firstHour, Time.calendar.component(.hour, from: Date()) - 1)
        DispatchQueue.main.async {
            withAnimation(.none) { proxy.scrollTo("hour-\(h)", anchor: .top) }
        }
    }

    private func shift(_ days: Int) {
        date = Time.calendar.date(byAdding: .day, value: days, to: date) ?? date
    }
    private var dayLabel: String {
        CalFmt.weekdayMonthDay.string(from: date)
    }
    private func minutesOf(_ hhmm: String) -> Int {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }
}

// MARK: - Block edit sheet (reschedule / resize / unschedule)

/// Tap a scheduled task block → reschedule (free-slot chips), resize (duration
/// chips), or unschedule. Mirrors the Android CalBlockEditSheet (and the web
/// cal-block-edit-modal). External/Google blocks never reach here — the day
/// grid only opens this for task blocks — and SHARED blocks (someone else's
/// schedule, `SharedBlock`) can't even be passed in: they open the read-only
/// SharedTaskDetailSheet instead. The model is @Observable, so the live block
/// follows sequential edits without manual refresh.
struct CalBlockEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let vm: CalendarModel
    let block: CalBlock

    private static let durations = [15, 25, 45, 60, 90]

    var body: some View {
        // Track the live block so sequential edits compose + the selection
        // follows (resize then reschedule re-reads the new duration).
        let live = vm.blocks.first { $0.id == block.id } ?? block
        // Full-day window (not the default 08:00–18:00) so an early-morning /
        // evening block can be rescheduled within its own time band.
        let slots = findFreeSlotsForDate(vm.blocks, durationMin: live.durationMinutes,
                                         isoDate: live.date, now: Date(), limit: 5,
                                         dayStartMin: 0, dayEndMin: 24 * 60)
        // Keep the current start at the head so it always shows as selected.
        var times = [live.startTime]
        for s in slots where !times.contains(s.startTime) { times.append(s.startTime) }

        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Edit block")
                    Text(live.taskName).font(UFont.sans(18, .semibold)).foregroundStyle(theme.palette.ink)

                    VStack(alignment: .leading, spacing: 7) {
                        SectionLabel("Start time")
                        chipRow {
                            ForEach(times, id: \.self) { t in
                                chip(ClockFormat.device.time(t), selected: live.startTime == t) {
                                    model.moveBlock(live, toDate: live.date, startTime: t)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        SectionLabel("Duration")
                        chipRow {
                            ForEach(Self.durations, id: \.self) { m in
                                chip("\(m)m", selected: live.durationMinutes == m) {
                                    model.resizeBlock(live, durationMinutes: m)
                                }
                            }
                        }
                    }

                    UButton("Unschedule", kind: .danger) {
                        model.unschedule(live.id); dismiss()
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Edit block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func chipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
        }
    }

    private func chip(_ label: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label).font(UFont.sans(13, selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.palette.bg : theme.palette.ink2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? theme.palette.ink : theme.palette.bg2, in: Capsule())
                .overlay(Capsule().stroke(theme.palette.line2))
                // 44pt hit area without growing the drawn capsule row.
                .frame(minHeight: 44).contentShape(Capsule()).padding(.vertical, -9)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
