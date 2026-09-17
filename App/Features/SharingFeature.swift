// Per-task sharing — the iOS port of the web sharing surfaces:
//   • ShareModel   — the app-wide live state (tasks shared WITH me + my
//     outgoing badges / delegation map), the analogue of the web
//     `useSharedWithMe` + `useShareBadges` hooks. Refetches on the live
//     `unstuckCollabSharesChanged` signal CollabRealtime posts.
//   • (sharing a task lives in ShareScreen.swift — the ONE Share screen for
//     tasks + collections since unified sharing v1; the old per-task
//     ShareSheet is gone.)
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
    /// The OWNER-scheduled blocks of tasks shared with me, by date — the
    /// calendar's read-only "shared" layer (shared_task_blocks, migration 052).
    /// A small per-window cache: each calendar surface asks for its visible
    /// range (`loadSharedBlocks`), which fetches only when the window isn't
    /// already covered. The cache is INVALIDATED (every loaded window
    /// re-read) on the shares-changed signal and on every foreground resync
    /// (`refresh()`), so an owner-side reschedule / completion shows up the
    /// next time the app comes back — the realtime channel only carries
    /// task_shares / trusted_circle rows (an owner moving a cal_block never
    /// touches those), so without the foreground re-read the dashed block
    /// stayed at its old slot until a relaunch.
    private(set) var sharedBlocks = SharedBlocksCache()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    /// Bumped on every refetch — a cheap "the shared layer changed" signal
    /// the tests + surfaces can key on.
    private(set) var revision = 0
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
        if foregroundObserver == nil {
            // Foreground resync: the owner may have rescheduled / finished
            // while we were in the background (nothing live tells us).
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        Task { await refresh() }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
    }

    /// Drop every cached shared-block window; the next `loadSharedBlocks`
    /// (or `refresh`) fetches fresh. Used when the layer is known stale.
    func invalidateSharedBlocks() { sharedBlocks.clear() }

    /// Refetch both projections. Tolerant (each RPC returns [] on failure); a nil
    /// client (demo/UITest boot) degrades to empty.
    func refresh() async {
        guard let client else { sharedWithMe = []; badges = [:]; sharedBlocks.clear(); onChange?(); return }
        async let swm = client.tasksSharedWithMe()
        async let flat = client.shareBadges()
        sharedWithMe = await swm
        badges = CircleClient.shareBadgesByTask(await flat)
        revision += 1
        onChange?()
        // Invalidate the shared-block cache: re-read every calendar window
        // we've served, so an owner's reschedule / completion that happened
        // while we weren't looking (a share change, a foreground) lands on
        // my calendar without a relaunch.
        for w in sharedBlocks.windows {
            let rows = await client.sharedTaskBlocks(from: w.from, to: w.to)
            sharedBlocks.store(w, blocks: rows)
        }
    }

    /// Make sure the shared-block layer covers [from, to] ('YYYY-MM-DD',
    /// inclusive; ≤ 62 days — the server's cap). No-op when an already-loaded
    /// window covers it; otherwise ONE RPC, stored under that window. A nil
    /// client (demo/UITest boot) leaves the layer empty.
    func loadSharedBlocks(from: String, to: String) async {
        let w = SharedBlocksCache.Window(from: from, to: to)
        guard let client, !sharedBlocks.covers(w) else { return }
        let rows = await client.sharedTaskBlocks(from: from, to: to)
        sharedBlocks.store(w, blocks: rows)
    }

    /// Shared blocks on a day (skipped ones dropped, sorted by start) — O(1)
    /// once the window is loaded; [] before that / with no shares.
    func sharedBlocks(on iso: String) -> [SharedBlock] { sharedBlocks.blocks(on: iso) }

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
        // Optimistic, stamp included: the row must move views (out of Today,
        // into Completed) the instant it's ticked, not only after the refetch —
        // and the visibility rule needs a completion time to place it. Mirrors
        // the web useSharedWithMe.setDone. On failure we re-read the truth.
        let stamp = done ? AppModel.isoNow() : nil
        sharedWithMe = sharedWithMe.map { s in
            guard s.taskId == taskId else { return s }
            var next = s
            next.done = done
            next.completedAt = stamp
            return next
        }
        do {
            try await client?.setSharedTaskDone(taskId: taskId, done: done)
        } catch {
            await refresh()
            throw error
        }
        if done { await client?.shareNotify(kind: "task_done", taskId: taskId) }
        await refresh()
    }

    /// Best-effort in-app + push notify after a share (task_share needs the
    /// recipient). Fire-and-forget, like the web.
    func notifyShare(taskId: String, recipientId: String) async {
        await client?.shareNotify(kind: "task_share", taskId: taskId, recipientId: recipientId)
    }

    /// The read-only detail of a task shared WITH me (T1) — the only window a
    /// recipient has into the task's contents. nil client / failure → nil.
    func sharedTaskDetail(taskId: String) async -> SharedTaskDetail? {
        await client?.sharedTaskDetail(taskId: taskId)
    }

    /// Accrue focus seconds onto the shared task's exactly-once ledger (T3 /
    /// one true shared session — owner included, migration 047); no-ops for ≤ 0.
    /// `sessionId` = the live focus session's id; the RPC is idempotent per that
    /// id (migration 046), so a re-fire from any finalize path never double-counts.
    /// SURFACES the outcome so AppModel.logSharedFocusDurable can queue a retry
    /// on failure / fall back on not_allowed; a nil client (demo boot / signed
    /// out) reports `.failure` — "can't run" is queued like any other failure.
    @discardableResult
    func logSharedFocus(taskId: String, actualSec: Int, sessionId: String) async -> SharedFocusLogResult {
        await client?.logSharedFocus(taskId: taskId, actualSec: actualSec, sessionId: sessionId) ?? .failure
    }

    /// Best-effort start/finish ping to everyone a task is shared with (the
    /// View-level promise). Called by AppModel's session-signal observer with
    /// kind session_start / session_end. Fire-and-forget, like the web.
    func notifySession(kind: String, taskId: String) async {
        await client?.shareNotify(kind: kind, taskId: taskId)
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
    /// Which list this group is sitting in — decides where a share belongs:
    /// placed by the owner's next live block (Today / Upcoming / Backlog), and
    /// once COMPLETED gone from Today, today's win still in All, and under
    /// Completed from then on — exactly like the user's own tasks.
    var mode: ShareViewMode = .all
    /// When set, only show shares in this life area (mirrors the list filter
    /// + DelegatedGroup). nil = no filter.
    var activeArea: String? = nil
    /// Builds a co-focus presence model for a partner-row taskId (nil on the
    /// demo/UITest boot → the presence indicator is simply omitted).
    var makeCoFocus: ((String) -> CoFocusModel)? = nil
    /// The LIVE session's task id: its row skips PartnerPresence entirely.
    /// I'm IN that session (the live card shows it), and — because supabase-
    /// swift dedupes channels by topic — an observe-join here would share the
    /// underlying channel with AppModel's session-lifetime one, and its leave
    /// would untrack/unsubscribe the live channel out from under it.
    var suppressPresenceTaskId: String? = nil
    let onToggle: (String, Bool) -> Void   // (taskId, nextDone)

    /// The row the recipient tapped to OPEN the read-only detail (T1).
    @State private var detailTarget: SharedDetailTarget?

    var body: some View {
        // A shared task follows the same placement + completion rules as your
        // own tasks — SharedTaskVisibility (port of lib/shared-task-visibility.ts,
        // placed by the owner's next block since migration 052).
        let today = Clock.todayISO()
        let visible = visibleShares(items, mode: mode, now: Date().timeIntervalSince1970 * 1000,
                                    todayISO: today, activeArea: activeArea)
        // Keep the container alive while the detail sheet is open even if its
        // row just filtered out (completing the last share from inside the
        // sheet) — tearing the host down would yank the sheet away mid-read.
        if visible.isEmpty && detailTarget == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !visible.isEmpty {
                    GroupHeader(mode == .completed ? "Shared with you · completed" : "Shared with you")
                    ForEach(visible) { s in row(s, todayISO: today) }
                }
            }
            .padding(.bottom, 8)
            // Read-only detail — the only window a recipient has into the task
            // (steps, area, estimate, due) + level-appropriate actions (T1/T3).
            .sheet(item: $detailTarget) { target in
                SharedTaskDetailSheet(taskId: target.id, block: target.block)
            }
        }
    }

    private func row(_ s: SharedWithMe, todayISO: String) -> some View {
        let canComplete = levelCanComplete(s.level)
        // The owner's slot, in words — "Sat 04:30 · 45m · from Anna" — so a
        // shared task reads like your own scheduled row; just "from Anna" when
        // nothing is planned (or against a pre-052 server).
        let slot = sharedSlotLabel(nextDate: s.nextDate, nextStartTime: s.nextStartTime,
                                   nextDurationMinutes: s.nextDurationMinutes, nextDone: s.nextDone,
                                   nextStartAt: s.nextStartAt, todayISO: todayISO)
        let subtitle = slot.map { "\($0) · from \(shortName(s.ownerName))" } ?? "from \(shortName(s.ownerName))"
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
                Text(subtitle).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3).lineLimit(1)
                // Live co-focus: on a PARTNER row, show "focusing now" when the
                // owner is present + a "Sit with them" toggle (mirrors web
                // PartnerPresence). Only when a presence factory is available.
                if s.level == .partner, s.taskId != suppressPresenceTaskId, let makeCoFocus {
                    PartnerPresence(taskId: s.taskId, make: makeCoFocus)
                }
            }
            Spacer(minLength: 8)
            StatusChip(shareStatusLabel(s.level, done: s.done))
            // Affordance: the row opens the read-only detail (the checkbox +
            // "Sit with them" stay independent tap targets beneath the row tap).
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.ink3)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(theme.palette.primarySoft, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle())
        .onTapGesture { detailTarget = SharedDetailTarget(id: s.taskId) }
        .accessibilityHint("Opens the shared task")
    }
}

