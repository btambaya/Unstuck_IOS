// In-app Notification Center — the bell next to the avatar (spec 10 §1.9;
// 1:1 with Android NotificationCenterScreen). Two sections: "Upcoming"
// (scheduled task reminders in the next 2 days, computed live from the
// blocks via the pure upcomingReminders) and "Recent" (the persisted
// NotificationLog, newest first, MERGED with the server's `notification_queue`
// cards the way the web's useNotificationQueue + mergeRecent do it). The
// cards are every moment the bell can show (`NotificationQueueCards.moments`):
// a call the server rang ("Unstuck called you about X", with the call's notes
// from the local call_requests mirror), recaps, the brief, and every sharing
// moment — so a push swiped out of the tray still leaves its record here, and
// one this phone already logged is not listed twice. Tapping a task-linked row
// opens that task; any other deep link (a card's own `deep_link`, else its
// moment's destination) routes through the app's deep-link handler, as a push
// tap does. Opening the center marks everything seen (clears the unread badge).

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
    /// The server's cards (notification_queue, `NotificationQueueCards.moments`), as bell entries.
    @State private var serverCards: [NotificationLog.Entry] = []
    /// When the bell was last opened BEFORE this open (the .task below marks
    /// everything seen at once) — a server card newer than this is unread.
    @State private var seenAtOpen: Double = NotificationLog.shared.lastSeenMs
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
                    let recent = NotificationQueueCards.mergeRecent(local: log.items, queue: serverCards)
                    if recent.isEmpty {
                        Text("Nothing yet. Reminders and recaps will show up here.")
                            .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(recent) { n in
                            card(dot: dotColor(n), title: n.title,
                                 meta: "\(n.body)  ·  \(relPast(now - n.at))",
                                 action: tapAction(for: n),
                                 kindLabel: notificationKindLabel(n.kind))
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
        .task { await loadServerCards() }
        .onChange(of: scenePhase) { _, phase in
            // postgres_changes has no replay and this screen holds no channel:
            // a return to the foreground while it is open is the catch-up.
            if phase == .active { Task { await loadServerCards() } }
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

    /// The server's cards for every moment the bell shows. A `call` card is
    /// matched to its call in the local mirror by label (the card carries no
    /// id) so the row shows the notes that were read back; every other card
    /// is shown as the server wrote it. Best-effort — offline keeps what was
    /// there.
    private func loadServerCards() async {
        guard let coord = model.coordinator else { return }
        guard let cards = try? await coord.notifications.queueCards(moments: NotificationQueueCards.moments) else { return }
        let calls = (try? coord.callsMirror.all()) ?? []
        serverCards = cards.map { NotificationQueueCards.entry(from: $0, calls: calls) }
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

    /// A server card that isn't a call's: coral only while unread (newer than
    /// the last open), otherwise its kind's tone with coral folded to ink —
    /// the colour rules. Call cards and the local log keep their accents.
    private func dotColor(_ n: NotificationLog.Entry) -> Color {
        guard NotificationQueueCards.isQuietCard(n) else { return accentColor(n.kind) }
        if n.at > seenAtOpen { return theme.palette.coral }
        return notificationAccent(kind: n.kind) == .coral ? theme.palette.ink2 : accentColor(n.kind)
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


/// The server's in-app cards → bell entries (pure; tested). Web parity:
/// `entryFromRow` + `mergeRecent` in lib/use-notification-queue.ts.
enum NotificationQueueCards {
    static let callMoment = "call"

    /// Every notification_queue moment the bell reads (the senders'
    /// `moment`s — notify.ts callers + the writeCard senders). NOT the task
    /// reminders (`task_reminder` / `task_starting`): this phone rings its
    /// own reminders locally, in its own words, and lists what's coming under
    /// Upcoming — the server's card would double every one of them.
    static let moments = [
        callMoment, "session_recap", "morning_brief",
        "task_share", "shared_task_done", "shared_session_start", "shared_session_end",
        "collection_share", "collection_activity", "collection_task_done", "collection_late",
        "circle_invite", "invite_claimed",
    ]

    /// moment → the bell's kind: the `kind` the same event's push carries,
    /// so the row reads (label, dot) like the push the phone logged. The
    /// collection senders push every list moment as `collection_share`.
    static func kind(forMoment moment: String) -> String {
        moment.hasPrefix("collection") ? "collection_share" : moment
    }

    /// Where a card with no `deep_link` of its own goes — its moment's
    /// destination, the one its push uses when it has no id to carry.
    static func fallbackLink(forMoment moment: String) -> String {
        switch moment {
        case "session_recap": return "unstuck://today/recap"
        case "morning_brief": return "unstuck://today/brief"
        case "task_share", "shared_task_done", "shared_session_start", "shared_session_end":
            return "unstuck://tasks"
        case "circle_invite", "invite_claimed": return "unstuck://settings"
        default: return moment.hasPrefix("collection") ? "unstuck://collections" : "unstuck://today"
        }
    }

    /// A server card other than a call's (those keep their own dot).
    static func isQuietCard(_ e: NotificationLog.Entry) -> Bool {
        e.id.hasPrefix("q_") && e.kind != "call" && e.kind != skippedKind
    }
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

    /// A queue row → the bell's entry. Any moment but `call`: the card as
    /// written, its kind the push's, its link its own `deep_link` (an
    /// `unstuck://` one) else the moment's destination. A `call` card: kind
    /// `call`, "Unstuck called you about <label>", the call's notes as the
    /// body (or the card's own copy when no call matches), the anchored task
    /// as the destination (else Today).
    static func entry(from card: NotificationQueueCard, calls: [CallRequest]) -> NotificationLog.Entry {
        let at = Time.parseMillis(card.createdAt) ?? 0
        guard card.moment == callMoment else {
            let own = card.deepLink.flatMap { $0.hasPrefix("unstuck://") ? $0 : nil }
            return NotificationLog.Entry(id: "q_\(card.id)", kind: kind(forMoment: card.moment),
                                         title: card.title, body: card.body,
                                         deepLink: own ?? fallbackLink(forMoment: card.moment), at: at)
        }
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
    /// server card that duplicates a push this phone logged dropped. A card
    /// and a local entry within 5 min are one event when they have the same
    /// copy, are both recaps, or are the same kind with the same id-carrying
    /// link (`unstuck://collections/<id>`, `unstuck://task/<id>` — the list
    /// update's push is a clipped digest of its card, so the copy differs).
    /// One local entry answers for ONE card: two events the push cooldown
    /// folded into one push still leave the second card. A local "I called
    /// about X" and the server's "Unstuck called you about X" differ in copy
    /// on purpose — the local one is the miss, the card is the record — so
    /// both stay.
    static func mergeRecent(local: [NotificationLog.Entry], queue: [NotificationLog.Entry], cap: Int = cap) -> [NotificationLog.Entry] {
        var used = Set<Int>()
        let deduped = queue.filter { q in
            let hit = local.indices.first { i in
                !used.contains(i) && sameEvent(local[i], q)
            }
            guard let hit else { return true }
            used.insert(hit)
            return false
        }
        var seen = Set<String>()
        return (local + deduped)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.at > $1.at }
            .prefix(cap)
            .map { $0 }
    }

    static func sameEvent(_ l: NotificationLog.Entry, _ q: NotificationLog.Entry) -> Bool {
        guard abs(l.at - q.at) < nearMs else { return false }
        if l.kind == "session_recap", q.kind == "session_recap" { return true }
        if l.title == q.title && l.body == q.body { return true }
        guard l.kind == q.kind, let link = q.deepLink, link == l.deepLink else { return false }
        return link.hasPrefix("unstuck://collections/") || link.hasPrefix("unstuck://task/")
    }
}

/// Human-readable name for a notification's color-coded kind, so VoiceOver
/// conveys the meaning that's otherwise only in the dot's accent color. The
/// card reads it as "<label>: <title>".
///
/// A kind only names the CHANNEL, not the event: `collection_share` carries a
/// new share ("Maya shared Groceries") but also a shared list's updates
/// ("Maya updated Groceries"), "Maya finished Milk" and the late-item nudges.
/// Labelling all of them "List shared with you" told a VoiceOver user every
/// edit was a fresh share; the neutral "Shared list" lets the title say what
/// happened.
func notificationKindLabel(_ kind: String) -> String {
    switch kind {
    case "paused_checkin": return "Paused check-in"
    case "atstart": return "Starting now"
    case "drifted": return "Drifted"
    case "session_recap": return "Session recap"
    case "morning_brief": return "Morning brief"
    case "evening_preview": return "Evening preview"
    case "daily_nudge": return "Daily nudge"
    case "task_share": return "Shared with you"
    case "collection_share": return "Shared list"
    case "invite_claimed": return "Someone joined"
    case "circle_invite": return "Added to a circle"
    case "shared_session_start", "shared_session_end": return "Shared session"
    case "shared_task_done": return "Shared task done"
    case "call", "call_missed": return "Call from Unstuck"
    case NotificationQueueCards.skippedKind: return "Call skipped"
    default: return "Notification"
    }
}
