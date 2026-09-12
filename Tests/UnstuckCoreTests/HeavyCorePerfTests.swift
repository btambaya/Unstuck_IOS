// Release-configuration cross-check for the heavy-account soak.
//
// The App-level soak (Tests/UnstuckAppTests/HeavySoakPerfTests.swift) can only
// be built Debug (-Onone) — the app test target needs @testable + #if DEBUG,
// and the Xcode -O override crashes swift-frontend inside a third-party test
// dependency. These are the SAME pure-logic passes over the SAME heavy shapes,
// runnable with `TZ=UTC swift test -c release --filter HeavyCorePerfTests`, so
// the ranking isn't distorted by -Onone.
//
// Numbers print as `PERF-CORE| <label> | …` (ms). No wall-clock assertions.

import XCTest
@testable import UnstuckCore

private enum CoreHeavy {
    static let tasksN = 800
    static let blocksN = 4_000
    static let sessionsN = 1_500
    static let templatesN = 40
    static let busyDayBlocks = 60

    static func isoStamp(_ daysAgo: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    static func day(_ offset: Int) -> String { LocalDate.addDays(Clock.todayISO(), offset) }

    static let areas = ["Work", "Personal", "Health", "Home", "Family", "Finance", "Learning", "Side project"]
    static let tags = ["deep-work", "quick", "errand", "admin", "call", "review", "writing", "email",
                       "planning", "chore", "reading", "research"]

    static func tasks() -> [TaskItem] {
        (0..<tasksN).map { i in
            let created = isoStamp(Double(i % 400))
            let template = i < templatesN
            return TaskItem(
                id: "task-\(i)",
                name: "Heavy task \(i) — \(tags[i % tags.count]) work item",
                estimateMin: [10, 15, 25, 30, 45, 60, 90][i % 7],
                totalFocused: (i * 137) % 5_000,
                done: !template && i % 5 == 0,
                tags: [tags[i % tags.count], tags[(i + 3) % tags.count]],
                lifeArea: areas[i % areas.count],
                moveCount: i % 7,
                completedAt: (!template && i % 5 == 0) ? isoStamp(Double(i % 30)) : nil,
                later: i % 11 == 0,
                recurrence: template ? .weekly(daysOfWeek: [1, 3, 5], until: nil) : nil,
                createdAt: created,
                updatedAt: created)
        }
    }

    static func blocks() -> [CalBlock] {
        var out: [CalBlock] = []
        out.reserveCapacity(blocksN)
        let spread = blocksN - busyDayBlocks
        for i in 0..<spread {
            let offset = (i % 401) - 200
            let slot = i / 401
            let startMin = 6 * 60 + slot * 55
            let taskIdx = (i * 7) % tasksN
            out.append(CalBlock(
                id: "blk-\(i)", taskId: "task-\(taskIdx)",
                taskName: "Heavy task \(taskIdx)",
                startTime: String(format: "%02d:%02d", startMin / 60, startMin % 60),
                durationMinutes: [45, 60, 90][i % 3],
                date: day(offset), kind: .task,
                done: offset < 0 && i % 3 == 0,
                skipped: offset < 0 && i % 17 == 0,
                completedAt: (offset < 0 && i % 3 == 0) ? isoStamp(Double(-offset)) : nil))
        }
        for j in 0..<busyDayBlocks {
            let startMin = 7 * 60 + j * 15
            let taskIdx = (j * 13) % tasksN
            out.append(CalBlock(
                id: "blk-busy-\(j)", taskId: "task-\(taskIdx)", taskName: "Busy block \(j)",
                startTime: String(format: "%02d:%02d", (startMin / 60) % 24, startMin % 60),
                durationMinutes: 120, date: day(0), kind: .task))
        }
        return out
    }

    static func sessions() -> [Session] {
        (0..<sessionsN).map { i in
            Session(id: "sess-\(i)", taskId: "task-\(i % tasksN)", taskName: "Heavy task \(i % tasksN)",
                    tags: [tags[i % tags.count]], estimateMin: [15, 25, 45][i % 3],
                    actualSec: 600 + (i * 37) % 4_200,
                    completedAt: isoStamp(Double(i % 400) + Double(i % 24) / 24.0))
        }
    }
}

private func corePerf(_ label: String, runs: Int = 5, _ body: () -> Void) {
    var ms: [Double] = []
    for _ in 0..<runs {
        let t0 = CFAbsoluteTimeGetCurrent()
        body()
        ms.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }
    let s = ms.sorted()
    print("PERF-CORE| \(label.padding(toLength: max(label.count, 50), withPad: " ", startingAt: 0)) | runs=\(runs)"
          + String(format: " min=%9.3fms med=%9.3fms max=%9.3fms", s.first!, s[s.count / 2], s.last!))
}

final class HeavyCorePerfTests: XCTestCase {

