// P6 — Insights. Swift Charts over the tested UnstuckCore.Analytics
// derivations (sessions + tasks from the live store). Shows the
// "worth noticing" insight cards, weekday focus hours, and calibration.

import SwiftUI
import Charts
import UnstuckCore
import UnstuckData
import UnstuckDesign

@MainActor
@Observable
final class AnalyticsModel {
    var sessions: [Session] = []
    var tasks: [TaskItem] = []
    var captures: [Capture] = []
    var reasonLogs: [ReasonLog] = []
    private let sessionRepo: Repository<Session>
    private let captureRepo: Repository<Capture>
    private let reasonRepo: Repository<ReasonLog>
    private let taskRepo: TaskRepository

    init(sessionRepo: Repository<Session>, captureRepo: Repository<Capture>,
         reasonRepo: Repository<ReasonLog>, taskRepo: TaskRepository) {
        self.sessionRepo = sessionRepo
        self.captureRepo = captureRepo
        self.reasonRepo = reasonRepo
        self.taskRepo = taskRepo
    }

    func load() async {
        tasks = (try? taskRepo.all()) ?? []
        captures = (try? captureRepo.all()) ?? []
        reasonLogs = (try? reasonRepo.all()) ?? []
        do { for try await rows in sessionRepo.observeValues() { sessions = rows } } catch {}
    }

    var insights: [Insight] { topInsights(sessions: sessions, tasks: tasks, captures: captures, reasonLogs: reasonLogs) }
    var weekday: [StackedBar] { weekdayAreaHours(sessions, tasks) }
    var hitRate: Double { calibrationHitRate(calibrationDots(sessions, tasks)) }
    var enoughData: Bool { sessions.count >= REAL_DATA_THRESHOLD }
    var interruptions: [Int] { interruptionBins(captures, sessions) }
    var reEntry: [Int] { reEntryDistribution(sessions) }
    var heatmap: Heatmap { timeOfDayHeatmap(sessions) }
    var slips: [SlipRow] { slipping(tasks) }
    var pauses: [PauseBar] { pauseAnatomy(reasonLogs) }
}

struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: AnalyticsModel?
    @State private var deep = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let vm {
                    Picker("Mode", selection: $deep) {
                        Text("Report").tag(false)
                        Text("Deep dive").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if !vm.enoughData {
                        EmptyHint(text: "A few focus sessions in and your patterns show up here — strongest day, estimate calibration, what keeps slipping.")
                    }
                    if !vm.insights.isEmpty { insightCards(vm) }
                    weekdayChart(vm)
                    calibration(vm)
                    if deep {
                        histogram("When interruptions happen", vm.interruptions, theme.palette.coral, unit: "min")
                        histogram("How fast you come back", vm.reEntry, theme.palette.primary, unit: "min")
                        timeOfDayHeatmapView(vm)
                        if !vm.pauses.isEmpty { pauseAnatomyView(vm) }
                        if !vm.slips.isEmpty { slipDetector(vm) }
                    }
                } else {
                    ProgressView()
                }
            }
            .padding(20)
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .navigationTitle("Insights")
        .task {
            guard vm == nil, let db = model.db, let taskRepo = model.taskRepo else { return }
            let m = AnalyticsModel(
                sessionRepo: Repository<Session>(db, orderColumn: "completedAt"),
                captureRepo: Repository<Capture>(db, orderColumn: "at"),
                reasonRepo: Repository<ReasonLog>(db, orderColumn: "at"),
                taskRepo: taskRepo)
            vm = m; await m.load()
        }
    }

    // Bar histogram over time bins (interruptions / re-entry). Each bin is
    // `binMin` minutes wide (Core uses 3 / 5 respectively).
    @ViewBuilder
    private func histogram(_ title: String, _ bins: [Int], _ color: Color, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            Card {
                Chart(Array(bins.enumerated()), id: \.offset) { i, count in
                    BarMark(x: .value("Bin", "\(i)"), y: .value("Count", count))
                        .foregroundStyle(color)
                }
                .chartXAxis(.hidden)
                .frame(height: 130)
            }
        }
    }

    // Day-of-week × time-of-day grid (darker = more focus). 7 rows × 4 buckets.
    @ViewBuilder
    private func timeOfDayHeatmapView(_ vm: AnalyticsModel) -> some View {
        let grid = vm.heatmap          // 5 weekday rows (Mon–Fri) × 6 time buckets (7a–7p)
        let maxV = max(grid.flatMap { $0 }.max() ?? 1, 0.001)
        let dows = ["M", "T", "W", "T", "F"]
        let cols = ["7a", "9a", "11", "1p", "3p", "5p"]
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("When focus happens")
            Card {
                VStack(spacing: 4) {
                    ForEach(Array(grid.enumerated()), id: \.offset) { r, row in
                        HStack(spacing: 4) {
                            Text(r < dows.count ? dows[r] : "")
                                .font(UFont.mono(9)).foregroundStyle(theme.palette.ink4).frame(width: 14)
                            ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(theme.palette.primary.opacity(0.12 + 0.78 * (v / maxV)))
                                    .frame(height: 18)
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        Spacer().frame(width: 14)
                        ForEach(cols, id: \.self) { c in
                            Text(c).font(UFont.mono(8)).foregroundStyle(theme.palette.ink4).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pauseAnatomyView(_ vm: AnalyticsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("What pauses you")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(vm.pauses.enumerated()), id: \.offset) { _, p in
                        HStack {
                            Text(p.reason).font(UFont.sans(14)).foregroundStyle(theme.palette.ink)
                            Spacer()
                            Text("\(p.count)× · \(Int(p.minutes.rounded()))m")
                                .font(UFont.mono(12)).foregroundStyle(theme.palette.ink3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func slipDetector(_ vm: AnalyticsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("The slip detector")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(vm.slips.enumerated()), id: \.offset) { _, s in
                        HStack {
                            Text(s.name).font(UFont.sans(14)).foregroundStyle(theme.palette.ink).lineLimit(1)
                            Spacer()
                            Text("\(s.weeks)w · moved \(s.moveCount)×")
                                .font(UFont.mono(11)).foregroundStyle(theme.palette.amber)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func insightCards(_ vm: AnalyticsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Worth noticing")
            ForEach(Array(vm.insights.enumerated()), id: \.offset) { _, insight in
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(insight.title).font(UFont.sans(15, .medium)).foregroundStyle(theme.palette.ink)
                        Text(insight.sub).font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func weekdayChart(_ vm: AnalyticsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Focus by weekday")
            Card {
                Chart(vm.weekday, id: \.d) { bar in
                    BarMark(x: .value("Day", bar.d), y: .value("Hours", bar.data.reduce(0, +)))
                        .foregroundStyle(theme.palette.primary)
                }
                .frame(height: 160)
            }
        }
    }

    @ViewBuilder
    private func calibration(_ vm: AnalyticsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Estimate calibration")
            Card {
                HStack {
                    Text("Within 5 min").font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)
                    Spacer()
                    Text("\(Int((vm.hitRate * 100).rounded()))%").font(UFont.mono(18, .medium)).foregroundStyle(theme.palette.ink)
                }
            }
        }
    }
}
