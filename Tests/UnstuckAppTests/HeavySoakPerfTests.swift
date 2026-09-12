// SOAK: the app's derivation paths against a HEAVY local account.
//
// Builds ~800 tasks / 4000 cal_blocks / 1500 sessions / 300 captures /
// 40 collections × 30 items / 200 outbox ops / a 200-turn assistant thread
// ENTIRELY LOCALLY (in-memory + a temp-dir GRDB file — never production data)
// and times the production code paths a real user of that size hits:
//
//   • cold-start database hydrate (open + migrate + the observed snapshot read)
//   • the hydrate write path (AppDatabase.replaceAll per table)
//   • TodayModel's snapshot derivation (visibleTasks × 2 + occurrence projection)
//   • Recurrence.materializeOccurrences over a month window
//   • CalendarModel's week/month derivation incl. layoutLanes
//   • buildAssistantContext (one per assistant turn)
//   • receipt derivation over a 50-call bulk turn
//   • the assistant thread's persist + cold load at 200 turns
//   • enqueue + drain of 200 outbox ops
//
// Numbers print as `PERF| <label> | runs=N min=… med=… max=…` (ms).
// Diagnostic only — the XCTAssert calls only prove the fixtures really landed;
// nothing here asserts a wall-clock budget (that would be flaky).

import XCTest
import Supabase
import UnstuckCore
import UnstuckData
import UnstuckSync
@testable import Unstuck

// MARK: - the heavy fixture (pure, local)

