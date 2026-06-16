// Insights — 1:1 with the Android InsightsScreen: a "REFLECTION · <range>"
// eyebrow + a serif headline, a Report/Deep-dive segment + a Week/Month/All
// segment, then (Report) stat cards + weekday stacked bars + an interruption
// histogram + "worth noticing" cards, or (Deep dive) a 2×2 stat grid + pause
// anatomy + a re-entry histogram + a captures-by-kind breakdown + the slip
// detector + an hour×day heatmap. Numbers stay gentle below the 5-session
// threshold. Live store via GRDB; derivations from the tested UnstuckCore.

import SwiftUI
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
    var lifeAreas: [LifeArea] = []
    private let sessionRepo: Repository<Session>
    private let captureRepo: Repository<Capture>
    private let reasonRepo: Repository<ReasonLog>
    private let taskRepo: TaskRepository
    private let db: AppDatabase

    init(sessionRepo: Repository<Session>, captureRepo: Repository<Capture>,
         reasonRepo: Repository<ReasonLog>, taskRepo: TaskRepository, db: AppDatabase) {
        self.sessionRepo = sessionRepo
        self.captureRepo = captureRepo
        self.reasonRepo = reasonRepo
        self.taskRepo = taskRepo
        self.db = db
    }

    /// Reflection time window (Android parity). Derivations read the windowed
    /// slices; the slip detector stays task-based (always-on).
    enum Window: Hashable { case week, month, all }
    var window: Window = .week

    func load() async {
        tasks = (try? taskRepo.all()) ?? []
        captures = (try? captureRepo.all()) ?? []
        reasonLogs = (try? reasonRepo.all()) ?? []
        lifeAreas = (try? Repository<LifeArea>(db, orderColumn: "sortOrder").all()) ?? []
        do { for try await rows in sessionRepo.observeValues() { sessions = rows } } catch {}
    }

    /// Cutoff (epoch ms) for the window — Monday 00:00 (week), 1st 00:00 (month),
    /// 0 (all). Mirrors the Android calendar-anchored cutoff.
    private var cutoff: Double {
        let cal = Calendar.current
        switch window {
        case .all: return 0
        case .week:
            let wd = cal.component(.weekday, from: Date())            // 1=Sun … 7=Sat
            let monday = cal.date(byAdding: .day, value: -((wd + 5) % 7), to: cal.startOfDay(for: Date())) ?? Date()
            return monday.timeIntervalSince1970 * 1000
        case .month:
            let first = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
            return first.timeIntervalSince1970 * 1000
        }
    }
    private func inWindow(_ iso: String) -> Bool { (Time.parseMillis(iso) ?? 0) >= cutoff }
    private var wSessions: [Session] { sessions.filter { inWindow($0.completedAt) } }
    private var wCaptures: [Capture] { captures.filter { inWindow($0.at) } }
    private var wReasons: [ReasonLog] { reasonLogs.filter { inWindow($0.at) } }

    /// Exposed windowed counts (header captions + threshold note).
    var sessionCount: Int { wSessions.count }
    var captureCount: Int { wCaptures.count }

    var rangeLabel: String {
        switch window {
        case .week: return "WEEK"
        case .month: return "MONTH"
        case .all: return "ALL TIME"
        }
    }

    /// Drive the stacked bars from the user's OWN areas — DEFAULT_AREAS dropped
    /// every custom/renamed area's hours (Android parity).
    var areaNames: [String] {
        let names = lifeAreas.map { $0.name }
        return names.isEmpty ? DEFAULT_AREAS : names
    }
    /// area name → color token, so the stacked bars + legend use each life
    /// area's real color (mirrors Android's areaColorFor).
    func areaToken(_ name: String) -> String? { lifeAreas.first { $0.name == name }?.color }

    var insights: [Insight] { topInsights(sessions: wSessions, tasks: tasks, captures: wCaptures, reasonLogs: wReasons) }
    var weekday: [StackedBar] { weekdayAreaHours(wSessions, tasks, areas: areaNames) }
    var hitRate: Double { calibrationHitRate(calibrationDots(wSessions, tasks)) }
    var hitPct: Int { Int((hitRate * 100).rounded()) }
    /// Show real numbers + charts from the FIRST session (kept calm) instead of
    /// blanking everything to "—" until 5 (Android parity). The qualitative
    /// "Worth noticing" insights keep their own REAL_DATA_THRESHOLD floor.
    var enoughData: Bool { !wSessions.isEmpty }
    /// Estimate-hit % only means something once there's at least one calibration
    /// dot (an estimated, completed task) — otherwise the card reads "—".
    var dots: [CalibrationDot] { calibrationDots(wSessions, tasks) }
    var hasDots: Bool { !dots.isEmpty }
    var interruptions: [Int] { interruptionBins(wCaptures, wSessions) }
    var reEntry: [Int] { reEntryDistribution(wSessions) }
    var heatmap: Heatmap { timeOfDayHeatmap(wSessions) }
    var slips: [SlipRow] { slipping(tasks) }                  // task-based, not windowed (Android parity)
    var pauses: [PauseBar] { pauseAnatomy(wReasons) }
    var captureKinds: [CaptureTag: Int] { captureBreakdown(wCaptures) }

    /// Median session length in minutes (round once at display — truncating
    /// each session to whole minutes first skewed the median; web parity).
    var medianMin: Int {
        let secs = wSessions.map { $0.actualSec }.sorted()
        return secs.isEmpty ? 0 : Int((Double(secs[secs.count / 2]) / 60).rounded())
    }
    /// Share of re-entries that came back within the first <5m bin.
    var reEntryFastPct: Int {
        let re = reEntry
        let total = re.reduce(0, +)
        return total == 0 ? 0 : Int((Double(re[0]) * 100 / Double(total)).rounded())
    }
}

struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: AnalyticsModel?
    @State private var deep = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let vm {
                    content(vm)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 96)   // clear the floating bottom nav
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard vm == nil, let db = model.db, let taskRepo = model.taskRepo else { return }
            let m = AnalyticsModel(
                sessionRepo: Repository<Session>(db, orderColumn: "completedAt"),
                captureRepo: Repository<Capture>(db, orderColumn: "at"),
                reasonRepo: Repository<ReasonLog>(db, orderColumn: "at"),
                taskRepo: taskRepo, db: db)
            vm = m; await m.load()
        }
    }

    // MARK: header (eyebrow + serif headline + two segments)

    @ViewBuilder
    private func content(_ vm: AnalyticsModel) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Reflection · \(vm.rangeLabel)")
                .foregroundStyle(theme.palette.primaryDeep)
                .padding(.top, 4)
            Text(deep ? "Let's look closer. Calmly." : "Observations, not a score.")
                .font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink)
                .padding(.top, 4)
            MdSegment(options: ["Report", "Deep dive"], selected: deep ? "Deep dive" : "Report") {
                deep = ($0 == "Deep dive")
            }
            .padding(.top, 12)
            MdSegment(options: ["Week", "Month", "All"], selected: windowLabel(vm.window)) {
                vm.window = window(from: $0)
            }
            .padding(.top, 8).padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if !deep { reportBody(vm) } else { deepBody(vm) }
    }

    private func windowLabel(_ w: AnalyticsModel.Window) -> String {
        switch w { case .week: return "Week"; case .month: return "Month"; case .all: return "All" }
    }
    private func window(from label: String) -> AnalyticsModel.Window {
        switch label { case "Month": return .month; case "All": return .all; default: return .week }
    }

    // MARK: Report mode

    @ViewBuilder
    private func reportBody(_ vm: AnalyticsModel) -> some View {
        if !vm.enoughData { ThresholdNote().padding(.top, 8) }

        VStack(spacing: 10) {
            StatCard(label: "Estimates", value: vm.hasDots ? "\(vm.hitPct)%" : "—",
                     badge: "\(vm.sessionCount) sessions", badgeBg: theme.palette.greenSoft, badgeFg: theme.palette.greenInk,
                     caption: "landed within 5 min")
            // The headline is the session COUNT — the real <5m re-entry rate
            // lives in the Deep dive. Label it for what the number actually is.
            StatCard(label: "Focus sessions", value: vm.enoughData ? "\(vm.sessionCount)" : "—",
                     badge: "\(vm.captureCount) captures", badgeBg: theme.palette.blueSoft, badgeFg: theme.palette.blueInk,
                     caption: "completed this window")
            StatCard(label: "Gentle friction", value: "\(vm.slips.count) tasks",
                     badge: vm.slips.isEmpty ? "All clear." : "Watch these",
                     badgeBg: vm.slips.isEmpty ? theme.palette.greenSoft : theme.palette.amberSoft,
                     badgeFg: vm.slips.isEmpty ? theme.palette.greenInk : theme.palette.amberInk,
                     caption: "slipping")
        }
        .padding(.top, 8)

        if vm.enoughData {
            stackedBars("When focus happens", vm).padding(.top, 12)
            if vm.hasDots {
                CalibrationScatter(dots: vm.dots, hitPct: vm.hitPct).padding(.top, 12)
            }
            histogram("When interruptions happen", vm.interruptions, theme.palette.coral).padding(.top, 12)
            if !vm.insights.isEmpty {
                SectionLabel("Worth noticing").padding(.top, 18).padding(.bottom, 6)
                VStack(spacing: 8) {
                    ForEach(Array(vm.insights.prefix(4).enumerated()), id: \.offset) { _, ins in
                        Card {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ins.title).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                                Text(ins.sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: Deep dive mode

    @ViewBuilder
    private func deepBody(_ vm: AnalyticsModel) -> some View {
        if !vm.enoughData { ThresholdNote().padding(.top, 8) }

        VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatCard(label: "Median", value: vm.enoughData ? "\(vm.medianMin)m" : "—",
                         caption: "across \(vm.sessionCount) sessions")
                StatCard(label: "On estimate", value: vm.hasDots ? "\(vm.hitPct)%" : "—",
                         caption: "within 5 min")
            }
            HStack(spacing: 8) {
                StatCard(label: "Re-entry <5m", value: vm.enoughData ? "\(vm.reEntryFastPct)%" : "—",
                         caption: "fast comebacks")
                StatCard(label: "Captures", value: vm.enoughData ? "\(vm.captureCount)" : "—",
                         caption: "kept this window")
            }
        }
        .padding(.top, 8)

        if !vm.pauses.isEmpty {
            SectionLabel("What pauses you").padding(.top, 18).padding(.bottom, 6)
            let maxMin = max(vm.pauses.map { $0.minutes }.max() ?? 0, 0.001)
            Card {
                VStack(spacing: 8) {
                    ForEach(Array(vm.pauses.enumerated()), id: \.offset) { _, p in
                        LabeledBar(label: p.reason, frac: p.minutes / maxMin,
                                   value: "\(Int(p.minutes.rounded()))m · \(p.count)", color: theme.palette.coral)
                    }
                }
            }
        }

        histogram("How fast you come back", vm.reEntry, theme.palette.primary).padding(.top, 12)

        let kinds = vm.captureKinds
        if vm.captureCount > 0 {
            SectionLabel("Captures by kind").padding(.top, 18).padding(.bottom, 6)
            let maxN = max(kinds.values.max() ?? 1, 1)
            Card {
                VStack(spacing: 8) {
                    ForEach(captureTagOrder, id: \.self) { tag in
                        let n = kinds[tag] ?? 0
                        LabeledBar(label: tag.rawValue, frac: Double(n) / Double(maxN),
                                   value: "\(n)", color: theme.palette.primary)
                    }
                }
            }
        }

        if !vm.slips.isEmpty {
            SectionLabel("The slip detector").padding(.top, 18).padding(.bottom, 6)
            VStack(spacing: 6) {
                ForEach(Array(vm.slips.prefix(8).enumerated()), id: \.offset) { _, s in
                    Card {
                        HStack {
                            Text(s.name).font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.ink).lineLimit(1)
                            Spacer()
                            Text("\(s.moveCount)× · \(s.weeks)w").font(UFont.mono(11)).foregroundStyle(theme.palette.ink3)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }

        heatmap(vm).padding(.top, 12)
    }

    // CaptureBreakdown always carries the 5 fixed keys; keep Android's display
    // order (follow-up, idea, edit, question, distraction) with hyphenated names.
    private var captureTagOrder: [CaptureTag] { [.followUp, .idea, .edit, .question, .distraction] }

    // MARK: stacked bars — weekday × area hours

    @ViewBuilder
    private func stackedBars(_ title: String, _ vm: AnalyticsModel) -> some View {
        let bars = vm.weekday
        let areas = vm.areaNames
        let maxV = max(bars.map { $0.data.reduce(0, +) }.max() ?? 0, 0.001)
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    HStack(spacing: 8) {
                        Text(bar.d).font(UFont.mono(10)).foregroundStyle(theme.palette.ink3).frame(width: 30, alignment: .leading)
                        GeometryReader { geo in
                            HStack(spacing: 0) {
                                ForEach(Array(bar.data.enumerated()), id: \.offset) { i, v in
                                    let frac = min(max(v / maxV, 0), 1)
                                    if frac > 0 {
                                        Rectangle()
                                            .fill(theme.palette.areaColor(areas.indices.contains(i) ? vm.areaToken(areas[i]) : nil))
                                            .frame(width: geo.size.width * frac)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.palette.bg2)
                        }
                        .frame(height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                FlowLegend(areas: areas, token: { vm.areaToken($0) }).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: histogram (interruptions / re-entry)

    @ViewBuilder
    private func histogram(_ title: String, _ bins: [Int], _ color: Color) -> some View {
        let maxV = max(bins.max() ?? 0, 1)
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(bins.enumerated()), id: \.offset) { _, v in
                        let frac = min(max(Double(v) / Double(maxV), 0.02), 1)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(v > 0 ? color : theme.palette.bg2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 80 * frac)
                    }
                }
                .frame(height: 80)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: hour × day heatmap

    @ViewBuilder
    private func heatmap(_ vm: AnalyticsModel) -> some View {
        let grid = vm.heatmap          // 5 weekday rows (Mon–Fri) × 6 buckets
        let maxV = max(grid.flatMap { $0 }.max() ?? 0, 0.001)
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hour × day").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                ForEach(Array(grid.enumerated()), id: \.offset) { d, row in
                    HStack(spacing: 5) {
                        Text(d < days.count ? days[d] : "").font(UFont.sans(11)).foregroundStyle(theme.palette.ink3).frame(width: 30, alignment: .leading)
                        ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                            let t = min(max(v / maxV, 0), 1)
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(v <= 0 ? theme.palette.bg2 : theme.palette.green.opacity(0.2 + 0.7 * t))
                                .aspectRatio(1, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: shared local building blocks (mirror the Android InsightsScreen helpers)

/// Material-style segmented control: a bg2 track with a cream (ink) active pill.
private struct MdSegment: View {
    @Environment(\.uTheme) private var theme
    let options: [String]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { opt in
                let active = opt == selected
                Button { onSelect(opt) } label: {
                    Text(opt)
                        .font(UFont.sans(11, .semibold))
                        .foregroundStyle(active ? theme.palette.bg : theme.palette.ink3)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(active ? theme.palette.ink : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Insights stat card: eyebrow + big value + colored badge pill + caption.
private struct StatCard: View {
    @Environment(\.uTheme) private var theme
    let label: String
    let value: String
    var badge: String? = nil
    var badgeBg: Color? = nil
    var badgeFg: Color? = nil
    var caption: String? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(label)
                HStack(spacing: 10) {
                    Text(value).font(UFont.sans(28, .semibold)).foregroundStyle(theme.palette.ink)
                    if let badge {
                        Text(badge)
                            .font(UFont.sans(11, .semibold))
                            .foregroundStyle(badgeFg ?? theme.palette.greenInk)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(badgeBg ?? theme.palette.greenSoft, in: Capsule())
                    }
                }
                if let caption {
                    Text(caption).font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Label + value row over a thin track-with-fill bar (pause anatomy, captures).
private struct LabeledBar: View {
    @Environment(\.uTheme) private var theme
    let label: String
    let frac: Double
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                Spacer()
                Text(value).font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.palette.bg2)
                    Capsule().fill(color).frame(width: geo.size.width * min(max(frac, 0.02), 1))
                }
            }
            .frame(height: 8)
        }
    }
}

/// Threshold note shown below the segments until there are ≥5 sessions.
private struct ThresholdNote: View {
    @Environment(\.uTheme) private var theme
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("No focus sessions yet.")
                    .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                Text("Your reflection fills in here as you focus — come back after a session or two.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Legend of colored squares + area names (stacked-bars footer). A single
/// horizontal row like Android; scrolls when the user has many custom areas.
private struct FlowLegend: View {
    @Environment(\.uTheme) private var theme
    let areas: [String]
    let token: (String) -> String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(areas, id: \.self) { a in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(theme.palette.areaColor(token(a)))
                            .frame(width: 8, height: 8)
                        Text(a).font(UFont.sans(9)).foregroundStyle(theme.palette.ink3)
                    }
                }
            }
        }
    }
}

/// Estimate-vs-actual scatter: square axes off a shared max so the y=x
/// reference reads as a true 45° "perfect estimate" line (web/Android parity).
/// Dots are green within 5 min of estimate, coral when off.
private struct CalibrationScatter: View {
    @Environment(\.uTheme) private var theme
    let dots: [CalibrationDot]
    let hitPct: Int

    var body: some View {
        let maxVal = ([70] + dots.flatMap { [$0.e, $0.a] }).max() ?? 70
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Estimate calibration").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                Text("\(hitPct)% of recent sessions landed within 5 min of estimate.")
                    .font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                Canvas { ctx, size in
                    let pad: CGFloat = 8
                    let w = size.width - 2 * pad
                    let h = size.height - 2 * pad
                    func px(_ v: Int) -> CGFloat { pad + (CGFloat(v) / CGFloat(maxVal)) * w }
                    func py(_ v: Int) -> CGFloat { (size.height - pad) - (CGFloat(v) / CGFloat(maxVal)) * h }
                    // Axes.
                    var axes = Path()
                    axes.move(to: CGPoint(x: pad, y: size.height - pad))
                    axes.addLine(to: CGPoint(x: size.width - pad, y: size.height - pad))
                    axes.move(to: CGPoint(x: pad, y: pad))
                    axes.addLine(to: CGPoint(x: pad, y: size.height - pad))
                    // y = x reference (estimate == actual).
                    axes.move(to: CGPoint(x: px(0), y: py(0)))
                    axes.addLine(to: CGPoint(x: px(maxVal), y: py(maxVal)))
                    ctx.stroke(axes, with: .color(theme.palette.line2), lineWidth: 1)
                    // Dots: green within 5 min of estimate, coral when off.
                    for d in dots {
                        let within = abs(d.e - d.a) <= 5
                        let cx = px(min(d.e, maxVal)), cy = py(min(d.a, maxVal))
                        let r: CGFloat = 4
                        let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
                        ctx.fill(Path(ellipseIn: rect), with: .color(within ? theme.palette.green : theme.palette.coral))
                    }
                }
                .frame(height: 180)
                .padding(.top, 8)
                HStack(spacing: 14) {
                    Text("→ estimate").font(UFont.mono(9)).foregroundStyle(theme.palette.ink3)
                    Text("↑ actual").font(UFont.mono(9)).foregroundStyle(theme.palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
