// `buildAssistantContext` derives two things from the whole block set: each
// task's NEXT live block (`scheduledDate` / `scheduledTime`) and the `week`
// rows. Both used to scan or sort all 4,000 blocks; they now filter first and
// resolve tasks through a dictionary.
//
// The model reads those fields to decide when something is already planned, so
// a changed pick is a behaviour change, not a perf detail. These tests pin the
// pick against a REFERENCE written the original way (sort everything, then
// guard inside the loop; linear `first(where:)` for the task), over fixtures
// built to make the difference visible if there were one: done and skipped
// blocks that sort ahead of the live one, past blocks, ties on
// date+startTime, blocks whose task doesn't exist, and duplicate task ids.

import XCTest
import Supabase
import UnstuckCore
@testable import Unstuck

@MainActor
final class AssistantContextDerivationTests: XCTestCase {

    // MARK: - the reference (what the builder did before)

    private func referenceBlocksByTask(_ blocks: [CalBlock], today: String) -> [String: CalBlock] {
        var out: [String: CalBlock] = [:]
        for b in blocks.sorted(by: { ($0.date + $0.startTime) < ($1.date + $1.startTime) }) {
            guard let tid = b.taskId, !tid.isEmpty, !b.done, !b.skipped, b.date >= today else { continue }
            if out[tid] == nil { out[tid] = b }
        }
        return out
    }

    private func referenceTask(_ tasks: [TaskItem], _ id: String) -> TaskItem? {
        tasks.first { $0.id == id }
    }

    // MARK: - fixture

    private func block(_ id: String, _ taskId: String?, _ date: String, _ time: String,
                       done: Bool = false, skipped: Bool = false, name: String = "") -> CalBlock {
        CalBlock(id: id, taskId: taskId, taskName: name, startTime: time, durationMinutes: 30,
                 date: date, kind: .task, done: done, skipped: skipped)
    }

    private func fixture() -> (tasks: [TaskItem], blocks: [CalBlock], today: String) {
        let today = Clock.todayISO()
        let yesterday = LocalDate.addDays(today, -1)
        let lastMonth = LocalDate.addDays(today, -30)
        let tomorrow = LocalDate.addDays(today, 1)
        let nextWeek = LocalDate.addDays(today, 6)

        let tasks = (0..<40).map { task("t\($0)", "Task \($0)") }
            // a duplicate id: first-wins must still hold
            + [task("t0", "Shadow of task 0")]

        var blocks: [CalBlock] = []
        for i in 0..<40 {
            let tid = "t\(i)"
            // past blocks (must never be picked)
            blocks.append(block("p\(i)", tid, lastMonth, "06:00"))
            blocks.append(block("p2\(i)", tid, yesterday, "07:00"))
            // a DONE and a SKIPPED block earlier in the day than the live one
            blocks.append(block("d\(i)", tid, today, "08:00", done: true))
            blocks.append(block("s\(i)", tid, today, "08:30", skipped: true))
            // the live ones, in reverse order so sorting actually matters
            blocks.append(block("late\(i)", tid, nextWeek, "10:00", name: "late \(i)"))
            if i % 3 == 0 { blocks.append(block("mid\(i)", tid, tomorrow, "09:00", name: "mid \(i)")) }
            if i % 5 == 0 { blocks.append(block("early\(i)", tid, today, "12:00", name: "early \(i)")) }
            // a tie on date+startTime with the live one
            if i % 7 == 0 { blocks.append(block("tie\(i)", tid, nextWeek, "10:00", name: "tie \(i)")) }
        }
        // blocks with no task, an empty task id, and an unknown task id
        blocks.append(block("orphan1", nil, today, "05:00"))
        blocks.append(block("orphan2", "", today, "05:00"))
        blocks.append(block("orphan3", "t-does-not-exist", today, "05:00", name: "ghost"))
        return (tasks, blocks, today)
    }

    // MARK: - tests

    /// The NEXT-live-block pick, per task, must be byte-identical to the
    /// sort-everything version — including which block wins a tie.
    func testNextLiveBlockPickIsUnchanged() {
        let (tasks, blocks, today) = fixture()
        let api = FakeAssistantState()
        api.tasks = tasks
        api.blocks = blocks

        let want = referenceBlocksByTask(blocks, today: today)
        let ctx = buildAssistantContext(api)
        guard case .array(let rows)? = ctx["tasks"] else { return XCTFail("no tasks in context") }

        var seen = 0
        for row in rows {
            guard case .object(let o) = row, case .string(let id)? = o["id"] else { continue }
            let wanted = want[id]
            if let wanted, !wanted.startTime.isEmpty {
                XCTAssertEqual(o["scheduledDate"], .string(wanted.date), "task \(id)")
                XCTAssertEqual(o["scheduledTime"], .string(wanted.startTime), "task \(id)")
                seen += 1
            } else if wanted == nil {
                XCTAssertNil(o["scheduledDate"], "task \(id) should have no next block")
                XCTAssertNil(o["scheduledTime"], "task \(id)")
            }
        }
        XCTAssertGreaterThan(seen, 20, "fixture didn't exercise the pick")
    }

    /// The `week` rows — same rows, same order, same names (names resolve
    /// through the task dictionary now, with the block's own name winning).
    func testWeekRowsAreUnchanged() {
        let (tasks, blocks, today) = fixture()
        let api = FakeAssistantState()
        api.tasks = tasks
        api.blocks = blocks

        let weekFrom = LocalDate.mondayOf(today)
        let weekTo = LocalDate.addDays(weekFrom, 7)
        let wantRows = blocks
            .filter { $0.date >= weekFrom && $0.date < weekTo }
            .sorted { ($0.date + $0.startTime) < ($1.date + $1.startTime) }
            .prefix(60)
            .map { b -> [String: AnyJSON] in
                let t = b.taskId.flatMap { id in self.referenceTask(tasks, id) }
                var o: [String: AnyJSON] = ["date": .string(b.date)]
                if !b.startTime.isEmpty { o["time"] = .string(b.startTime) }
                o["name"] = .string(!b.taskName.isEmpty ? b.taskName : (t?.name ?? "?"))
                if t?.done == true { o["done"] = .bool(true) }
                return o
            }

        guard case .array(let got)? = buildAssistantContext(api)["week"] else { return XCTFail("no week") }
        XCTAssertEqual(got.count, wantRows.count)
        XCTAssertGreaterThan(wantRows.count, 5, "fixture didn't produce week rows")
        for (i, row) in got.enumerated() {
            guard case .object(let o) = row else { return XCTFail("week row \(i) not an object") }
            XCTAssertEqual(o, wantRows[i], "week row \(i)")
        }
    }

    /// A duplicate task id resolves to the FIRST one, exactly as
    /// `tasks.first { $0.id == id }` did.
    func testDuplicateTaskIdResolvesFirstWins() {
        let today = Clock.todayISO()
        let api = FakeAssistantState()
        api.tasks = [task("dup", "First wins"), task("dup", "Second loses")]
        api.blocks = [block("b1", "dup", today, "09:00")]   // no taskName → falls back to the task's
        guard case .array(let rows)? = buildAssistantContext(api)["week"], case .object(let o) = rows[0] else {
            return XCTFail("no week row")
        }
        XCTAssertEqual(o["name"], .string("First wins"))
    }

    /// Empty input still produces the same (empty) derivations.
    func testEmptyStore() {
        let api = FakeAssistantState()
        let ctx = buildAssistantContext(api)
        XCTAssertEqual(ctx["week"], .array([]))
        XCTAssertEqual(ctx["tasks"], .array([]))
    }
}
