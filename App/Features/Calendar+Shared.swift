// Calendar — the SHARED layer: blocks of tasks other people shared with me,
// rendered read-only at the OWNER's slot (shared_task_blocks, migration 052).
//
//   • SharedBlocksCache — a small per-window cache (pure, unit-tested) the
//     ShareModel owns; each calendar surface asks for its visible range.
//   • CalLaneItem / mergedLanes — the user's own blocks + shared blocks laid
//     out side-by-side in the same greedy lane pass, so an owner's 09:00 block
//     never paints over mine (or vice versa).
//   • SharedBlockCard / SharedWeekBlock — dashed outline, the TASK as the
//     label and the owner beneath it (UnstuckCore `sharedBlockLabel`: the
//     sharer is the first thing dropped when space is tight). NOT draggable,
//     resizable, deletable, or editable; tap → the shared-task detail sheet. The guard is structural: a shared block is a different
//     type from CalBlock, so it can never reach CalBlockEditSheet, handleDrop,
//     moveBlock, resizeBlock, or deleteBlock.
//
// Kept apart from CalendarFeature.swift so the shared layer is one contained
// diff on top of the (Android-1:1) calendar.

import SwiftUI
import UnstuckCore
import UnstuckDesign

// MARK: - Window cache (pure)

/// Per-window cache of the shared-block projection. A window is an inclusive
/// 'YYYY-MM-DD' range (≤ 62 days — the server's cap). Loading a window
/// REPLACES every date inside it (so a block the owner removed disappears);
/// the newest `maxWindows` windows are kept, older ones evicted with their
/// dates (a user paging months doesn't grow this unbounded).
struct SharedBlocksCache: Equatable {
    struct Window: Equatable, Hashable {
        let from: String
        let to: String
        /// True when `other` lies entirely inside this window (string compare
        /// is date order for 'YYYY-MM-DD').
        func contains(_ other: Window) -> Bool { other.from >= from && other.to <= to }
    }

    static let maxWindows = 4

    /// Loaded windows, oldest first.
    private(set) var windows: [Window] = []
    /// Blocks by date (unsorted, unfiltered — `blocks(on:)` drops skipped +
    /// sorts).
    private(set) var byDate: [String: [SharedBlock]] = [:]

    /// True when some loaded window already covers `w` — no fetch needed.
    func covers(_ w: Window) -> Bool { windows.contains { $0.contains(w) } }

    /// Store a fetched window: clear its dates, insert the rows (only those
    /// dated inside the window — a server row outside it is ignored), record
    /// the window (moved to newest), evict beyond the cap.
    mutating func store(_ w: Window, blocks: [SharedBlock]) {
        for d in CalWindow.days(from: w.from, to: w.to) { byDate[d] = nil }
        for b in blocks where b.date >= w.from && b.date <= w.to {
            byDate[b.date, default: []].append(b)
        }
        windows.removeAll { $0 == w }
        windows.append(w)
        while windows.count > Self.maxWindows {
            let old = windows.removeFirst()
            for d in CalWindow.days(from: old.from, to: old.to)
            where !windows.contains(where: { d >= $0.from && d <= $0.to }) {
                byDate[d] = nil
            }
        }
    }

    /// Shared blocks on a day: skipped occurrences dropped, sorted by start
    /// (the same `blocks(on:)` semantics as the user's own layer).
    func blocks(on iso: String) -> [SharedBlock] {
        (byDate[iso] ?? []).filter { !$0.skipped }.sorted { $0.startTime < $1.startTime }
    }

    mutating func clear() {
        windows = []
        byDate = [:]
    }
}

/// ISO-date window arithmetic for the calendar surfaces (local calendar).
enum CalWindow {
    /// Local midnight for a 'YYYY-MM-DD'; nil if malformed.
    static func date(_ iso: String) -> Date? {
        let p = iso.split(separator: "-").map { Int($0) }
        guard p.count == 3, let y = p[0], let m = p[1], let d = p[2] else { return nil }
        return Time.civil(y, m, d)
    }

    /// Every 'YYYY-MM-DD' from `from` through `to` inclusive ([] when
    /// reversed or malformed). Bounded to 62 entries — the server's cap.
    static func days(from: String, to: String) -> [String] {
        guard let start = date(from), from <= to else { return [] }
        var out: [String] = []
        var d = start
        var iso = from
        while iso <= to && out.count < 62 {
            out.append(iso)
            d = Time.addDays(d, 1)
            iso = Clock.dateISO(d)
        }
        return out
    }

