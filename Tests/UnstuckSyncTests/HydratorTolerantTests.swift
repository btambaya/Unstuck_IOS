// Per-row tolerant hydrate (the data-correctness fix, mirrored from Android).
//
// The trap: a task row written by a NEWER web/iOS release can carry a shape this
// build can't model. Two failure modes existed:
//   (a) an UNKNOWN recurrence kind THREW in Recurrence.init(from:), aborting the
//       whole TaskRow decode → the task VANISHED from the list, and
//   (b) hydrate decoded the server array EAGERLY (PostgREST .execute().value),
//       so one undecodable row threw and aborted the ENTIRE table refresh.
//
// The fix: (a) an unknown kind degrades to an inert sentinel recurrence, and
// (b) hydrate decodes PER-ROW (fetchAllTolerant over fetchAllRaw), dropping only
// the bad row. These tests prove a row list with one genuinely-undecodable row
// still yields every good row in the local store after a hydrate.

import XCTest
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

/// Read-side fake whose `fetchAllRaw` returns scripted per-row JSON `Data`
/// (one object per row) for a single table — exactly what the real gateway
/// hands the Hydrator's tolerant decode.
private actor FakeRawGateway: SyncReadGatewayProtocol {
    private let rowsByTable: [String: [Data]]
    init(rowsByTable: [String: [Data]]) { self.rowsByTable = rowsByTable }

    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        // Eager path is unused by hydrate now; decode tolerantly here too so the
        // fake never throws on the bad row (the prune path uses fetchAllTolerant).
        let dec = JSONDecoder()
        return (rowsByTable[table] ?? []).compactMap { try? dec.decode(Row.self, from: $0) }
    }

    func fetchAllRaw(table: String) async throws -> [Data] {
        rowsByTable[table] ?? []
    }
}

final class HydratorTolerantTests: XCTestCase {
    private var db: AppDatabase!

    override func setUpWithError() throws {
        db = try AppDatabase.makeInMemory()
    }

    private func goodTaskJSON(id: String, name: String) -> Data {
        """
        {"id":"\(id)","name":"\(name)","estimate_min":25,"total_focused":0,"done":false,
         "priority":null,"tags":[],"objectives":[],"comments":[],
         "intent_when":null,"intent_then":null,"life_area":null,
         "first_physical_action":null,"move_count":0,"completed_at":null,"later":false,
         "recurrence":null,
         "created_at":"2026-05-21T10:00:00.000Z","updated_at":"2026-05-21T10:00:00.000Z"}
        """.data(using: .utf8)!
    }

    // One genuinely-undecodable row (missing the required `name` column) sits
    // between two good rows. The eager whole-array decode would have thrown and
    // dropped ALL three; the tolerant per-row decode keeps the two good ones.
    func testHydrateSkipsUndecodableRowKeepsTheRest() async throws {
        let badRow = """
        {"id":"bad","estimate_min":25,"total_focused":0,"done":false,
         "created_at":"2026-05-21T10:00:00.000Z","updated_at":"2026-05-21T10:00:00.000Z"}
        """.data(using: .utf8)!   // no "name" → TaskRow decode fails

        let gateway = FakeRawGateway(rowsByTable: ["tasks": [
            goodTaskJSON(id: "g1", name: "Alpha"),
            badRow,
            goodTaskJSON(id: "g2", name: "Beta"),
        ]])
        let hydrator = Hydrator(gateway: gateway, db: db)
        await hydrator.hydrate(userId: "u1")

        let tasks = try TaskRepository(db).all().sorted { $0.id < $1.id }
        XCTAssertEqual(tasks.map(\.id), ["g1", "g2"], "the bad row is dropped; the good rows survive")
        XCTAssertEqual(tasks.map(\.name), ["Alpha", "Beta"])
    }

    // A task carrying an UNKNOWN recurrence kind is NOT undecodable anymore — it
    // degrades to an inert recurrence and the task stays visible after hydrate.
    func testHydrateKeepsTaskWithUnknownRecurrenceKind() async throws {
        let unknownRecTask = """
        {"id":"u1","name":"Future task","estimate_min":25,"total_focused":0,"done":false,
         "priority":null,"tags":[],"objectives":[],"comments":[],
         "intent_when":null,"intent_then":null,"life_area":null,
         "first_physical_action":null,"move_count":0,"completed_at":null,"later":false,
         "recurrence":{"kind":"yearly"},
         "created_at":"2026-05-21T10:00:00.000Z","updated_at":"2026-05-21T10:00:00.000Z"}
        """.data(using: .utf8)!

        let gateway = FakeRawGateway(rowsByTable: ["tasks": [
            goodTaskJSON(id: "g1", name: "Alpha"),
            unknownRecTask,
        ]])
        let hydrator = Hydrator(gateway: gateway, db: db)
        await hydrator.hydrate(userId: "u1")

        let tasks = try TaskRepository(db).all().sorted { $0.id < $1.id }
        XCTAssertEqual(tasks.map(\.id), ["g1", "u1"], "the unknown-recurrence task stays visible")
        let future = tasks.first { $0.id == "u1" }
        XCTAssertTrue(Recurrence.isUnknown(future?.recurrence), "its recurrence is the inert sentinel")
    }
}

/// Gauges hydrate concurrency: records the max number of simultaneous
/// `fetchAllRaw` calls and how many full passes touched `tasks`. A small sleep
/// per fetch widens the interleave window so an UN-coalesced overlap is visible.
private actor GaugedGateway: SyncReadGatewayProtocol {
    private(set) var maxConcurrent = 0
    private(set) var tasksPasses = 0
    private var current = 0
    private let sleepNs: UInt64
    init(sleepNs: UInt64) { self.sleepNs = sleepNs }

    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] { [] }

    func fetchAllRaw(table: String) async throws -> [Data] {
        current += 1
        maxConcurrent = max(maxConcurrent, current)
        if table == "tasks" { tasksPasses += 1 }   // one fetch per full hydrate pass
        try? await Task.sleep(nanoseconds: sleepNs)
        current -= 1
        return []
    }
}

// BUG 2: the socket-reconnect resync, the 60s safety-net, and the auth hydrate
// all call hydrate() and can interleave at await points. The coalescer must
// serialize them — never two full hydrates overlapping — and collapse extra
// concurrent requests into a single trailing run.
final class HydratorCoalesceTests: XCTestCase {
    func testConcurrentHydratesAreSerializedAndCoalesced() async throws {
        let db = try AppDatabase.makeInMemory()
        let gateway = GaugedGateway(sleepNs: 15_000_000)   // 15ms per fetch widens the race window
        let hydrator = Hydrator(gateway: gateway, db: db)
        // Fire several hydrates at once.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { await hydrator.hydrate(userId: "u1") } }
        }
        let maxC = await gateway.maxConcurrent
        let passes = await gateway.tasksPasses
        XCTAssertEqual(maxC, 1, "at most one full hydrate runs at a time")
        XCTAssertGreaterThanOrEqual(passes, 1, "at least one hydrate ran")
        XCTAssertLessThanOrEqual(passes, 2, "extra concurrent requests coalesce to one trailing run")
    }
}
