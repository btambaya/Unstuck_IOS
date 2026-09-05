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
