// Today — 1:1 with the Android TodayScreen: Orbit + bell + avatar header, a
// date eyebrow + "<greeting>, Unstuck." serif line, a "This week · focused"
// pill, the gradient Start-Next hero (full-width Focus), the Today/Backlog +
// area filter pills, and the filtered today list. Live store via GRDB.

import SwiftUI
import UIKit
import UserNotifications
import WidgetKit
import UnstuckCore
import UnstuckData
import UnstuckDesign
import UnstuckShared

@MainActor
@Observable
final class TodayModel {
    var all: [TaskItem] = []
    var blocks: [CalBlock] = []
    var areas: [LifeArea] = []
    var sessions: [Session] = []
    var captures: [Capture] = []
    private let repo: TaskRepository
    init(_ repo: TaskRepository) { self.repo = repo }

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
                all = snap.tasks
                blocks = snap.blocks
                areas = snap.areas
                sessions = snap.sessions
                writeWidgetSnapshot()
            }
        } catch {}
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

    private func writeWidgetSnapshot() {
        let next = startNext(liveTaskId: nil, area: nil)
        let openCount = all.filter { !$0.done && !($0.later ?? false) }.count
        AppGroup.writeStartNext(StartNextSnapshot(
            taskName: next?.name, estimateMin: next?.estimateMin, lifeArea: next?.lifeArea,
            openCount: openCount, updatedAt: Date()))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The Start-Next hero — scoped to TODAY (next-scheduled by time → else
    /// shortest-estimate → else nil so the hero points to the Backlog instead of
    /// pulling a backlog task). Excludes the live-focused task + honours the area.
    func startNext(liveTaskId: String?, area: String?) -> TaskItem? {
        pickTodayHero(tasks: all, blocks: blocks, now: Date().timeIntervalSince1970 * 1000,
                      liveTaskId: liveTaskId, areaFilter: area)
    }

    /// How many tasks sit in the Backlog (for the empty-hero pointer).
    var backlogCount: Int {
        visibleTasks(view: .backlog, tasks: all, blocks: blocks,
                     now: Date().timeIntervalSince1970 * 1000, activeArea: nil, slipMode: false).count
    }

    func rows(backlog: Bool, area: String?, startNextId: String?, liveTaskId: String?) -> [TaskItem] {
        let now = Date().timeIntervalSince1970 * 1000
        if backlog {
            return visibleTasks(view: .backlog, tasks: all, blocks: blocks, now: now, activeArea: nil, slipMode: false)
                .filter { $0.id != startNextId && $0.id != liveTaskId }
        }
        // Today: open rows (area-agnostic bucket) PLUS today's completions kept as
        // struck-through wins (sorted last) until tomorrow, then area-filtered and
        // with the hero/live task subtracted — 1:1 with Android TodayScreen.kt:127-136.
        let open = visibleTasks(view: .today, tasks: all, blocks: blocks, now: now, activeArea: nil, slipMode: false)
        let today = Clock.todayISO()
        let doneToday = (all.filter { !isTemplate($0) } + projectOccurrences(all, blocks, fromISO: today))
            .filter { t in isCompletedToday(t, now: now) && !open.contains { $0.id == t.id } }
        return (open + doneToday).filter {
            (area == nil || $0.lifeArea == area) && $0.id != startNextId && $0.id != liveTaskId
        }
    }

    /// Minutes focused in the last 7 days (the header pill).
    var weekFocusMin: Int {
        let cutoff = Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970 * 1000
        return sessions.filter { (Time.parseMillis($0.completedAt) ?? 0) >= cutoff }
            .reduce(0) { $0 + $1.actualSec } / 60
    }

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
    @Environment(\.colorScheme) private var scheme
    @State private var vm: TodayModel?
    @State private var showSettings = false
    @State private var showNotifCenter = false
    @State private var showPalette = false
    @State private var showInsights = false
    @State private var notifsEnabled = true
    @State private var areaFilter: String?
    @State private var backlogActive = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let vm {
                    if !notifsEnabled { notificationsOffBanner.padding(.horizontal, 18).padding(.top, 8) }
                    // "Just now" session recap — shows for 6h after a finished
                    // focus session, between the notif banner and the hero
                    // (Android TodayScreen recap parity).
                    if let recap = model.lastRecap,
                       Date().timeIntervalSince1970 * 1000 - recap.at < 6 * 3_600_000 {
                        recapCard(recap).padding(.horizontal, 18).padding(.top, 8)
                    }
                    // Quiet in-app nudge — the FIRST of "things slipping" surfaced
                    // between the recap and the hero (Android TodayScreen parity).
                    if let nudge = vm.nudges.first {
                        nudgeCard(vm, nudge).padding(.horizontal, 18).padding(.top, 6)
                    }
                    heroOrEmpty(vm).padding(.horizontal, 18).padding(.top, 14)
                    filterBar(vm)
                    list(vm)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.bottom, 96)   // clear the floating bottom nav
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNotifCenter, onDismiss: { model.flushPendingDeepLink() }) { NotificationCenterView() }
        .sheet(isPresented: $showPalette) { CommandPalette() }
        .sheet(isPresented: $showInsights) { NavigationStack { AnalyticsView() } }
        .feedbackBubble()
        .task {
            guard vm == nil, let repo = model.taskRepo else { return }
            let m = TodayModel(repo); vm = m; await m.observe()
        }
        .task { await refreshNotifStatus() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotifStatus() }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Mark(size: 24)
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
                    }.buttonStyle(.plain).accessibilityLabel("Inbox")
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
                    Button { showSettings = true } label: {
                        Text(model.avatarInitials)
                            .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.greenInk)
                            .frame(width: 32, height: 32).background(theme.palette.greenSoft, in: Circle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(.leading, 18).padding(.trailing, 12).padding(.top, 8).padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(dateEyebrow).foregroundStyle(theme.palette.primaryDeep)
                Text("\(greeting)\nUnstuck.")
                    .font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink)
                weekPill
            }
            .padding(.horizontal, 18).padding(.bottom, 4)
        }
    }

    private var weekPill: some View {
        let min = vm?.weekFocusMin ?? 0
        let label = min >= 60 ? "\(min / 60)h\(min % 60 != 0 ? " \(min % 60)m" : "") focused" : "\(min)m focused"
        // Opens INSIGHTS, not Settings — Android parity (TodayScreen pill → Route.Insights).
        return Button { showInsights = true } label: {
            HStack(spacing: 8) {
                Circle().fill(theme.palette.coral).frame(width: 6, height: 6)
                Text("This week · ").font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                    + Text(label).font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.ink)
                Text("→").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(theme.palette.bg2, in: Capsule())
        }.buttonStyle(.plain).padding(.top, 2)
            .accessibilityIdentifier("week-pill")
    }

    // MARK: Start-Next hero

    @ViewBuilder
    private func heroOrEmpty(_ vm: TodayModel) -> some View {
        if let t = vm.startNext(liveTaskId: model.liveTaskId, area: areaFilter) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(theme.palette.primaryDeep)
                    SectionLabel("Start next").foregroundStyle(theme.palette.primaryDeep)
                }
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color.white.opacity(scheme == .dark ? 0.12 : 0.7), in: Capsule())
                HStack(spacing: 6) {
                    Circle().fill(theme.palette.coral).frame(width: 6, height: 6)
                    Text("\(t.lifeArea ?? "Focus") · \(t.name)")
                        .font(UFont.sans(11, .semibold)).foregroundStyle(theme.palette.primaryDeep).lineLimit(1)
                }.padding(.top, 12)
                Text(firstStepHeadline(t))
                    .font(UFont.sans(21, .bold)).foregroundStyle(theme.palette.ink).lineLimit(2).padding(.top, 6)
                Text("\(t.estimateMin) min").font(UFont.sans(12)).foregroundStyle(theme.palette.ink2).padding(.top, 6)
                HStack(spacing: 10) {
                    Button { model.router.beginFocus(t) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 13))
                            Text("Focus").font(UFont.sans(15, .semibold))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 13)
                        .background(theme.palette.coral, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }.buttonStyle(.plain)
                    Button { showPalette = true } label: {
                        Text("Pick another").font(UFont.sans(13, .medium))
                            .foregroundStyle(theme.palette.primaryDeep)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }.buttonStyle(.plain)
                }.padding(.top, 14)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: theme.palette.heroGradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else if vm.backlogCount > 0 {
            // Nothing scheduled today — point to the Backlog (don't pull a backlog
            // task into the hero). Tapping flips the list below to the Backlog.
            Button { backlogActive = true } label: {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Nothing scheduled today").foregroundStyle(theme.palette.primaryDeep)
                    Text("Pick something to start.")
                        .font(UFont.sans(21, .bold)).foregroundStyle(theme.palette.ink).padding(.top, 6)
                    HStack(spacing: 6) {
                        Text("\(vm.backlogCount) in your backlog")
                            .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                        Text("→").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                    }.padding(.top, 4)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: theme.palette.heroGradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }.buttonStyle(.plain)
        } else {
            VStack(spacing: 10) {
                Mark(size: 48)
                SectionLabel("Nothing to start").foregroundStyle(theme.palette.primaryDeep)
                Text("You're all clear.").font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink)
                Text("Nothing's missing. When something's on your mind, drop it in.")
                    .font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)
                    .multilineTextAlignment(.center).padding(.horizontal, 8)
                Button { showPalette = true } label: {
                    Text("Add one thing").font(UFont.sans(15, .semibold))
                        .foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 13)
                        .background(theme.palette.coral, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }.buttonStyle(.plain).padding(.top, 6)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 22)
            .background(LinearGradient(colors: theme.palette.heroGradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func firstStepHeadline(_ t: TaskItem) -> String {
        if let s = t.firstPhysicalAction?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        return t.name
    }

    // MARK: filter pills

    @ViewBuilder
    private func filterBar(_ vm: TodayModel) -> some View {
        Text(backlogActive ? "Backlog" : "Today")
            .font(UFont.sans(15, .semibold)).foregroundStyle(theme.palette.ink)
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { backlogActive.toggle(); if backlogActive { areaFilter = nil } } label: {
                    HStack(spacing: 5) {
                        if !backlogActive { Circle().fill(theme.palette.amber).frame(width: 6, height: 6) }
                        Text("Backlog").font(UFont.sans(12, .medium))
                            .foregroundStyle(backlogActive ? theme.palette.amberInk : theme.palette.ink2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(backlogActive ? theme.palette.amberSoft : theme.palette.bg2, in: Capsule())
                }.buttonStyle(.plain)
                pill("All", selected: !backlogActive && areaFilter == nil, dot: nil) { backlogActive = false; areaFilter = nil }
                ForEach(vm.areas) { a in
                    pill(a.name, selected: !backlogActive && areaFilter == a.name, dot: theme.palette.areaColor(a.color)) {
                        backlogActive = false; areaFilter = (areaFilter == a.name) ? nil : a.name
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
        let startNextId = vm.startNext(liveTaskId: liveId, area: areaFilter)?.id
        let rows = vm.rows(backlog: backlogActive, area: areaFilter, startNextId: startNextId, liveTaskId: liveId)
        // The in-progress focus session, surfaced at the top of the list (Android
        // TodayScreen LiveSessionCard) — resolved by liveTaskId from observed tasks.
        let liveTask = liveId.flatMap { id in vm.all.first { $0.id == id } }
        VStack(spacing: 6) {
            if let liveTask, let live = model.liveSession {
                liveSessionCard(liveTask, live)
            }
            ForEach(rows) { t in taskRow(t) }
        }
        .padding(.horizontal, 18)
        // Per-view empty note — only when nothing else is on screen (the live
        // card counts as content), and only inside Backlog or an area filter
        // (matches Android's displayRows.isEmpty && liveTask == null gate).
        if rows.isEmpty && liveTask == nil && (backlogActive || areaFilter != nil) {
            Text(backlogActive ? "Backlog's clear — nothing waiting."
                 : "Nothing in \(areaFilter ?? "") right now.")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                .padding(.horizontal, 18).padding(.vertical, 28)
        } else if rows.isEmpty && liveTask == nil {
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
    /// captured snapshot) so pausing/resuming from this card — which mutates the
    /// device-local live store, outside SwiftUI's observation — reflects within a
    /// second without an explicit observable trigger. `initial` is the parent's
    /// snapshot, used as the fallback if a tick can't read the store.
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
                // Tapping the card body returns to the Focus screen for this task.
                Button { model.router.beginFocus(task) } label: {
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
        let isOccurrence = model.occurrenceBlockForId(t.id) != nil
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
                            Text("#\(tn)").font(UFont.sans(10, .medium)).foregroundStyle(theme.palette.primaryDeep)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(theme.palette.primarySoft, in: Capsule())
                        }
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
                SectionLabel("Just now").foregroundStyle(theme.palette.coralDeep)
                Spacer()
                Button { model.lastRecap = nil } label: {
                    Text("✕").font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                }.buttonStyle(.plain)
            }
            Text("You did the thing.").font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
                .padding(.top, 4)
            Text("\(max(1, recap.focusedSec / 60)) MIN FOCUSED · \(recap.taskName)")
                .font(UFont.mono(11)).foregroundStyle(theme.palette.ink2)
                .lineLimit(1).truncationMode(.tail).padding(.top, 6)
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
                Text(n.action).font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.primaryDeep)
            }.buttonStyle(.plain)
            Button { vm.dismissNudge(n.id) } label: {
                Text("✕").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }.buttonStyle(.plain)
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
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Still up"
        }
    }
    private var dateEyebrow: String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US"); df.dateFormat = "EEEE · h:mm a"
        return df.string(from: Date())
    }
}
