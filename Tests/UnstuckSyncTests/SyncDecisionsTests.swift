import XCTest
import UnstuckCore
@testable import UnstuckSync

final class SyncDecisionsTests: XCTestCase {

    func testSignedInAlwaysWipes() {
        XCTAssertTrue(SyncDecision.shouldWipeCache(event: .signedIn, prevUserId: "u1", currentUserId: "u1"))
        XCTAssertTrue(SyncDecision.shouldWipeCache(event: .signedIn, prevUserId: nil, currentUserId: "u1"))
    }

    func testInitialSessionWipesOnlyIfUserChanged() {
        XCTAssertFalse(SyncDecision.shouldWipeCache(event: .initialSession, prevUserId: "u1", currentUserId: "u1"))
        XCTAssertTrue(SyncDecision.shouldWipeCache(event: .initialSession, prevUserId: "u1", currentUserId: "u2"))
        XCTAssertTrue(SyncDecision.shouldWipeCache(event: .initialSession, prevUserId: nil, currentUserId: "u1"))
    }

    func testUserUpdatedNeverWipes() {
        XCTAssertFalse(SyncDecision.shouldWipeCache(event: .userUpdated, prevUserId: "u1", currentUserId: "u2"))
    }

    func testMergePreservesLocalExternalBlocks() {
        let remote = [
            CalBlock(id: "r1", taskId: "t1", taskName: "Task", startTime: "09:00", durationMinutes: 25, date: "2026-05-21", kind: .task),
        ]
        let localExternal = [
            CalBlock(id: "g_abc", taskId: nil, taskName: "Meeting", startTime: "10:00", durationMinutes: 30, date: "2026-05-21", externalEventId: "abc", kind: .external),
        ]
        let merged = SyncDecision.mergeHydratedCalBlocks(remote: remote, localExternal: localExternal)
        XCTAssertEqual(Set(merged.map(\.id)), ["r1", "g_abc"])
    }

    func testMergeDropsLocalNonExternalAndRemoteWinsOnClash() {
        let remote = [CalBlock(id: "x", taskId: "t1", taskName: "Server", startTime: "09:00", durationMinutes: 25, date: "2026-05-21", kind: .task)]
        // A local row with the same id but stale; and a local NON-external row that must be dropped.
        let local = [
            CalBlock(id: "x", taskId: "t1", taskName: "StaleLocal", startTime: "08:00", durationMinutes: 10, date: "2026-05-21", externalEventId: "e", kind: .external),
            CalBlock(id: "localTask", taskId: "t2", taskName: "LocalOnlyTask", startTime: "11:00", durationMinutes: 25, date: "2026-05-21", kind: .task),
        ]
        let merged = SyncDecision.mergeHydratedCalBlocks(remote: remote, localExternal: local)
        XCTAssertEqual(Set(merged.map(\.id)), ["x"])                       // localTask dropped (not external); g_/external 'x' overwritten by remote
        XCTAssertEqual(merged.first { $0.id == "x" }?.taskName, "Server")  // remote wins
    }
}
