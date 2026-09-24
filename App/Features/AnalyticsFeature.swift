// Insights — "how did this week / month go?", told from real data.
//
// Report = the period's story, the SAME facts the assistant's
// get_period_review reads out (periodFacts, UnstuckCore/PeriodFacts.swift):
// a Week / Month / All selector with a ‹ › stepper to any past week or month,
// then Done · Focused · Showed up (with neutral changes vs the equivalent
// span before), the daily rhythm, what got unstuck, plan vs followed
// through, the repeating-task rhythm, when focus happens, gentle friction
// and worth-noticing cards.
// Deep dive = patterns over time: the 8-week / 6-month trend, the stat strip,
// estimates, done by area, pauses, coming back, interruptions, captures, the
// slip detector and the hour × day heatmap.
//
// Every focus number goes through the D1 filter (accidental < 1 min starts
// dropped, runaway timers clamped). No streaks, no red/green: changes are
// neutral ("+2", "same", "−40m") and a past repeating day not ticked is
// "open", never "missed". Colours: the ink scale + the user's area colours.
// Live store via GRDB; derivations from the tested UnstuckCore.

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckData
import UnstuckDesign

/// Everything the screen draws for one period, computed once per change.
struct InsightsSnapshot {
    let period: InsightsPeriod
    let headline: PeriodHeadline
    let facts: PeriodFacts
    /// One entry per day of the nominal span (Week / Month).
    let days: [DayFacts]
    let today: String
    let wins: [UnstuckWin]
    let plan: PlanFacts?
    let series: [SeriesRhythm]
    /// All time's rhythm (weekly) and Deep dive's trend.
    let weekly: [TrendPoint]
    let trend: [TrendPoint]
    let weekday: [StackedBar]
    /// The bars' series, in slot order: the user's areas, any other area a
    /// task carries (by name), then "No area" (AreaSeries.area == nil).
    let areaSeries: [AreaSeries]
    let dots: [CalibrationDot]
    let interruptions: [Int]
    let comeBack: [Int]
    let heatmap: Heatmap
    let slips: [SlipRow]
    let pauses: [PauseBar]
    let captureKinds: [CaptureTag: Int]
    let insights: [Insight]
    let doneByArea: [AreaCount]
    let medianMin: Int?
    let hasHistory: Bool
    let canStepBack: Bool
    /// Last week's headline, for the empty "this week" note.
    let lastWeek: PeriodHeadline?

    var sessions: [Session] { facts.sessions.map(\.session) }
    var hasFocus: Bool { !facts.sessions.isEmpty }
    /// Nothing at all happened in the period (the honest empty note).
    var isEmpty: Bool {
        headline.done == 0 && headline.sessions == 0 && headline.added == 0
            && facts.captures.isEmpty && facts.pauses.isEmpty && (plan?.recorded != true)
    }
    var hitPct: Int { Int((calibrationHitRate(dots) * 100).rounded()) }
    /// Share of timed pauses that ended within 5 min; nil before any pause
    /// was timed (the screen says "—", not a fake 0%).
    var backWithin5Pct: Int? {
        let total = comeBack.reduce(0, +)
        return total == 0 ? nil : Int((Double(comeBack[0]) * 100 / Double(total)).rounded())
    }
    var showInterruptions: Bool { interruptions.reduce(0, +) >= INTERRUPTIONS_MIN_LINKED }
}

@MainActor
@Observable
final class AnalyticsModel {
    var sessions: [Session] = []
    var tasks: [TaskItem] = []
    var blocks: [CalBlock] = []
    var captures: [Capture] = []
    var reasonLogs: [ReasonLog] = []
    var lifeAreas: [LifeArea] = []
    private let captureRepo: Repository<Capture>
    private let reasonRepo: Repository<ReasonLog>
    private let taskRepo: TaskRepository

    /// Week / Month / All, and how many weeks/months back the stepper is.
    private(set) var kind: InsightsPeriodKind = .week
    private(set) var offset = 0
    private(set) var snapshot: InsightsSnapshot?

    init(captureRepo: Repository<Capture>, reasonRepo: Repository<ReasonLog>,
         taskRepo: TaskRepository, weekOffset: Int = 0) {
        self.captureRepo = captureRepo
        self.reasonRepo = reasonRepo
        self.taskRepo = taskRepo
        self.offset = max(0, weekOffset)
    }

    func select(_ k: InsightsPeriodKind) {
        guard k != kind else { return }
        kind = k
        offset = 0
        recompute()
    }

    /// ‹ = +1 (further back), › = −1 (towards now).
    func step(_ by: Int) {
        let next = max(0, offset + by)
        guard next != offset else { return }
        offset = next
        recompute()
    }

    /// Observe every input live (Android parity): tasks + blocks + life areas
    /// + sessions in one tracked snapshot, captures and reason logs on their
    /// own trackers; each change recomputes the period's facts.
    func load() async {
        async let tb: Void = observeTasksAndBlocks()
        async let cap: Void = observeCaptures()
        async let rea: Void = observeReasons()
        _ = await (tb, cap, rea)
    }

    private func observeTasksAndBlocks() async {
        do {
            for try await snap in taskRepo.observeTasksAndBlocks() {
                tasks = snap.tasks
                blocks = snap.blocks
                lifeAreas = snap.areas
                sessions = snap.sessions
                loaded = true
                recompute()
            }
        } catch {}
    }

