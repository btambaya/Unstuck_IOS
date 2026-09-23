// Changes the server refuses (audit 2026-09-22, C28): the flusher's side of
// the quarantine — what it adopts instead of quarantining, what it reports
// after every drain, the once-per-build release — and the inputs that used to
// be refused at all (a capture over 4096 characters).

import XCTest
import Supabase
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

/// Refuses the rows it is told to, with the error it is given.
private actor RefusingGateway: SyncGatewayProtocol {
    private var refusals: [String: Error] = [:]
    private(set) var sent: [String] = []

    func refuse(_ rowId: String, with error: Error) { refusals[rowId] = error }

    func upsert<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws {
        let obj = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any]) ?? [:]
        let id = obj["id"] as? String ?? ""
        if let error = refusals[id] { throw error }
        sent.append(id)
    }

    func delete(table: String, id: String) async throws {
        if let error = refusals[id] { throw error }
        sent.append(id)
    }
}

/// A definite server rejection other than a name clash.
private struct CheckViolation: Error, ServerRejectionClassifiable { var isServerRejection: Bool { true } }

private final class DrainCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

final class StuckChangesTests: XCTestCase {
    private var db: AppDatabase!
    private var box: OutboxStore!
    private var gateway: RefusingGateway!
    private var flusher: OutboxFlusher!
    private let now = "2026-09-22T10:00:00.000Z"

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
        box = OutboxStore(db)
        gateway = RefusingGateway()
        flusher = OutboxFlusher(gateway: gateway, db: db)
    }

    private func json<T: Encodable>(_ row: T) throws -> String {
        String(data: try JSONEncoder().encode(row), encoding: .utf8)!
    }

    // MARK: - name twins

    /// Onboarding seeded "Work" from a store the sign-in hydrate hadn't reached,
    /// while the server's sign-up seed already had it (or another device made
    /// the same tag): unique(user_id, name) refuses the insert. It can never
    /// succeed, and quarantined, both copies showed here for good. The op is
    /// dropped with this phone's twin; the server's row comes by pull.
    func testANameTwinTheServerRefusesIsDroppedNotQuarantined() async throws {
        let area = LifeArea(id: "a-local", name: "Work", color: "indigo", sortOrder: 0)
        try db.save(area)
        _ = try box.enqueue(table: "life_areas", rowId: area.id, kind: .upsert, payload: try json(LifeAreaDbRow(area)), nowISO: now)
        let tag = TagRow(id: "g-local", name: "errands", color: nil, sortOrder: 0)
        try db.save(tag)
        _ = try box.enqueue(table: "tags", rowId: tag.id, kind: .upsert, payload: try json(TagDbRow(tag)), nowISO: now)
        let clash = PostgrestError(detail: nil, hint: nil, code: "23505",
                                   message: "duplicate key value violates unique constraint")
        await gateway.refuse(area.id, with: clash)
        await gateway.refuse(tag.id, with: clash)

        await flusher.flush(userId: "u1")

        XCTAssertEqual(try box.count(), 0, "a retry could only fail again")
        XCTAssertEqual(try box.stuck().count, 0)
        XCTAssertNil(try db.fetchById(LifeArea.self, id: area.id), "no second Work pill")
        XCTAssertNil(try db.fetchById(TagRow.self, id: tag.id))
    }

    /// Only a name clash is adopted: any other refusal still quarantines —
    /// and every drain tells the app what is stuck.
    func testOtherRefusalsQuarantineAndEveryDrainReports() async throws {
        let drains = DrainCounter()
        await flusher.setOnDrained { drains.bump() }
        let t = TaskItem(id: "t1", name: "Refused", estimateMin: 25, createdAt: now, updatedAt: now)
        try db.save(t)
        _ = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, payload: try json(TaskRow(t)), nowISO: now)
        await gateway.refuse("t1", with: CheckViolation())

        for _ in 0..<OutboxStore.quarantineCap { await flusher.flush(userId: "u1") }

        XCTAssertEqual(try box.stuck().count, 1)
        XCTAssertNotNil(try db.fetchById(TaskItem.self, id: "t1"), "a quarantined change is kept, never deleted")
        XCTAssertEqual(drains.value, OutboxStore.quarantineCap)
    }

    // MARK: - a new build retries

    /// Nothing ever reset `attempts`, so "a future build can retry it" never
    /// happened. Each new build number releases the quarantine once.
    func testTheQuarantineIsReleasedOncePerBuild() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "stuck-changes-\(UUID().uuidString)"))
        let op = try box.enqueue(table: "tasks", rowId: "t1", kind: .upsert, payload: "{}", nowISO: now)
        func quarantine() throws { for _ in 0..<OutboxStore.quarantineCap { _ = try box.bumpAttempts(op.opSeq!) } }
        try quarantine()

        XCTAssertEqual(SyncCoordinator.releaseQuarantineIfNewBuild("86", box: box, defaults: defaults), 1)
        XCTAssertEqual(try box.stuck().count, 0)
        try quarantine()
        XCTAssertEqual(SyncCoordinator.releaseQuarantineIfNewBuild("86", box: box, defaults: defaults), 0,
                       "the same build doesn't retry for ever")
        XCTAssertEqual(SyncCoordinator.releaseQuarantineIfNewBuild("87", box: box, defaults: defaults), 1)
    }

    // MARK: - discard

    /// Discarding leaves rows the server never took in the store, and the
    /// catch-up never re-reads a row this device already has: the next pull
    /// must be the full server-canonical hydrate.
    func testADiscardMakesTheNextPullAFullHydrate() async throws {
        let fullSyncs = DrainCounter()
        let catchUps = DrainCounter()
        let owner = FreshnessOwner(actions: FreshnessOwner.Actions(
            fullSync: { _ in fullSyncs.bump() },
            catchUp: { _, _ in catchUps.bump(); return CatchUpPuller.Outcome() }))
        await owner.setUser("u1")
        await owner.markHydrated()

        await owner.requireFullHydrate()
        await owner.awaitIdle()
        XCTAssertEqual(fullSyncs.value, 1)
        XCTAssertEqual(catchUps.value, 0)

        await owner.report(.manual)
        await owner.awaitIdle()
        XCTAssertEqual(fullSyncs.value, 1, "then back to the catch-up")
        XCTAssertEqual(catchUps.value, 1)
    }

    // MARK: - a capture over 4096 characters

    /// `captures.body` is `check (length(body) between 1 and 4096)`. A long
    /// paste was saved here, refused on every flush and quarantined. The row
    /// and the op now both carry what the server accepts.
    func testALongCaptureIsClampedOnTheRowAndTheOp() async throws {
        let write = WriteThrough(db: db)
        let long = String(repeating: "a", count: 5000)
        try await write.upsertCapture(Capture(id: "c1", tag: .idea, body: long, at: now), nowISO: now)

        XCTAssertEqual(try db.fetchById(Capture.self, id: "c1")?.body.unicodeScalars.count, maxCaptureBodyLength)
        let payload = try XCTUnwrap(box.pending().first?.payload?.data(using: .utf8))
        let body = try XCTUnwrap((JSONSerialization.jsonObject(with: payload) as? [String: Any])?["body"] as? String)
        XCTAssertEqual(body.unicodeScalars.count, maxCaptureBodyLength)
    }

    /// An op an earlier build queued with the full body goes out clamped when
    /// the release retries it — the wire codec clamps too.
    func testTheWireCodecClampsACaptureQueuedBeforeTheFix() throws {
        let row = CaptureRow(Capture(id: "c1", tag: .idea, body: String(repeating: "é", count: 4100), at: now))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        XCTAssertEqual((obj["body"] as? String)?.unicodeScalars.count, maxCaptureBodyLength)
    }
}
