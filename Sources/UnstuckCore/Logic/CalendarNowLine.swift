// Where the calendar's current-time ("NOW") marker goes. Pure functions,
// shared by the Day grid and the Week grid so both put the line at the same
// minute (Ahmad, build 103: the Week view had no line at all).

import Foundation

public enum CalendarNowLine {
    /// Minutes from the top of an hour grid that runs `firstHour`…`lastHour`
    /// to `now`, or nil when `now` is outside the grid.
    ///
    /// Wall-clock minutes (hour × 60 + minute in `calendar`'s time zone) — the
    /// frame the blocks themselves are laid out in (their "HH:mm" start
    /// times), so the line meets a block that is running now in any time zone
    /// and across a daylight-saving change. The end is inclusive (the Day
    /// grid's original rule).
    public static func minutesIntoGrid(now: Date, firstHour: Int, lastHour: Int,
                                       calendar: Calendar) -> Int? {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0) - firstHour * 60
        guard minutes >= 0, minutes <= (lastHour - firstHour) * 60 else { return nil }
        return minutes
    }

    /// The y offset of `minutes` on a grid drawn `pointsPerHour` tall per hour.
    public static func y(minutes: Int, pointsPerHour: Double) -> Double {
        Double(minutes) / 60 * pointsPerHour
    }

    /// Which of `days` (a week's columns, left to right) is `now`'s own day in
    /// `calendar`'s time zone — nil when today isn't in view (another week).
    public static func todayColumn(days: [Date], now: Date, calendar: Calendar) -> Int? {
        days.firstIndex { calendar.isDate($0, inSameDayAs: now) }
    }

    /// Width of one day column in a grid `totalWidth` wide whose first
    /// `gutter` points are the hour labels, split into `columns` equal columns.
    public static func columnWidth(totalWidth: Double, gutter: Double, columns: Int) -> Double {
        guard columns > 0 else { return 0 }
        return max(0, totalWidth - gutter) / Double(columns)
    }

    /// Leading x of column `index` in that grid (where the marker's dot sits).
    public static func columnLeading(index: Int, totalWidth: Double, gutter: Double, columns: Int) -> Double {
        gutter + columnWidth(totalWidth: totalWidth, gutter: gutter, columns: columns) * Double(index)
    }
}
