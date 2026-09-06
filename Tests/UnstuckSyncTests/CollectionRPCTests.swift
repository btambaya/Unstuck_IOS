// Shared-collection item mutations as OUTBOX `rpc` ops: the CollectionRPC
// descriptors (idempotent by item id — the server upserts `p_item.id`), the
// OutboxRPCPayload envelope, and WriteThrough.applyCollectionRPC's
// row-save + enqueue in ONE transaction (replacing the fire-and-forget RPC
// whose failure left an optimistic row for the next echo to delete).

import XCTest
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

final class CollectionRPCTests: XCTestCase {
    private let now = "2026-05-21T10:00:00.000Z"

    func testAddItemCarriesTheClientIdInsideTheItem() {
        let rpc = CollectionRPC.addItem(collectionId: "c1", id: "i1", body: "Milk", at: now)
        XCTAssertEqual(rpc.fn, "collection_add_item")
        let p = rpc.params
        XCTAssertEqual(p["p_collection_id"], .string("c1"))
        guard case let .object(item)? = p["p_item"] else { return XCTFail("p_item must be a JSON object") }
        XCTAssertEqual(item["id"], .string("i1"), "the server UPSERTS by this id — a replay is a no-op")
        XCTAssertEqual(item["body"], .string("Milk"))
        XCTAssertEqual(item["at"], .string(now))
    }

    func testDescriptorsAreDeterministicSoAReplaySendsTheSameBytes() {
        let a = CollectionRPC.setItemFlag(collectionId: "c1", itemId: "i1", flag: "done", value: true)
        let b = CollectionRPC.setItemFlag(collectionId: "c1", itemId: "i1", flag: "done", value: true)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.paramsJSON, b.paramsJSON)
    }

    func testPromotionEncodesExplicitNullsForClearedFields() {
        let rpc = CollectionRPC.setItemPromotion(collectionId: "c1", itemId: "i1", assignee: "Maya", done: nil, dueAt: nil)
        XCTAssertEqual(rpc.fn, "collection_set_item_promotion")
        XCTAssertEqual(rpc.params["p_done"], .null, "nil must reach Postgres as NULL, not be omitted")
        XCTAssertEqual(rpc.params["p_due_at"], .null)
        XCTAssertEqual(rpc.params["p_assignee"], .string("Maya"))
    }

    func testOtherDescriptors() {
        XCTAssertEqual(CollectionRPC.updateItem(collectionId: "c", itemId: "i", body: "x").fn, "collection_update_item")
        XCTAssertEqual(CollectionRPC.removeItem(collectionId: "c", itemId: "i").fn, "collection_remove_item")
        XCTAssertEqual(CollectionRPC.removeItem(collectionId: "c", itemId: "i").params["p_item_id"], .string("i"))
    }

    func testOutboxRPCPayloadRoundTrips() throws {
        let rpc = CollectionRPC.removeItem(collectionId: "c1", itemId: "i1")
        let encoded = try OutboxRPCPayload(fn: rpc.fn, paramsJSON: rpc.paramsJSON).encoded()
        let decoded = OutboxRPCPayload.decode(encoded)
        XCTAssertEqual(decoded?.fn, "collection_remove_item")
        XCTAssertEqual(decoded?.paramsJSON, rpc.paramsJSON)
        XCTAssertNil(OutboxRPCPayload.decode(nil))
        XCTAssertNil(OutboxRPCPayload.decode("not json"))
    }

    // MARK: - WriteThrough.applyCollectionRPC

    func testApplyCollectionRPCSavesTheOptimisticRowAndQueuesTheOpTogether() async throws {
        let db = try AppDatabase.makeInMemory()
        let write = WriteThrough(db: db)
        let box = OutboxStore(db)
        let shared = ItemCollection(id: "c1", name: "Groceries", color: "indigo",
                                    items: [CollectionItem(id: "i1", body: "Milk", at: now)],
                                    sortOrder: 0, ownerId: "owner", members: ["me"], myRole: "editor")
        let rpc = CollectionRPC.addItem(collectionId: "c1", id: "i1", body: "Milk", at: now)
        try await write.applyCollectionRPC(shared, rpc: rpc, nowISO: now)

        // The optimistic row is on disk (with its client-only sharing fields).
        let stored = try db.fetchById(ItemCollection.self, id: "c1")
        XCTAssertEqual(stored?.items.map(\.id), ["i1"])
        XCTAssertEqual(stored?.members, ["me"])
        XCTAssertEqual(stored?.myRole, "editor")
        // ONE rpc op for that row, carrying the descriptor — retried like any
        // edit, dropped + rolled back only on a definite server refusal.
        let ops = try box.pending()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].kind, .rpc)
        XCTAssertEqual(ops[0].tableName, "collections")
        XCTAssertEqual(ops[0].rowId, "c1")
        XCTAssertEqual(OutboxRPCPayload.decode(ops[0].payload)?.fn, "collection_add_item")
    }

    func testDeletingTheCollectionCancelsItsQueuedRPCs() async throws {
        // A shared-list item RPC must not fire on a list that no longer exists.
        let db = try AppDatabase.makeInMemory()
        let write = WriteThrough(db: db)
        let box = OutboxStore(db)
        let shared = ItemCollection(id: "c1", name: "G", color: "indigo", items: [], sortOrder: 0, ownerId: "owner", members: ["me"])
        try await write.applyCollectionRPC(shared, rpc: .removeItem(collectionId: "c1", itemId: "i9"), nowISO: now)
        try await write.deleteCollection(id: "c1", nowISO: now)
        let ops = try box.pending()
        XCTAssertEqual(ops.map(\.kind), [.delete])
    }
}