/// Identifiable wrapper so a tapped shared-task id can drive `.sheet(item:)`
/// (the shared group rows + the calendar's shared blocks). A calendar tap
/// passes the BLOCK it landed on, so the detail's "Planned …" line shows
/// THAT slot (the one the user is looking at) rather than the projection's
/// next block — which differs for a task with several blocks, or a past one.
struct SharedDetailTarget: Identifiable, Equatable {
    let id: String
    var block: SharedBlock? = nil
    init(id: String, block: SharedBlock? = nil) {
        self.id = id
        self.block = block
    }
}

// MARK: - Shared task read-only detail (T1) + shared focus entry (T3)

/// The read-only detail of a task shared WITH me, built from shared_task_detail
/// (migration 045) — the ONLY window a recipient has into the task's contents
/// (RLS blocks the raw row). Shows the title, "from <owner>", life area, estimate,
/// due, steps/subtasks, and tags, plus a level chip. Level-appropriate actions:
/// partner/assign can Complete + start a real focus session that reflects onto the
/// owner's task (T3); VIEW is strictly read-only. Never edits the owner's task.
struct SharedTaskDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let taskId: String
    /// The calendar block the sheet was opened from, when it was — its slot
    /// is what the "Planned …" line reads (nil: the projection's next block).
    var block: SharedBlock? = nil

    @State private var detail: SharedTaskDetail?
    @State private var loaded = false
    /// Set when the recipient taps Focus: we dismiss THIS sheet first, then start
    /// the shared focus on `onDisappear` (the focus cover lives on another host, so
    /// it can't present while this sheet is still dismissing).
    @State private var pendingFocus: SharedTaskDetail?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let d = detail {
                    content(d)
                } else if !loaded {
                    ProgressView().padding(.top, 60)
                } else {
                    Text("Couldn't load this shared task.")
                        .font(UFont.sans(14)).foregroundStyle(theme.palette.ink2)
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity)
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Shared task").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            if detail == nil { detail = await model.shareState.sharedTaskDetail(taskId: taskId) }
            loaded = true
        }
        // Start the shared focus AFTER this sheet is gone (cover on another host).
        .onDisappear { if let d = pendingFocus { model.beginSharedFocus(d) } }
    }

    @ViewBuilder
    private func content(_ d: SharedTaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title + the level chip.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(d.name.isEmpty ? "Untitled task" : d.name)
                    .font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusChip(shareStatusLabel(d.level, done: d.done))
            }
            Text("from \(shortName(d.ownerName))")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)

            // The owner's schedule (migration 052 / 053): "Planned Sat, Sep 12 ·
            // 04:30 · 45m" in MY zone — read-only; the recipient never moves the
            // owner's block. Opened from a calendar block → that block's slot.
            if let planned = Self.plannedLabel(detail: d, block: block) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                    Text(planned).font(UFont.sans(12.5, .medium))
                }
                .foregroundStyle(theme.palette.primaryDeep)
                .accessibilityElement(children: .combine)
            }

            // Meta chips: life area · estimate · due (a short, fixed set).
            HStack(spacing: 6) {
                ForEach(Array(metaChips(d).enumerated()), id: \.offset) { _, m in QuietChip(m) }
            }

            // Steps / subtasks (objectives).
            if !d.objectives.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Steps")
                    ForEach(Array(d.objectives.enumerated()), id: \.offset) { _, o in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: o.done == true ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14))
                                .foregroundStyle(o.done == true ? theme.palette.green : theme.palette.ink3)
                            Text(o.text).font(UFont.sans(14))
                                .strikethrough(o.done == true)
                                .foregroundStyle(o.done == true ? theme.palette.ink3 : theme.palette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            // Tags — horizontal scroll so a long set never breaks the layout.
            if !d.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(d.tags, id: \.self) { QuietChip("#\($0)") } }
                }
            }

            // Level-appropriate actions — partner/assign can act; view is read-only.
            if levelCanComplete(d.level) {
                actions(d)
            } else {
                Text("You're following this task. You'll see when \(shortName(d.ownerName)) starts and finishes it.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    /// The "Planned …" / "Done …" line: the tapped calendar block's slot when
    /// the sheet was opened from one, else the projection's next block —
    /// both rendered in the recipient's zone when an instant is available.
    static func plannedLabel(detail d: SharedTaskDetail, block: SharedBlock?, timeZone: TimeZone = .current) -> String? {
        if let b = block { return sharedBlockPlannedLabel(b, timeZone: timeZone) }
        return sharedPlannedLabel(nextDate: d.nextDate, nextStartTime: d.nextStartTime,
                                  nextDurationMinutes: d.nextDurationMinutes, nextDone: d.nextDone,
                                  nextStartAt: d.nextStartAt, timeZone: timeZone)
    }

    private func metaChips(_ d: SharedTaskDetail) -> [String] {
        var out: [String] = []
        if let area = d.lifeArea, !area.isEmpty { out.append(area) }
        out.append("\(d.estimateMin)m")
        if let due = d.dueAt, let label = Self.dueLabel(due) { out.append("due \(label)") }
        return out
    }

    @ViewBuilder
    private func actions(_ d: SharedTaskDetail) -> some View {
        HStack(spacing: 10) {
            // Complete / reopen (shared_task_set_done, partner/assign only).
            // Optimistic, with a ROLLBACK: shared_task_set_done can reject
            // (e.g. the owner revoked the share, or offline) — reverting the flip
            // keeps the chip honest instead of showing a "done" that never landed.
            Button {
                let next = !d.done
                detail?.done = next          // optimistic
                Task {
                    do { try await model.shareState.completeSharedTask(taskId: d.taskId, done: next) }
                    catch { detail?.done = !next }   // revert on RPC failure
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: d.done ? "arrow.uturn.left" : "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text(d.done ? "Reopen" : "Complete").font(UFont.sans(13, .semibold))
                }
                .foregroundStyle(d.done ? theme.palette.ink2 : .white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(d.done ? AnyShapeStyle(theme.palette.bg2) : AnyShapeStyle(theme.palette.primary), in: Capsule())
            }.buttonStyle(.plain)

            // Focus with them (partner) / Focus (assign) — a real session whose
            // time reflects onto the owner's task via log_shared_focus (T3).
            Button {
                pendingFocus = d
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "timer").font(.system(size: 12, weight: .semibold))
                    Text(sharedFocusActionLabel(d.level)).font(UFont.sans(13, .semibold))
                }
                .foregroundStyle(theme.palette.primaryDeep)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(theme.palette.primarySoft, in: Capsule())
            }.buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    /// "Jun 14" from an ISO due timestamp (best-effort; drops on a bad parse).
    private static func dueLabel(_ iso: String) -> String? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? {
            f.formatOptions = [.withInternetDateTime]; return f.date(from: iso)
        }()
        guard let date else { return nil }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        return out.string(from: date)
    }
}

/// A small quiet capsule chip (life area / estimate / due / tag) in the detail.
private struct QuietChip: View {
    @Environment(\.uTheme) private var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(UFont.sans(11.5, .medium)).foregroundStyle(theme.palette.ink2)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(theme.palette.bg2, in: Capsule())
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
    /// Serializes every channel op (start / stop / endSession) behind every
    /// other co-focus op, app-wide — set by AppModel.makeCoFocusModel to
    /// AppModel.chainCoFocusOp. supabase-swift dedupes channels BY TOPIC, so an
    /// unordered stop() from one surface (e.g. a PartnerPresence row) could
    /// otherwise unsubscribe another surface's fresh channel. The chain head
    /// is read + re-registered at ENQUEUE time on the main actor — never a
    /// stale task captured at some earlier call site.
    @ObservationIgnored var chainOp: (@MainActor (@escaping @MainActor () async -> Void) -> Task<Void, Never>)?
    /// Consulted at teardown EXECUTION time: true ⇒ the topic is currently
    /// owned by AppModel's session-lifetime channel, so tear down with
    /// `detach()` (release our callbacks, keep the deduped channel subscribed)
    /// instead of `stop()` (untrack + removeChannel — which would kill the
    /// live channel out from under it).
    @ObservationIgnored var preserveTopicOnStop: (@MainActor () -> Bool)?

    init(client: CoFocusPresenceClient?, taskId: String, selfId: String?, selfName: String) {
        if let client, let selfId, !selfId.isEmpty {
            channel = client.channel(taskId: taskId, selfId: selfId, selfName: selfName)
        } else {
            channel = nil
        }
    }

    /// Enqueue an op on the app-wide co-focus chain (FIFO with every other
    /// start/stop/probe); falls back to an unchained Task when no chain was
    /// injected (demo/UITest boot).
    @discardableResult
    private func run(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        chainOp?(op) ?? Task { @MainActor in await op() }
    }

    /// Join the channel (idempotent). `track` = how you appear: .focusing (owner),
    /// .here (recipient sitting in), or nil (observe only). `timer` carries the
    /// live focus-session state so focusing peers can render the shared timer
    /// (T1b); `shared` the one-true-shared-session control snapshot
    /// (sessionId/rev/atMs) riding along it; `onControl` receives every incoming
    /// timer message for the LWW reducer; `suppressControls` binds in the
    /// DIVERGED state (offline & reconnect convergence); `onDeliveryFailure`
    /// reports an undeliverable control broadcast; `onSocketDown` reports the
    /// realtime socket dropping under a live shared session (socket-down alone
    /// marks divergence); `onDivergedAlone` reports the diverged re-exchange
    /// grace expiring with nobody to converge with (the app clears the flag +
    /// re-announces). `rejoin` marks a REBIND of an EXISTING session (Rejoin
    /// reconciliation v2): the join is hello-only — identity presence, NO
    /// state re-announce — and the channel arms `rejoinPending`, surfaced per
    /// message through `onControl`'s Bool (true ⇒ the first same-session
    /// exchange after a rejoin — the app widens its most-ahead gate to it).
    /// The join runs on the co-focus chain, so it lands strictly after any
    /// in-flight teardown of the same topic.
    func start(track: CoFocusState?, timer: CoFocusTimerState? = nil,
               shared: SharedSessionState? = nil,
               suppressControls: Bool = false,
               rejoin: Bool = false,
               onControl: (@Sendable (SharedSessionMsg, Bool) -> Void)? = nil,
               onDeliveryFailure: (@Sendable (String) -> Void)? = nil,
               onSocketDown: (@Sendable (String) -> Void)? = nil,
               onDivergedAlone: (@Sendable (String) -> Void)? = nil) {
        guard !running, let channel else { return }
        running = true
        run { [weak self] in
            await channel.start(track: track, timer: timer, shared: shared,
                                suppressControls: suppressControls,
                                rejoin: rejoin,
                                onPeers: { peers in
                                    Task { @MainActor in self?.peers = peers }
                                },
                                onControl: onControl,
                                onDeliveryFailure: onDeliveryFailure,
                                onSocketDown: onSocketDown,
                                onDivergedAlone: onDivergedAlone)
        }
    }

    /// Flip your presence in place (recipient "Sit with them" on/off) — no
    /// channel teardown. Chained so it can't race an in-flight join.
    func setTrack(_ track: CoFocusState?, timer: CoFocusTimerState? = nil) {
        guard running, let channel else { return }
        run { await channel.setTrack(track, timer: timer) }
    }

    /// Re-broadcast the focus timer (pause / resume / extend / start) so peers'
    /// shared timers update live (T1b). `shared` carries the full control
    /// snapshot (rev+1 by the caller). No-op unless tracking as `.focusing`.
    func updateTimer(_ timer: CoFocusTimerState?, shared: SharedSessionState? = nil) {
        guard running, let channel else { return }
        run { await channel.updateTimer(timer, shared: shared) }
    }

    /// Flip the transport side of the `divergedOffline` flag: while suppressed
    /// the channel stops announcing timer state (hello replies, rejoin
    /// re-announces, presence timer fields) — a diverged client doesn't fight
    /// the channel with stale state.
    func setControlsSuppressed(_ suppressed: Bool) {
        guard running, let channel else { return }
        run { await channel.setControlsSuppressed(suppressed) }
    }

    /// Refresh the channel's retained announce state WITHOUT any wire traffic:
    /// the DIVERGED choke point keeps the (suppressed) channel current so a
    /// forced diverged-hello reply carries the TRUE local state (an offline
    /// pause included), not the pre-divergence snapshot.
    func syncLocalState(timer: CoFocusTimerState?, shared: SharedSessionState? = nil) {
        guard running, let channel else { return }
        run { await channel.syncLocalState(timer: timer, shared: shared) }
    }

    /// Foreground / reconnect re-exchange: ensure the channel is genuinely
    /// joined, re-assert presence, idempotently re-announce (unless diverged),
    /// and `hello` so any focuser re-broadcasts its state to us (the diverged
    /// side's convergence trigger). Chained like every other channel op.
    func reexchange() {
        guard running, let channel else { return }
        run { await channel.reexchange() }
    }

    /// End the shared session for everyone: broadcast the final state
    /// (`ended: true`), THEN tear down — one chained op so the order holds.
    /// Teardown preserves the topic (detach, not removeChannel) when the
    /// session-lifetime channel owns it at execution time (same-task rebind).
    @discardableResult
    func endSession(_ finalState: SharedSessionState) -> Task<Void, Never>? {
        peers = []
        guard running, let channel else { running = false; return nil }
        running = false
        let preserve = preserveTopicOnStop
        return run {
            await channel.broadcastEnded(finalState)
            if preserve?() == true { await channel.detach() } else { await channel.stop() }
        }
    }

    /// Leave + tear down (call on disappear/finish — no leaks).
    func stop() {
        stopTask()
    }

    /// `stop()` that hands back the teardown task. Decides detach-vs-stop at
    /// EXECUTION time: a PartnerPresence row unmounting while AppModel's live
    /// channel holds the same topic (the row got suppressed by the session it
    /// just helped start) must NOT untrack/removeChannel the shared instance.
    @discardableResult
    func stopTask() -> Task<Void, Never>? {
        peers = []
        guard running, let channel else { running = false; return nil }
        running = false
        let preserve = preserveTopicOnStop
        return run {
            if preserve?() == true { await channel.detach() } else { await channel.stop() }
        }
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
            // Shared view (T1b): if a focusing peer carries a live session, show
            // their running/paused timer so both sides see the same clock.
            let timed = peers.first { $0.state == .focusing && $0.sessionStartMs != nil }
            VStack(spacing: 4) {
                HStack(spacing: 9) {
                    CoFocusPulseDot()
                    Text("\(coFocusPeopleLabel(peers)) \(coFocusPresenceVerb(peers, anyFocusing: anyFocusing))")
                        .font(UFont.sans(12.5, .semibold)).foregroundStyle(theme.palette.ink)
                }
                if let timed { CoFocusPeerTimerView(peer: timed) }
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

/// The live shared timer for a FOCUSING peer (T1b) — a calm mm:ss + "N left"
/// that ticks locally (TimelineView) and shows a "Paused" badge when the peer
/// paused. Elapsed/remaining come from the pure `coFocusPeerTimer`, so all
/// platforms compute them identically. Renders nothing if the peer isn't
/// focusing / carries no session (the callers already gate on that).
struct CoFocusPeerTimerView: View {
    @Environment(\.uTheme) private var theme
    let peer: CoFocusPeer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date.timeIntervalSince1970 * 1000
            if let t = coFocusPeerTimer(peer, now: now) {
                HStack(spacing: 6) {
                    Text(formatMMSS(t.elapsedSec))
                        .font(UFont.mono(12, .medium)).monospacedDigit()
                        .foregroundStyle(t.paused ? theme.palette.ink3 : theme.palette.ink)
                    Text("\(formatMMSS(t.remainingSec)) left")
                        .font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                    if t.paused {
                        Text("Paused")
                            .font(UFont.sans(9.5, .bold)).tracking(0.4)
                            .foregroundStyle(theme.palette.amberInk)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(theme.palette.amberSoft, in: Capsule())
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(t.paused
                    ? "Paused at \(formatMMSS(t.elapsedSec))"
                    : "\(formatMMSS(t.elapsedSec)) focused, \(formatMMSS(t.remainingSec)) left")
            }
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
        // The owner's focusing presence (if any) — carries the shared timer (T1b).
        let ownerPeer = cf?.peers.first { $0.state == .focusing }
        let ownerFocusing = ownerPeer != nil
        Group {
            // Nothing to show until the owner is focusing or you've chosen to sit in.
            if ownerFocusing || sitting {
                VStack(alignment: .leading, spacing: 3) {
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
                    // The same running/paused timer the owner sees — shared view.
                    if let p = ownerPeer, p.sessionStartMs != nil {
                        CoFocusPeerTimerView(peer: p)
                    }
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
