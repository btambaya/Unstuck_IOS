// Port of the Android LocalStoreTest clearAll assertions (spec
// 02-sync-engine §1.7/§2.2): a user-change/sign-out wipe must clear the
// synced records AND the local-only outbox + live_session — leaving the
// outbox behind lets the next sign-in replay the previous user's queued
// ops under the new user's id (cross-account leak).

import XCTest
import UnstuckCore
@testable import UnstuckData

final class SyncStoreClearAllTests: XCTestCase {
    private var db: AppDatabase!
    private let now = "2026-05-21T10:00:00.000Z"

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
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