enum HeavySeed {
    static let tasksN = 800
    static let blocksN = 4_000
    static let sessionsN = 1_500
    static let capturesN = 300
    static let collectionsN = 40
    static let itemsPerCollection = 30
    static let templatesN = 40          // recurring tasks among the 800
    static let busyDayBlocks = 60       // heavy-overlap day (today)

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
                firstPhysicalAction: i % 4 == 0 ? "Open the doc and write one sentence" : nil,
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
        // ~10/day over 401 days centred on today; starts stagger by 55 min from
        // 06:00 with 45–90 min durations, so neighbouring blocks overlap.
        for i in 0..<spread {
            let offset = (i % 401) - 200
            let slot = i / 401                      // 0…9 within the day
            let startMin = 6 * 60 + slot * 55
            let taskIdx = (i * 7) % tasksN
            out.append(CalBlock(
                id: "blk-\(i)",
                taskId: "task-\(taskIdx)",
                taskName: "Heavy task \(taskIdx) — \(tags[taskIdx % tags.count]) work item",
                startTime: String(format: "%02d:%02d", startMin / 60, startMin % 60),
                durationMinutes: [45, 60, 90][i % 3],
                date: day(offset),
                kind: .task,
                done: offset < 0 && i % 3 == 0,
                skipped: offset < 0 && i % 17 == 0,
                completedAt: (offset < 0 && i % 3 == 0) ? isoStamp(Double(-offset)) : nil))
        }
        // Worst-case lane day: 60 blocks on TODAY, 15-min staggered starts,
        // 120-min durations → an 8-deep overlap cluster.
        for j in 0..<busyDayBlocks {
            let startMin = 7 * 60 + j * 15
            let taskIdx = (j * 13) % tasksN
            out.append(CalBlock(
                id: "blk-busy-\(j)",
                taskId: "task-\(taskIdx)",
                taskName: "Busy block \(j)",
                startTime: String(format: "%02d:%02d", (startMin / 60) % 24, startMin % 60),
                durationMinutes: 120,
                date: day(0),
                kind: .task))
        }
        return out
    }

    static func sessions() -> [UnstuckCore.Session] {
        (0..<sessionsN).map { i in
            UnstuckCore.Session(id: "sess-\(i)", taskId: "task-\(i % tasksN)",
                                taskName: "Heavy task \(i % tasksN)",
                                tags: [tags[i % tags.count]],
                                estimateMin: [15, 25, 45][i % 3],
                                actualSec: 600 + (i * 37) % 4_200,
                                completedAt: isoStamp(Double(i % 400) + Double(i % 24) / 24.0))
        }
    }

    static func captures() -> [Capture] {
        (0..<capturesN).map { i in
            Capture(id: "cap-\(i)", taskId: i % 3 == 0 ? "task-\(i % tasksN)" : nil,
                    sessionId: i % 4 == 0 ? "sess-\(i % sessionsN)" : nil,
                    tag: [CaptureTag.idea, .distraction, .followUp][i % 3],
                    body: "Captured thought number \(i) with a sentence of context after it.",
                    at: isoStamp(Double(i % 120) / 4.0))
        }
    }

    static func collections() -> [ItemCollection] {
        (0..<collectionsN).map { c in
            let items = (0..<itemsPerCollection).map { j in
                CollectionItem(id: "c\(c)-i\(j)", body: "List \(c) item \(j) — something to pick up",
                               at: isoStamp(Double(j)))
            }
            return ItemCollection(id: "col-\(c)", name: "Heavy list \(c)", color: ["green", "indigo", "coral"][c % 3],
                                  subtitle: c % 2 == 0 ? "A framing line" : nil,
                                  items: items, sortOrder: c, archived: false)
        }
    }

    static func lifeAreas() -> [LifeArea] {
        areas.enumerated().map { LifeArea(id: "area-\($0.element)", name: $0.element,
                                          color: ["indigo", "coral", "green"][$0.offset % 3], sortOrder: $0.offset) }
    }

    static func tagRows() -> [TagRow] {
        tags.enumerated().map { TagRow(id: "tag-\($0.element)", name: $0.element, color: nil, sortOrder: $0.offset) }
    }

    /// Write the whole fixture — one transaction per table (the hydrate shape).
    static func write(into db: AppDatabase) throws {
        try db.replaceAll(TaskItem.self, with: tasks())
        try db.replaceAll(CalBlock.self, with: blocks())
        try db.replaceAll(UnstuckCore.Session.self, with: sessions())
        try db.replaceAll(Capture.self, with: captures())
        try db.replaceAll(ItemCollection.self, with: collections())
        try db.replaceAll(LifeArea.self, with: lifeAreas())
        try db.replaceAll(TagRow.self, with: tagRows())
    }

    /// A 200-turn assistant thread: user / assistant-with-tool_calls / tool /
    /// assistant-reply-with-receipts — the real persisted shape.
    static func thread(_ n: Int = 200) -> [AssistantTurn] {
        let base = Date().timeIntervalSince1970 * 1000
        return (0..<n).map { i in
            let at = base - Double(n - i) * 60_000
            switch i % 4 {
            case 0:
                return AssistantTurn(ChatMessage(role: "user",
                                                 content: "Turn \(i): can you move the review to Thursday and add two follow-ups?"), at: at)
            case 1:
                return AssistantTurn(ChatMessage(role: "assistant", content: "On it — scheduling that now.",
                                                 toolCalls: [ToolCall(id: "call-\(i)", type: "function",
                                                                      function: ToolFunction(name: "schedule_task",
                                                                                             arguments: "{\"taskId\":\"task-\(i % tasksN)\",\"date\":\"2026-09-17\",\"startTime\":\"09:00\"}"))]),
                                     at: at)
            case 2:
                return AssistantTurn(ChatMessage(role: "tool",
                                                 content: "ok: scheduled \"Heavy task \(i % tasksN)\" id=task-\(i % tasksN)",
                                                 toolCallId: "call-\(i - 1)", name: "schedule_task"), at: at)
            default:
                return AssistantTurn(ChatMessage(role: "assistant", content: "Booked — Thursday at nine, forty-five minutes."),
                                     at: at,
                                     receipts: [Receipt(icon: .calendar, label: "Scheduled “Heavy task \(i % tasksN)” · 2026-09-17 09:00")])
            }
        }
    }
}

// MARK: - timing helpers

@discardableResult
func perfClock(_ label: String, runs: Int = 5, _ body: () throws -> Void) rethrows -> Double {
    var ms: [Double] = []
    for _ in 0..<runs {
        let t0 = CFAbsoluteTimeGetCurrent()
        try body()
        ms.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }
    return perfReport(label, ms)
}

