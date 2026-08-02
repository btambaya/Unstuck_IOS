// The assistant "cockpit" — the redesigned first page + the live context strip,
// ported from components/assistant/assistant-home.tsx and share-confirm-card.tsx.
//
// The strip proves the assistant already knows the day (Start-Next pick, usable
// time, paused session) before a word is typed; the chips are DYNAMIC — built
// from the user's real tasks/lists via UnstuckCore's `buildSuggestions` and
// hidden when not applicable. Everything here is client-computed from the local
// store: the LLM is only called when the user actually sends something.

import SwiftUI
import UnstuckCore
import UnstuckDesign

// MARK: - context

/// Where a context-strip chip jumps. Each piece is a real destination, so the
/// strip is navigation, not decoration.
enum AssistantJump: Equatable {
    case tasks
    case calendar
    case focus(TaskItem)
}

struct AssistantContext {
    var nextTask: TaskItem?
    var usableLabel: String?
    var pausedTask: TaskItem?
    var tourResumable: Bool
    var groups: SuggestionGroups
    /// Grounded daily check-in line (client-built, zero tokens).
    var checkinLine: String

    static let empty = AssistantContext(nextTask: nil, usableLabel: nil, pausedTask: nil,
                                        tourResumable: false, groups: SuggestionGroups(),
                                        checkinLine: "")
}

/// Build the panel's live context from the local store. Cheap (one read of
/// tasks/blocks/collections) and recomputed each time the panel appears.
@MainActor
func buildAssistantContext(_ model: AppModel, now: Date = Date()) -> AssistantContext {
    let tasks = (try? model.taskRepo?.all()) ?? []
    let blocks = (try? model.db?.fetchAllCalBlocks()) ?? []
    let collections = (try? model.db?.fetchAllCollections()) ?? []
    let todayIso = Clock.todayISO()

    let live = model.cachedLiveSession
    let liveTaskId = model.liveTaskId
    // The REAL Start-Next pick — the same ranker (and the same assigned-away
    // exclusions) the Tasks screen, the widget and Siri use.
    let next = pickStartNext(tasks: tasks, blocks: blocks, liveTaskId: liveTaskId,
                             excludeIds: model.shareState.assignedOutIds)
    let paused: TaskItem? = (live?.sessionStart != nil && live?.paused == true)
        ? tasks.first { $0.id == live?.taskId }
        : nil

    // The same usable-time math the web's right-rail TimeRemaining panel shows.
    let usable = usableToday(blocks: blocks, todayIso: todayIso)
    let usableLabel = usable.usableMins > 0 ? fmtHrs(usable.usableMins) : nil
    let openTodayCount = blocks.filter { $0.date == todayIso && !$0.done && !$0.skipped }.count

    let tour = TourStore().load()
    let hour = Foundation.Calendar.current.component(.hour, from: now)

    return AssistantContext(
        nextTask: next,
        usableLabel: usableLabel,
        pausedTask: paused,
        tourResumable: (tour.started ?? false) && !(tour.done ?? false),
        groups: buildSuggestions(tasks: tasks, blocks: blocks, collections: collections,
                                 todayIso: todayIso),
        checkinLine: buildCheckin(firstName: GreetingName.firstName(model.currentUserName),
                                  openTodayCount: openTodayCount,
                                  usableLabel: usableLabel,
                                  hour: hour))
}

// MARK: - context strip

/// Pinned band under the header — NEXT → Tasks, USABLE → Calendar, PAUSED →
/// Focus. Renders nothing when there's nothing to show, and each piece is
/// hidden individually when it doesn't apply.
struct AssistantContextStrip: View {
    @Environment(\.uTheme) private var theme
    let ctx: AssistantContext
    let onJump: (AssistantJump) -> Void

    private struct Piece: Identifiable {
        let key: String
        let value: String
        let jump: AssistantJump
        var id: String { key }
    }

    private var pieces: [Piece] {
        var out: [Piece] = []
        if let next = ctx.nextTask { out.append(Piece(key: "NEXT", value: next.name, jump: .tasks)) }
        if let usable = ctx.usableLabel { out.append(Piece(key: "USABLE", value: usable, jump: .calendar)) }
        if let paused = ctx.pausedTask { out.append(Piece(key: "PAUSED", value: paused.name, jump: .focus(paused))) }
        return out
    }

