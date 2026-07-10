// Per-task sharing — the iOS port of the web sharing surfaces:
//   • ShareModel   — the app-wide live state (tasks shared WITH me + my
//     outgoing badges / delegation map), the analogue of the web
//     `useSharedWithMe` + `useShareBadges` hooks. Refetches on the live
//     `unstuckCollabSharesChanged` signal CollabRealtime posts.
//   • ShareSheet   — share one task with circle members at a graded level
//     (Off / View / Partner / Assign), + invite a new person inline
//     (components/sharing/share-sheet.tsx).
//   • SharedWithYouGroup — the "quiet company" section: tasks others shared
//     with me, completable only at partner/assign (shared-with-me-group.tsx).
//   • DelegatedGroup     — tasks I assigned away; they leave my active list and
//     collect here with the assignee's name (delegated-group.tsx).
//
// All writes go through CircleClient's SECURITY DEFINER RPCs. Co-focus
// (CoFocusBar / PartnerPresence) is built on Supabase Realtime Presence via
// UnstuckSync's CoFocusChannel (M5).

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckDesign
import UnstuckSync

// MARK: - Live sharing state

/// App-wide per-task sharing state, bound to the shared CircleClient. A single
/// @MainActor @Observable instance (held by AppModel) so Today, Tasks, the share
/// sheet, and the Start-Next picker read one source of truth. Refetches on the
/// live shares-changed signal (a share added/updated/revoked, incoming or
/// outgoing) — mirrors the web hooks' SHARES_CHANGED subscription.
@MainActor
@Observable
final class ShareModel {
    private let client: CircleClient?
    /// Tasks other people have shared WITH me (drives "Shared with you").
    var sharedWithMe: [SharedWithMe] = []
    /// My OUTGOING shares, grouped by task id (drives row badges + delegation).
    var badges: [String: [ShareBadge]] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Fired after each refresh (badges may have changed) so AppModel can pump
    /// the share-session signal reducer — a session_start that was waiting on
    /// late-resolving badges fires once they land. Set by AppModel.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(client: CircleClient?) { self.client = client }

    /// Subscribe to the live shares-changed signal (once) + do a fetch. Called
    /// from every consuming surface's `.task`; idempotent on the subscribe,
    /// always re-fetches (so appearing after sign-in loads current state — the
    /// realtime channel only emits on an actual change, never on subscribe).
    func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .unstuckCollabSharesChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        Task { await refresh() }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Refetch both projections. Tolerant (each RPC returns [] on failure); a nil
    /// client (demo/UITest boot) degrades to empty.
    func refresh() async {
        guard let client else { sharedWithMe = []; badges = [:]; onChange?(); return }
        async let swm = client.tasksSharedWithMe()
        async let flat = client.shareBadges()
        sharedWithMe = await swm
        badges = CircleClient.shareBadgesByTask(await flat)
        onChange?()
    }

    /// taskId → assignee name for tasks shared at 'assign' (the Delegated group).
    var assignedOut: [String: String] { UnstuckCore.assignedOutMap(badges) }
    /// The set of task ids assigned away — excluded from Start-Next + the active
    /// list, surfaced in Delegated instead.
    var assignedOutIds: Set<String> { UnstuckCore.assignedOutIds(badges) }

    // MARK: mutations (refetch after so every surface updates immediately, not
    // only when the realtime round-trip lands)

    func shareTask(taskId: String, user: String, level: ShareLevel) async throws {
        try await client?.shareTask(taskId: taskId, user: user, level: level)
        await refresh()
    }

    func unshareTask(shareId: String) async {
        await client?.unshareTask(shareId: shareId)
        await refresh()
    }

    /// The shares currently on a task I own — drives the share sheet's picker.
    func sharesForTask(_ taskId: String) async -> [ShareForTask] {
        await client?.sharesForTask(taskId: taskId) ?? []
    }