@discardableResult
func perfReport(_ label: String, _ ms: [Double]) -> Double {
    let s = ms.sorted()
    let med = s[s.count / 2]
    print("PERF| \(label.padding(toLength: max(label.count, 56), withPad: " ", startingAt: 0)) | runs=\(s.count)"
          + String(format: " min=%9.3fms med=%9.3fms max=%9.3fms", s.first ?? 0, med, s.last ?? 0))
    return med
}

// MARK: - a no-op sync gateway (never touches the network)

private struct NoopGateway: SyncGatewayProtocol {
    func upsert<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws {}
    func delete(table: String, id: String) async throws {}
    func rpc(fn: String, paramsJSON: String) async throws {}
}

// MARK: - the soak

@MainActor
final class HeavySoakPerfTests: XCTestCase {

    private static let tmpDir: URL = {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unstuck-soak-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private func heavyMemoryDB() throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try HeavySeed.write(into: db)
        return db
    }

    private func areaRepo(_ db: AppDatabase) -> Repository<LifeArea> { Repository(db, orderColumn: "sortOrder") }
    private func sessionRepo(_ db: AppDatabase) -> Repository<UnstuckCore.Session> { Repository(db, orderColumn: "completedAt") }
    private func captureRepo(_ db: AppDatabase) -> Repository<Capture> { Repository(db, orderColumn: "at") }

    // 1 ─ cold-start database hydrate (on-disk, the real shipping path)

    func test01_coldStartDatabaseHydrate() throws {
        let path = Self.tmpDir.appendingPathComponent("cold-\(UUID().uuidString).sqlite").path
        let seeded = try AppDatabase.make(path: path)

        try perfClock("hydrate WRITE: replaceAll ×7 tables (on disk)", runs: 3) {
            try HeavySeed.write(into: seeded)
        }

        try perfClock("cold open: AppDatabase.make(path:) + migrate", runs: 5) {
            _ = try AppDatabase.make(path: path)
        }

        let db = try AppDatabase.make(path: path)
        let repo = TaskRepository(db)

        try perfClock("cold read: TaskRepository.all() — 800 tasks w/ JSON cols", runs: 5) { _ = try repo.all() }
        try perfClock("cold read: fetchAllCalBlocks() — 4000", runs: 5) { _ = try db.fetchAllCalBlocks() }
        try perfClock("cold read: LifeArea.all()", runs: 5) { _ = try self.areaRepo(db).all() }
        try perfClock("cold read: Session.all() — 1500", runs: 5) { _ = try self.sessionRepo(db).all() }
        try perfClock("cold read: Capture.all() — 300", runs: 5) { _ = try self.captureRepo(db).all() }
        try perfClock("cold read: fetchAllCollections() — 40×30 JSON items", runs: 5) { _ = try db.fetchAllCollections() }
        try perfClock("cold read: observeTasksAndBlocks equivalent (4 fetches)", runs: 5) {
            _ = try repo.all()
            _ = try db.fetchAllCalBlocks()
            _ = try self.areaRepo(db).all()
            _ = try self.sessionRepo(db).all()
        }

        XCTAssertEqual(try repo.all().count, HeavySeed.tasksN)
        XCTAssertEqual(try db.fetchAllCalBlocks().count, HeavySeed.blocksN)
    }

    // 2 ─ Today model derivation