    /// The Monday-anchored week containing `iso` — the Day grid's load unit
    /// (paging day-by-day inside a week costs no extra RPC) and exactly the
    /// Week view's range, so the two share cache windows.
    static func week(containing iso: String) -> SharedBlocksCache.Window {
        guard let d = date(iso) else { return .init(from: iso, to: iso) }
        let weekdaySun1 = Time.calendar.component(.weekday, from: d)   // 1=Sun … 7=Sat
        let monday = Time.addDays(d, -((weekdaySun1 + 5) % 7))
        return .init(from: Clock.dateISO(monday), to: Clock.dateISO(Time.addDays(monday, 6)))
    }

    /// The Monday-anchored week starting `weekOffset` weeks from this week.
    static func week(offset weekOffset: Int, today: Date = Date()) -> SharedBlocksCache.Window {
        let cal = Time.calendar
        let weekdaySun1 = cal.component(.weekday, from: today)
        let thisMonday = Time.addDays(cal.startOfDay(for: today), -((weekdaySun1 + 5) % 7))
        let monday = Time.addDays(thisMonday, weekOffset * 7)
        return .init(from: Clock.dateISO(monday), to: Clock.dateISO(Time.addDays(monday, 6)))
    }

    /// The calendar month containing `d` (1st … last day).
    static func month(containing d: Date) -> SharedBlocksCache.Window {
        let cal = Time.calendar
        let first = cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        return .init(from: Clock.dateISO(first), to: Clock.dateISO(Time.addDays(first, count - 1)))
    }
}

// MARK: - Lane layout over own + shared blocks

/// One positioned item on a day column: the user's own block (editable when
/// it's a task block) or a shared one (always read-only).
enum CalLaneItem: Identifiable, Equatable {
    case own(CalBlock)
    case shared(SharedBlock)

    var id: String {
        switch self {
        case .own(let b): return "own:\(b.id)"
        case .shared(let s): return "shared:\(s.blockId)"
        }
    }
    var startTime: String {
        switch self {
        case .own(let b): return b.startTime
        case .shared(let s): return s.startTime
        }
    }
    var durationMinutes: Int {
        switch self {
        case .own(let b): return b.durationMinutes
        case .shared(let s): return s.durationMinutes
        }
    }
    var isShared: Bool { if case .shared = self { return true } else { return false } }
    /// The ONE gate every mutating calendar path keys off: only my own TASK
    /// blocks may be dragged / resized / unscheduled / deleted / edited.
    /// External (Google) blocks and every shared block are display-only.
    var isEditable: Bool {
        if case .own(let b) = self { return isTaskBlock(b) }
        return false
    }
}

/// A laid-out item: its column placement so time-overlapping items render
/// side-by-side. Generic over the item so own + shared blocks share one pass.
struct LaidItem<T> {
    let item: T
    let startMin: Int
    let endMin: Int
    var lane: Int = 0
    var lanes: Int = 1
}

/// Greedy interval colouring — mirrors the Android layoutLanes / web calendar.
/// Items are sorted by (start, end); overlapping clusters get `lanes` columns.
func layoutLanes<T>(_ items: [T], startTime: (T) -> String, durationMinutes: (T) -> Int) -> [LaidItem<T>] {
    func parse(_ s: String) -> Int {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }
    var laid = items.map { it -> LaidItem<T> in
        let s = parse(startTime(it))
        return LaidItem(item: it, startMin: s, endMin: s + max(1, durationMinutes(it)))
    }.sorted { ($0.startMin, $0.endMin) < ($1.startMin, $1.endMin) }

    var i = 0
    while i < laid.count {
        var clusterEnd = laid[i].endMin
        var j = i + 1
        while j < laid.count && laid[j].startMin < clusterEnd {
            clusterEnd = max(clusterEnd, laid[j].endMin); j += 1
        }
        var laneEnd: [Int] = []
        for k in i..<j {
            if let lane = laneEnd.firstIndex(where: { $0 <= laid[k].startMin }) {
                laid[k].lane = lane; laneEnd[lane] = laid[k].endMin
            } else {
                laid[k].lane = laneEnd.count; laneEnd.append(laid[k].endMin)
            }
        }
        for k in i..<j { laid[k].lanes = laneEnd.count }
        i = j
    }
    return laid
}

/// Own + shared blocks in ONE lane pass, so an owner's block at my 09:00 sits
/// beside mine instead of on top of it. Skipped shared occurrences are
/// dropped (the own list is expected pre-filtered, as `blocks(on:)` does).
func mergedLanes(own: [CalBlock], shared: [SharedBlock]) -> [LaidItem<CalLaneItem>] {
    let items = own.map { CalLaneItem.own($0) } + shared.filter { !$0.skipped }.map { CalLaneItem.shared($0) }
    return layoutLanes(items, startTime: \.startTime, durationMinutes: \.durationMinutes)
}

