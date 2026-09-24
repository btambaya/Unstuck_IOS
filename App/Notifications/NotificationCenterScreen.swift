// In-app Notification Center — the bell next to the avatar (spec 10 §1.9;
// 1:1 with Android NotificationCenterScreen). Two sections: "Upcoming"
// (scheduled task reminders in the next 2 days, computed live from the
// blocks via the pure upcomingReminders) and "Recent" (the persisted
// NotificationLog, newest first, MERGED with the server's `notification_queue`
// cards of moment `call` — "Unstuck called you about X" — the way the web's
// useNotificationQueue + mergeRecent do it, so a call the server rang shows
// up on every device with the call's label and notes, read from the local
// call_requests mirror). Tapping a task-linked row opens that task; any other
// deep link routes through the app's deep-link handler. Opening the center
// marks everything seen (clears the unread badge).

import SwiftUI
import UnstuckCore
import UnstuckData
import UnstuckDesign
import UnstuckSync

struct NotificationCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    @State private var tasks: [TaskItem] = []
    @State private var blocks: [CalBlock] = []
    /// The server's call cards (notification_queue, moment `call`), as bell entries.
    @State private var callCards: [NotificationLog.Entry] = []
    @Environment(\.scenePhase) private var scenePhase
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
                    let recent = NotificationQueueCards.mergeRecent(local: log.items, queue: callCards)
                    if recent.isEmpty {
                        Text("Nothing yet. Reminders and recaps will show up here.")
                            .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(recent) { n in
                            card(dot: accentColor(n.kind), title: n.title,
                                 meta: "\(n.body)  ·  \(relPast(now - n.at))",
                                 action: tapAction(for: n),
                                 kindLabel: kindLabel(n.kind))
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
        .task { await loadCallCards() }
        .onChange(of: scenePhase) { _, phase in
            // postgres_changes has no replay and this screen holds no channel:
            // a return to the foreground while it is open is the catch-up.
            if phase == .active { Task { await loadCallCards() } }
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

    /// The "Unstuck called you about X" cards: the server rows of moment
    /// `call`, each matched to its call in the local mirror by label (the
    /// card carries no id) so the row shows the notes that were read back.
    /// Best-effort — offline keeps what was there.
    private func loadCallCards() async {
        guard let coord = model.coordinator else { return }
        guard let cards = try? await coord.notifications.queueCards(moment: NotificationQueueCards.callMoment) else { return }
        let calls = (try? coord.callsMirror.all()) ?? []
        callCards = cards.map { NotificationQueueCards.entry(from: $0, calls: calls) }
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

    /// Human-readable name for the dot's color-coded kind, so VoiceOver conveys
    /// the meaning that's otherwise only in the accent color.
    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "paused_checkin": return "Paused check-in"
        case "atstart": return "Starting now"
        case "drifted": return "Drifted"
        case "session_recap": return "Session recap"
        case "morning_brief": return "Morning brief"
        case "evening_preview": return "Evening preview"
        case "daily_nudge": return "Daily nudge"
        case "task_share": return "Shared with you"
        case "collection_share": return "List shared with you"
        case "invite_claimed": return "Someone joined"
        case "shared_task_done": return "Shared task done"
        case "call", "call_missed": return "Call from Unstuck"
        case NotificationQueueCards.skippedKind: return "Call skipped"
        default: return "Notification"
        }
    }

    private func accentColor(_ kind: String) -> Color {
        // A call skipped for the day's voice minutes is a note, not an
        // alert: the neutral ink, never the coral the calls use (Ahmad
        // 2026-09-23 — "a quiet note says it was skipped").
        if kind == NotificationQueueCards.skippedKind { return theme.palette.ink3 }
        switch notificationAccent(kind: kind) {
        case .amber: return theme.palette.amber
        case .green: return theme.palette.green
        case .ink: return theme.palette.ink2
        case .coral: return theme.palette.coral
        }
    }

    private func card(dot: Color, title: String, meta: String, action: (() -> Void)?,
                      kindLabel: String = "Reminder") -> some View {
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
        // The dot's color is the ONLY signal of the notification kind — surface
        // it as a label so it isn't color-only for VoiceOver.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kindLabel): \(title)")
        .accessibilityValue(meta)

        return Group {
            if let action {
                Button(action: action) { row }.buttonStyle(.plain)
            } else {
                row
            }
        }
    }
}


/// The server's in-app call cards → bell entries (pure; tested). Web parity:
/// `entryFromRow` + `mergeRecent` in lib/use-notification-queue.ts.
enum NotificationQueueCards {
    static let callMoment = "call"
    /// send-call writes `body = "Unstuck is calling about <label>"` on the
    /// card (the push's copy); the label is what we key the mirror on.
    static let callBodyPrefix = "Unstuck is calling about "
    /// Local entries (the phone's own "I called about X") and server cards
    /// describe the same event: collapse when the copy matches within 5 min,
    /// or both are recaps within 5 min (the web's two rules).
    static let nearMs: Double = 5 * 60 * 1000
    static let cap = 20

    /// dispatch_calls' card for a due call it did NOT ring because today's
    /// voice minutes were used (migration 077, Ahmad 2026-09-23): moment
    /// `call`, title "Call skipped", body "Unstuck didn't call about <label>
    /// — today's voice minutes are used.", no push. Shown as written, as a
    /// quiet entry of its own kind.
    static let skippedKind = "call_skipped"
    static let skippedBodyPrefix = "Unstuck didn't call about "
    static let skippedBodySuffix = " — today's voice minutes are used."

    /// "Unstuck didn't call about ring the bank — today's voice minutes are
    /// used." → "ring the bank"; nil for any other body. Curly apostrophes
    /// read the same.
    static func skippedLabel(fromBody body: String) -> String? {
        let t = body.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(skippedBodyPrefix), t.hasSuffix(skippedBodySuffix),
              t.count > skippedBodyPrefix.count + skippedBodySuffix.count else { return nil }
        let label = String(t.dropFirst(skippedBodyPrefix.count).dropLast(skippedBodySuffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    /// "Unstuck is calling about speak to James" → "speak to James"; nil for
    /// any other body.
    static func callLabel(fromBody body: String) -> String? {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(callBodyPrefix) else { return nil }
        let label = String(t.dropFirst(callBodyPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    /// The mirrored call a card is about: the same label (case-insensitive),
    /// the one whose ring time is nearest the card's creation (a label can be
    /// booked more than once over time).
    static func matchingCall(label: String, cardAtMs: Double?, in calls: [CallRequest]) -> CallRequest? {
        let key = label.lowercased()
        let same = calls.filter { $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }
        guard let at = cardAtMs else { return same.first }
        return same.min { a, b in
            let da = abs((a.effectiveAtDate?.timeIntervalSince1970 ?? .infinity) * 1000 - at)
            let db = abs((b.effectiveAtDate?.timeIntervalSince1970 ?? .infinity) * 1000 - at)
            return da < db
        }
    }

    /// A queue row → the bell's entry: kind `call`, "Unstuck called you about
    /// <label>", the call's notes as the body (or the card's own copy when
    /// no call matches), the anchored task as the destination (else Today).
    static func entry(from card: NotificationQueueCard, calls: [CallRequest]) -> NotificationLog.Entry {
        let at = Time.parseMillis(card.createdAt) ?? 0
        if let skipped = skippedLabel(fromBody: card.body) {
            // The card's own plain words; a tap opens the call's task, as
            // any call card does.
            let call = matchingCall(label: skipped, cardAtMs: at, in: calls)
            let link = call?.taskId.map { AppModel.exactTaskLink($0) } ?? "unstuck://today"
            return NotificationLog.Entry(id: "q_\(card.id)", kind: skippedKind,
                                         title: card.title.isEmpty ? "Call skipped" : card.title,
                                         body: card.body, deepLink: link, at: at)
        }
        let label = callLabel(fromBody: card.body)
        let call = label.flatMap { matchingCall(label: $0, cardAtMs: at, in: calls) }
        let title = label.map { "Unstuck called you about \($0)" } ?? (card.title.isEmpty ? "Unstuck called you" : card.title)
        let body: String
        if let call, !call.notes.isEmpty { body = call.notes.joined(separator: "\n") }
        else if let call, call.status == "missed" || call.status == "declined" { body = "You missed it — no notes on this one." }
        else { body = card.body }
        // The receipt lives on the SERIES editor's "Call me" section (C3).
        let link = call?.taskId.map { AppModel.exactTaskLink($0) } ?? "unstuck://today"
        return NotificationLog.Entry(id: "q_\(card.id)", kind: "call", title: title, body: body, deepLink: link, at: at)
    }

    /// Fold the server cards into the local log: newest first, capped, a
    /// server card that duplicates a local entry (same copy within 5 min, or
    /// both recaps within 5 min) dropped. A local "I called about X" and the
    /// server's "Unstuck called you about X" differ in copy on purpose — the
    /// local one is the miss, the card is the record — so both stay.
    static func mergeRecent(local: [NotificationLog.Entry], queue: [NotificationLog.Entry], cap: Int = cap) -> [NotificationLog.Entry] {
        let deduped = queue.filter { q in
            !local.contains { l in
                guard abs(l.at - q.at) < nearMs else { return false }
                if l.kind == "session_recap", q.kind == "session_recap" { return true }
                return l.title == q.title && l.body == q.body
            }
        }
        var seen = Set<String>()
        return (local + deduped)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.at > $1.at }
            .prefix(cap)
            .map { $0 }
    }
}