    func test02_todayModelDerivation() throws {
        let db = try heavyMemoryDB()
        let repo = TaskRepository(db)
        let tasks = try repo.all()
        let blocks = try db.fetchAllCalBlocks()
        let now = Date().timeIntervalSince1970 * 1000
        let todayISO = Clock.todayISO()

        let today = TodayModel(repo)
        today.areas = try areaRepo(db).all()
        today.all = tasks                 // first didSet: recompute with no blocks

        perfClock("TodayModel.recomputeSnapshot (didSet on blocks)", runs: 5) {
            today.blocks = []
            today.blocks = blocks
        }

        perfClock("  visibleTasks(.today)", runs: 5) {
            _ = visibleTasks(view: .today, tasks: tasks, blocks: blocks, now: now, activeArea: nil, slipMode: false)
        }
        perfClock("  visibleTasks(.backlog)", runs: 5) {
            _ = visibleTasks(view: .backlog, tasks: tasks, blocks: blocks, now: now, activeArea: nil, slipMode: false)
        }
        perfClock("  visibleTasks(.all)", runs: 5) {
            _ = visibleTasks(view: .all, tasks: tasks, blocks: blocks, now: now, activeArea: nil, slipMode: false)
        }
        perfClock("  visibleTasks(.upcoming)", runs: 5) {
            _ = visibleTasks(view: .upcoming, tasks: tasks, blocks: blocks, now: now, activeArea: nil, slipMode: false)
        }
        perfClock("  projectOccurrences(fromISO: today)", runs: 5) {
            _ = projectOccurrences(tasks, blocks, fromISO: todayISO)
        }
        perfClock("  projectOverdueOccurrences", runs: 5) {
            _ = projectOverdueOccurrences(tasks, blocks, todayISO: todayISO)
        }
        perfClock("  overdueOccurrenceDates (backlog row labels)", runs: 5) {
            _ = overdueOccurrenceDates(tasks, blocks, todayISO: todayISO)
        }
        perfClock("  pickStartNext", runs: 5) {
            _ = pickStartNext(tasks: tasks, blocks: blocks, liveTaskId: nil)
        }
        let rowIds = Array(blocks.prefix(50).map(\.id))
        perfClock("  occurrenceBlockFor ×50 rows (linear scan each)", runs: 5) {
            for id in rowIds { _ = occurrenceBlockFor(id, tasks: tasks, blocks: blocks) }
        }

        print("PERF| today rows=\(visibleTasks(view: .today, tasks: tasks, blocks: blocks, now: now, activeArea: nil, slipMode: false).count)"
              + " backlog=\(today.backlogCount)")
        XCTAssertGreaterThan(today.backlogCount, 0)
    }

    // 3 ─ recurrence occurrence projection over a month window

    func test03_materializeOccurrences() throws {
        let start = Calendar.current.startOfDay(for: Date())
        let daily = Recurrence.daily(until: nil)
        let weekly = Recurrence.weekly(daysOfWeek: [1, 3, 5], until: nil)
        let monthly = Recurrence.monthly(until: nil)

        perfClock("materializeOccurrences daily — 30-day window", runs: 20) {
            _ = materializeOccurrences(daily, startDate: start, startTime: "09:00", horizonDays: 30)
        }
        perfClock("materializeOccurrences weekly(M/W/F) — 30-day window", runs: 20) {
            _ = materializeOccurrences(weekly, startDate: start, startTime: "09:00", horizonDays: 30)
        }
        perfClock("materializeOccurrences monthly — 30-day window", runs: 20) {
            _ = materializeOccurrences(monthly, startDate: start, startTime: "09:00", horizonDays: 30)
        }
        perfClock("materializeOccurrences weekly — 56-day horizon (ship default)", runs: 20) {
            _ = materializeOccurrences(weekly, startDate: start, startTime: "09:00")
        }
        perfClock("materializeOccurrences × 40 templates — 30-day window", runs: 5) {
            for _ in 0..<HeavySeed.templatesN {
                _ = materializeOccurrences(weekly, startDate: start, startTime: "09:00", horizonDays: 30)
            }
        }

        let db = try heavyMemoryDB()
        let tasks = try TaskRepository(db).all()
        let blocks = try db.fetchAllCalBlocks()
        let tpl = try XCTUnwrap(tasks.first { $0.recurrence != nil })
        perfClock("regenerateForTask (1 template, 4000 existing blocks)", runs: 5) {
            _ = regenerateForTask(task: tpl, recurrence: weekly, existingBlocks: blocks,
                                  todayIso: Clock.todayISO(), startTime: "09:00", startDate: start)
        }
        perfClock("regenerateForTask × 40 templates (edit-all worst case)", runs: 3) {
            for t in tasks.prefix(HeavySeed.templatesN) {
                _ = regenerateForTask(task: t, recurrence: weekly, existingBlocks: blocks,
                                      todayIso: Clock.todayISO(), startTime: "09:00", startDate: start)
            }
        }

        XCTAssertEqual(materializeOccurrences(daily, startDate: start, startTime: "09:00", horizonDays: 30).count, 30)
    }