    private func observeCaptures() async {
        do { for try await rows in captureRepo.observeValues() { captures = rows; recompute() } } catch {}
    }

    private func observeReasons() async {
        do { for try await rows in reasonRepo.observeValues() { reasonLogs = rows; recompute() } } catch {}
    }

    /// Drive the stacked bars from the user's OWN areas (DEFAULT_AREAS dropped
    /// every custom/renamed area's hours — Android parity); the core adds any
    /// other area a task carries, by name, then "No area" (web's rule).
    var areaNames: [String] {
        let names = lifeAreas.map { $0.name }
        return names.isEmpty ? DEFAULT_AREAS : names
    }
    /// area name → color token, so the bars + legend use each life area's real color.
    func areaToken(_ name: String) -> String? { lifeAreas.first { $0.name == name }?.color }

    /// The first tasks/blocks snapshot has landed — before it, an empty
    /// snapshot would flash "Nothing logged yet" at someone with history.
    private var loaded = false

    func recompute(now: Date = Date()) {
        guard loaded else { return }
        let data = PeriodData(tasks: tasks, blocks: blocks, sessions: sessions, captures: captures, reasons: reasonLogs)
        let earliest = data.earliestDay
        let p = resolveInsightsPeriod(kind, offset: offset, now: now, earliest: earliest)
        let f = periodFacts(data, p.window)
        let today = PeriodTime.at(Int64((now.timeIntervalSince1970 * 1000).rounded(.down))).day
        let wSessions = f.sessions.map(\.session)
        // The same sessions as stored: the interruptions chart places a
        // runaway timer at its REAL start (the clamped copy put it hours late).
        let rawById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let wRaw = wSessions.map { rawById[$0.id] ?? $0 }
        let bars = weekdayAreaBars(wSessions, tasks, areas: areaNames)
        let nowMs = now.timeIntervalSince1970 * 1000
        // Calendar weeks from the first activity's week through this one.
        let weeksSinceFirst = earliest.map {
            max(1, civilDaysBetween(LocalDate.mondayOf($0), LocalDate.mondayOf(today)) / 7 + 1)
        } ?? 1
        let secs = wSessions.map(\.actualSec).sorted()
        let lastWeek: PeriodHeadline? = (kind == .week && offset == 0)
            ? periodHeadline(data, resolveInsightsPeriod(.week, offset: 1, now: now, earliest: earliest)) : nil
        snapshot = InsightsSnapshot(
            period: p,
            headline: periodHeadline(data, p),
            facts: f,
            days: kind == .all ? [] : dailyFacts(f, from: p.from, to: p.to),
            today: today,
            wins: gotUnstuck(f),
            plan: kind == .all ? nil : planFacts(data, from: p.from, end: p.end, clipped: p.clipped, nowMs: Int64(nowMs)),
            series: kind == .all ? [] : seriesRhythm(data, from: p.from, to: p.to, today: today),
            weekly: kind == .all ? periodTrend(data, kind: .week, selectedFrom: nil, now: now, count: min(26, weeksSinceFirst)) : [],
            trend: periodTrend(data, kind: kind == .month ? .month : .week,
                               selectedFrom: kind == .all ? nil : p.from, now: now,
                               count: kind == .month ? min(26, max(6, offset + 1))
                                   : kind == .all ? min(26, weeksSinceFirst) : min(26, max(8, offset + 1))),
            weekday: bars.days,
            areaSeries: bars.series,
            dots: calibrationDots(wSessions, tasks),
            interruptions: interruptionBins(f.captures, wRaw),
            comeBack: pauseLengthBins(f.pauses),
            heatmap: focusHourGrid(wSessions),
            slips: slipping(tasks, now: nowMs),
            pauses: pauseAnatomy(f.pauses),
            captureKinds: captureBreakdown(f.captures),
            insights: topInsights(sessions: wSessions, tasks: tasks, captures: f.captures, reasonLogs: f.pauses, now: nowMs),
            doneByArea: doneByArea(f),
            // Upper median, rounded once at display (web parity).
            medianMin: secs.isEmpty ? nil : Int((Double(secs[secs.count / 2]) / 60).rounded()),
            hasHistory: earliest != nil,
            canStepBack: canStepBack(p, earliest: earliest),
            lastWeek: lastWeek)
    }
}

