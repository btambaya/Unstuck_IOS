// Port of the Android LocalStoreTest clearAll assertions (spec
// 02-sync-engine §1.7/§2.2): a user-change/sign-out wipe must clear the
// synced records AND the local-only outbox + live_session — leaving the
// outbox behind lets the next sign-in replay the previous user's queued
// ops under the new user's id (cross-account leak).

import XCTest
import GRDB
import UnstuckCore
@testable import UnstuckData

final class SyncStoreClearAllTests: XCTestCase {
    private var db: AppDatabase!
    private let now = "2026-05-21T10:00:00.000Z"

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
    }

    // Bug-9 regression: replaceAll upserts (not inserts) each row, so a
    // duplicate id in the hydrated set resolves last-write-wins instead of
    // throwing — a throw here was swallowed by the Hydrator's catch and aborted
    // the WHOLE table's hydrate, blanking every good row on the UI.
    func testReplaceAllToleratesDuplicateIds() throws {
        try db.save(TaskItem(id: "old", name: "Old", estimateMin: 25, createdAt: now, updatedAt: now))
        let dupes = [
            TaskItem(id: "x", name: "First", estimateMin: 25, createdAt: now, updatedAt: now),
            TaskItem(id: "x", name: "Second", estimateMin: 30, createdAt: now, updatedAt: now),  // same id
            TaskItem(id: "y", name: "Other", estimateMin: 15, createdAt: now, updatedAt: now),
        ]

        XCTAssertNoThrow(try db.replaceAll(TaskItem.self, with: dupes))

        // The prior row is replaced; the duplicate id collapses to the last write.
        XCTAssertNil(try db.fetchById(TaskItem.self, id: "old"))
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "x")?.name, "Second")
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "y")?.name, "Other")
    }

    // The replace writes each row with INSERT OR REPLACE instead of GRDB's
    // `upsert` (4× cheaper for the same stored result — see
    // AppDatabase.insertReplacing). These pin the semantics that change would
    // be able to break: full-fidelity round-trip of every column INCLUDING the
    // JSON-encoded ones, deletion of rows the server no longer has, an empty
    // server set blanking the table, and the last-write-wins duplicate above.
    func testReplaceAllRoundTripsEveryColumn() throws {
        let task = TaskItem(
            id: "full", name: "Every column", estimateMin: 45, totalFocused: 900,
            done: true, tags: ["deep-work", "admin"], lifeArea: "Work", moveCount: 4,
            completedAt: "2026-05-20T18:30:00.000Z", later: true,
            recurrence: .weekly(daysOfWeek: [1, 3, 5], until: "2026-12-31"),
            createdAt: now, updatedAt: now)
        try db.replaceAll(TaskItem.self, with: [task])
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "full"), task)

        let block = CalBlock(id: "b1", taskId: "full", taskName: "Every column", startTime: "09:15",
                             durationMinutes: 90, date: "2026-05-21",
                             externalEventId: "evt", externalConnectionId: "conn", kind: .external,
                             done: true, skipped: true, completedAt: now)
        try db.replaceAll(CalBlock.self, with: [block])
        XCTAssertEqual(try db.fetchAllCalBlocks(), [block])
    }

    func testReplaceAllDropsRowsTheServerNoLongerHas() throws {
        try db.save(TaskItem(id: "gone", name: "Deleted on the server", estimateMin: 25,
                             createdAt: now, updatedAt: now))
        try db.save(TaskItem(id: "kept", name: "Stale local copy", estimateMin: 25,
                             createdAt: now, updatedAt: now))
        try db.replaceAll(TaskItem.self, with: [
            TaskItem(id: "kept", name: "Server copy", estimateMin: 30, createdAt: now, updatedAt: now),
            TaskItem(id: "new", name: "Arrived", estimateMin: 10, createdAt: now, updatedAt: now),
        ])
        XCTAssertNil(try db.fetchById(TaskItem.self, id: "gone"))
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "kept")?.name, "Server copy")
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "kept")?.estimateMin, 30)
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "new")?.name, "Arrived")

        try db.replaceAll(TaskItem.self, with: [])
        XCTAssertNil(try db.fetchById(TaskItem.self, id: "kept"))
        XCTAssertNil(try db.fetchById(TaskItem.self, id: "new"))
    }

    /// `replaceAllAtomically` is the door the real hydrate uses, and it is what
    /// preserves rows with a pending outbox upsert (spec §1.3 localPending) and
    /// profile-fact tombstones. The body's decision must land verbatim.
    func testReplaceAllAtomicallyKeepsWhatTheBodyReturns() throws {
        try db.save(TaskItem(id: "local-only", name: "Offline edit", estimateMin: 25,
                             createdAt: now, updatedAt: now))
        try db.save(TaskItem(id: "both", name: "Local version", estimateMin: 25,
                             createdAt: now, updatedAt: now))
        var sawLocal: [String] = []
        try db.replaceAllAtomically(TaskItem.self) { _, local in
            sawLocal = local.map(\.id).sorted()
            // keep the local-only row, take the server's copy of the shared one,
            // and add a brand-new server row — a duplicate id in the result too.
            return [
                local.first { $0.id == "local-only" }!,
                TaskItem(id: "both", name: "Server version", estimateMin: 30, createdAt: now, updatedAt: now),
                TaskItem(id: "both", name: "Server version 2", estimateMin: 35, createdAt: now, updatedAt: now),
                TaskItem(id: "fresh", name: "New", estimateMin: 5, createdAt: now, updatedAt: now),
            ]
        }
        XCTAssertEqual(sawLocal, ["both", "local-only"])
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "local-only")?.name, "Offline edit")
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "both")?.name, "Server version 2")
        XCTAssertEqual(try db.fetchById(TaskItem.self, id: "fresh")?.name, "New")
    }

    /// A tombstoned profile fact (active == false) must survive the replace as
    /// a tombstone — the hydrate's last-write-wins merge needs the inactive row.
    func testReplaceAllKeepsProfileFactTombstones() throws {
        let live = ProfileFact(id: "f1", category: .person, fact: "Nadia is their partner",
                               source: .chat, createdAt: now, updatedAt: now)
        var dead = ProfileFact(id: "f2", category: .person, fact: "Removed",
                               source: .chat, createdAt: now, updatedAt: now)
        dead.active = false
        try db.replaceAll(ProfileFact.self, with: [live, dead])
        let back = try db.fetchAllProfileFacts().sorted { $0.id < $1.id }
        XCTAssertEqual(back, [live, dead])
        XCTAssertEqual(back.last?.active, false)
    }

    func testClearAllKeepsParkedOpsAndWipesTheCaptureArchive() throws {
        let box = OutboxStore(db)
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, payload: "{}", nowISO: now)
        try box.park(userId: "u1")
        try db.setCaptureArchived(id: "c1", archivedAt: now)
        XCTAssertEqual(try db.archivedCaptureIds(), ["c1"])

        try db.clearAll()

        XCTAssertEqual(try box.parkedCount(userId: "u1"), 1, "parked ops survive the wipe for their owner's next sign-in")
        XCTAssertTrue(try db.archivedCaptureIds().isEmpty)
    }

    func testCaptureArchiveHelpers() throws {
        try db.setCaptureArchived(id: "c1", archivedAt: now)
        try db.setCaptureArchived(id: "c2", archivedAt: now)
        XCTAssertEqual(try db.captureArchivedAt(id: "c1"), now)
        try db.setCaptureArchived(id: "c1", archivedAt: nil)
        XCTAssertNil(try db.captureArchivedAt(id: "c1"))
        XCTAssertEqual(try db.archivedCaptureIds(), ["c2"])
        // Server-canonical replace: pending ids keep their local state, both ways.
        try db.writer.write { conn in
            try AppDatabase.replaceCaptureArchive(in: conn,
                                                   serverArchived: ["s1": now, "c1": now],   // server: c1 archived
                                                   keepLocalIds: ["c1", "c2"])               // local says c1 open, c2 archived
        }
        XCTAssertEqual(try db.archivedCaptureIds(), ["s1", "c2"])
    }

    func testClearAllWipesRecordsOutboxAndLiveSession() throws {
        let box = OutboxStore(db)
        let live = LiveSessionStore(db)
        try db.save(TaskItem(id: "a", name: "T", estimateMin: 25, createdAt: now, updatedAt: now))
        try db.save(CalBlock(id: "g_evt1", taskId: nil, taskName: "Standup", startTime: "09:00",
                             durationMinutes: 30, date: "2026-05-21", externalEventId: "evt1", kind: .external))
        _ = try box.enqueue(table: "tasks", rowId: "a", kind: .upsert, payload: "{}", nowISO: now)
        try live.set(LiveSession(id: "s1", taskId: "a", sessionEstimateMin: 25, treatment: .ambient))

        try db.clearAll()

        XCTAssertNil(try db.fetchById(TaskItem.self, id: "a"))
        // Even preserved-across-hydrate external g_ blocks go on a user change.
        XCTAssertEqual(try db.fetchAllCalBlocks(), [])
        XCTAssertEqual(try box.count(), 0)
        XCTAssertNil(try live.get())
    }
}
