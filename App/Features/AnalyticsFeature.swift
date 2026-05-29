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
    private let sessionRepo: Repository<Session>
    private let taskRepo: TaskRepository

    init(sessionRepo: Repository<Session>, taskRepo: TaskRepository) {
        self.sessionRepo = sessionRepo
        self.taskRepo = taskRepo
    }

    func load() async {
        tasks = (try? taskRepo.all()) ?? []
        do { for try await rows in sessionRepo.observeValues() { sessions = rows } } catch {}
    }

    var insights: [Insight] { topInsights(sessions: sessions, tasks: tasks, captures: [], reasonLogs: []) }
    var weekday: [StackedBar] { weekdayAreaHours(sessions, tasks) }
    var hitRate: Double { calibrationHitRate(calibrationDots(sessions, tasks)) }
    var enoughData: Bool { sessions.count >= REAL_DATA_THRESHOLD }
}

struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: AnalyticsModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let vm {
                    if !vm.enoughData {
                        EmptyHint(text: "A few focus sessions in and your patterns show up here — strongest day, estimate calibration, what keeps slipping.")
                    }
                    if !vm.insights.isEmpty { insightCards(vm) }
                    weekdayChart(vm)
                    calibration(vm)
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
            let m = AnalyticsModel(sessionRepo: Repository<Session>(db, orderColumn: "completedAt"), taskRepo: taskRepo)
            vm = m; await m.load()
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