    // 4 ─ calendar week + month view models, incl. lane layout

    func test04_calendarViewModels() throws {
        let db = try heavyMemoryDB()
        let repo = TaskRepository(db)
        let tasks = try repo.all()
        let blocks = try db.fetchAllCalBlocks()
        let sessions = try sessionRepo(db).all()

        let vm = CalendarModel(repo, Repository<CalendarConnection>(db, orderColumn: "connectedAt"))
        vm.tasks = tasks

        perfClock("CalendarModel.recomputeBlockDerived (byDate + laidByDate, 401 days)", runs: 5) {
            vm.blocks = []
            vm.blocks = blocks
        }
        perfClock("CalendarModel.recomputeFocusByDay (1500 sessions)", runs: 5) {
            vm.sessions = []
            vm.sessions = sessions
        }
        perfClock("CalendarModel.recomputeTaskDerived (unscheduled tray)", runs: 5) {
            vm.tasks = []
            vm.tasks = tasks
        }

        let busy = vm.blocks(on: Clock.todayISO())
        perfClock("layoutLanes — busiest day (\(busy.count) blocks)", runs: 20) { _ = layoutLanes(busy) }
        perfClock("layoutLanes — all 4000 blocks in one pass", runs: 5) { _ = layoutLanes(blocks) }
        perfClock("mergedLanes(own: busiest day, shared: [])", runs: 20) {
            _ = mergedLanes(own: busy, shared: [SharedBlock]())
        }

        let cal = Calendar.current
        let monday = cal.date(byAdding: .day, value: -((cal.component(.weekday, from: Date()) + 5) % 7),
                              to: cal.startOfDay(for: Date()))!
        let weekDays = (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }
        perfClock("WeekView body pass (7× blocks(on:) rollup + 7× laidBlocks)", runs: 20) {
            let planned = weekDays.map { d in
                vm.blocks(on: Clock.dateISO(d)).filter { isTaskBlock($0) }.reduce(0) { $0 + $1.durationMinutes }
            }
            _ = planned.reduce(0, +)
            for d in weekDays { _ = vm.laidBlocks(on: Clock.dateISO(d)) }
        }

        let first = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let daysInMonth = cal.range(of: .day, in: .month, for: first)!.count
        let monthCells = (0..<daysInMonth).map { cal.date(byAdding: .day, value: $0, to: first)! }
        perfClock("MonthView body pass (\(daysInMonth) cells × blocks(on:) reduce)", runs: 20) {
            var byDay: [String: Int] = [:]
            for d in monthCells {
                let iso = Clock.dateISO(d)
                let own = vm.blocks(on: iso).filter { !$0.skipped }.reduce(0) { $0 + $1.durationMinutes }
                if own > 0 { byDay[iso] = own }
            }
            _ = byDay.values.max()
        }

        print("PERF| busiest-day blocks=\(busy.count) lanes=\(layoutLanes(busy).map(\.lanes).max() ?? 0)")
        XCTAssertGreaterThan(busy.count, 50)
    }

    // 5 ─ assistant context build (once per turn, text AND voice)

