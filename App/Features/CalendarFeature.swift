// P4 — Calendar (read slice). Agenda of cal_blocks grouped by date from
// the live store. Block-time creation, drag-to-schedule, and Google
// two-way sync (via coordinator.calendar + ASWebAuthenticationSession)
// are the next P4 increments.

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

@MainActor
@Observable
final class CalendarModel {
    var tasks: [TaskItem] = []
    var blocks: [CalBlock] = []
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
        do { for try await snap in repo.observeTasksAndBlocks() { tasks = snap.tasks; blocks = snap.blocks } } catch {}
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
        blocks.filter { $0.date == iso }.sorted { $0.startTime < $1.startTime }
    }
    /// Open tasks with no block on `iso` — the day grid's drag tray.
    func unscheduled(on iso: String) -> [TaskItem] {
        tasks.filter { t in
            !t.done && !(t.later ?? false) && !blocks.contains { $0.taskId == t.id && $0.date == iso }
        }
    }
}

struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: CalendarModel?
    @State private var connecting = false
    @State private var connectError: String?
    @State private var showBlock = false
    @State private var mode: CalMode = .day
    @State private var selectedDate = Date()
    @State private var weekOffset = 0

    enum CalMode: Hashable { case day, week, agenda }

    var body: some View {
        NavigationStack {
            Group {
                if let vm { content(vm) } else { ProgressView() }
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showBlock = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .primaryAction) {
                    if vm?.connected == true {
                        Button { Task { await model.pullGoogleCalendar() } } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .sheet(isPresented: $showBlock) { BlockTimeSheet() }
            .feedbackBubble()
        }
        .task {
            guard vm == nil, let db = model.db, let taskRepo = model.taskRepo else { return }
            let m = CalendarModel(taskRepo, Repository<CalendarConnection>(db, orderColumn: "connectedAt"))
            vm = m; await m.observe()
        }
    }

    @ViewBuilder
    private func content(_ vm: CalendarModel) -> some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                Text("Day").tag(CalMode.day)
                Text("Week").tag(CalMode.week)
                Text("Agenda").tag(CalMode.agenda)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.bottom, 8)

            switch mode {
            case .day:
                DayGridView(vm: vm, date: $selectedDate)
            case .week:
                weekView(vm)
            case .agenda:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !vm.connected { connectBanner }
                        if vm.byDate.isEmpty {
                            EmptyHint(text: "No scheduled blocks yet. Schedule a task, or connect Google Calendar above.")
                        } else {
                            agenda(vm)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    // Monday-anchored week overview: ‹ / Today / › navigation, focus-planned
    // rollup (busiest / lightest day), and a per-day load list that drills into
    // the Day grid. 1:1 intent with the Android WeekView.
    @ViewBuilder
    private func weekView(_ vm: CalendarModel) -> some View {
        let cal = Calendar.current
        let weekdaySun1 = cal.component(.weekday, from: Date())          // 1=Sun … 7=Sat
        let thisMonday = cal.date(byAdding: .day, value: -((weekdaySun1 + 5) % 7), to: cal.startOfDay(for: Date()))!
        let monday = cal.date(byAdding: .day, value: weekOffset * 7, to: thisMonday)!
        let days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }
        let labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let planned = days.map { d in vm.blocks(on: Clock.dateISO(d)).filter { isTaskBlock($0) }.reduce(0) { $0 + $1.durationMinutes } }
        let total = planned.reduce(0, +)
        let maxP = planned.max() ?? 0, minP = planned.min() ?? 0
        let flat = maxP == minP
        let busiest = flat ? "—" : labels[planned.firstIndex(of: maxP) ?? 0]
        let lightest = flat ? "—" : labels[planned.firstIndex(of: minP) ?? 0]
        let todayISO = Clock.todayISO()

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(weekOffset == 0 ? "This week" : "Week")
                        Text(weekRangeLabel(days.first!, days.last!))
                            .font(UFont.serifItalic(24)).foregroundStyle(theme.palette.ink)
                    }
                    Spacer()
                    Button { weekOffset -= 1 } label: { Text("‹").font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink2) }.buttonStyle(.plain)
                    if weekOffset != 0 {
                        Button { weekOffset = 0 } label: { Text("Today").font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.primaryDeep) }.buttonStyle(.plain)
                    }
                    Button { weekOffset += 1 } label: { Text("›").font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink2) }.buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    rollup("Focus planned", total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m", theme.palette.primaryDeep)
                    rollup("Busiest", busiest, theme.palette.amber)
                    rollup("Lightest", lightest, theme.palette.greenInk)
                }

                VStack(spacing: 8) {
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        let iso = Clock.dateISO(d)
                        let isToday = iso == todayISO
                        Button {
                            selectedDate = d; mode = .day
                        } label: {
                            HStack(spacing: 12) {
                                VStack(spacing: 1) {
                                    Text(labels[i]).font(UFont.mono(9, .medium)).foregroundStyle(isToday ? theme.palette.coral : theme.palette.ink3)
                                    Text("\(cal.component(.day, from: d))").font(UFont.sans(15, .semibold)).foregroundStyle(isToday ? theme.palette.coral : theme.palette.ink)
                                }
                                .frame(width: 34)
                                let count = vm.blocks(on: iso).count
                                if count == 0 {
                                    Text("Clear").font(UFont.sans(13)).foregroundStyle(theme.palette.ink4)
                                } else {
                                    Text("\(count) block\(count == 1 ? "" : "s") · \(planned[i])m focus")
                                        .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(theme.palette.ink4)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .background(theme.palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isToday ? theme.palette.coral.opacity(0.4) : theme.palette.line))
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
    }

    private func rollup(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(UFont.mono(9, .medium)).foregroundStyle(theme.palette.ink3)
            Text(value).font(UFont.sans(16, .semibold)).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func weekRangeLabel(_ start: Date, _ end: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US"); df.dateFormat = "MMM d"
        let cal = Calendar.current
        if cal.component(.month, from: start) == cal.component(.month, from: end) {
            return "\(df.string(from: start))–\(cal.component(.day, from: end))"
        }
        return "\(df.string(from: start)) – \(df.string(from: end))"
    }

    private var connectBanner: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Google Calendar")
                Text("See your events alongside your plan, and push task blocks back.")
                    .font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)
                if let connectError { Text(connectError).font(UFont.sans(12)).foregroundStyle(theme.palette.red) }
                UButton(connecting ? "Connecting…" : "Connect Google Calendar") { connect() }
                    .disabled(connecting)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func connect() {
        guard let calendar = model.calendar else { connectError = "Sign in first."; return }
        connecting = true; connectError = nil
        Task {
            let controller = GoogleConnectController(calendar)
            let result = await controller.connect()
            connecting = false
            switch result {
            case .success: await model.pullGoogleCalendar()
            case .failure(let error): connectError = "Couldn't connect. \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func agenda(_ vm: CalendarModel) -> some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(vm.byDate, id: \.date) { day in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(day.date)
                    ForEach(day.blocks) { block in blockRow(block) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockRow(_ block: CalBlock) -> some View {
        HStack(spacing: 12) {
            Text(formatTime(block.startTime))
                .font(UFont.mono(12)).foregroundStyle(theme.palette.ink3)
                .frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 2)
                .fill(isExternalBlock(block) ? theme.palette.blue : theme.palette.primary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.taskName).font(UFont.sans(15)).foregroundStyle(theme.palette.ink)
                Text(blockTimeRange(block)).font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
            }
            Spacer()
        }
        .padding(12)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(theme.palette.line))
        .contextMenu {
            Button(role: .destructive) { model.deleteBlock(block) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

// Create a time block (no task). Pushes to Google when connected.
struct BlockTimeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var day = Date()
    @State private var start = Date()
    @State private var duration = 60

    var body: some View {
        NavigationStack {
            Form {
                TextField("Label (e.g. Lunch, Gym)", text: $label)
                DatePicker("Day", selection: $day, displayedComponents: .date)
                DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                Stepper("Duration \(duration)m", value: $duration, in: 15...480, step: 15)
            }
            .navigationTitle("Block time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { save() } }
            }
        }
    }

    private func save() {
        let iso = Clock.dateISO(day)
        let c = Calendar.current.dateComponents([.hour, .minute], from: start)
        let hhmm = String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
        let block = CalBlock(id: newUUID(), taskId: nil,
                             taskName: label.trimmingCharacters(in: .whitespaces).isEmpty ? "Busy" : label,
                             startTime: hhmm, durationMinutes: duration, date: iso, kind: .task)
        model.saveBlock(block)
        dismiss()
    }
}

// Day view with a draggable unscheduled-task tray + a time grid. Dropping
// a task creates a block at the dropped time; dragging a block reschedules
// it. Both push to Google when connected.
struct DayGridView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    let vm: CalendarModel
    @Binding var date: Date

    private let firstHour = 6
    private let lastHour = 22
    private let pxPerHour: CGFloat = 56
    private var gridHeight: CGFloat { CGFloat(lastHour - firstHour) * pxPerHour }
    private var iso: String { Clock.dateISO(date) }

    var body: some View {
        VStack(spacing: 0) {
            dateHeader
            tray
            Divider()
            ScrollView {
                GeometryReader { geo in grid(width: geo.size.width) }
                    .frame(height: gridHeight)
            }
        }
    }

    private var dateHeader: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Spacer()
            Text(dayLabel).font(UFont.sans(15, .medium)).foregroundStyle(theme.palette.ink)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
        }
        .foregroundStyle(theme.palette.ink2)
        .padding(.horizontal, 24).padding(.vertical, 8)
    }

    @ViewBuilder
    private var tray: some View {
        let items = vm.unscheduled(on: iso)
        if items.isEmpty {
            Text("All scheduled — drag a block to move it.")
                .font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { task in
                        Text("\(task.name) · \(task.estimateMin)m")
                            .font(UFont.sans(12)).lineLimit(1)
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            .background(theme.palette.primarySoft)
                            .foregroundStyle(theme.palette.primaryDeep)
                            .clipShape(Capsule())
                            .draggable("task:\(task.id)")
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
    }

    private func grid(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(firstHour..<lastHour, id: \.self) { hour in
                    HStack(alignment: .top, spacing: 8) {
                        Text(hourLabel(hour)).font(UFont.mono(9)).foregroundStyle(theme.palette.ink4)
                            .frame(width: 44, alignment: .trailing)
                        Rectangle().fill(theme.palette.line).frame(height: 1)
                    }
                    .frame(height: pxPerHour, alignment: .top)
                }
            }
            ForEach(vm.blocks(on: iso)) { block in
                blockCard(block, width: max(80, width - 64))
                    .offset(x: 52, y: yFor(block))
                    .draggable("block:\(block.id)")
            }
        }
        .frame(width: width, height: gridHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, location in handleDrop(items, location) }
    }

    private func blockCard(_ block: CalBlock, width: CGFloat) -> some View {
        let h = max(22, CGFloat(block.durationMinutes) / 60 * pxPerHour - 2)
        return VStack(alignment: .leading, spacing: 1) {
            Text(block.taskName).font(UFont.sans(12, .medium)).lineLimit(1).foregroundStyle(theme.palette.ink)
            if h > 30 { Text(formatTime(block.startTime)).font(UFont.mono(9)).foregroundStyle(theme.palette.ink3) }
        }
        .padding(6)
        .frame(width: width, height: h, alignment: .topLeading)
        .background(isExternalBlock(block) ? theme.palette.blue.opacity(0.18) : theme.palette.primarySoft)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button(role: .destructive) { model.deleteBlock(block) } label: { Label("Delete", systemImage: "trash") }
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
        let startTime = String(format: "%02d:%02d", min(23, total / 60), total % 60)
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

    private func shift(_ days: Int) {
        date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }
    private var dayLabel: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }
    private func hourLabel(_ hour: Int) -> String {
        "\(((hour + 11) % 12) + 1) \(hour >= 12 ? "PM" : "AM")"
    }
    private func minutesOf(_ hhmm: String) -> Int {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }
}
