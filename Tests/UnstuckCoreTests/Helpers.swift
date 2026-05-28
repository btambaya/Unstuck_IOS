// Shared test factories mirroring the `task()` / `block()` helpers in
// lib/visible-tasks.test.ts so the ported cases read 1:1 against the web.

import Foundation
@testable import UnstuckCore

/// Fixed "now" used across the ported cases (matches the web's NOW).
let NOW: EpochMillis = Time.parseMillis("2026-05-21T12:00:00.000Z")!

/// ISO-8601 (UTC, millis) string for an epoch-ms value — matches JS
/// `new Date(ms).toISOString()`.
func iso(_ ms: EpochMillis) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}

/// Local today (+/- N days) as YYYY-MM-DD, internally consistent with
/// `Clock.todayISO()` so the bucket comparisons line up.
func todayPlus(_ days: Int) -> String {
    let cal = Calendar.current
    let start = cal.startOfDay(for: Date())
    let d = cal.date(byAdding: .day, value: days, to: start)!
    return Clock.dateISO(d)
}

func mkTask(
    id: String = "t",
    name: String = "A task",
    estimateMin: Int = 25,
    totalFocused: Int = 0,
    done: Bool = false,
    priority: Priority? = nil,
    tags: [String]? = nil,
    createdAt: String = "2026-05-21T10:00:00.000Z",
    updatedAt: String = "2026-05-21T10:00:00.000Z",
    lifeArea: String? = nil,
    completedAt: String? = nil,
    moveCount: Int? = nil,
    later: Bool? = nil
) -> TaskItem {
    TaskItem(
        id: id, name: name, estimateMin: estimateMin, totalFocused: totalFocused,
        done: done, priority: priority, tags: tags, lifeArea: lifeArea,
        moveCount: moveCount, completedAt: completedAt, later: later,
        createdAt: createdAt, updatedAt: updatedAt
    )
}

func mkBlock(
    id: String = "b",
    taskId: String? = "t",
    taskName: String = "A task",
    startTime: String = "09:00",
    durationMinutes: Int = 25,
    date: String? = nil,
    kind: CalBlockKind? = nil
) -> CalBlock {
    CalBlock(
        id: id, taskId: taskId, taskName: taskName, startTime: startTime,
        durationMinutes: durationMinutes, date: date ?? Clock.todayISO(), kind: kind
    )
}
