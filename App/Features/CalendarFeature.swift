// Calendar — 1:1 with the Android CalendarScreen: the shared AppBar, a
// Day/Week/Month segmented control, a Google connect/sync bar, and per-mode
// grids (a draggable Day hour grid with a NOW line + unscheduled tray, a
// Monday-anchored Week rollup + 7-column hour grid, and a Month focus-density
// heatmap). Block-time creation, drag-to-schedule, and Google two-way sync
// preserved from the prior iOS slice. Live store via GRDB.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

@MainActor
@Observable
final class CalendarModel {
    var tasks: [TaskItem] = []
    var blocks: [CalBlock] = []
    var areas: [LifeArea] = []
    var sessions: [Session] = []
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
                tasks = snap.tasks
                blocks = snap.blocks
                areas = snap.areas
                sessions = snap.sessions
            }
        } catch {}
    }
    private func observeConnections() async {
        do { for try await rows in connRepo.observeValues() { connections = rows } } catch {}
    }
    var connected: Bool { !connections.isEmpty }

    /// Blocks grouped by date (ascending), each day's blocks sorted by start.
    var byDate: [(date: String, blocks: [CalBlock])] {
        Dictionary(grouping: blocks, by: { $0.date })
            .map { ($0.key, $0.value.sorted { $0.startTime < $1.startTime }) }
            .sorted { $0.date < $1.date }
    }
    func blocks(on iso: String) -> [CalBlock] {
        // Skipped recurring occurrences are cancelled for that day — drop them
        // (matches Android `blocksRaw.filter { !it.skipped }`).
        blocks.filter { $0.date == iso && !$0.skipped }.sorted { $0.startTime < $1.startTime }
    }
    /// Open tasks with no block anywhere — the day grid's drag tray (matches
    /// Android: scheduled-anywhere tasks drop out of the tray so dragging one
    /// MOVES its block rather than re-adding it).
    func unscheduled() -> [TaskItem] {
        let scheduledIds = Set(blocks.filter { isTaskBlock($0) }.compactMap { $0.taskId })
        // recurrence == nil: never offer a recurring TEMPLATE in the schedule tray
        // — it's a hidden definition that generates occurrences, not a schedulable
        // task. Mirrors the Android DayGrid `it.recurrence == null` filter.
        return tasks.filter { !$0.done && !($0.later ?? false) && $0.recurrence == nil && !scheduledIds.contains($0.id) }
    }

    /// Focused seconds per ISO date, for the Month heatmap.
    var focusByDay: [String: Int] {
        var out: [String: Int] = [:]
        for s in sessions {
            guard let ms = Time.parseMillis(s.completedAt) else { continue }
            let k = Clock.dateISO(millis: ms)
            out[k, default: 0] += s.actualSec
        }
        return out
    }
}

struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: CalendarModel?
    @State private var showSettings = false
    @State private var showPalette = false
    @State private var mode: CalMode = .day
    /// Tap-to-create prefill: the day + snapped time of an empty grid slot. A
    /// local sheet (the AppRouter's Sheet enum can't carry a prefill payload).
    @State private var createAt: CreateAt?

    enum CalMode: String, Hashable, CaseIterable { case day = "Day", week = "Week", month = "Month" }

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
        // No bubble on Calendar (Android gates it off `tab == "calendar"`): it
        // sits bottom-trailing over the drag-to-schedule gesture area.
        .task {
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
                Button { mode = m } label: {
                    Text(m.rawValue)
                        // ink2 (not ink3) for inactive labels: 11pt on bg2 needs ≥4.5:1 AA contrast.
                        .font(UFont.sans(11, .semibold))
                        .foregroundStyle(on ? theme.palette.bg : theme.palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(on ? theme.palette.ink : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }.buttonStyle(.plain)
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
/// alert (drops all synced events — AppModel.disconnectCalendar).
private struct CalendarSyncBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let vm: CalendarModel
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if vm.connections.isEmpty {
                    Button { connect() } label: {
                        Text(busy ? "Connecting…" : "＋ Connect Google Calendar")
                            .font(UFont.sans(12, .medium)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(theme.palette.bg2, in: Capsule())
                    }.buttonStyle(.plain).disabled(busy)
                } else {
                    Text(busy ? "Syncing…" : vm.connections.map { "Synced · \($0.accountEmail)" }.joined(separator: ", "))
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
            if let error {
                Text(error).font(UFont.sans(11)).foregroundStyle(theme.palette.red)
                    .padding(.horizontal, 18).padding(.bottom, 6)
            }
        }
        .alert("Disconnect Google Calendar?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { model.disconnectCalendar() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Synced events are removed from your calendar. Your tasks are unaffected.")
        }
    }

    private func sync() {
        busy = true; error = nil
        Task { await model.pullGoogleCalendar(); busy = false }
    }

    private func connect() {
        guard let calendar = model.calendar else { error = "Sign in first."; return }
        busy = true; error = nil
        Task {
            let controller = GoogleConnectController(calendar)
            let result = await controller.connect()
            busy = false
            switch result {
            case .success: await model.pullGoogleCalendar()
            case .failure(let err): error = "Couldn't connect. \(err.localizedDescription)"
            }
        }
    }
}

// MARK: - Week view (Monday-anchored rollup + 7-column hour grid)

private struct WeekView: View {
    @Environment(\.uTheme) private var theme
    let vm: CalendarModel
    /// Tap an empty slot → create a task prefilled at that day + snapped time.
    let onCreateAt: (String, String) -> Void
    @State private var weekOffset = 0
    /// Tap a task block → reschedule/resize/unschedule (same sheet as the Day grid).
    @State private var editingBlock: CalBlock?

    private let wStart = 0
    private let wEnd = 24
    private let wHour: CGFloat = 44
    private let dows = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let cal = Calendar.current
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

        ScrollView {
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
                    }.buttonStyle(.plain)
                    if weekOffset != 0 {
                        Button { weekOffset = 0 } label: {
                            Text("Today").font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                    Button { weekOffset += 1 } label: {
                        Text("›").font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 12).padding(.vertical, 2)
                    }.buttonStyle(.plain)
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

                // Hour grid: time gutter + 7 day columns with positioned blocks.
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(wStart..<wEnd, id: \.self) { h in
                            Text(String(format: "%02d", h)).font(UFont.mono(8))
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
        // Tap a task block → reschedule / resize / unschedule.
        .sheet(item: $editingBlock) { block in
            CalBlockEditSheet(vm: vm, block: block)
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
                let laid = layoutLanes(vm.blocks(on: iso))
                ForEach(laid, id: \.block.id) { item in
                    let b = item.block
                    let top = minutesOf(b.startTime) - wStart * 60
                    if top >= 0 && top <= (wEnd - wStart) * 60 {
                        let laneW = item.lanes > 1 ? geo.size.width / CGFloat(item.lanes) : geo.size.width
                        weekBlock(b)
                            .frame(width: max(5, laneW - 1),
                                   height: max(13, CGFloat(b.durationMinutes) / 60 * wHour))
                            // Task blocks open the edit sheet; external/placeholder
                            // blocks just swallow the tap so it doesn't fall through
                            // to the create-task gesture underneath.
                            .onTapGesture { if isTaskBlock(b) { editingBlock = b } }
                            .offset(x: laneW * CGFloat(item.lane), y: wHour * CGFloat(top) / 60)
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
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US"); df.dateFormat = "MMM d"
        let cal = Calendar.current
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

// MARK: - Month view (focus-density heatmap)

private struct MonthView: View {
    @Environment(\.uTheme) private var theme
    let vm: CalendarModel
    @State private var ym = Date()

    private let dows = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let cal = Calendar.current
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
        let byDay = vm.focusByDay
        let maxV = max(1, byDay.values.max() ?? 1)
        let todayISO = Clock.todayISO()
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header: month + year, ‹ Today ›
                HStack(alignment: .center) {
                    Text(monthName).font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink)
                    Spacer()
                    Button { ym = cal.date(byAdding: .month, value: -1, to: ym)! } label: {
                        Text("‹").font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 10).padding(.vertical, 2)
                    }.buttonStyle(.plain)
                    Button { ym = Date() } label: {
                        Text("Today").font(UFont.sans(12, .medium)).foregroundStyle(theme.palette.primaryDeep)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                    }.buttonStyle(.plain)
                    Button { ym = cal.date(byAdding: .month, value: 1, to: ym)! } label: {
                        Text("›").font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 10).padding(.vertical, 2)
                    }.buttonStyle(.plain)
                }
                .padding(.top, 8)

                Text("Focus density").font(UFont.mono(10, .medium)).foregroundStyle(theme.palette.ink3)
                    .padding(.top, 2).padding(.bottom, 10)

                // Weekday header
                HStack(spacing: 4) {
                    ForEach(Array(dows.enumerated()), id: \.offset) { _, d in
                        Text(d).font(UFont.mono(10)).foregroundStyle(theme.palette.ink4)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 4)

                // Day grid card
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

                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 96)
        }
    }

    private func monthCell(_ d: Date, byDay: [String: Int], maxV: Int, todayISO: String) -> some View {
        let iso = Clock.dateISO(d)
        let v = byDay[iso] ?? 0
        let t = min(1, max(0, Double(v) / Double(maxV)))
        let isToday = iso == todayISO
        let day = Calendar.current.component(.day, from: d)
        // Heat fill: today = coral, empty = bg2, else lerp bg2→primary.
        let fill: Color = isToday ? theme.palette.coral
            : (v == 0 ? theme.palette.bg2 : lerpColor(theme.palette.bg2, theme.palette.primary, 0.2 + 0.6 * t))
        let textColor: Color = (isToday || t > 0.5) ? theme.palette.bg : theme.palette.ink2
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill)
            Text("\(day)").font(UFont.sans(11, .semibold)).foregroundStyle(textColor)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func monthLabel(_ d: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US"); df.dateFormat = "MMMM yyyy"
        return df.string(from: d)
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
func layoutLanes(_ blocks: [CalBlock]) -> [LaidBlock] {
    func parse(_ s: String) -> Int {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }
    var laid = blocks.map { b -> LaidBlock in
        let s = parse(b.startTime)
        return LaidBlock(block: b, startMin: s, endMin: s + max(1, b.durationMinutes))
    }.sorted { ($0.startMin, $0.endMin) < ($1.startMin, $1.endMin) }

    var i = 0
    while i < laid.count {
        var clusterEnd = laid[i].endMin
        var j = i + 1
        while j < laid.count && laid[j].startMin < clusterEnd {
            clusterEnd = max(clusterEnd, laid[j].endMin); j += 1
        }
        var laneEnd: [Int] = []
        for k in i..<j {
            if let lane = laneEnd.firstIndex(where: { $0 <= laid[k].startMin }) {
                laid[k].lane = lane; laneEnd[lane] = laid[k].endMin
            } else {
                laid[k].lane = laneEnd.count; laneEnd.append(laid[k].endMin)
            }
        }
        for k in i..<j { laid[k].lanes = laneEnd.count }
        i = j
    }
    return laid
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
            }.buttonStyle(.plain)
            Spacer()
            Text(iso == Clock.todayISO() ? "Today" : dayLabel).font(UFont.sans(15, .medium)).foregroundStyle(theme.palette.ink)
            Spacer()
            Button { shift(1) } label: {
                Text("›").font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink2)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }.buttonStyle(.plain)
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
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .padding(.bottom, 84)   // clear the floating bottom nav
    }

    private func grid(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(firstHour..<lastHour, id: \.self) { hour in
                    HStack(alignment: .top, spacing: 0) {
                        Text(formatTime(String(format: "%02d:00", hour))).font(UFont.mono(10)).foregroundStyle(theme.palette.ink4)
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
            // Blocks for the day, positioned by start time, lane-split on overlap.
            // Only TASK blocks are draggable — external/Google + placeholder
            // blocks are display-only (they mirror the remote calendar; moving
            // one would enqueue a non-UUID g_ row Postgres rejects forever, and
            // only changes local state that reverts on the next sync). Mirrors
            // the Android DayGrid gating.
            ForEach(layoutLanes(vm.blocks(on: iso)), id: \.block.id) { item in
                let b = item.block
                let laneW = item.lanes > 1 ? (width - 82) / CGFloat(item.lanes) : (width - 82)
                let card = blockCard(b, width: max(20, laneW - 3))
                    .offset(x: 70 + laneW * CGFloat(item.lane), y: yFor(b))
                if isTaskBlock(b) {
                    // Tap to edit (reschedule/resize/unschedule) + drag to move.
                    card
                        .onTapGesture { editingBlock = b }
                        .draggable("block:\(b.id)")
                } else {
                    // External/placeholder blocks are display-only — swallow the tap
                    // so it doesn't fall through to the grid's create handler.
                    card.onTapGesture { }
                }
            }
            // NOW line on today's grid.
            if iso == Clock.todayISO() {
                let cal = Calendar.current
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
            if h > 34 { Text(formatTime(block.startTime)).font(UFont.mono(9)).foregroundStyle(theme.palette.ink3) }
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

    private func yFor(_ block: CalBlock) -> CGFloat {
        CGFloat(minutesOf(block.startTime) - firstHour * 60) / 60 * pxPerHour
    }

    private func handleDrop(_ items: [String], _ location: CGPoint) -> Bool {
        guard let payload = items.first else { return false }
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
        let h = max(firstHour, Calendar.current.component(.hour, from: Date()) - 1)
        DispatchQueue.main.async {
            withAnimation(.none) { proxy.scrollTo("hour-\(h)", anchor: .top) }
        }
    }

    private func shift(_ days: Int) {
        date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }
    private var dayLabel: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
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
/// grid only opens this for task blocks. The model is @Observable, so the live
/// block follows sequential edits without manual refresh.
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
                                chip(formatTime(t), selected: live.startTime == t) {
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
        }
        .buttonStyle(.plain)
    }
}
