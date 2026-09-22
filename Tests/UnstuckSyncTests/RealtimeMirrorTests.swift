// RealtimeMirror last-write-wins guard. An incoming `tasks` UPDATE echo must
// not clobber a newer local edit: the apply is skipped when the local row's
// updated_at parses to a STRICTLY newer instant than the incoming row's.
// Exercises the pure decision (incomingTaskWins) against a real in-memory
// GRDB store — no network/realtime channel needed.

import XCTest
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

final class RealtimeMirrorTests: XCTestCase {
    private var db: AppDatabase!

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
    }

    private func saveLocal(id: String, name: String, updatedAt: String) throws {
        try db.save(TaskItem(id: id, name: name, estimateMin: 25,
                             createdAt: "2026-05-21T09:00:00.000Z", updatedAt: updatedAt))
    }

    private func incoming(id: String, name: String, updatedAt: String) -> TaskRow {
        TaskRow(TaskItem(id: id, name: name, estimateMin: 25,
                         createdAt: "2026-05-21T09:00:00.000Z", updatedAt: updatedAt))
    }

    func testStaleIncomingUpdateIsSkipped() throws {
        // Local edit is NEWER than the incoming realtime echo → don't apply.
        try saveLocal(id: "t1", name: "local-new", updatedAt: "2026-05-21T10:05:00.000Z")
        let echo = incoming(id: "t1", name: "remote-old", updatedAt: "2026-05-21T10:00:00.000Z")
        XCTAssertFalse(RealtimeMirror.incomingTaskWins(echo, db: db))
    }

    func testNewerIncomingUpdateIsApplied() throws {
        // Incoming is genuinely newer than local → apply it.
        try saveLocal(id: "t1", name: "local-old", updatedAt: "2026-05-21T10:00:00.000Z")
        let fresh = incoming(id: "t1", name: "remote-new", updatedAt: "2026-05-21T10:05:00.000Z")
        XCTAssertTrue(RealtimeMirror.incomingTaskWins(fresh, db: db))
    }

    func testEqualTimestampIsApplied() throws {
        // At-or-after applies (>=): an identical-timestamp re-broadcast is a
        // harmless idempotent write, not a clobber to suppress.
        try saveLocal(id: "t1", name: "local", updatedAt: "2026-05-21T10:00:00.000Z")
        let same = incoming(id: "t1", name: "remote", updatedAt: "2026-05-21T10:00:00.000Z")
        XCTAssertTrue(RealtimeMirror.incomingTaskWins(same, db: db))
    }

    /// The slow-device-clock trap, realtime edition: the phone (3 min slow)
    /// edited the row offline ON TOP OF the server's 10:00 state; a late echo
    /// of that same 10:00 state arrives. LWW alone would apply it (10:00 >
    /// "09:57") and revert the pending edit off the UI. The queued op's base
    /// says the echo is the state the edit was made on → skip it.
    func testEchoOfTheBaseStateDoesNotOverwriteAPendingEdit() throws {
        try saveLocal(id: "t1", name: "edited-offline", updatedAt: "2026-05-21T09:57:00.000Z")
        _ = try OutboxStore(db).enqueue(table: "tasks", rowId: "t1", kind: .upsert, payload: "{}",
                                        nowISO: "2026-05-21T09:57:00.000Z",
                                        baseUpdatedAt: "2026-05-21T10:00:00.000000+00:00", basePayload: "{}")
        let echo = incoming(id: "t1", name: "server-base", updatedAt: "2026-05-21T10:00:00.000Z")
        XCTAssertFalse(RealtimeMirror.incomingTaskWins(echo, db: db))
        // A row that genuinely moved on the server AFTER the base still applies.
        let moved = incoming(id: "t1", name: "web-completed", updatedAt: "2026-05-21T10:05:00.000Z")
        XCTAssertTrue(RealtimeMirror.incomingTaskWins(moved, db: db))
    }

    func testNoLocalRowIsApplied() throws {
        // Nothing local to protect (e.g. an UPDATE arriving before the row
        // hydrated) → apply.
        let fresh = incoming(id: "t1", name: "remote", updatedAt: "2026-05-21T10:00:00.000Z")
        XCTAssertTrue(RealtimeMirror.incomingTaskWins(fresh, db: db))
    }

    func testHandlesFractionalAndWholeSecondTimestamps() throws {
        // Parsed-date comparison (not string compare): a whole-second local
        // stamp is correctly seen as newer than a fractional-second incoming
        // one a few seconds earlier, where a lexicographic compare could differ.
        try saveLocal(id: "t1", name: "local-new", updatedAt: "2026-05-21T10:00:05Z")
        let echo = incoming(id: "t1", name: "remote-old", updatedAt: "2026-05-21T10:00:00.500Z")
        XCTAssertFalse(RealtimeMirror.incomingTaskWins(echo, db: db))
    }

    /// The owner must hear a join / leave on a list it OWNS: those membership
    /// rows carry the member's user_id, so a `user_id = me` filter hid them and
    /// the owner's phone kept treating a shared list as unshared (audit
    /// 2026-09-22, C8). The singleton preference rows keep their filter.
    func testCollectionMembersSignalIsUnfilteredSoTheOwnerHearsJoins() {
        XCTAssertTrue(RealtimeMirror.unfilteredSignalTables.contains("collection_members"))
        XCTAssertFalse(RealtimeMirror.unfilteredSignalTables.contains("notification_preferences"))
        XCTAssertFalse(RealtimeMirror.unfilteredSignalTables.contains("user_preferences"))
    }

    // MARK: - subscribe retry backoff (pure)

    func testRetryBackoffDoublesFromHalfSecond() {
        // 1-based attempt → delay before the next try: 0.5s, 1s, 2s, 4s.
        XCTAssertEqual(RealtimeMirror.retryBackoffNs(attempt: 1), 500_000_000)
        XCTAssertEqual(RealtimeMirror.retryBackoffNs(attempt: 2), 1_000_000_000)
        XCTAssertEqual(RealtimeMirror.retryBackoffNs(attempt: 3), 2_000_000_000)
        XCTAssertEqual(RealtimeMirror.retryBackoffNs(attempt: 4), 4_000_000_000)
    }

    func testRetryBackoffCapsAtEightSeconds() {
        // 5th try wants 8s; anything beyond stays capped (no runaway growth /
        // UInt64 overflow from an unbounded shift).
        XCTAssertEqual(RealtimeMirror.retryBackoffNs(attempt: 5), 8_000_000_000)
        XCTAssertEqual(RealtimeMirror.retryBackoffNs(attempt: 6), 8_000_000_000)
        XCTAssertEqual(RealtimeMirror.retryBackoffNs(attempt: 50), 8_000_000_000)
    }

    func testRetryBackoffClampsNonPositiveAttempt() {
        // Defensive: a 0 / negative attempt clamps to the base delay, never a
        // negative shift (which would trap).
        XCTAssertEqual(RealtimeMirror.retryBackoffNs(attempt: 0), 500_000_000)
        XCTAssertEqual(RealtimeMirror.retryBackoffNs(attempt: -3), 500_000_000)
    }
}