    func test05_assistantContextBuild() throws {
        AssistantModel.scrubPersisted()
        let model = AppModel()
        model.startUITestMode()
        let db = try XCTUnwrap(model.db)
        try HeavySeed.write(into: db)
        let state = AppModelAssistantState(model: model, assistant: model.assistant)

        perfClock("buildAssistantContext (heavy account, PER TURN)", runs: 5) { _ = buildAssistantContext(state) }

        let ctx = buildAssistantContext(state)
        perfClock("assistantContextJSON encode", runs: 5) { _ = assistantContextJSON(ctx) }
        print("PERF| assistantContext JSON size = \(assistantContextJSON(ctx).utf8.count) bytes")

        perfClock("  state.getTasks() — full-table read", runs: 5) { _ = state.getTasks() }
        perfClock("  state.getBlocks() — full-table read", runs: 5) { _ = state.getBlocks() }
        perfClock("  state.getCollections() — full-table read", runs: 5) { _ = state.getCollections() }
        perfClock("  state.getSessions() — full-table read", runs: 5) { _ = state.getSessions() }
        perfClock("  state.getCaptures() — full-table read", runs: 5) { _ = state.getCaptures() }

        let tasks = state.getTasks(), blocks = state.getBlocks(), sessions = state.getSessions()
        let todayISO = Clock.todayISO()
        perfClock("  derivePatterns(tasks, blocks)", runs: 5) { _ = derivePatterns(tasks, blocks, todayIso: todayISO) }
        let pats = derivePatterns(tasks, blocks, todayIso: todayISO)
        perfClock("  patternGaps", runs: 5) { _ = patternGaps(pats, blocks, todayIso: todayISO) }
        perfClock("  freeWindowsToday", runs: 5) {
            _ = freeWindowsToday(blocks: blocks, today: todayISO, nowHM: state.nowHM())
        }
        perfClock("  goldenHours(1500 sessions)", runs: 5) { _ = goldenHours(sessions, now: Date()) }
        perfClock("  blocks.sorted(by: date+startTime) — the blocksByTask pass", runs: 5) {
            _ = blocks.sorted { ($0.date + $0.startTime) < ($1.date + $1.startTime) }
        }

        XCTAssertNotNil(ctx["tasks"])
    }

    // 6 ─ receipt derivation over a bulk turn

    func test06_receiptsOverBulkTurn() throws {
        let db = try heavyMemoryDB()
        let tasks = try TaskRepository(db).all()
        let facts: [ProfileFact] = []

        let calls: [(String, ToolArgs, String)] = (0..<50).map { i in
            let id = "task-\(i)"
            switch i % 5 {
            case 0: return ("create_task", ToolArgs([:]), "ok: created \"Heavy task \(i)\" id=\(id)")
            case 1: return ("schedule_task",
                            ToolArgs(["taskId": .string(id), "date": .string("2026-09-17"), "startTime": .string("09:00")]),
                            "ok: scheduled \"Heavy task \(i)\"")
            case 2: return ("complete_task", ToolArgs(["taskId": .string(id)]),
                            "ok: completed \"Heavy task \(i)\" id=\(id)")
            case 3: return ("block_time",
                            ToolArgs(["date": .string("2026-09-17"), "startTime": .string("10:00")]),
                            "ok: blocked \"Commitment \(i)\" id=blk-\(i)")
            default: return ("create_tasks", ToolArgs([:]),
                             "ok: created 25 tasks ids=" + (0..<25).map { "task-\($0)" }.joined(separator: ","))
            }
        }

        perfClock("assistantReceipt ×50 (bulk turn, 800-task resolve)", runs: 5) {
            for (name, args, result) in calls {
                _ = assistantReceipt(name: name, args: args, result: result, tasks: tasks, facts: facts)
            }
        }
        perfClock("  deriveReceipt ×50 (core only)", runs: 5) {
            for (name, args, result) in calls {
                _ = deriveReceipt(name: name, args: args.receiptArgs, result: result, tasks: tasks, tone: .gentle)
            }
        }
        perfClock("  toneFromFacts ×50", runs: 5) { for _ in 0..<50 { _ = toneFromFacts(facts) } }

        XCTAssertNotNil(assistantReceipt(name: calls[0].0, args: calls[0].1, result: calls[0].2,
                                         tasks: tasks, facts: facts))
    }

    // 7 ─ the 200-turn assistant thread: persist + cold load

