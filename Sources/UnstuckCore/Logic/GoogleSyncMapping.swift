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
///   duplicate g_ block sits next to it (and double-counts in findFreeSlots);
/// - skip all-day events (date-only start, no 'T') — they'd collapse to
///   15-min 00:00 slivers stacked on the time grid;
/// - drop in-window EXTERNAL blocks Google no longer returns (deleted or
///   moved in Google); `fromYmd...toYmd` are the date-only pull bounds.
public func reconcileCalendarPull(
    events: [ExternalEvent], localBlocks: [CalBlock], fromYmd: String, toYmd: String
) -> CalendarPullPlan {
    let ownEventIds = Set(localBlocks
        .filter { blockKind($0) == .task }
        .compactMap { $0.externalEventId }
        .filter { !$0.isEmpty })
    let toUpsert = events
        .filter { !ownEventIds.contains($0.id) }
        .filter { $0.start.contains("T") }
        .map { externalEventToBlock($0, calendarId: $0.calendarId) }
    let keep = Set(toUpsert.map(\.id))
    let toDelete = localBlocks
        .filter { isExternalBlock($0) && $0.date >= fromYmd && $0.date <= toYmd && !keep.contains($0.id) }
        .map(\.id)
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
