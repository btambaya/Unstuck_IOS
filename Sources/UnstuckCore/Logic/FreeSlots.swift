// Free-slot finder + conflict detector for scheduling. Pure functions.
// Port of lib/free-slots.ts.

import Foundation

public struct Slot: Equatable, Sendable {
    public let date: String       // YYYY-MM-DD
    public let label: String      // 'Today · 9:30 AM'
    public let startTime: String  // HH:MM
    public init(date: String, label: String, startTime: String) {
        self.date = date
        self.label = label
        self.startTime = startTime
    }
}

public struct Conflict: Equatable, Sendable {
    public let block: CalBlock
    public let overlapMin: Int    // minutes the proposed slot overlaps this block
    public init(block: CalBlock, overlapMin: Int) {
        self.block = block
        self.overlapMin = overlapMin
    }
}

// Workday window: 08:00–18:00. Inlined as literals in the default args
// below (Swift forbids referencing non-public symbols in a public
// function's default-argument expression).

/// 12-hour time with AM/PM, e.g. "9:00 AM", "2:30 PM", "12:15 AM".
public func formatTime(_ hhmm: String) -> String {
    let (h, m) = parseHM(hhmm)
    let period = h >= 12 ? "PM" : "AM"
    let h12 = ((h + 11) % 12) + 1
    return "\(h12):\(pad2(m)) \(period)"
}

private func parseHM(_ hhmm: String) -> (Int, Int) {
    let parts = hhmm.split(separator: ":")
    let h = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
    let m = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    return (h, m)
}

private func parseHhmm(_ hhmm: String) -> Int {
    let (h, m) = parseHM(hhmm)
    return h * 60 + m
}

private func pad2(_ n: Int) -> String { String(format: "%02d", n) }

private func hhmmFromMin(_ totalMin: Int) -> String {
    "\(pad2(totalMin / 60)):\(pad2(totalMin % 60))"
}

private func dayLabelFor(_ d: Date, today: Date) -> String {
    let diffDays = Time.wholeDaysBetween(d, today)
    if diffDays == 0 { return "Today" }
    if diffDays == 1 { return "Tomorrow" }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US")
    df.dateFormat = "EEE"
    return df.string(from: d)
}

/// Scan upcoming days for free windows large enough for `durationMin`.
/// Returns at most `limit` slots in chronological order. Every block on a
/// day is treated as consumed (task, placeholder, and external all
/// represent real conflicts).
public func findFreeSlots(
    _ blocks: [CalBlock],
    durationMin: Int,
    now: Date = Date(),
    startDate: Date? = nil,
    daysToScan: Int = 4,
    dayStartMin: Int = 8 * 60,
    dayEndMin: Int = 18 * 60,
    limit: Int = 9
) -> [Slot] {
    let start = startDate ?? now
    var out: [Slot] = []
    let nowMin = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)

    var d = 0
    while d < daysToScan && out.count < limit {
        defer { d += 1 }
        let day = Time.addDays(Time.startOfDay(start), d)
        let dayIso = Clock.dateISO(day)
        let dayBlocks = blocks
            .filter { $0.date == dayIso }
            .map { (start: parseHhmm($0.startTime), end: parseHhmm($0.startTime) + $0.durationMinutes) }
            .sorted { $0.start < $1.start }

        let isToday = Time.startOfDay(day) == Time.startOfDay(now)
        let startMin = isToday
            ? max(dayStartMin, Int((Double(nowMin + 5) / 15).rounded(.up)) * 15)
            : dayStartMin

        var cursor = startMin
        let step = max(durationMin, 30)  // back-to-back no closer than 30min
        let scan = dayBlocks + [(start: dayEndMin, end: dayEndMin)]
        for block in scan {
            let gapEnd = min(block.start, dayEndMin)
            while cursor + durationMin <= gapEnd {
                let hhmm = hhmmFromMin(cursor)
                out.append(Slot(date: dayIso, label: "\(dayLabelFor(day, today: now)) · \(formatTime(hhmm))", startTime: hhmm))
                if out.count >= limit { return out }
                cursor += step
            }
            cursor = max(cursor, block.end)
        }
    }
    return out
}

/// Slots for a specific date only (no multi-day scanning).
public func findFreeSlotsForDate(
    _ blocks: [CalBlock],
    durationMin: Int,
    isoDate: String,
    now: Date = Date(),
    limit: Int = 6,
    dayStartMin: Int = 8 * 60,
    dayEndMin: Int = 18 * 60
) -> [Slot] {
    let parts = isoDate.split(separator: "-").map { Int($0) }
    guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2] else { return [] }
    let day = Time.civil(y, m, d)
    return findFreeSlots(blocks, durationMin: durationMin, now: now, startDate: day,
                         daysToScan: 1, dayStartMin: dayStartMin, dayEndMin: dayEndMin, limit: limit)
}

/// Every block on `date` overlapping the proposed slot, sorted by start.
/// `excludeBlockId` skips a block being edited in-place.
public func findConflicts(
    date: String,
    startTime: String,
    durationMin: Int,
    blocks: [CalBlock],
    excludeBlockId: String? = nil
) -> [Conflict] {
    let startMin = parseHhmm(startTime)
    let endMin = startMin + durationMin
    var out: [Conflict] = []
    for b in blocks {
        if b.date != date { continue }
        if let excludeBlockId, b.id == excludeBlockId { continue }
        let bStart = parseHhmm(b.startTime)
        let bEnd = bStart + b.durationMinutes
        let overlap = max(0, min(endMin, bEnd) - max(startMin, bStart))
        if overlap > 0 { out.append(Conflict(block: b, overlapMin: overlap)) }
    }
    return out.sorted { parseHhmm($0.block.startTime) < parseHhmm($1.block.startTime) }
}

/// A block's time range for conflict pills, e.g. "9:00 AM–10:00 AM".
public func blockTimeRange(_ b: CalBlock) -> String {
    let startMin = parseHhmm(b.startTime)
    let endMin = startMin + b.durationMinutes
    return "\(formatTime(hhmmFromMin(startMin)))–\(formatTime(hhmmFromMin(endMin)))"
}