/// The day column's items for a view: the cached own-only layout when there
/// is nothing shared that day (the common case — no per-render relayout),
/// else the merged pass.
@MainActor
func dayLanes(_ vm: CalendarModel, iso: String, shared: [SharedBlock]) -> [LaidItem<CalLaneItem>] {
    if shared.isEmpty {
        return vm.laidBlocks(on: iso).map {
            LaidItem(item: .own($0.block), startMin: $0.startMin, endMin: $0.endMin, lane: $0.lane, lanes: $0.lanes)
        }
    }
    return mergedLanes(own: vm.blocks(on: iso), shared: shared)
}

// MARK: - Month marks

/// Per-day indicators for the Month grid, kept apart from the focus-density
/// fill: how many of MY task blocks are planned that day + how many shared
/// blocks sit there. Skipped occurrences are excluded on both sides (the own
/// list from `blocksByDate` already drops them; shared ones are filtered here).
struct MonthDayMarks: Equatable {
    let planned: Int
    let shared: Int
    var isEmpty: Bool { planned == 0 && shared == 0 }
}

func monthDayMarks(own: [CalBlock], shared: [SharedBlock]) -> MonthDayMarks {
    MonthDayMarks(planned: own.filter { isTaskBlock($0) && !$0.skipped }.count,
                  shared: shared.filter { !$0.skipped }.count)
}

// MARK: - A block's slot, in words

/// The "Planned Sat, Sep 12 · 04:30 · 45m" / "Done …" line for ONE shared
/// block — what the detail sheet shows when it was opened from a calendar
/// tap (that block, not the projection's next one). Rendered in the
/// recipient's zone when the row carries `startAt` (migration 053); a pre-053
/// row reads the owner's date/time text. The time is in the phone's clock.
func sharedBlockPlannedLabel(_ b: SharedBlock, timeZone: TimeZone = .current,
                             clock: ClockFormat = .device) -> String? {
    sharedPlannedLabel(nextDate: b.date, nextStartTime: b.startTime, nextDurationMinutes: b.durationMinutes,
                       nextDone: b.done, nextStartAt: b.startAt, timeZone: timeZone, clock: clock)
}

// MARK: - Shared block views (read-only)

