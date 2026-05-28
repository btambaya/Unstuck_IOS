import XCTest
import GRDB
import UnstuckCore
@testable import UnstuckData

final class RoundTripTests: XCTestCase {
    private var db: AppDatabase!

    override func setUpWithError() throws { db = try AppDatabase.makeInMemory() }

    private func roundTrip<T: FetchableRecord & PersistableRecord & Equatable>(_ value: T, key: String) throws -> T? {
        try db.writer.write { try value.upsert($0) }
        return try db.writer.read { try T.fetchOne($0, key: key) }
    }

    func testRichTaskRoundTrips() throws {
        let task = TaskItem(
            id: "task-1", name: "Write spec", estimateMin: 30, totalFocused: 120, done: false,
            priority: .high, tags: ["deep-work", "x"],
            objectives: [Objective(text: "outline", done: true, minutes: 5)],
            comments: [Comment(text: "c", at: "2026-05-21T10:00:00.000Z")],
            intentWhen: "after lunch", intentThen: "open editor", lifeArea: "Work",
            firstPhysicalAction: "open doc", moveCount: 1, completedAt: nil, later: true,
            recurrence: .weekly(daysOfWeek: [1, 3], until: "2026-09-01"),
            createdAt: "2026-05-21T10:00:00.000Z", updatedAt: "2026-05-21T10:00:00.000Z")
        XCTAssertEqual(try roundTrip(task, key: "task-1"), task)
    }

    func testEachTableRoundTrips() throws {
        XCTAssertEqual(try roundTrip(CalBlock(id: "b1", taskId: "t1", taskName: "B", startTime: "09:00", durationMinutes: 50, date: "2026-05-21", externalEventId: "g_1", externalConnectionId: "c1", kind: .external), key: "b1")?.id, "b1")
        XCTAssertEqual(try roundTrip(Session(id: "s1", taskId: "t1", taskName: "S", tags: ["a"], estimateMin: 25, actualSec: 1500, completedAt: "2026-05-21T10:00:00.000Z"), key: "s1")?.actualSec, 1500)
        XCTAssertEqual(try roundTrip(Capture(id: "c1", taskId: "t1", sessionId: "s1", tag: .followUp, body: "x", at: "2026-05-21T10:00:00.000Z"), key: "c1")?.tag, .followUp)
        XCTAssertEqual(try roundTrip(ReasonLog(id: "r1", taskId: "t1", reason: "Bathroom", action: .pause, at: "2026-05-21T10:00:00.000Z", durationSec: 120), key: "r1")?.durationSec, 120)
        let col = ItemCollection(id: "col1", name: "Books", color: "indigo", subtitle: "to read", items: [CollectionItem(id: "i1", body: "Deep Work", pinned: true, done: false, at: "2026-05-21T10:00:00.000Z")], sortOrder: 1)
        XCTAssertEqual(try roundTrip(col, key: "col1"), col)
        XCTAssertEqual(try roundTrip(TagRow(id: "tag1", name: "urgent", color: "coral", sortOrder: 0), key: "tag1")?.name, "urgent")
        let conn = CalendarConnection(id: "conn1", provider: .google, accountEmail: "a@b.com", displayName: "Work", selectedCalendarIds: ["primary", "x"], colorSlot: 2, lastSyncCursor: "cur", connectedAt: "2026-05-21T10:00:00.000Z")
        XCTAssertEqual(try roundTrip(conn, key: "conn1"), conn)
    }
}

final class TaskRepositoryTests: XCTestCase {
    private var db: AppDatabase!
    private var repo: TaskRepository!

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        repo = TaskRepository(db)
    }

    private func task(_ id: String, createdAt: String) -> TaskItem {
        TaskItem(id: id, name: id, estimateMin: 25, createdAt: createdAt, updatedAt: createdAt)
    }

    func testUpsertUpdatesInPlace() throws {
        var t = task("t1", createdAt: "2026-05-21T10:00:00.000Z")
        try repo.upsert(t)
        t.name = "renamed"
        try repo.upsert(t)
        XCTAssertEqual(try repo.all().count, 1)
        XCTAssertEqual(try repo.fetch(id: "t1")?.name, "renamed")
    }

    func testAllOrderedByCreatedAt() throws {
        try repo.upsert(task("late", createdAt: "2026-05-22T10:00:00.000Z"))
        try repo.upsert(task("early", createdAt: "2026-05-20T10:00:00.000Z"))
        XCTAssertEqual(try repo.all().map(\.id), ["early", "late"])
    }

    func testDelete() throws {
        try repo.upsert(task("t1", createdAt: "2026-05-21T10:00:00.000Z"))
        try repo.delete(id: "t1")
        XCTAssertNil(try repo.fetch(id: "t1"))
    }

    func testObserveAllEmitsInitialValue() async throws {
        try repo.upsert(task("t1", createdAt: "2026-05-21T10:00:00.000Z"))
        for try await tasks in repo.observeAll().values(in: db.writer) {
            XCTAssertEqual(tasks.map(\.id), ["t1"])  // first emission = initial fetch
            break
        }
    }
}
