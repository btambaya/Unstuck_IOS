// In-app Notification Center — the bell next to the avatar (spec 10 §1.9;
// 1:1 with Android NotificationCenterScreen). Two sections: "Upcoming"
// (scheduled task reminders in the next 2 days, computed live from the
// blocks via the pure upcomingReminders) and "Recent" (the persisted
// NotificationLog, newest first). Tapping a task-linked row opens that
// task; any other deep link routes through the app's deep-link handler.
// Opening the center marks everything seen (clears the unread badge).

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign

struct NotificationCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    @State private var tasks: [TaskItem] = []
    @State private var blocks: [CalBlock] = []
    // Stable for this screen open (not a per-frame key) — Android parity.
    private let now = Date().timeIntervalSince1970 * 1000
    private var log: NotificationLog { NotificationLog.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let upcoming = upcomingReminders(blocks: blocks, tasks: tasks, now: now)
                    if !upcoming.isEmpty {
                        SectionLabel("Upcoming").padding(.top, 4).padding(.bottom, 8)
                        ForEach(upcoming) { u in
                            let act: (() -> Void)? = u.taskId.isEmpty ? nil : { openTask(u.taskId) }
                            card(dot: theme.palette.coral, title: u.name,
                                 meta: relFuture(u.at - now), action: act)
                        }
                    }
                    SectionLabel("Recent")
                        .padding(.top, upcoming.isEmpty ? 4 : 18).padding(.bottom, 8)
                    if log.items.isEmpty {
                        Text("Nothing yet. Reminders and recaps will show up here.")
                            .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(log.items) { n in
                            card(dot: accentColor(n.kind), title: n.title,
                                 meta: "\(n.body)  ·  \(relPast(now - n.at))",
                                 action: tapAction(for: n))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            log.sweepDelivered()
            log.markAllSeen()
            guard let repo = model.taskRepo else { return }
            do {
                for try await snap in repo.observeTasksAndBlocks() {
                    tasks = snap.tasks
                    blocks = snap.blocks
                }
            } catch {}
        }
    }

    // Task links open the task; any other deep link (collection share,
    // recap, brief) routes through the deep-link handler instead of dying.
    private func tapAction(for n: NotificationLog.Entry) -> (() -> Void)? {
        guard let dl = n.deepLink, !dl.isEmpty else { return nil }
        if dl.hasPrefix("unstuck://task/") {
            let id = String(dl.dropFirst("unstuck://task/".count))
            return { openTask(id) }
        }
        // Defer routing until this sheet finishes dismissing — the host (Today)
        // flushes on the sheet's onDismiss. Routing here (which may present the
        // task editor / focus, a second presentation from the same host) while
        // we dismiss would silently no-op in SwiftUI.
        return { model.routeDeepLinkAfterDismiss(dl); dismiss() }
    }

    private func openTask(_ id: String) {
        model.routeDeepLinkAfterDismiss("unstuck://task/\(id)")
        dismiss()
    }

    private func accentColor(_ kind: String) -> Color {
        switch notificationAccent(kind: kind) {
        case .amber: return theme.palette.amber
        case .green: return theme.palette.green
        case .primaryDeep: return theme.palette.primaryDeep
        case .coral: return theme.palette.coral
        }
    }

    private func card(dot: Color, title: String, meta: String, action: (() -> Void)?) -> some View {
        let row = HStack(alignment: .center, spacing: 11) {
            Circle().fill(dot).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                Text(meta).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.palette.line))
        .padding(.vertical, 3)

        return Group {
            if let action {
                Button(action: action) { row }.buttonStyle(.plain)
            } else {
                row
            }
        }
    }
}
