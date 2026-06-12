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
}

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var vm: TodayModel?
    @State private var showSettings = false
    @State private var showNotifCenter = false
    @State private var showPalette = false
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
                // Inbox (MoveToInbox) → the capture triage tray; the coral dot
                // marks open (untriaged) captures (Android Today header parity).
                Button { model.router.present(.inbox) } label: {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 18))
                        .foregroundStyle(theme.palette.ink2).frame(width: 40, height: 40)
                        .overlay(alignment: .topTrailing) {
                            if (vm?.openCaptureCount(archivedIds: model.archivedCaptureIds) ?? 0) > 0 {
                                Circle().fill(theme.palette.coral).frame(width: 8, height: 8)
                                    .offset(x: -8, y: 8)
                            }
                        }
                }.buttonStyle(.plain)
                // Bell → in-app Notification Center; the dot is the unread
                // badge (newest log entry vs lastSeen — spec 10 §1.9).
                Button { showNotifCenter = true } label: {
                    Image(systemName: "bell").font(.system(size: 18)).foregroundStyle(theme.palette.ink2).frame(width: 40, height: 40)
                        .overlay(alignment: .topTrailing) {
                            if NotificationLog.shared.hasUnread {
                                Circle().fill(theme.palette.coral).frame(width: 8, height: 8)
                                    .offset(x: -8, y: 8)
                            }
                        }
                }.buttonStyle(.plain)
                Button { showSettings = true } label: {
                    Text(model.avatarInitials)
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.greenInk)
                        .frame(width: 32, height: 32).background(theme.palette.greenSoft, in: Circle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(dateEyebrow).foregroundStyle(theme.palette.primaryDeep)
                Text("\(greeting),\nUnstuck.")
                    .font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink)
                weekPill
            }
            .padding(.horizontal, 18).padding(.bottom, 4)
        }
    }

    private var weekPill: some View {
        let min = vm?.weekFocusMin ?? 0
        let label = min >= 60 ? "\(min / 60)h\(min % 60 != 0 ? " \(min % 60)m" : "") focused" : "\(min)m focused"
        return Button { showSettings = true } label: {
            HStack(spacing: 8) {
                Circle().fill(theme.palette.coral).frame(width: 6, height: 6)
                Text("This week · ").font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                    + Text(label).font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.ink)
                Text("→").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(theme.palette.bg2, in: Capsule())
        }.buttonStyle(.plain).padding(.top, 2)
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
                HStack(spacing: 6) {
                    Circle().fill(theme.palette.coral).frame(width: 6, height: 6)
                    Text("\(t.lifeArea ?? "Focus") · \(t.name)")
                        .font(UFont.sans(11, .semibold)).foregroundStyle(theme.palette.primaryDeep).lineLimit(1)
                }.padding(.top, 12)
                Text(firstStepHeadline(t))
                    .font(UFont.sans(21, .bold)).foregroundStyle(theme.palette.ink).lineLimit(2).padding(.top, 6)
                Text("\(t.estimateMin) min").font(UFont.sans(12)).foregroundStyle(theme.palette.ink2).padding(.top, 6)
                Button { model.router.beginFocus(t) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 13))
                        Text("Focus").font(UFont.sans(15, .semibold))
                    }
                    .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(theme.palette.coral, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }.buttonStyle(.plain).padding(.top, 14)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: theme.palette.heroGradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else if vm.backlogCount > 0 {
            // Nothing scheduled today — point to the Backlog (don't pull a backlog
            // task into the hero). Tapping flips the list below to the Backlog.
            Button { backlogActive = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Nothing scheduled today").foregroundStyle(theme.palette.primaryDeep)
                    Text("Pick something to start.")
                        .font(UFont.sans(21, .bold)).foregroundStyle(theme.palette.ink)
                    HStack(spacing: 6) {
                        Text("\(vm.backlogCount) in your backlog")
                            .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.palette.primaryDeep)
                    }.padding(.top, 4)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: theme.palette.heroGradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }.buttonStyle(.plain)
        } else {
            VStack(spacing: 8) {
                Text("All clear.").font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
                Text("Add a task to get going.").font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
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
                    .foregroundStyle(selected ? .white : theme.palette.ink2)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? theme.palette.primary : theme.palette.bg2, in: Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: today list

    @ViewBuilder
    private func list(_ vm: TodayModel) -> some View {
        let live = model.liveTaskId
        let startNextId = vm.startNext(liveTaskId: live, area: areaFilter)?.id
        let rows = vm.rows(backlog: backlogActive, area: areaFilter, startNextId: startNextId, liveTaskId: live)
        if rows.isEmpty {
            Text(backlogActive ? "Backlog's clear — nothing waiting."
                 : (areaFilter != nil ? "Nothing in \(areaFilter!) right now." : "Nothing scheduled. Tap + to add."))
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                .padding(.horizontal, 18).padding(.vertical, 28)
        } else {
            VStack(spacing: 8) {
                ForEach(rows) { t in taskRow(t) }
            }
            .padding(.horizontal, 18)
        }
    }

    private func taskRow(_ t: TaskItem) -> some View {
        let isOccurrence = model.occurrenceBlockForId(t.id) != nil
        return Button { model.toggleDone(t) } label: {
            HStack(spacing: 12) {
                // Completed-today rows stay visible as wins — a green check +
                // struck-through/greyed name distinguishes them from open work
                // (mirrors Android TodayScreen + the Tasks list).
                if t.done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(theme.palette.greenInk)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(t.name).font(UFont.sans(16, .medium))
                            .strikethrough(t.done)
                            .foregroundStyle(t.done ? theme.palette.ink3 : theme.palette.ink).lineLimit(1)
                        if isOccurrence { Text("↻").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3) }
                    }
                    HStack(spacing: 6) {
                        Circle().fill(theme.palette.areaColor(t.lifeArea)).frame(width: 6, height: 6)
                        Text(t.lifeArea ?? "—").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    }
                }
                Spacer()
                Text("\(t.estimateMin)m").font(UFont.mono(12)).foregroundStyle(theme.palette.ink3)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.palette.line))
        }.buttonStyle(.plain)
        .contextMenu {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("JUST NOW").font(UFont.mono(11, .medium)).tracking(0.8)
                    .foregroundStyle(theme.palette.coralDeep)
                Spacer()
                Button { model.lastRecap = nil } label: {
                    Text("✕").font(UFont.sans(14)).foregroundStyle(theme.palette.ink3)
                }.buttonStyle(.plain)
            }
            Text("You did the thing.").font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
            Text("\(max(1, recap.focusedSec / 60)) MIN FOCUSED · \(recap.taskName)")
                .font(UFont.mono(11)).foregroundStyle(theme.palette.ink2)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.coralSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