/// A shared block on the Day grid — dashed neutral outline, a bg2 fill, the
/// title + owner. Display-only: the caller attaches ONLY a tap (→ detail);
/// never `.draggable`, never a context menu, never the edit sheet.
struct SharedBlockCard: View {
    @Environment(\.uTheme) private var theme
    let block: SharedBlock
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.system(size: 9))
                    .foregroundStyle(theme.palette.ink2)
                Text(sharedBlockLabel(taskName: block.title, sharer: block.ownerName, compact: true))
                    .font(UFont.sans(12, .medium)).lineLimit(1)
                    .strikethrough(block.done)
                    .foregroundStyle(block.done ? theme.palette.ink3 : theme.palette.ink)
            }
            if height > 34 {
                Text("\(ClockFormat.device.time(block.startTime)) · \(shortName(block.ownerName))")
                    .font(UFont.mono(9)).foregroundStyle(theme.palette.ink3).lineLimit(1)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(theme.palette.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(theme.palette.ink3, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(block.title), shared by \(shortName(block.ownerName)), \(ClockFormat.device.time(block.startTime)), \(block.durationMinutes) minutes")
        .accessibilityHint("Opens the shared task")
    }
}

/// A shared block in a Week column — the compact 8pt variant. The TASK is the
/// (tail-truncated) line, exactly like my own blocks beside it; the sharer sits
/// on a 7pt second line only when the block is tall enough for one, so a short
/// block never trades its title for a name. (It used to read "<sharer> · <task>"
/// — in a ~45pt column only the sharer survived.)
struct SharedWeekBlock: View {
    @Environment(\.uTheme) private var theme
    let block: SharedBlock
    /// The laid-out height — decides whether the sharer line fits.
    let height: CGFloat

    /// Two 8pt/7pt lines + the 1pt padding need ~21pt; 26pt (≈ 35 min at
    /// 44pt/h) leaves the second line clear of the clip.
    static let sharerLineMinHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sharedBlockLabel(taskName: block.title, sharer: block.ownerName, compact: true))
                .font(UFont.sans(8, .medium))
                .foregroundStyle(block.done ? theme.palette.ink3 : theme.palette.ink)
                .strikethrough(block.done)
                .lineLimit(1)
            if height >= Self.sharerLineMinHeight, let who = sharerDisplayName(block.ownerName) {
                Text(who).font(UFont.mono(7)).foregroundStyle(theme.palette.ink3).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(1)
        .background(theme.palette.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3)
            .strokeBorder(theme.palette.ink3, style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(block.title), shared by \(shortName(block.ownerName))")
    }
}

/// The Month cell's indicator row: up to three solid dots for MY planned
/// blocks, plus one dashed ring when something shared sits that day. Both are
/// separate from the heat fill (which is focus density).
struct MonthMarksRow: View {
    @Environment(\.uTheme) private var theme
    let marks: MonthDayMarks
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<min(3, marks.planned), id: \.self) { _ in
                Circle().fill(tint).frame(width: 3.5, height: 3.5)
            }
            if marks.shared > 0 {
                Circle()
                    .strokeBorder(theme.palette.ink2, style: StrokeStyle(lineWidth: 1, dash: [1.5, 1]))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

// MARK: - Month day peek

/// One tapped month day (Identifiable on its 'YYYY-MM-DD').
struct MonthDayPeek: Identifiable, Equatable { let id: String }

/// What a peek row asked for. The month view acts on it after the sheet has
/// finished dismissing — SwiftUI silently drops a sheet presented while
/// another is still going.
enum MonthPeekAction: Equatable {
    case task(String)
    case shared(SharedDetailTarget)
}

/// Everything on one day, from the month grid: my planned blocks, anything
/// shared with me, and the tasks due that day that were never scheduled.
/// Every row leads somewhere — a plain day used to be a dead end while a
/// shared day opened a sheet (tester, 2026-09-08).
struct MonthDayPeekSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let iso: String
    let vm: CalendarModel
    /// Row tapped — the host presents the target after this sheet closes.
    let onPick: (MonthPeekAction) -> Void

    var body: some View {
        let own = vm.blocks(on: iso).filter { !$0.skipped }.sorted { $0.startTime < $1.startTime }
        let planned = own.filter { isTaskBlock($0) }
        let events = own.filter { !isTaskBlock($0) }
        let shared = model.shareState.sharedBlocks(on: iso)
        let empty = planned.isEmpty && events.isEmpty && shared.isEmpty

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if empty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nothing on this day.").font(UFont.serifItalic(20)).foregroundStyle(theme.palette.ink)
                            Text("A clear day is a fine thing.").font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                        }
                        .padding(.top, 8)
                    }
                    section("Planned", planned.map { b in
                        // For a recurring occurrence completion lives on the block;
                        // for a one-off it lives on the task (same rule as the grids).
                        let t = vm.tasks.first { $0.id == b.taskId }
                        // A series' day opens THAT day's occurrence (the block
                        // id), not the series (audit 2026-09-22, C3).
                        return PeekRow(id: b.id, title: b.taskName, meta: slotText(b.startTime, b.durationMinutes),
                                       done: blockIsDone(b, task: t), tint: theme.palette.ink, dashed: false,
                                       action: b.taskId.map { MonthPeekAction.task(t?.recurrence != nil ? b.id : $0) })
                    })
                    section("Shared with you", shared.map { sb in
                        PeekRow(id: sb.blockId, title: sb.title, meta: "\(slotText(sb.startTime, sb.durationMinutes)) · \(sharerDisplayName(sb.ownerName))",
                                done: sb.done, tint: theme.palette.ink2, dashed: true,
                                action: .shared(SharedDetailTarget(id: sb.taskId, block: sb)))
                    })
                    section("In the calendar", events.map { b in
                        PeekRow(id: b.id, title: b.taskName, meta: slotText(b.startTime, b.durationMinutes),
                                done: false, tint: theme.palette.ink3, dashed: false, action: nil)
                    })
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(theme.palette.bg)
            .navigationTitle(dayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.font(UFont.sans(15))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func section(_ label: String, _ rows: [PeekRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(label).foregroundStyle(theme.palette.ink3)
                ForEach(rows) { row in
                    Button {
                        guard let a = row.action else { return }
                        onPick(a)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .strokeBorder(row.tint, style: StrokeStyle(lineWidth: row.dashed ? 1 : 4, dash: row.dashed ? [1.5, 1] : []))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(UFont.sans(15, .medium))
                                    .foregroundStyle(row.done ? theme.palette.ink3 : theme.palette.ink)
                                    .strikethrough(row.done, color: theme.palette.ink3)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Text(row.meta).font(UFont.mono(10)).foregroundStyle(theme.palette.ink3)
                            }
                            Spacer(minLength: 6)
                            if row.action != nil {
                                Text("›").font(UFont.serifItalic(20)).foregroundStyle(theme.palette.ink4)
                            }
                        }
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.palette.bg2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(row.action == nil)
                    .accessibilityHint(row.action == nil ? "" : "Opens it")
                }
            }
        }
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        return CalFmt.weekdayMonthDay.string(from: d)
    }

    /// "14:30 · 45m" / "2:30 PM · 1h 15m" — the start in the phone's clock.
    private func slotText(_ start: String, _ minutes: Int) -> String {
        let at = ClockFormat.device.time(start)
        return minutes >= 60 ? "\(at) · \(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" : "\(at) · \(minutes)m"
    }

    struct PeekRow: Identifiable {
        let id: String
        let title: String
        let meta: String
        let done: Bool
        let tint: Color
        let dashed: Bool
        let action: MonthPeekAction?
    }
}