struct AnalyticsView: View {
    /// Weeks back to open on (the Today pill opens LAST week early in a quiet week).
    var initialWeekOffset: Int = 0
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: AnalyticsModel?
    /// Lists opened past their cut with "+N more" (keys: wins, open, series, slips).
    @State private var expanded: Set<String> = []
    // Report/Deep-dive is persisted (not local @State) so it survives leaving
    // and re-entering Insights — Android route-persists this flag.
    @AppStorage("insights.deepDive") private var deep = false
    #if DEBUG
    private static let debugScroll = CGFloat(Double(ProcessInfo.processInfo.environment["UITEST_INSIGHTS_SCROLL"] ?? "") ?? 0)
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let vm, let snap = vm.snapshot {
                    content(vm, snap)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 96)   // clear the floating bottom nav
            #if DEBUG
            .offset(y: -Self.debugScroll)   // UITEST_INSIGHTS_SCROLL: screenshot further down
            #endif
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard vm == nil, let db = model.db, let taskRepo = model.taskRepo else { return }
            let m = AnalyticsModel(
                captureRepo: Repository<Capture>(db, orderColumn: "at"),
                reasonRepo: Repository<ReasonLog>(db, orderColumn: "at"),
                taskRepo: taskRepo, weekOffset: initialWeekOffset)
            #if DEBUG
            // Screenshot hooks (UITEST_* like the rest): open on a kind / offset.
            let env = ProcessInfo.processInfo.environment
            if let k = env["UITEST_INSIGHTS_KIND"].flatMap(InsightsPeriodKind.init(rawValue:)) { m.select(k) }
            if let o = Int(env["UITEST_INSIGHTS_OFFSET"] ?? "") { m.step(o) }
            #endif
            vm = m; await m.load()
        }
    }

    // MARK: header (eyebrow + serif headline + segments + the period stepper)

    @ViewBuilder
    private func content(_ vm: AnalyticsModel, _ snap: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Reflection · \(snap.period.title)")
                .foregroundStyle(theme.palette.primaryDeep)
                .padding(.top, 4)
            Text(deep ? "Let's look closer. Calmly." : "Observations, not a score.")
                .font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink)
                .padding(.top, 4)
            MdSegment(options: ["Report", "Deep dive"], selected: deep ? "Deep dive" : "Report") {
                deep = ($0 == "Deep dive")
            }
            .padding(.top, 12)
            MdSegment(options: ["Week", "Month", "All"], selected: kindLabel(vm.kind)) {
                vm.select(kind(from: $0))
            }
            .padding(.top, 8)
            stepper(vm, snap).padding(.top, 10).padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if !deep { reportBody(vm, snap) } else { deepBody(vm, snap) }
    }

    private func kindLabel(_ k: InsightsPeriodKind) -> String {
        switch k { case .week: return "Week"; case .month: return "Month"; case .all: return "All" }
    }
    private func kind(from label: String) -> InsightsPeriodKind {
        switch label { case "Month": return .month; case "All": return .all; default: return .week }
    }

    /// ‹  This week · 21–24 Sep, so far  ›  + "vs same point last week".
    @ViewBuilder
    private func stepper(_ vm: AnalyticsModel, _ snap: InsightsSnapshot) -> some View {
        let p = snap.period
        HStack(spacing: 6) {
            if p.kind != .all {
                stepButton("chevron.left", enabled: snap.canStepBack, label: "Earlier \(p.kind == .week ? "week" : "month")") { vm.step(1) }
            }
            VStack(alignment: p.kind == .all ? .leading : .center, spacing: 1) {
                Text(p.title).font(UFont.sans(15, .semibold)).foregroundStyle(theme.palette.ink)
                Text(p.subtitle).font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                if let cmp = p.compareLabel {
                    Text(cmp).font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: p.kind == .all ? .leading : .center)
            .accessibilityElement(children: .combine)
            if p.kind != .all {
                stepButton("chevron.right", enabled: p.canStepForward, label: "Later \(p.kind == .week ? "week" : "month")") { vm.step(-1) }
            }
        }
    }

    private func stepButton(_ icon: String, enabled: Bool, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? theme.palette.ink : theme.palette.ink4)
                .frame(width: 44, height: 44)
                .background(theme.palette.bg2, in: Circle().inset(by: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// Resolve a stacked-bar / legend area NAME to its color — matches Android's
    /// `areaColorFor`: a matched area uses its token color; an UNMATCHED name
    /// (and "No area") falls back to ink4.
    private func areaColor(forName name: String?, _ vm: AnalyticsModel) -> Color {
        guard let token = name.flatMap({ vm.areaToken($0) }) else { return theme.palette.ink4 }
        return theme.palette.areaColor(token)
    }

    /// Component-wise color interpolation (mirrors Compose `lerp`), so the
    /// heatmap blends bg2 → green instead of layering translucent green.
    private func lerpColor(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = UIColor(a); let cb = UIColor(b)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        ca.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        cb.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let f = CGFloat(min(max(t, 0), 1))
        return Color(red: Double(ar + (br - ar) * f), green: Double(ag + (bg - ag) * f), blue: Double(ab + (bb - ab) * f))
    }

    // MARK: Report mode — the period's story

    @ViewBuilder
    private func reportBody(_ vm: AnalyticsModel, _ snap: InsightsSnapshot) -> some View {
        if snap.isEmpty { emptyNote(vm, snap).padding(.top, 8) }

        headlineRow(snap).padding(.top, 8)

        if snap.period.kind == .all {
            if snap.weekly.contains(where: { $0.done > 0 || $0.focusMin > 0 }) {
                trendCard("Weekly rhythm", "Done and focus, week by week.", snap.weekly).padding(.top, 12)
            }
        } else if !snap.isEmpty {
            rhythmCard(snap).padding(.top, 12)
        }

        if !snap.wins.isEmpty { winsCard(snap.wins).padding(.top, 12) }
        if let plan = snap.plan, plan.planned > 0 || plan.skipped > 0 { planCard(plan, snap).padding(.top, 12) }
        if !snap.series.isEmpty { seriesCard(snap).padding(.top, 12) }

        if snap.hasFocus {
            stackedBars("When focus happens", vm, snap).padding(.top, 12)
        }

        StatCard(label: "Gentle friction", value: "\(snap.slips.count) \(snap.slips.count == 1 ? "task" : "tasks")",
                 badge: snap.slips.isEmpty ? "All clear." : "Worth a look",
                 badgeBg: theme.palette.bg2, badgeFg: theme.palette.ink2,
                 caption: snap.slips.isEmpty ? "Nothing has been waiting too long."
                     : "waiting 3+ weeks or moved 3+ times — the list is in Deep dive")
            .padding(.top, 12)

        let noticing = worthNoticing(snap)
        if !noticing.isEmpty {
            SectionLabel("Worth noticing").padding(.top, 18).padding(.bottom, 6)
            VStack(spacing: 8) {
                ForEach(Array(noticing.enumerated()), id: \.offset) { _, ins in
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

    /// The engine's cards (strongest day, estimates, a slipping task) plus a
    /// quiet-win card — positive or actionable only, at most four.
    private func worthNoticing(_ snap: InsightsSnapshot) -> [Insight] {
        var out: [Insight] = []
        if let top = snap.wins.first {
            let n = snap.wins.count
            out.append(Insight(
                title: n == 1 ? "You got \"\(top.name)\" unstuck." : "You got \(n) things unstuck.",
                sub: "\"\(top.name)\" had waited \(top.waitedDays) \(top.waitedDays == 1 ? "day" : "days")\(top.moves >= 2 ? " and moved \(top.moves)×" : ""). That's the hard kind of done."))
        }
        return Array((out + snap.insights).prefix(4))
    }

    /// Nothing in the period: say so honestly — never "no focus sessions yet"
    /// to someone with history (cross-check P0-8) — and offer last week.
    @ViewBuilder
    private func emptyNote(_ vm: AnalyticsModel, _ snap: InsightsSnapshot) -> some View {
        let p = snap.period
        Card {
            VStack(alignment: .leading, spacing: 6) {
                if !snap.hasHistory {
                    Text("Nothing logged yet.").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                    Text("Your reflection fills in as you tick things off and focus — come back after a day or two.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                } else {
                    Text(p.kind == .week && p.offset == 0 ? "Nothing logged this week yet."
                         : p.kind == .month && p.offset == 0 ? "Nothing logged this month yet."
                         : "Nothing logged in this \(p.kind == .month ? "month" : p.kind == .week ? "week" : "span").")
                        .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                    if let lw = snap.lastWeek, lw.done > 0 || lw.focusMin > 0 {
                        Button { vm.step(1) } label: {
                            Text("Last week: \(lw.done) done · \(fmtFocusDur(lw.focusMin)) focused  →")
                                .font(UFont.sans(12, .medium)).foregroundStyle(theme.palette.ink)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("A quiet stretch is part of the pattern, not a verdict.")
                            .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: headline — Done · Focused · Showed up

    @ViewBuilder
    private func headlineRow(_ snap: InsightsSnapshot) -> some View {
        let h = snap.headline
        let doneSub = [[h.plainDone > 0 ? "\(h.plainDone) \(h.plainDone == 1 ? "task" : "tasks")" : nil,
                        h.repeatingDone > 0 ? "\(h.repeatingDone) repeating" : nil].compactMap { $0 }.joined(separator: " · "),
                       h.added > 0 ? "added \(h.added)" : ""].filter { !$0.isEmpty }.joined(separator: "\n")
        HStack(alignment: .top, spacing: 8) {
            HeadlineCard(label: "Done", value: "\(h.done)",
                         sub: doneSub.isEmpty ? (snap.period.clipped ? "nothing ticked yet" : "nothing ticked") : doneSub,
                         delta: h.prevDone.map { neutralDelta(h.done - $0) })
            HeadlineCard(label: "Focused", value: fmtFocusDur(h.focusMin),
                         sub: "\(h.sessions) \(h.sessions == 1 ? "session" : "sessions")",
                         delta: h.prevFocusMin.map { neutralDurDelta(h.focusMin - $0) })
            HeadlineCard(label: "Showed up", value: "\(h.showedUp)",
                         sub: "of \(h.days) \(h.days == 1 ? "day" : "days")",
                         delta: h.prevShowedUp.map { neutralDelta(h.showedUp - $0) })
        }
        .fixedSize(horizontal: false, vertical: true)   // three cards, one height
        .accessibilityElement(children: .combine)
    }

    // MARK: daily rhythm — focus bar + done count per day

    @ViewBuilder
    private func rhythmCard(_ snap: InsightsSnapshot) -> some View {
        let days = snap.days
        let maxSec = max(days.map(\.focusSec).max() ?? 0, 1)
        let week = snap.period.kind == .week
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Daily rhythm").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                Text("Bars are focus time; the number is what got done that day.")
                    .font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                HStack(alignment: .bottom, spacing: week ? 8 : 2) {
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        let future = d.date > snap.today
                        VStack(spacing: 3) {
                            Text(d.done > 0 ? "\(d.done)" : " ")
                                .font(UFont.mono(week ? 10 : 8)).foregroundStyle(theme.palette.ink2)
                                .lineLimit(1).minimumScaleFactor(0.5)
                            RoundedRectangle(cornerRadius: week ? 4 : 2, style: .continuous)
                                .fill(d.focusSec > 0 ? theme.palette.ink : future ? theme.palette.bg2.opacity(0.5) : theme.palette.bg2)
                                .frame(height: max(4, 70 * Double(d.focusSec) / Double(maxSec)))
                            Text(rhythmLabel(d.date, index: i, week: week))
                                .font(UFont.mono(9)).foregroundStyle(future ? theme.palette.ink4 : theme.palette.ink3)
                                .lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 104, alignment: .bottom)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rhythmSummary(days))
    }

    private static let weekLetters = ["M", "T", "W", "T", "F", "S", "S"]
    private func rhythmLabel(_ date: String, index: Int, week: Bool) -> String {
        if week { return Self.weekLetters[index % 7] }
        let day = Int(date.suffix(2)) ?? 0
        return (day - 1) % 7 == 0 ? "\(day)" : " "
    }

    private func rhythmSummary(_ days: [DayFacts]) -> String {
        let active = days.filter(\.active)
        guard !active.isEmpty else { return "Daily rhythm. Nothing logged yet." }
        let parts = active.map { "\($0.date.suffix(5)): \($0.done) done, \(fmtFocusDur(roundedMinutes($0.focusSec))) focus" }
        return "Daily rhythm. " + parts.joined(separator: "; ")
    }

    // MARK: "+N more" — every clipped list opens in place

    private func cut(_ key: String, _ max: Int) -> Int { expanded.contains(key) ? Int.max : max }

    /// "+N more ›" under a clipped list; tapping shows the rest, "Show less" folds it back.
    @ViewBuilder
    private func moreToggle(_ key: String, total: Int, max: Int) -> some View {
        if total > max {
            let open = expanded.contains(key)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if open { expanded.remove(key) } else { expanded.insert(key) }
                }
            } label: {
                Text(open ? "Show less" : "+\(total - max) more ›")
                    .font(UFont.sans(11, .semibold)).foregroundStyle(theme.palette.ink2)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Show less" : "Show \(total - max) more")
        }
    }

    // MARK: got unstuck (quiet wins) — hidden when empty

    private func winsCard(_ wins: [UnstuckWin]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Things you got unstuck").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                Text("Finished after waiting a week or more, or after moving it around.")
                    .font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                ForEach(Array(wins.prefix(cut("wins", 3)).enumerated()), id: \.offset) { _, w in
                    HStack(spacing: 8) {
                        Text(w.name).font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(winChip(w)).font(UFont.mono(10)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(theme.palette.bg2, in: Capsule())
                    }
                }
                moreToggle("wins", total: wins.count, max: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func winChip(_ w: UnstuckWin) -> String {
        var parts: [String] = []
        if w.waitedDays >= WIN_WAITED_DAYS { parts.append("waited \(w.waitedDays)d") }
        if w.moves >= WIN_MOVES { parts.append("moved \(w.moves)×") }
        return parts.joined(separator: " · ")
    }

    // MARK: plan vs followed through — counts, never a grade

    @ViewBuilder
    private func planCard(_ plan: PlanFacts, _ snap: InsightsSnapshot) -> some View {
        let onTime = plan.doneToPlan
        let later = plan.doneLater
        let open = plan.stillOpen
        let skipped = plan.skipped
        let total = max(onTime + later + open + skipped, 1)
        let openTasks = plan.slipped.filter { !$0.doneLater }
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan vs followed through").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                Text(plan.planned > 0 ? "Followed through on \(onTime) of \(plan.planned) planned\(snap.period.clipped ? " (today isn't counted yet)" : "")."
                     : "Nothing was planned on a finished day yet.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        planSegment(onTime, total, geo.size.width, fill: theme.palette.ink)
                        planSegment(later, total, geo.size.width, fill: theme.palette.ink3)
                        planSegment(open, total, geo.size.width, fill: theme.palette.ink4)
                        if skipped > 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(theme.palette.line2, lineWidth: 1.5)
                                .frame(width: max(6, geo.size.width * Double(skipped) / Double(total) - 2))
                        }
                    }
                }
                .frame(height: 12)
                HStack(spacing: 12) {
                    planLegend("done", onTime, theme.palette.ink)
                    if later > 0 { planLegend("done later", later, theme.palette.ink3) }
                    if open > 0 { planLegend("still open", open, theme.palette.ink4) }
                    if skipped > 0 { planLegend("skipped on purpose", skipped, nil) }
                }
                if !openTasks.isEmpty {
                    Text("Still open from earlier").font(UFont.sans(11, .semibold)).foregroundStyle(theme.palette.ink3)
                        .padding(.top, 2)
                    ForEach(Array(openTasks.prefix(cut("open", 3)).enumerated()), id: \.offset) { _, s in
                        HStack {
                            Text(s.task.name).font(UFont.sans(13)).foregroundStyle(theme.palette.ink).lineLimit(1)
                            Spacer(minLength: 6)
                            Text("planned \(plannedLabel(s.planDate))")
                                .font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
                        }
                    }
                    moreToggle("open", total: openTasks.count, max: 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// "yesterday" / "Tue 15 Sep" for a plan date.
    private func plannedLabel(_ date: String) -> String {
        let l = sessionDayLabel(date + "T12:00:00", now: Date()) ?? date
        return l == "Yesterday" || l == "Today" ? l.lowercased() : l
    }

    @ViewBuilder
    private func planSegment(_ n: Int, _ total: Int, _ width: CGFloat, fill: Color) -> some View {
        if n > 0 {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(fill)
                .frame(width: max(6, width * Double(n) / Double(total) - 2))
        }
    }

    private func planLegend(_ label: String, _ n: Int, _ color: Color?) -> some View {
        HStack(spacing: 4) {
            if let color {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous).stroke(theme.palette.line2, lineWidth: 1.5).frame(width: 8, height: 8)
            }
            Text("\(n) \(label)").font(UFont.sans(10)).foregroundStyle(theme.palette.ink3)
        }
    }

    // MARK: repeating rhythm — one dot per day, no streaks

    @ViewBuilder
    private func seriesCard(_ snap: InsightsSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Repeating tasks").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                ForEach(Array(snap.series.prefix(cut("series", 5)).enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(s.name).font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.ink).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(seriesCaption(s, soFar: snap.period.clipped)).font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                        }
                        dotRow(s.dots)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(s.name): \(seriesCaption(s, soFar: snap.period.clipped))")
                }
                moreToggle("series", total: snap.series.count, max: 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "kept 5 of 6" for a finished week or month; "… so far" while it runs;
    /// "1 skipped" when every day was skipped on purpose; "coming up" only
    /// when nothing is due yet.
    private func seriesCaption(_ s: SeriesRhythm, soFar: Bool) -> String {
        var parts: [String] = []
        if s.dueSoFar > 0 { parts.append("kept \(s.kept) of \(s.dueSoFar)\(soFar ? " so far" : "")") }
        if s.skipped > 0 { parts.append("\(s.skipped) skipped") }
        return parts.isEmpty ? "coming up" : parts.joined(separator: " · ")
    }

    /// Filled = done, dash = skipped on purpose, hollow = open, faint = today or later.
    private func dotRow(_ dots: [SeriesDot]) -> some View {
        let size: CGFloat = dots.count > 14 ? 7 : 11
        return HStack(spacing: dots.count > 14 ? 3 : 5) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, d in
                switch d.state {
                case .done:
                    Circle().fill(theme.palette.ink).frame(width: size, height: size)
                case .skipped:
                    Capsule().fill(theme.palette.ink3).frame(width: size, height: 2).frame(height: size)
                case .open:
                    Circle().stroke(theme.palette.ink3, lineWidth: 1.5).frame(width: size - 1, height: size - 1)
                case .upcoming:
                    Circle().stroke(theme.palette.line2, lineWidth: 1.5).frame(width: size - 1, height: size - 1)
                }
            }
        }
    }

    // MARK: Deep dive mode — patterns over time

    @ViewBuilder
    private func deepBody(_ vm: AnalyticsModel, _ snap: InsightsSnapshot) -> some View {
        if snap.trend.contains(where: { $0.done > 0 || $0.focusMin > 0 }) {
            trendCard(snap.period.kind == .month ? "Last 6 months" : snap.period.kind == .all ? "Every week so far" : "Last \(snap.trend.count) weeks",
                      "Bars are focus time; the number is what got done.", snap.trend)
                .padding(.top, 8)
        }

        VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatCard(label: "Focused", value: fmtFocusDur(snap.headline.focusMin),
                         caption: "\(snap.headline.sessions) \(snap.headline.sessions == 1 ? "session" : "sessions")")
                StatCard(label: "Median", value: snap.medianMin.map { "\($0)m" } ?? "—",
                         caption: "per session")
            }
            HStack(spacing: 8) {
                StatCard(label: "Back in 5 min", value: snap.backWithin5Pct.map { "\($0)%" } ?? "—",
                         caption: "of timed pauses")
                StatCard(label: "Captures", value: "\(snap.facts.captures.count)",
                         caption: "kept this \(snap.period.kind == .all ? "time" : snap.period.kind == .month ? "month" : "week")")
            }
        }
        .padding(.top, 8)

        if !snap.dots.isEmpty {
            CalibrationScatter(dots: snap.dots, hitPct: snap.hitPct).padding(.top, 12)
        }

        if !snap.doneByArea.isEmpty {
            SectionLabel("Done by area").padding(.top, 18).padding(.bottom, 6)
            let maxN = Double(max(snap.doneByArea.map(\.count).max() ?? 1, 1))
            Card {
                VStack(spacing: 8) {
                    ForEach(Array(snap.doneByArea.enumerated()), id: \.offset) { _, a in
                        LabeledBar(label: a.area ?? NO_AREA_LABEL, frac: Double(a.count) / maxN,
                                   value: "\(a.count)", color: areaColor(forName: a.area, vm))
                    }
                }
            }
        }

        if !snap.pauses.isEmpty {
            SectionLabel("What pauses you").padding(.top, 18).padding(.bottom, 6)
            // Real minutes once pauses are timed; until then (older pauses were
            // never timed) the bars are the COUNT of pauses per reason — a row
            // of 2% slivers reading "0m · 3" said nothing (cross-check P0-3).
            let timed = snap.pauses.contains { $0.minutes > 0 }
            let maxMin = max(snap.pauses.map { $0.minutes }.max() ?? 0, 0.001)
            let maxN = Double(max(snap.pauses.map { $0.count }.max() ?? 1, 1))
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(snap.pauses.enumerated()), id: \.offset) { _, p in
                        LabeledBar(label: p.reason,
                                   frac: timed ? p.minutes / maxMin : Double(p.count) / maxN,
                                   value: timed ? "\(Int(p.minutes.rounded()))m · \(p.count)×" : "\(p.count)×",
                                   color: theme.palette.coral)
                    }
                    if !timed {
                        Text("How often each reason came up. Pause lengths show here once you resume after a pause.")
                            .font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                    }
                }
            }
        }

        comeBackChart(snap).padding(.top, 12)

        if snap.showInterruptions {
            histogram("When interruptions happen", snap.interruptions, theme.palette.coral,
                      axis: ["0m", "15m", "30m+"], caption: "Captures you took during a session, by minutes in.")
                .padding(.top, 12)
        }

        if !snap.facts.captures.isEmpty {
            SectionLabel("Captures by kind").padding(.top, 18).padding(.bottom, 6)
            let kinds = snap.captureKinds
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

        if !snap.slips.isEmpty {
            SectionLabel("The slip detector").padding(.top, 18).padding(.bottom, 6)
            VStack(spacing: 6) {
                ForEach(Array(snap.slips.prefix(cut("slips", 8)).enumerated()), id: \.offset) { _, s in
                    Card {
                        HStack {
                            Text(s.name).font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.ink).lineLimit(1)
                            Spacer()
                            Text("\(s.moveCount)× · \(s.weeks)w").font(UFont.mono(11)).foregroundStyle(theme.palette.ink3)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                moreToggle("slips", total: snap.slips.count, max: 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        if snap.hasFocus { heatmap(snap).padding(.top, 12) }
    }

    // CaptureBreakdown always carries the 5 fixed keys; keep Android's display
    // order (follow-up, idea, edit, question, distraction) with hyphenated names.
    private var captureTagOrder: [CaptureTag] { [.followUp, .idea, .edit, .question, .distraction] }

    // MARK: trend — done + focus per week / month, the selected one highlighted

    @ViewBuilder
    private func trendCard(_ title: String, _ caption: String, _ points: [TrendPoint]) -> some View {
        let maxMin = max(points.map(\.focusMin).max() ?? 0, 1)
        let dense = points.count > 12
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                Text(caption).font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                HStack(alignment: .bottom, spacing: dense ? 2 : 6) {
                    ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                        VStack(spacing: 3) {
                            Text(p.done > 0 ? "\(p.done)" : " ")
                                .font(UFont.mono(dense ? 8 : 10)).foregroundStyle(theme.palette.ink2)
                                .lineLimit(1).minimumScaleFactor(0.5)
                            RoundedRectangle(cornerRadius: dense ? 2 : 4, style: .continuous)
                                .fill(p.focusMin > 0 ? (p.selected ? theme.palette.ink : theme.palette.ink3) : theme.palette.bg2)
                                .opacity(p.partial && !p.selected ? 0.6 : 1)
                                .frame(height: max(4, 70 * Double(p.focusMin) / Double(maxMin)))
                            Text(dense && i % 4 != 0 && i != points.count - 1 ? " " : p.label)
                                .font(UFont.mono(8)).foregroundStyle(p.selected ? theme.palette.ink : theme.palette.ink3)
                                .lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 104, alignment: .bottom)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). " + points.map { "\($0.label): \($0.done) done, \(fmtFocusDur($0.focusMin)) focus\($0.partial ? " so far" : "")" }.joined(separator: "; "))
    }

    // MARK: stacked bars — weekday × area hours

    @ViewBuilder
    private func stackedBars(_ title: String, _ vm: AnalyticsModel, _ snap: InsightsSnapshot) -> some View {
        let bars = snap.weekday
        // The series in slot order: the user's own areas, any other area a
        // task carries (ink4, like any unmatched name), then "No area" (ink4).
        let series = snap.areaSeries
        let areas = series.map(\.name)
        let maxV = max(bars.map { $0.data.reduce(0, +) }.max() ?? 0, 0.001)
        let legend = areas.enumerated().filter { i, _ in bars.contains { ($0.data.count > i ? $0.data[i] : 0) > 0 } }.map(\.element)
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
                                            .fill(areaColor(forName: i < series.count ? series[i].area : nil, vm))
                                            .frame(width: geo.size.width * frac)
                                    }
                                }
                            }
                            // Full height even with no bars, so an empty day
                            // still draws its (bg2) track.
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .background(theme.palette.bg2)
                        }
                        .frame(height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                FlowLegend(areas: legend, color: { name in
                    areaColor(forName: series.first { $0.name == name }?.area, vm)
                }).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The bars are area-colored only — give VoiceOver the numbers instead of
        // silence: total focus hours per weekday + the busiest day.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stackedBarsSummary(title, bars))
    }

    private func stackedBarsSummary(_ title: String, _ bars: [StackedBar]) -> String {
        let totals = bars.map { ($0.d, $0.data.reduce(0, +)) }
        let grand = totals.reduce(0.0) { $0 + $1.1 }
        guard grand > 0 else { return "\(title). No focus hours recorded yet." }
        let parts = totals.filter { $0.1 > 0 }
            .map { "\($0.0) \(String(format: "%.1f", $0.1)) hours" }
            .joined(separator: ", ")
        let busiest = totals.max { $0.1 < $1.1 }
        let lead = busiest.map { "Busiest \($0.0)." } ?? ""
        return "\(title). \(lead) \(parts)."
    }

    // MARK: histogram (interruptions / coming back)

    @ViewBuilder
    private func histogram(_ title: String, _ bins: [Int], _ color: Color, axis: [String] = [],
                           caption: String? = nil) -> some View {
        let maxV = max(bins.max() ?? 0, 1)
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                if let caption {
                    Text(caption).font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                }
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
                if !axis.isEmpty {
                    HStack {
                        ForEach(Array(axis.enumerated()), id: \.offset) { i, a in
                            Text(a).font(UFont.mono(9)).foregroundStyle(theme.palette.ink3)
                            if i < axis.count - 1 { Spacer() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Bars are height + color only — summarize the distribution for VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(histogramSummary(title, bins))
    }

    private func histogramSummary(_ title: String, _ bins: [Int]) -> String {
        let total = bins.reduce(0, +)
        guard total > 0 else { return "\(title). No data yet." }
        let peakIdx = bins.indices.max { bins[$0] < bins[$1] } ?? 0
        return "\(title). \(total) total, peak in bin \(peakIdx + 1) of \(bins.count)."
    }

    // MARK: how fast you come back (pause → resume)

    @ViewBuilder
    private func comeBackChart(_ snap: InsightsSnapshot) -> some View {
        let bins = snap.comeBack
        if bins.reduce(0, +) == 0 {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How fast you come back").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                    Text("Time from pausing a focus session to resuming it. It fills in the next few times you pause and come back.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            histogram("How fast you come back", bins, theme.palette.primary,
                      axis: ["<5m", "15m", "30m+"], caption: "Pause to resume, in 5-minute steps.")
        }
    }

    // MARK: hour × day heatmap (7 days × 24 hours, by the hours sessions ran)

    @ViewBuilder
    private func heatmap(_ snap: InsightsSnapshot) -> some View {
        let grid = snap.heatmap          // 7 rows (Mon–Sun) × 24 hours, focus minutes
        let maxV = max(grid.flatMap { $0 }.max() ?? 0, 0.001)
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hour × day").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                Text("Every hour a session ran through, on every day.")
                    .font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                ForEach(Array(grid.enumerated()), id: \.offset) { d, row in
                    HStack(spacing: 2) {
                        Text(days[d]).font(UFont.sans(10)).foregroundStyle(theme.palette.ink3).frame(width: 28, alignment: .leading)
                        ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                            let t = min(max(v / maxV, 0), 1)
                            // Interpolate bg2 → green (Android's lerp) so low-intensity
                            // cells read as a tinted surface, not translucent green.
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(v <= 0 ? theme.palette.bg2 : lerpColor(theme.palette.bg2, theme.palette.green, 0.2 + 0.7 * t))
                                .aspectRatio(1, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                HStack(spacing: 0) {
                    Color.clear.frame(width: 30, height: 1)
                    ForEach(["12am", "6am", "12pm", "6pm"], id: \.self) { h in
                        Text(h).font(UFont.mono(9)).foregroundStyle(theme.palette.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Cells encode intensity by color only — call out the busiest slot for
        // VoiceOver instead of leaving the grid silent.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heatmapSummary(grid, days))
    }

    private func heatmapSummary(_ grid: Heatmap, _ days: [String]) -> String {
        guard let peak = peakFocusHour(grid) else { return "Hour by day focus heatmap. No focus recorded yet." }
        return "Hour by day focus heatmap. Busiest: \(days[peak.day]) \(hourSpanLabel(peak.hour))."
    }
}

// MARK: shared local building blocks (mirror the Android InsightsScreen helpers)

/// Headline stat: eyebrow + big value + a sub-line + a neutral change chip
/// ("+2", "same", "−40m") — ink only, never red/green (D4).
private struct HeadlineCard: View {
    @Environment(\.uTheme) private var theme
    let label: String
    let value: String
    let sub: String
    let delta: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(label)
                Text(value).font(UFont.sans(24, .semibold)).foregroundStyle(theme.palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(sub).font(UFont.sans(11)).foregroundStyle(theme.palette.ink2)
                    .lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let delta {
                    Text(delta).font(UFont.mono(10)).foregroundStyle(theme.palette.ink2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(theme.palette.bg2, in: Capsule())
                        .accessibilityLabel("change: \(delta)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

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
                        // 44pt hit area; negative padding keeps the track's drawn height.
                        .frame(minHeight: 44).contentShape(Rectangle()).padding(.vertical, -11)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt)
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
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

/// Legend of colored squares + area names (stacked-bars footer). A single
/// horizontal row like Android; scrolls when the user has many custom areas.
private struct FlowLegend: View {
    @Environment(\.uTheme) private var theme
    let areas: [String]
    // Resolved per name so an unmatched area falls back to ink4 (Android parity),
    // matching the swatch color used in the stacked bars above.
    let color: (String) -> Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(areas, id: \.self) { a in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(a))
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
                // The denominator is the dots on the chart (≤ 24 recent
                // estimated sessions), not every session (cross-check P1-14).
                Text("\(hitPct)% of \(dots.count) recent \(dots.count == 1 ? "session" : "sessions") landed within 5 min of the estimate.")
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
                // The Canvas scatter is purely visual (green = on estimate, coral =
                // off) — describe it for VoiceOver.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(scatterSummary)
                HStack(spacing: 14) {
                    Text("→ estimate").font(UFont.mono(9)).foregroundStyle(theme.palette.ink3)
                    Text("↑ actual").font(UFont.mono(9)).foregroundStyle(theme.palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scatterSummary: String {
        guard !dots.isEmpty else { return "Estimate calibration scatter. No estimated sessions yet." }
        let within = dots.filter { abs($0.e - $0.a) <= 5 }.count
        return "Estimate calibration scatter. \(dots.count) sessions, \(within) within 5 minutes of estimate, \(hitPct)% on estimate."
    }
}