    func test07_assistantThread200Turns() throws {
        AssistantModel.scrubPersisted()
        let model = AppModel()
        model.startUITestMode()

        let thread = HeavySeed.thread(200)

        try perfClock("thread persist: encode 200 turns + UserDefaults write", runs: 5) {
            let data = try JSONEncoder().encode(thread)
            UserDefaults.standard.set(data, forKey: "unstuck.assistant.thread")
        }
        let size = (UserDefaults.standard.data(forKey: "unstuck.assistant.thread") ?? Data()).count
        print("PERF| persisted 200-turn thread = \(size) bytes")

        perfClock("AssistantModel.init → loadHistory (200 turns + tool-call scrub)", runs: 5) {
            _ = AssistantModel(model: model, client: nil)
        }

        let assistant = AssistantModel(model: model, client: nil)
        perfClock("appendLocal ×20 on a 200-turn thread (persist per append)", runs: 3) {
            for i in 0..<20 { assistant.appendLocal("local line \(i)") }
        }

        perfClock("displayTurns filter (200 turns)", runs: 20) { _ = AssistantModel.displayTurns(thread) }
        perfClock("modelWindow (200 turns → 40)", runs: 20) { _ = AssistantModel.modelWindow(thread) }

        AssistantModel.scrubPersisted()
        XCTAssertEqual(thread.count, 200)
    }

    // 8 ─ outbox: 200 queued ops, enqueue + drain

    func test08_outboxFlush200Ops() async throws {
        let db = try AppDatabase.makeInMemory()
        try HeavySeed.write(into: db)
        let write = WriteThrough(db: db)
        let box = OutboxStore(db)
        let nowISO = HeavySeed.isoStamp(0)
        let tasks = Array(try TaskRepository(db).all().prefix(200))

        var t0 = CFAbsoluteTimeGetCurrent()
        for t in tasks { try await write.upsertTask(t, nowISO: nowISO) }
        perfReport("enqueue 200 task upserts (WriteThrough: row + op, 1 txn each)",
                   [(CFAbsoluteTimeGetCurrent() - t0) * 1000])
        XCTAssertEqual(try box.count(), 200)

        try perfClock("OutboxStore.pending() (200 ops)", runs: 5) { _ = try box.pending() }
        try perfClock("OutboxStore.nextFlushable() (200 ops)", runs: 5) { _ = try box.nextFlushable() }

        let flusher = OutboxFlusher(gateway: NoopGateway(), db: db)
        t0 = CFAbsoluteTimeGetCurrent()
        await flusher.flush(userId: "soak-user")
        perfReport("OutboxFlusher.flush 200 ops (no-op gateway = local cost)",
                   [(CFAbsoluteTimeGetCurrent() - t0) * 1000])
        XCTAssertEqual(try box.count(), 0)

        for t in tasks { try await write.upsertTask(t, nowISO: nowISO) }
        t0 = CFAbsoluteTimeGetCurrent()
        for op in try box.pending() { if let s = op.opSeq { try box.markDone(s) } }
        perfReport("markDone ×200 (one write txn each)", [(CFAbsoluteTimeGetCurrent() - t0) * 1000])
    }

    // 9 ─ the whole cold-start derivation chain, end to end

    func test09_coldStartChain() throws {
        let path = Self.tmpDir.appendingPathComponent("chain-\(UUID().uuidString).sqlite").path
        let seeded = try AppDatabase.make(path: path)
        try HeavySeed.write(into: seeded)
        _ = seeded

        try perfClock("COLD-START CHAIN: open + snapshot read + Today derive + Calendar derive", runs: 3) {
            let db = try AppDatabase.make(path: path)
            let repo = TaskRepository(db)
            let tasks = try repo.all()
            let blocks = try db.fetchAllCalBlocks()
            let areas = try self.areaRepo(db).all()
            let sessions = try self.sessionRepo(db).all()

            let today = TodayModel(repo)
            today.areas = areas
            today.sessions = sessions
            today.all = tasks
            today.blocks = blocks

            let vm = CalendarModel(repo, Repository<CalendarConnection>(db, orderColumn: "connectedAt"))
            vm.tasks = tasks
            vm.blocks = blocks
            vm.sessions = sessions
        }
    }
}