// MARK: - the boolean refusal contract (migration 056)

/// The item RPCs return BOOLEAN: `false` = the write did nothing (RLS hid the
/// collection / unknown item id). SyncGateway decodes the body and turns a
/// 200-with-`false` into `RPCRefusedError` — a definite server rejection, so
/// the outbox drops the op and the app rolls the optimistic row back with a
/// visible error (the web's `isRpcRefusal` contract).
final class CollectionRPCRefusalTests: XCTestCase {
    private func body(_ s: String) -> Data { Data(s.utf8) }

    func testAJSONFalseBodyIsARefusal() {
        XCTAssertTrue(SyncGateway.rpcReturnedFalse(body("false")))
        XCTAssertTrue(SyncGateway.rpcReturnedFalse(body(" false\n")), "whitespace around the literal is still the literal")
    }

    func testAcksAndVoidReturnsAreNotRefusals() {
        XCTAssertFalse(SyncGateway.rpcReturnedFalse(body("true")))
        XCTAssertFalse(SyncGateway.rpcReturnedFalse(body("null")), "a void function answers null")
        XCTAssertFalse(SyncGateway.rpcReturnedFalse(Data()), "…or an empty body")
        XCTAssertFalse(SyncGateway.rpcReturnedFalse(body(#"{"ok":false}"#)), "only a top-level boolean counts")
        XCTAssertFalse(SyncGateway.rpcReturnedFalse(body(#"[false]"#)))
        XCTAssertFalse(SyncGateway.rpcReturnedFalse(body(#""false""#)), "a string is not the boolean")
        XCTAssertFalse(SyncGateway.rpcReturnedFalse(body("0")))
    }

    func testRPCRefusedErrorIsADefiniteRejectionThatNamesTheFunction() {
        let err = RPCRefusedError(fn: "collection_set_item_flag")
        XCTAssertTrue(err.isServerRejection)
        XCTAssertEqual(SyncDecision.classifyFlushFailure(err), .rejected, "never a transient retry")
        XCTAssertEqual(err.errorDescription, "collection_set_item_flag returned false (RLS or unknown item)")
        XCTAssertEqual(err.localizedDescription, "collection_set_item_flag returned false (RLS or unknown item)")
    }
}