    /// Complete/uncomplete a task shared with me (partner + assign only — the RPC
    /// rejects view). Throws on the server's `not_allowed`. On completion, pings
    /// the OWNER (share-notify task_done → shared_task_done push), 1:1 with the
    /// web use-task-shares.ts.
    func completeSharedTask(taskId: String, done: Bool) async throws {
        try await client?.setSharedTaskDone(taskId: taskId, done: done)
        if done { await client?.shareNotify(kind: "task_done", taskId: taskId) }
        await refresh()
    }

    /// Best-effort in-app + push notify after a share (task_share needs the
    /// recipient). Fire-and-forget, like the web.
    func notifyShare(taskId: String, recipientId: String) async {
        await client?.shareNotify(kind: "task_share", taskId: taskId, recipientId: recipientId)
    }

    /// Best-effort start/finish ping to everyone a task is shared with (the
    /// View-level promise). Called by AppModel's session-signal observer with
    /// kind session_start / session_end. Fire-and-forget, like the web.
    func notifySession(kind: String, taskId: String) async {
        await client?.shareNotify(kind: kind, taskId: taskId)
    }
}

// MARK: - Share sheet (per-task)

/// Share ONE task with circle members at a graded level, and invite a new person
/// inline. Mirrors components/sharing/share-sheet.tsx: a per-member Off/View/
/// Partner/Assign segmented picker, an inline "Add someone", and the explainer.
struct ShareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let task: TaskItem

    @State private var circle: CircleModel?
    @State private var shares: [ShareForTask] = []
    @State private var busyUser: String?

    // Inline invite-a-new-person state (so you never leave the task).
    @State private var inviting = false
    @State private var inviteEmail = ""
    @State private var inviteResult: InviteOutcome?
    @State private var inviteErr: String?
    @State private var copied = false

    private struct InviteOutcome { let added: Bool; let emailed: Bool; let link: String?; let email: String }

    /// nil == "Off"; else the granted level. Mirrors the web OPTIONS list.
    private let options: [(value: ShareLevel?, label: String)] = [
        (nil, "Off"), (.view, "View"), (.partner, "Partner"), (.assign, "Assign"),
    ]

    private var activeMembers: [CircleMember] {
        (circle?.members ?? []).filter { $0.status == "active" && $0.memberUserId != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(task.name.isEmpty ? "Untitled task" : task.name)
                        .font(UFont.sans(16, .semibold)).foregroundStyle(theme.palette.ink)

                    if !activeMembers.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(activeMembers) { m in memberRow(m) }
                        }
                    }

                    if inviting { invitePanel } else { addSomeoneButton }

                    if activeMembers.isEmpty && !inviting {
                        Text("You haven't shared with anyone yet. Add someone above to share this with them.")
                            .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                    }

                    explainer
                }
                .padding(20)
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Share this task").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            let c = circle ?? model.makeCircleModel()
            circle = c
            c.start()
            shares = await model.shareState.sharesForTask(task.id)
        }
        .onDisappear { circle?.stop() }
    }

    // MARK: member row + level picker

    private func memberRow(_ m: CircleMember) -> some View {
        let userId = m.memberUserId ?? ""
        let current: ShareLevel? = shares.first(where: { $0.recipientUserId == userId })?.level
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.memberName ?? "Member").font(UFont.sans(13, .semibold))
                    .foregroundStyle(theme.palette.ink).lineLimit(1)
                if let label = m.relationshipLabel {
                    Text(label).font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(options, id: \.label) { opt in
                    let selected = current == opt.value
                    Button { setLevel(userId, opt.value) } label: {
                        Text(opt.label)
                            .font(UFont.sans(11, .semibold))
                            .foregroundStyle(selected ? .white : theme.palette.ink2)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(selected ? theme.palette.primary : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busyUser == userId)
                    .opacity(busyUser == userId ? 0.5 : 1)
                }
            }
            .padding(2)
            .background(theme.palette.bg, in: Capsule())
            .overlay(Capsule().stroke(theme.palette.line2))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func setLevel(_ userId: String, _ next: ShareLevel?) {
        guard busyUser == nil else { return }
        busyUser = userId
        Task {
            if let next {
                try? await model.shareState.shareTask(taskId: task.id, user: userId, level: next)
                await model.shareState.notifyShare(taskId: task.id, recipientId: userId)
            } else if let existing = shares.first(where: { $0.recipientUserId == userId }) {
                await model.shareState.unshareTask(shareId: existing.shareId)
            }
            shares = await model.shareState.sharesForTask(task.id)
            busyUser = nil
        }
    }

    // MARK: inline invite

    private var addSomeoneButton: some View {
        Button { inviting = true; inviteResult = nil; inviteErr = nil } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("Add someone").font(UFont.sans(13, .semibold))
            }.foregroundStyle(theme.palette.primaryDeep)
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var invitePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = inviteResult {
                if r.added {
                    Text("✓ Added — pick their level above.")
                        .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.greenInk)
                } else if r.emailed {
                    Text("✓ Invite sent to \(r.email). Pick their level once they accept.")
                        .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.greenInk)
                } else if let link = r.link {
                    Text("Invite link ready\(copied ? " · copied!" : "")")
                        .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                    Text(link).font(UFont.mono(12)).foregroundStyle(theme.palette.ink2)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.palette.bg, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        .textSelection(.enabled)
                    Text(r.email.isEmpty ? "Send it to them — it's the only way in."
                         : "We couldn't email them — send this link instead.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                }
                HStack(spacing: 8) {
                    if let link = r.link {
                        Button { copy(link) } label: {
                            Text("Copy link").font(UFont.sans(13, .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(theme.palette.ink, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Button { inviting = false; inviteResult = nil } label: {
                        Text("Done").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(theme.palette.bg, in: Capsule())
                    }.buttonStyle(.plain)
                }
            } else {
                Text("Their email (optional)").font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                TextField("name@example.com", text: $inviteEmail)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("We'll email them the invite. Or leave it blank for a link you send yourself.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                if let inviteErr {
                    Text(inviteErr).font(UFont.sans(12)).foregroundStyle(theme.palette.coralDeep)
                }
                HStack(spacing: 8) {
                    Button { generateInvite() } label: {
                        Text(inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty ? "Generate link" : "Send invite")
                            .font(UFont.sans(13, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(theme.palette.ink, in: Capsule())
                    }.buttonStyle(.plain)
                    Button { inviting = false; inviteErr = nil } label: {
                        Text("Cancel").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(theme.palette.bg, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func generateInvite() {
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        inviteErr = nil
        Task {
            guard let circle else { inviteErr = "Sign in to invite people."; return }
            let r = await circle.invite(email: email.isEmpty ? nil : email)
            if r.ok == false, r.added != true, r.emailed != true, r.link == nil {
                inviteErr = r.error == "circle_full" ? "Your circle is full." : "Could not create invite."
                return
            }
            inviteResult = InviteOutcome(added: r.added == true, emailed: r.emailed == true, link: r.link, email: email)
            inviteEmail = ""
            if let link = r.link { copy(link) }
        }
    }

    private func copy(_ s: String) {
        UIPasteboard.general.string = s
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copied = false }
    }

    private var explainer: some View {
        (Text("View").font(UFont.sans(12, .semibold)) + Text(" — they see it + get pinged when you start & finish. ").font(UFont.sans(12))
         + Text("Partner").font(UFont.sans(12, .semibold)) + Text(" — either of you can start/complete & focus together. ").font(UFont.sans(12))
         + Text("Assign").font(UFont.sans(12, .semibold)) + Text(" — it becomes their task; you keep view.").font(UFont.sans(12)))
            .foregroundStyle(theme.palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Shared with you (recipient side)

/// Tasks others in your circle have shared WITH you. View is read-only company;
/// partner + assign add a completion checkbox (either side can tick it). A
/// partner-level row also shows live co-focus presence (PartnerPresence).
/// Renders nothing when empty. Mirrors components/tasks/shared-with-me-group.tsx.
struct SharedWithYouGroup: View {
    @Environment(\.uTheme) private var theme
    let items: [SharedWithMe]
    /// Builds a co-focus presence model for a partner-row taskId (nil on the
    /// demo/UITest boot → the presence indicator is simply omitted).
    var makeCoFocus: ((String) -> CoFocusModel)? = nil
    let onToggle: (String, Bool) -> Void   // (taskId, nextDone)

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                GroupHeader("Shared with you")
                ForEach(items) { s in row(s) }
            }
            .padding(.bottom, 8)
        }
    }

    private func row(_ s: SharedWithMe) -> some View {
        let canComplete = levelCanComplete(s.level)
        return HStack(spacing: 12) {
            if canComplete {
                Button { onToggle(s.taskId, !s.done) } label: {
                    Image(systemName: s.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18)).foregroundStyle(s.done ? theme.palette.green : theme.palette.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.done ? "Mark not done" : "Mark done")
            } else {
                // Spacer keeps view-only rows title-aligned with the others.
                Color.clear.frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(UFont.sans(14, .medium))
                    .strikethrough(s.done)
                    .foregroundStyle(s.done ? theme.palette.ink3 : theme.palette.ink).lineLimit(1)
                Text("from \(shortName(s.ownerName))").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                // Live co-focus: on a PARTNER row, show "focusing now" when the
                // owner is present + a "Sit with them" toggle (mirrors web
                // PartnerPresence). Only when a presence factory is available.
                if s.level == .partner, let makeCoFocus {
                    PartnerPresence(taskId: s.taskId, make: makeCoFocus)
                }
            }
            Spacer(minLength: 8)
            StatusChip(shareStatusLabel(s.level, done: s.done))
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(theme.palette.primarySoft, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// MARK: - Delegated (owner side)

/// Tasks YOU assigned away — they leave your active list and collect here, with
/// the assignee's name + a done/assigned chip. Tap opens the task. Mirrors
/// components/tasks/delegated-group.tsx (incl. the done-today aging).
struct DelegatedGroup: View {
    @Environment(\.uTheme) private var theme
    let tasks: [TaskItem]
    /// taskId → assignee name.
    let assignedOut: [String: String]
    /// When set, only show delegations in this life area (mirrors the list filter).
    var activeArea: String?
    /// Completed hand-offs linger only for today's win, then age out.
    var now: EpochMillis
    let onSelect: (TaskItem) -> Void

    private var rows: [TaskItem] {
        tasks.filter { t in
            guard assignedOut[t.id] != nil else { return false }
            if let activeArea, t.lifeArea != activeArea { return false }
            if t.done && !isCompletedToday(t, now: now) { return false }
            return true
        }
    }

    var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                GroupHeader("Delegated")
                ForEach(rows) { t in row(t) }
            }
            .padding(.bottom, 8)
        }
    }

    private func row(_ t: TaskItem) -> some View {
        Button { onSelect(t) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(UFont.sans(14, .medium))
                        .strikethrough(t.done)
                        .foregroundStyle(t.done ? theme.palette.ink3 : theme.palette.ink).lineLimit(1)
                    Text("assigned to \(shortName(assignedOut[t.id] ?? ""))")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                }
                Spacer(minLength: 8)
                StatusChip(t.done ? "done" : "assigned")
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.palette.primarySoft, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }.buttonStyle(.plain)
    }
}

// MARK: - Small shared pieces

/// Uppercase group header with a people glyph (matches the web group titles).
private struct GroupHeader: View {
    @Environment(\.uTheme) private var theme
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill").font(.system(size: 10))
            Text(title.uppercased()).font(UFont.sans(10.5, .bold)).tracking(0.6)
        }
        .foregroundStyle(theme.palette.ink3)
        .padding(.horizontal, 2)
    }
}

/// The quiet primary-tinted status chip on shared/delegated rows.
private struct StatusChip: View {
    @Environment(\.uTheme) private var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(UFont.sans(10.5, .bold)).foregroundStyle(theme.palette.primaryDeep)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(theme.palette.primarySoft, in: Capsule())
    }
}

/// The "shared with N" pill on my OWN task rows (view/partner badges — assigned
/// rows have moved to Delegated). Single recipient → their short name, else the
/// count. Mirrors components/tasks/list-row.tsx `shareWith`.
struct ShareWithPill: View {
    @Environment(\.uTheme) private var theme
    let names: [String]
    var body: some View {
        if names.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 3) {
                Image(systemName: "person.2.fill").font(.system(size: 9))
                Text(names.count == 1 ? shortName(names[0]) : "\(names.count)")
                    .font(UFont.sans(10, .bold))
            }
            .foregroundStyle(theme.palette.primaryDeep)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(theme.palette.primarySoft, in: Capsule())
            .accessibilityLabel("Shared with \(names.joined(separator: ", "))")
        }
    }
}

/// Owner/assignee display name — drop an email domain the way the web does
/// (`name.split('@')[0]`).
func shortName(_ raw: String) -> String {
    raw.split(separator: "@").first.map(String.init) ?? raw
}

// MARK: - Co-focus presence (M5)

/// SwiftUI-facing wrapper around UnstuckSync's CoFocusChannel — the iOS analogue
/// of the web `useCoFocusPresence` hook. Publishes the OTHER peers reactively;
/// idempotent start + self-cleaning stop (untracks + removes the channel).
@MainActor
@Observable
final class CoFocusModel {
    /// The other participants on the channel (never yourself), focusing-first.
    private(set) var peers: [CoFocusPeer] = []
    @ObservationIgnored private let channel: CoFocusChannel?
    @ObservationIgnored private var running = false

    init(client: CoFocusPresenceClient?, taskId: String, selfId: String?, selfName: String) {
        if let client, let selfId, !selfId.isEmpty {
            channel = client.channel(taskId: taskId, selfId: selfId, selfName: selfName)
        } else {
            channel = nil
        }
    }

    /// Join the channel (idempotent). `track` = how you appear: .focusing (owner),
    /// .here (recipient sitting in), or nil (observe only).
    func start(track: CoFocusState?) {
        guard !running, let channel else { return }
        running = true
        Task { [weak self] in
            await channel.start(track: track) { peers in
                Task { @MainActor in self?.peers = peers }
            }
        }
    }

    /// Flip your presence in place (recipient "Sit with them" on/off) — no
    /// channel teardown.
    func setTrack(_ track: CoFocusState?) {
        guard running, let channel else { return }
        Task { await channel.setTrack(track) }
    }

    /// Leave + tear down (call on disappear/finish — no leaks).
    func stop() {
        peers = []
        guard running, let channel else { running = false; return }
        running = false
        Task { await channel.stop() }
    }
}

/// OWNER floating pill — "someone's here with you" while focusing a partner-
/// shared task. Renders only when a peer is actually present (mirrors the web
/// CoFocusBar). The caller passes the live `peers` from its CoFocusModel.
struct CoFocusBar: View {
    @Environment(\.uTheme) private var theme
    let peers: [CoFocusPeer]

    var body: some View {
        if peers.isEmpty {
            EmptyView()
        } else {
            let anyFocusing = peers.contains { $0.state == .focusing }
            HStack(spacing: 9) {
                CoFocusPulseDot()
                Text("\(coFocusPeopleLabel(peers)) \(coFocusPresenceVerb(peers, anyFocusing: anyFocusing))")
                    .font(UFont.sans(12.5, .semibold)).foregroundStyle(theme.palette.ink)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(theme.palette.surface, in: Capsule())
            .overlay(Capsule().stroke(theme.palette.line))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(coFocusPeopleLabel(peers)) \(coFocusPresenceVerb(peers, anyFocusing: anyFocusing))")
        }
    }
}

/// RECIPIENT inline presence on a partner "shared with you" row. Observes
/// whether the owner is focusing right now, and offers "Sit with them" to appear
/// alongside them (tracks .here). Joins on appear (observe-only), leaves on
/// disappear. Mirrors the web PartnerPresence.
struct PartnerPresence: View {
    @Environment(\.uTheme) private var theme
    let taskId: String
    let make: (String) -> CoFocusModel
    @State private var cf: CoFocusModel?
    @State private var sitting = false

    var body: some View {
        let ownerFocusing = cf?.peers.contains { $0.state == .focusing } ?? false
        Group {
            // Nothing to show until the owner is focusing or you've chosen to sit in.
            if ownerFocusing || sitting {
                HStack(spacing: 8) {
                    if ownerFocusing {
                        HStack(spacing: 5) {
                            CoFocusPulseDot()
                            Text("focusing now").font(UFont.sans(11.5, .semibold))
                                .foregroundStyle(theme.palette.greenInk)
                        }
                    }
                    Button {
                        sitting.toggle()
                        cf?.setTrack(sitting ? .here : nil)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "person.2.fill").font(.system(size: 10))
                            Text(sitting ? "Sitting with them" : "Sit with them")
                                .font(UFont.sans(11, .bold))
                        }
                        .foregroundStyle(sitting ? .white : theme.palette.primaryDeep)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(sitting ? theme.palette.primary : theme.palette.primarySoft, in: Capsule())
                    }.buttonStyle(.plain)
                }
                .padding(.top, 3)
            }
        }
        .task {
            guard cf == nil else { return }
            let m = make(taskId)
            m.start(track: nil)   // observe only until "Sit with them"
            cf = m
        }
        // Nil the ref (not just stop) so a scroll-away → scroll-back inside the
        // LazyVStack rebuilds a fresh channel; leaving `cf` non-nil would make
        // `.task`'s `guard cf == nil` block the restart (presence dies), or race
        // the async removeChannel of the old `cofocus:<taskId>`. Mirrors the
        // owner side (FocusFeature: `coFocus?.stop(); coFocus = nil`).
        .onDisappear { cf?.stop(); cf = nil }
    }
}

/// A calm pulsing green presence dot (mirrors the web `PulseDot`).
struct CoFocusPulseDot: View {
    @Environment(\.uTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle().fill(theme.palette.green)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse ? 1.0 : 0.72)
            .opacity(pulse ? 1.0 : 0.55)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .accessibilityHidden(true)
    }
}

/// "Ann" from "Ann Smith" / "ann@x.com" (mirrors the web `firstName`).
func coFocusFirstName(_ name: String) -> String {
    let n = name.isEmpty ? "Someone" : name
    return n.split(whereSeparator: { $0 == " " || $0 == "@" }).first.map(String.init) ?? n
}

/// "Ann" / "Ann & Bob" / "Ann & 2 others" (mirrors the web `peopleLabel`).
func coFocusPeopleLabel(_ peers: [CoFocusPeer]) -> String {
    let names = peers.map { coFocusFirstName($0.name) }
    if names.count == 1 { return names[0] }
    if names.count == 2 { return "\(names[0]) & \(names[1])" }
    if names.isEmpty { return "Someone" }
    return "\(names[0]) & \(names.count - 1) others"
}

/// "is focusing with you" / "is here with you" / "are here with you".
func coFocusPresenceVerb(_ peers: [CoFocusPeer], anyFocusing: Bool) -> String {
    if peers.count == 1 { return anyFocusing ? "is focusing with you" : "is here with you" }
    return "are here with you"
}