    func testHeavyPureLogic() {
        let tasks = CoreHeavy.tasks()
        let blocks = CoreHeavy.blocks()
        let sessions = CoreHeavy.sessions()
        let now = Date().timeIntervalSince1970 * 1000
        let todayISO = Clock.todayISO()
        let start = Calendar.current.startOfDay(for: Date())
        let weekly = Recurrence.weekly(daysOfWeek: [1, 3, 5], until: nil)

        corePerf("visibleTasks(.today)") {
            _ = visibleTasks(view: .today, tasks: tasks, blocks: blocks, now: now, activeArea: nil, slipMode: false)
        }
        corePerf("visibleTasks(.backlog)") {
            _ = visibleTasks(view: .backlog, tasks: tasks, blocks: blocks, now: now, activeArea: nil, slipMode: false)
        }
        corePerf("visibleTasks(.all)") {
            _ = visibleTasks(view: .all, tasks: tasks, blocks: blocks, now: now, activeArea: nil, slipMode: false)
        }
        corePerf("visibleTasks ×2 (the TodayModel recompute)") {
            _ = visibleTasks(view: .today, tasks: tasks, blocks: blocks, now: now, activeArea: nil, slipMode: false)
            _ = visibleTasks(view: .backlog, tasks: tasks, blocks: blocks, now: now, activeArea: nil, slipMode: false)
        }
        corePerf("visibleTasks ×2 via ONE shared prep (what TodayModel does now)") {
            let prep = VisibleTasksPrep(tasks: tasks, blocks: blocks)
            _ = visibleTasks(view: .today, prep: prep, now: now, activeArea: nil, slipMode: false)
            _ = visibleTasks(view: .backlog, prep: prep, now: now, activeArea: nil, slipMode: false)
        }
        corePerf("VisibleTasksPrep build (the shared half)") {
            _ = VisibleTasksPrep(tasks: tasks, blocks: blocks)
        }
        corePerf("projectOccurrences") { _ = projectOccurrences(tasks, blocks, fromISO: todayISO) }
        corePerf("projectOverdueOccurrences") { _ = projectOverdueOccurrences(tasks, blocks, todayISO: todayISO) }
        corePerf("overdueOccurrenceDates") { _ = overdueOccurrenceDates(tasks, blocks, todayISO: todayISO) }
        corePerf("pickStartNext") { _ = pickStartNext(tasks: tasks, blocks: blocks, liveTaskId: nil) }
        corePerf("occurrenceBlockFor ×50 rows") {
            for id in blocks.prefix(50).map(\.id) { _ = occurrenceBlockFor(id, tasks: tasks, blocks: blocks) }
        }

        corePerf("materializeOccurrences weekly — 30-day window", runs: 20) {
            _ = materializeOccurrences(weekly, startDate: start, startTime: "09:00", horizonDays: 30)
        }
        corePerf("materializeOccurrences weekly — 56-day default", runs: 20) {
            _ = materializeOccurrences(weekly, startDate: start, startTime: "09:00")
        }
        corePerf("materializeOccurrences × 40 templates — 30 days") {
            for _ in 0..<CoreHeavy.templatesN {
                _ = materializeOccurrences(weekly, startDate: start, startTime: "09:00", horizonDays: 30)
            }
        }
        corePerf("regenerateForTask (1 template, 4000 blocks)") {
            _ = regenerateForTask(task: tasks[0], recurrence: weekly, existingBlocks: blocks,
                                  todayIso: todayISO, startTime: "09:00", startDate: start)
        }

        corePerf("derivePatterns(800 tasks, 4000 blocks)") { _ = derivePatterns(tasks, blocks, todayIso: todayISO) }
        let pats = derivePatterns(tasks, blocks, todayIso: todayISO)
        corePerf("patternGaps") { _ = patternGaps(pats, blocks, todayIso: todayISO) }
        corePerf("goldenHours(1500 sessions)") { _ = goldenHours(sessions, now: Date()) }
        corePerf("freeWindowsToday") { _ = freeWindowsToday(blocks: blocks, today: todayISO, nowHM: "09:30") }
        corePerf("blocks.sorted(date+startTime) — assistant blocksByTask pass") {
            _ = blocks.sorted { ($0.date + $0.startTime) < ($1.date + $1.startTime) }
        }

        let calls: [(String, ReceiptArgs, String)] = (0..<50).map { i in
            ("complete_task", ReceiptArgs(taskId: "task-\(i)"), "ok: completed \"Heavy task \(i)\" id=task-\(i)")
        }
        corePerf("deriveReceipt ×50 (800-task resolve)") {
            for (n, a, r) in calls { _ = deriveReceipt(name: n, args: a, result: r, tasks: tasks, tone: .gentle) }
        }

        // ── primitives, to attribute the cost above ──
        let stamps = tasks.map(\.createdAt)
        corePerf("Time.parseMillis ×800 (ISO8601DateFormatter)") {
            for s in stamps { _ = Time.parseMillis(s) }
        }
        corePerf("Time.startOfDayMillis ×800 (Calendar.current)") {
            for _ in 0..<800 { _ = Time.startOfDayMillis(now) }
        }
        corePerf("isCreatedToday ×800") { for t in tasks { _ = isCreatedToday(t, now: now) } }
        let sessionStamps = sessions.map(\.completedAt)
        corePerf("LocalTime.parseMillis ×1500 (goldenHours' parse)") {
            for s in sessionStamps { _ = LocalTime.parseMillis(s) }
        }
        corePerf("Calendar.current.component(.hour) ×1500") {
            let d = Date()
            for _ in 0..<1500 { _ = Calendar.current.component(.hour, from: d) }
        }
        let cal = Calendar.current
        corePerf("hoisted Calendar.component(.hour) ×1500") {
            let d = Date()
            for _ in 0..<1500 { _ = cal.component(.hour, from: d) }
        }
        corePerf("Clock.todayISO() ×1000") { for _ in 0..<1000 { _ = Clock.todayISO() } }

        XCTAssertEqual(tasks.count, CoreHeavy.tasksN)
        XCTAssertEqual(blocks.count, CoreHeavy.blocksN)
    }
}