    var body: some View {
        let items = pieces
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                    if i > 0 {
                        Text("·").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    }
                    Button { onJump(p.jump) } label: {
                        HStack(spacing: 6) {
                            Text(p.key)
                                .font(UFont.mono(10, .semibold)).tracking(0.8)
                                .foregroundStyle(theme.palette.ink3)
                            Text(p.value)
                                .font(UFont.sans(12.5, .semibold))
                                .foregroundStyle(theme.palette.ink)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(p.key.lowercased()): \(p.value)")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(theme.palette.bg2)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.palette.line).frame(height: 0.5) }
        }
    }
}

// MARK: - suggestions block

/// The suggestions block. Full (serif hero + chips) as the empty thread's
/// "first page"; `compact` (chips only) as the check-in card at the tail of an
/// existing conversation.
struct AssistantHomeBlock: View {
    @Environment(\.uTheme) private var theme
    let ctx: AssistantContext
    var compact = false
    let onAsk: (String) -> Void
    let onResumeTour: () -> Void
    /// Present when the last turn made undoable changes — one-tap revert.
    var undoAll: (count: Int, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 16 : 20) {
            if !compact {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What can I take off your plate?")
                        .font(UFont.serifItalic(26)).foregroundStyle(theme.palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("I already know your day. Tell me what you want to happen — I’ll do it, not just talk about it.")
                        .font(UFont.sans(13.5)).foregroundStyle(theme.palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if ctx.tourResumable {
                Button(action: onResumeTour) {
                    HStack(spacing: 12) {
                        Mark(size: 20)
                            .frame(width: 38, height: 38)
                            .background(theme.palette.surface, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resume the product tour")
                                .font(UFont.sans(14.5, .semibold)).foregroundStyle(theme.palette.ink)
                            Text("Pick up where you left off")
                                .font(UFont.sans(12.5)).foregroundStyle(theme.palette.ink2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13)).foregroundStyle(theme.palette.ink2)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.palette.primarySoft,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if let undoAll {
                Button(action: undoAll.run) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                        Text("Undo all \(undoAll.count) change\(undoAll.count == 1 ? "" : "s")")
                            .font(UFont.sans(13))
                    }
                    .foregroundStyle(theme.palette.ink2)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(theme.palette.bg2, in: Capsule())
                    .overlay(Capsule().stroke(theme.palette.line2))
                }
                .buttonStyle(.plain)
            }

            ChipGroup(title: "GETTING STARTED", chips: ctx.groups.gettingStarted, onAsk: onAsk)
            ChipGroup(title: "PLAN & SCHEDULE", chips: ctx.groups.planAndSchedule, onAsk: onAsk)
            ChipGroup(title: "REFINE", chips: ctx.groups.refine, onAsk: onAsk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One titled row of wrapping suggestion chips. Renders nothing when the group
/// is empty — the panel never offers an action the data can't back.
private struct ChipGroup: View {
    @Environment(\.uTheme) private var theme
    let title: String
    let chips: [AssistantSuggestion]
    let onAsk: (String) -> Void

    var body: some View {
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(UFont.mono(10, .semibold)).tracking(1.4)
                    .foregroundStyle(theme.palette.ink3)
                ChipFlow(chips: chips, onAsk: onAsk)
            }
        }
    }
}

/// Wrapping chip layout (SwiftUI has no flex-wrap; this is the iOS idiom —
/// a Layout that measures each chip and breaks lines itself).
private struct ChipFlow: View {
    @Environment(\.uTheme) private var theme
    let chips: [AssistantSuggestion]
    let onAsk: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 8, lineSpacing: 8) {
            ForEach(chips) { chip in
                Button { onAsk(chip.message) } label: {
                    Text(chip.label)
                        .font(UFont.sans(13.5, .medium))
                        .foregroundStyle(theme.palette.ink)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(theme.palette.surface, in: Capsule())
                        .overlay(Capsule().stroke(theme.palette.line2))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal flow layout — places subviews left-to-right, wrapping at the
/// proposed width.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - receipts

/// A deterministic ✓-card for one thing the agent actually did.
struct AssistantReceiptRow: View {
    @Environment(\.uTheme) private var theme
    let receipt: Receipt
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.palette.green)
            Text(receipt.label)
                .font(UFont.sans(12.5))
                .foregroundStyle(theme.palette.ink2)
                .strikethrough(receipt.undone ?? false)
                .opacity((receipt.undone ?? false) ? 0.6 : 1)
            if receipt.isUndoable {
                Button("Undo", action: onUndo)
                    .font(UFont.sans(12, .semibold))
                    .foregroundStyle(theme.palette.coralDeep)
                    .buttonStyle(.plain)
            } else if receipt.undone ?? false {
                Text("undone").font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.palette.line))
    }
}

// MARK: - share confirm (the ONE action that leaves the device on a tap)

/// Performs a confirmed share. Split out of the card so the "nothing leaves
/// before the tap" contract is unit-testable without SwiftUI.
@MainActor
protocol AssistantSharePerformer {
    func share(taskId: String, user: String, level: ShareLevel) async throws
    func notify(taskId: String, recipientId: String) async
}

/// The live performer — the same RPC + best-effort heads-up the share sheet uses.
@MainActor
struct ShareModelPerformer: AssistantSharePerformer {
    let shares: ShareModel
    func share(taskId: String, user: String, level: ShareLevel) async throws {
        try await shares.shareTask(taskId: taskId, user: user, level: level)
    }
    func notify(taskId: String, recipientId: String) async {
        await shares.notifyShare(taskId: taskId, recipientId: recipientId)
    }
}

/// Run a staged share. Returns the outcome + a message on failure. The notify
/// only fires AFTER a successful share (a failed RPC must never look like one).
@MainActor
func performConfirmedShare(_ pending: PendingShare,
                           using performer: AssistantSharePerformer) async -> (PendingShareOutcome, String?) {
    do {
        try await performer.share(taskId: pending.taskId, user: pending.recipientUserId,
                                  level: pending.level)
    } catch {
        return (.failed, error.localizedDescription)
    }
    await performer.notify(taskId: pending.taskId, recipientId: pending.recipientUserId)
    return (.shared, nil)
}

/// The ONLY place an assistant-prepared share actually happens. The agent
/// stages a request; this card shows exactly who gets what; the RPC runs on the
/// user's tap. Mirrors components/assistant/share-confirm-card.tsx.
struct AssistantShareConfirmCard: View {
    @Environment(\.uTheme) private var theme
    let pending: PendingShare
    let performer: AssistantSharePerformer
    let onResolved: (PendingShareOutcome) -> Void

    @State private var busy = false
    @State private var error: String?

    private var done: Bool { pending.outcome == .shared }
    private var dismissed: Bool { pending.outcome == .dismissed }
    private var failed: Bool { pending.outcome == .failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(done ? "SHARED" : dismissed ? "NOT SHARED" : "CONFIRM SHARE")
                .font(UFont.mono(10, .semibold)).tracking(0.9)
                .foregroundStyle(theme.palette.ink3)

            (Text("Share ")
                + Text("“\(pending.taskName)”").bold()
                + Text(" with ")
                + Text(pending.recipientName).bold()
                + Text(" — \(shareLevelLabel(pending.level))"))
                .font(UFont.sans(13.5))
                .foregroundStyle(theme.palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !done && !dismissed {
                Text("They’ll see this task’s title and whether it’s done. Nothing else is shared.")
                    .font(UFont.sans(11.5)).foregroundStyle(theme.palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = error ?? (failed ? "Could not share — try again." : nil) {
                    Text(message).font(UFont.sans(12)).foregroundStyle(theme.palette.coralDeep)
                }
                HStack(spacing: 8) {
                    Button {
                        guard !busy else { return }
                        busy = true; error = nil
                        Task {
                            let (outcome, message) = await performConfirmedShare(pending, using: performer)
                            error = message
                            busy = false
                            onResolved(outcome)
                        }
                    } label: {
                        Text(busy ? "Sharing…" : "Share it")
                            .font(UFont.sans(13, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 15).padding(.vertical, 7)
                            .background(theme.palette.coral, in: Capsule())
                            .opacity(busy ? 0.6 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)

                    Button { onResolved(.dismissed) } label: {
                        Text("Not now")
                            .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .overlay(Capsule().stroke(theme.palette.line2))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
                .padding(.top, 2)
            }

            if done {
                Text("Manage or revoke it any time from the task’s share menu.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.palette.line))
    }
}

// MARK: - day dividers

/// "Today" / "Yesterday" / "Mon 28 Jul" for a turn's timestamp — the web
/// `dayLabel`. nil for a legacy turn with no stamp (it renders without one).
func assistantDayLabel(at: Double?, now: Date = Date()) -> String? {
    guard let at else { return nil }
    let cal = Foundation.Calendar.current
    let date = Date(timeIntervalSince1970: at / 1000)
    if cal.isDate(date, inSameDayAs: now) { return "Today" }
    if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
       cal.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
    let f = DateFormatter()
    f.locale = Locale.current
    f.setLocalizedDateFormatFromTemplate("EEE d MMM")
    return f.string(from: date)
}
