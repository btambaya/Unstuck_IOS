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
