// P2 — Today. Start Next (UnstuckCore.pickStartNext) + Up Next
// (pickUpNext) + today's open tasks, all from the live GRDB store. The
// "Begin focus" action is a placeholder until the Focus surface (P3).

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
    private let repo: TaskRepository
    init(_ repo: TaskRepository) { self.repo = repo }

    func observe() async {
        do {
            for try await snap in repo.observeTasksAndBlocks() {
                all = snap.tasks
                blocks = snap.blocks
                writeWidgetSnapshot()
            }
        } catch {}
    }

    /// Mirror Start Next into the App Group so the home/lock widgets render
    /// it without the network, and nudge WidgetKit to reload.
    private func writeWidgetSnapshot() {
        let next = startNext
        let openCount = all.filter { !$0.done && !($0.later ?? false) }.count
        AppGroup.writeStartNext(StartNextSnapshot(
            taskName: next?.name, estimateMin: next?.estimateMin, lifeArea: next?.lifeArea,
            openCount: openCount, updatedAt: Date()))
        WidgetCenter.shared.reloadAllTimelines()
    }

    var startNext: TaskItem? { pickStartNext(tasks: all, blocks: [], liveTaskId: nil) }
    var upNext: [TaskItem] { pickUpNext(tasks: all, blocks: [], liveTaskId: nil, startNextId: startNext?.id) }
    var today: [TaskItem] {
        visibleTasks(view: .today, tasks: all, blocks: blocks,
                     now: Date().timeIntervalSince1970 * 1000, activeArea: nil, slipMode: false)
    }
}

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: TodayModel?
    @State private var showSettings = false
    @State private var showPalette = false
    @State private var notifsEnabled = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionLabel("Today")
                    Text("What's next.").font(UFont.serifItalic(34)).foregroundStyle(theme.palette.ink)

                    if !notifsEnabled { notificationsOffBanner }

                    if let vm {
                        startNextCard(vm)
                        if !vm.upNext.isEmpty { upNextSection(vm) }
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showPalette = true } label: { Image(systemName: "magnifyingglass") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showPalette) { CommandPalette() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .feedbackBubble()
        }
        .task {
            guard vm == nil, let repo = model.taskRepo else { return }
            let m = TodayModel(repo); vm = m; await m.observe()
        }
        .task { await refreshNotifStatus() }
        // Re-check when returning from system Settings.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotifStatus() }
        }
    }

    // Surface a silent failure: if OS notifications are disabled, reminders never
    // reach the phone. Banner deep-links to the app's system settings. (Android parity.)
    private var notificationsOffBanner: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bell.slash").font(.system(size: 16)).foregroundStyle(theme.palette.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications are off").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.amber)
                    Text("Reminders won't reach your phone. Tap to turn them on.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.amber.opacity(0.85))
                }
                Spacer()
                Text("→").font(UFont.sans(14)).foregroundStyle(theme.palette.amber)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.amber.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func refreshNotifStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifsEnabled = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
    }

    @ViewBuilder
    private func startNextCard(_ vm: TodayModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(theme.palette.primaryDeep)
                    SectionLabel("Start next")
                }
                if let t = vm.startNext {
                    // Context line: area · task name.
                    HStack(spacing: 6) {
                        AreaDot("coral", size: 6)
                        Text("\(t.lifeArea ?? "Focus") · \(t.name)")
                            .font(UFont.sans(11, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                            .lineLimit(1)
                    }
                    // Headline = the smallest concrete step (firstPhysicalAction) when
                    // set, else the task name — the calming "do this one small thing".
                    Text(firstStepHeadline(t))
                        .font(UFont.sans(21, .bold)).foregroundStyle(theme.palette.ink)
                        .lineLimit(2).padding(.top, 4)
                    Text("\(t.estimateMin) min").font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                    HStack(spacing: 12) {
                        Button { model.router.beginFocus(t) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").font(.system(size: 12))
                                Text("Focus").font(UFont.sans(15, .medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.vertical, 11).padding(.horizontal, 18)
                            .background(theme.palette.coralDeep)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        }.buttonStyle(.plain)
                        Button { showPalette = true } label: {
                            Text("Pick another").font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.primaryDeep)
                        }.buttonStyle(.plain)
                    }
                    .padding(.top, 8)
                } else {
                    Text("All clear. Add a task to get going.")
                        .font(UFont.sans(15)).foregroundStyle(theme.palette.ink2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func firstStepHeadline(_ t: TaskItem) -> String {
        if let step = t.firstPhysicalAction?.trimmingCharacters(in: .whitespacesAndNewlines), !step.isEmpty {
            return step
        }
        return t.name
    }

    @ViewBuilder
    private func upNextSection(_ vm: TodayModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Up next")
            ForEach(vm.upNext) { t in
                HStack(spacing: 10) {
                    AreaDot(t.lifeArea)
                    Text(t.name).font(UFont.sans(15)).foregroundStyle(theme.palette.ink)
                    Spacer()
                    Text("\(t.estimateMin)m").font(UFont.mono(11)).foregroundStyle(theme.palette.ink3)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(theme.palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
        }
    }
}
