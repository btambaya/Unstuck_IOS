// Pure mapping between Google Calendar events and local CalBlocks.
// Port of the exported helpers in lib/sync/google-sync.ts. The pull/push
// orchestration (Edge Function calls, reconciliation, scheduler) lives in
// UnstuckSync; only the value transforms are here.

import Foundation

private func date(_ iso: String) -> Date? {
    Time.parseMillis(iso).map { Date(timeIntervalSince1970: $0 / 1000) }
}

/// Local YYYY-MM-DD for an ISO timestamp, anchored to the user's
/// timezone so a "Tuesday 10am" event lands on Tuesday in the grid.
public func isoToLocalYmd(_ iso: String) -> String {
    guard let d = date(iso) else { return String(iso.prefix(10)) }
    return Clock.dateISO(d)
}

/// HH:MM (local, zero-padded) for an ISO timestamp.
public func isoToLocalHHMM(_ iso: String) -> String {
    guard let d = date(iso) else { return "00:00" }
    return localHHMM(d)
}

private func localHHMM(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

/// Whole-minute duration between two ISO timestamps, floored at 15 (so
/// zero/short Google events stay visible).
public func diffMinutes(_ startIso: String, _ endIso: String) -> Int {
    guard let s = Time.parseMillis(startIso), let e = Time.parseMillis(endIso) else { return 15 }
    let ms = max(0, e - s)
    return max(15, Int((ms / 60_000).rounded()))
}

/// Map a Google event to an external CalBlock. The `id` is derived from
/// the Google id (`g_<id>`) so re-pulls overwrite the same row instead of
/// accumulating duplicates. (The web sneaks a `_sourceCalendarId` hint
/// onto the object; CalBlock has no slot for it, so `calendarId` is
/// accepted for signature parity but the push layer resolves the target
/// calendar from the connection instead.)
public func externalEventToBlock(_ ev: ExternalEvent, calendarId: String) -> CalBlock {
    CalBlock(
        id: "g_\(ev.id)",
        taskId: nil,
        taskName: ev.summary.isEmpty ? "(untitled)" : ev.summary,
        startTime: isoToLocalHHMM(ev.start),
        durationMinutes: diffMinutes(ev.start, ev.end),
        date: isoToLocalYmd(ev.start),
        externalEventId: ev.id,
        externalConnectionId: ev.connectionId,
        kind: .external)
}

/// A timed Google event as the blocks it covers, one per LOCAL day (audit
/// 2026-09-22, C25 / calendar#10). The whole span used to sit on the start
/// day: a Mon 09:00 → Wed 17:00 conference was one card running off Monday's
/// grid, and Tuesday / Wednesday read as free to findFreeSlots and the
/// assistant; an overnight flight left the next morning free. Each day's
/// block is clamped to that day (00:00–24:00). The start day keeps the
/// `g_<id>` id every earlier build stored; a later day is `g_<id>_<ymd>`
/// (Google event ids are base32hex plus '_', never '-', so no real event's
/// block can collide). With `fromYmd` / `toYmd`, only the days inside the
/// pull window are returned — an event that began weeks before it still
/// yields its in-window days. A zero-length or unparseable event keeps the
/// old single block.
public func externalEventBlocks(_ ev: ExternalEvent, fromYmd: String? = nil, toYmd: String? = nil) -> [CalBlock] {
    let one = externalEventToBlock(ev, calendarId: ev.calendarId)
    func inWindow(_ ymd: String) -> Bool { ymd >= (fromYmd ?? ymd) && ymd <= (toYmd ?? ymd) }
    guard let start = date(ev.start), let end = date(ev.end), end > start else {
        return inWindow(one.date) ? [one] : []
    }
    let cal = Calendar.current
    let startYmd = Clock.dateISO(start)
    // Days before the window are skipped by date, not walked one by one.
    var day = cal.startOfDay(for: start)
    if let fromYmd, fromYmd > startYmd { day = max(day, LocalDate.parse(fromYmd)) }
    var out: [CalBlock] = []
    while day < end {
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
        let ymd = Clock.dateISO(day)
        if let toYmd, ymd > toYmd { break }
        let from = max(start, day)
        let minutes = Int((min(end, next).timeIntervalSince(from) / 60).rounded())
        if minutes > 0 {
            var b = one
            b.id = ymd == startYmd ? one.id : "g_\(ev.id)_\(ymd)"
            b.date = ymd
            b.startTime = localHHMM(from)
            b.durationMinutes = max(15, minutes)
            out.append(b)
        }
        day = next
    }
    return out
}

/// One reconciled Google pull: the external blocks to upsert plus the
/// stale in-window external block ids to drop. Pure — the Edge-Function
/// pull and the local reads/writes happen in SyncCoordinator.pullCalendar.
public struct CalendarPullPlan: Equatable, Sendable {
    public var toUpsert: [CalBlock]
    public var toDelete: [String]

    public init(toUpsert: [CalBlock], toDelete: [String]) {
        self.toUpsert = toUpsert
        self.toDelete = toDelete
    }
}

/// Reconcile pulled Google events against the local cache — port of the
/// Android SyncCoordinator.pullCalendar filtering (spec 02-sync-engine §1.8):
/// - skip events the app itself pushed (a task block's externalEventId) —
///   the originating task block already represents them, otherwise a
///   duplicate g_ block sits next to it (and double-counts in findFreeSlots).
///   `pendingDeleteEventIds` are ours too: events whose block is gone but
///   whose Google delete has not gone through yet (GoogleWriteBacklog) —
///   imported, they came back as undeletable "meetings" (audit 2026-09-22,
///   C24);
/// - skip all-day events — the server flags them `allDay: true`
///   (`allDayEventIds`); a date-only start (no 'T') is honoured too. They'd
///   collapse to 15-min 00:00 slivers stacked on the time grid;
/// - a timed event is split into its in-window local days
///   (`externalEventBlocks`, C25);
/// - drop in-window EXTERNAL blocks Google no longer returns (deleted or
///   moved in Google); `fromYmd...toYmd` are the date-only pull bounds —
///   EXCEPT blocks belonging to a connection whose absence proves nothing
///   this pull (`failedConnectionIds`: a revoked token / 429 / 5xx on one of
///   its calendars, or a truncated read): a failure used to come back as
///   `events: []` and every client then "deleted" all the user's meetings.
///   When any connection failed, blocks of unknown provenance (no connection
///   id) are kept as well. A failed connection's RETURNED events are still
///   upserted: the server answers a failing calendar with no events at all,
///   so what came back is from calendars that answered — dropping them froze
///   every calendar of the account behind one dead calendar (C25);
/// - drop Google-import (g_) blocks dated before the window (nothing checks
///   them against Google any more, and every hydrate carried them forward
///   for good) and, given `liveConnectionIds`, those of a connection that no
///   longer exists (disconnected elsewhere while another stays), whatever
///   their date (C25 / calendar#9).
public func reconcileCalendarPull(
    events: [ExternalEvent], localBlocks: [CalBlock], fromYmd: String, toYmd: String,
    allDayEventIds: Set<String> = [], failedConnectionIds: Set<String> = [],
    pendingDeleteEventIds: Set<String> = [], liveConnectionIds: Set<String>? = nil
) -> CalendarPullPlan {
    let ownEventIds = Set(localBlocks
        .filter { blockKind($0) == .task }
        .compactMap { $0.externalEventId }
        .filter { !$0.isEmpty })
        .union(pendingDeleteEventIds)
    var seen = Set<String>()
    let toUpsert = events
        .filter { !ownEventIds.contains($0.id) }
        .filter { !allDayEventIds.contains($0.id) && $0.start.contains("T") }
        .flatMap { externalEventBlocks($0, fromYmd: fromYmd, toYmd: toYmd) }
        .filter { seen.insert($0.id).inserted }   // one event on two calendars
    let keep = Set(toUpsert.map(\.id))
    let stale = localBlocks
        .filter { isExternalBlock($0) && $0.date >= fromYmd && $0.date <= toYmd && !keep.contains($0.id) }
        .filter { b in
            guard !failedConnectionIds.isEmpty else { return true }
            guard let conn = b.externalConnectionId, !conn.isEmpty else { return false }
            return !failedConnectionIds.contains(conn)
        }
        .map(\.id)
    let orphaned = localBlocks
        .filter { isExternalBlock($0) && $0.id.hasPrefix("g_") && !keep.contains($0.id) }
        .filter { b in
            if b.date < fromYmd { return true }
            guard let live = liveConnectionIds, let conn = b.externalConnectionId, !conn.isEmpty else { return false }
            return !live.contains(conn)
        }
        .map(\.id)
    var dropped = Set<String>()
    let toDelete = (stale + orphaned).filter { dropped.insert($0).inserted }
    return CalendarPullPlan(toUpsert: toUpsert, toDelete: toDelete)
}

/// Convert a block's date + HH:MM into a Google-friendly ISO start/end,
/// anchored in local time. Port of `blockToIsoRange`.
public func blockToIsoRange(_ b: CalBlock) -> (start: String, end: String) {
    let dParts = b.date.split(separator: "-").map { Int($0) }
    let tParts = b.startTime.split(separator: ":").map { Int($0) }
    guard dParts.count == 3, tParts.count >= 1,
          let y = dParts[0], let m = dParts[1], let d = dParts[2] else {
        return (b.date, b.date)
    }
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d
    c.hour = tParts.count > 0 ? (tParts[0] ?? 0) : 0
    c.minute = tParts.count > 1 ? (tParts[1] ?? 0) : 0
    let startDate = Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 0)
    let endDate = startDate.addingTimeInterval(Double(b.durationMinutes) * 60)

    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return (f.string(from: startDate), f.string(from: endDate))
}
