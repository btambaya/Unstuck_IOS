// A weekly series placed on a day it doesn't repeat on (James, build 51,
// 2026-09-13): asked for his Saturday park run, the model sent
// schedule_task(date: "2026-09-20") believing the 20th was a Saturday — it
// was a Sunday — and the executor wrote exactly that: the calendar showed
// Sunday 20 Sep, then Saturdays from the 26th, with no run on the coming
// Saturday the 19th. Nothing checked the date against the series' days.
//
// The assistant executors (schedule_task, and set_task_recurrence over a slot
// placed earlier in the same turn) ask these helpers first. An off-day date is
// refused with the series' nearest real days, written out in plain words, so
// the model corrects itself; nothing is written. Moving ONE occurrence to
// another day on purpose ("I can't do Saturday, put it on Sunday") still
// works: the model repeats the call with the same date, and the result then
// says it is a one-off. Same rule and wording on web, iOS and Android.

import Foundation

private let MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July",
                           "August", "September", "October", "November", "December"]

/// "Saturday 19 September" for a 'YYYY-MM-DD' (no year — the dates here are
/// always within a week or two of today).
public func plainDayName(_ iso: String) -> String {
    let parts = iso.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, (1...12).contains(parts[1]) else { return iso }
    return "\(WEEKDAY_NAMES_CAP[LocalDate.dayOfWeek(iso)]) \(parts[2]) \(MONTH_NAMES[parts[1] - 1])"
}

/// "Saturday", "Saturday and Sunday", "Monday, Wednesday and Friday".
public func weekdayList(_ days: [Int]) -> String {
    let names = Array(Set(days.filter { (0...6).contains($0) })).sorted().map { WEEKDAY_NAMES_CAP[$0] }
    if names.count <= 1 { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + names.last!
}

/// The weekly days of `recurrence`, or nil when it isn't a weekly series with days.
public func weeklyDays(_ recurrence: Recurrence?) -> [Int]? {
    guard case .weekly(let days, _)? = recurrence else { return nil }
    let valid = days.filter { (0...6).contains($0) }
    return valid.isEmpty ? nil : valid
}

/// The series' days nearest `date` that are not before `today`: the latest one
/// before `date` (when there is one on or after today), then the first one
/// after it. "2026-09-20 is a Sunday" for a Saturday series on 2026-09-13
/// gives [2026-09-19, 2026-09-26] — the day the model most likely meant first.
public func nearestSeriesDays(daysOfWeek: [Int], date: String, today: String) -> [String] {
    let wanted = Set(daysOfWeek.filter { (0...6).contains($0) })
    guard !wanted.isEmpty else { return [] }
    var out: [String] = []
    for back in 1...7 {
        let d = LocalDate.addDays(date, -back)
        if d < today { break }
        if wanted.contains(LocalDate.dayOfWeek(d)) { out.append(d); break }
    }
    for ahead in 1...7 {
        let d = LocalDate.addDays(date, ahead)
        if wanted.contains(LocalDate.dayOfWeek(d)) { out.append(d); break }
    }
    return out
}

/// "Saturday 19 September (2026-09-19) or Saturday 26 September (2026-09-26)".
private func namedDates(_ dates: [String]) -> String {
    dates.map { "\(plainDayName($0)) (\($0))" }.joined(separator: " or ")
}

/// True when `date` falls on a day a weekly `recurrence` doesn't repeat on
/// (false for any other recurrence, or none).
public func isOffSeriesDay(_ recurrence: Recurrence?, date: String) -> Bool {
    guard let days = weeklyDays(recurrence), isCalendarDate(date) else { return false }
    return !days.contains(LocalDate.dayOfWeek(date))
}

/// schedule_task's refusal for a weekly series on a day it doesn't repeat on;
/// nil when the date is one of its days (or the task isn't a weekly series).
/// `date` must already be a valid, not-past date (rejectPastDate ran first).
public func rejectOffSeriesDay(taskName: String, recurrence: Recurrence?, date: String, today: String) -> String? {
    guard isOffSeriesDay(recurrence, date: date), let days = weeklyDays(recurrence) else { return nil }
    let dayName = WEEKDAY_NAMES_CAP[LocalDate.dayOfWeek(date)]
    let near = nearestSeriesDays(daysOfWeek: days, date: date, today: today)
    return "error: \"\(taskName)\" repeats every \(weekdayList(days)), but \(date) is a \(dayName) — nothing was scheduled."
        + (near.isEmpty ? "" : " Its nearest \(near.count == 1 ? "day is" : "days are") \(namedDates(near)).")
        + " Call schedule_task again with the day the user meant (a weekday name means the coming one — copy it from context.upcoming)."
        + " Only if they asked for \(plainDayName(date)) on purpose, as a one-off, call schedule_task again with exactly \(date)."
        + " To change the days it repeats on, call set_task_recurrence first."
}

/// The note a confirmed one-off adds to schedule_task's ok result, so the
/// reply says it plainly instead of calling it the series' day.
public func offSeriesDayNote(recurrence: Recurrence?, date: String) -> String {
    guard let days = weeklyDays(recurrence) else { return "" }
    return " — a one-off on \(plainDayName(date)); the series stays on \(weekdayList(days))"
}

/// set_task_recurrence's refusal when the slot placed for the task earlier in
/// THIS turn (create_task / schedule_task with a date) is on a day the new
/// weekly days don't include — the park-run variant: create_task on Sunday
/// 20 Sep, then weekly on Saturday, deleted the Sunday slot and started the
/// series on the 26th, skipping the coming Saturday. nil when it fits.
public func rejectOffSeriesPlacement(taskName: String, placedDate: String, daysOfWeek: [Int], today: String) -> String? {
    let days = daysOfWeek.filter { (0...6).contains($0) }
    guard !days.isEmpty, isCalendarDate(placedDate), !days.contains(LocalDate.dayOfWeek(placedDate)) else { return nil }
    let near = nearestSeriesDays(daysOfWeek: days, date: placedDate, today: today)
    return "error: \"\(taskName)\" was just put on \(plainDayName(placedDate)) (\(placedDate)), which isn't one of the days asked for (\(weekdayList(days))) — nothing changed."
        + (near.isEmpty ? "" : " The nearest matching \(near.count == 1 ? "day is" : "days are") \(namedDates(near)).")
        + " If the user meant one of those, schedule_task \"\(taskName)\" to that day first, then call set_task_recurrence again."
        + " Only if they want it to start on \(plainDayName(placedDate)) on purpose, call set_task_recurrence again unchanged."
}
