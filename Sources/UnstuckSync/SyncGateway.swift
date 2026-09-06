// SyncGateway — the PostgREST CRUD primitive the sync engine builds on.
// Generic over the DbRowCodec row types. Attaches `user_id` on every
// write the way the web bridge does (payload = { ...row, user_id }) by
// re-serializing the row to a JSON object and injecting the key — this
// keeps the explicit-null semantics of the row encoders intact (so an
// upsert still clears removed fields) without baking user_id into every
// row struct. Reads rely on RLS to auto-scope to the current user.

import Foundation
import Supabase

/// The CRUD seam the outbox drain builds on — SyncGateway in production;
/// tests inject a scripted fake (the real gateway needs a network +
/// Supabase client) to exercise the flusher's poison-pill/ordering logic.
public protocol SyncGatewayProtocol: Sendable {
    func upsert<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws
    func delete(table: String, id: String) async throws
    /// Call a Postgres function with a JSON-object parameter string (an
    /// `OutboxKind.rpc` op — a shared collection's atomic item mutation).
    func rpc(fn: String, paramsJSON: String) async throws
}

/// A gateway that doesn't do RPCs (test fakes that predate them): the op is a
/// definite rejection, never a retry loop.
public struct RPCUnsupportedError: Error, ServerRejectionClassifiable, Sendable {
    public let fn: String
    public var isServerRejection: Bool { true }
    public init(fn: String) { self.fn = fn }
}

public extension SyncGatewayProtocol {
    func rpc(fn: String, paramsJSON: String) async throws { throw RPCUnsupportedError(fn: fn) }
}

/// The server answered HTTP 200 with the JSON literal `false`: the shared-list
/// item RPCs (migration 056 — idempotent by item id) return BOOLEAN, and
/// `false` means the write did NOTHING (RLS hid the collection, or the item
/// id is unknown). A refusal dressed as a success: replaying the same bytes
/// can only produce another `false`, so it is a definite server rejection —
/// the outbox drops the op and the app rolls the optimistic row back with a
/// visible error, exactly like a PostgREST 4xx. A void function answers an
/// empty body / `null` and `true` is an ack — neither is a refusal. Web
/// parity: `isRpcRefusal` in lib/sync/outbox.ts.
public struct RPCRefusedError: Error, ServerRejectionClassifiable, LocalizedError, Sendable {
    public let fn: String
    public var isServerRejection: Bool { true }
    public var errorDescription: String? { "\(fn) returned false (RLS or unknown item)" }
    public init(fn: String) { self.fn = fn }
}

/// The server-read seam the Hydrator builds on — SyncGateway in production;
/// tests inject a scripted fake (the real gateway needs a network + Supabase
/// client) to exercise prune/hydrate ordering without a server.
public protocol SyncReadGatewayProtocol: Sendable {
    func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row]
    /// Fetch every row as a standalone JSON object (`Data` per row), so the
    /// caller can decode PER-ROW and tolerate a single un-decodable row
    /// (e.g. a forward-compat shape this build can't parse) instead of having
    /// the whole-array decode of `fetchAll` throw and abort the table refresh.
    func fetchAllRaw(table: String) async throws -> [Data]
}

public extension SyncReadGatewayProtocol {
    /// Per-row tolerant decode over `fetchAllRaw`: drops only the rows that
    /// fail to decode, keeping every good row. The load-bearing replacement
    /// for an eager `fetchAll` in the hydrate path — one bad row (an unknown
    /// recurrence kind already degrades, but any other forward-compat field
    /// could still throw) must not wipe the whole table off the UI.
    func fetchAllTolerant<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        let raw = try await fetchAllRaw(table: table)
        let decoder = JSONDecoder()
        return raw.compactMap { try? decoder.decode(Row.self, from: $0) }
    }
}

public struct SyncGateway: Sendable, SyncGatewayProtocol, SyncReadGatewayProtocol {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    public func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        try await client.from(table).select().execute().value
    }

    /// Fetch the table as a list of per-row JSON objects re-encoded to `Data`.
    /// PostgREST's whole-array decode is all-or-nothing, so we decode the
    /// response into `[AnyJSON]` (which never fails on a forward-compat shape)
    /// and re-encode each element — the caller then decodes per-row tolerantly.
    public func fetchAllRaw(table: String) async throws -> [Data] {
        let rows: [AnyJSON] = try await client.from(table).select().execute().value
        let encoder = JSONEncoder()
        return try rows.map { try encoder.encode($0) }
    }

    public func upsert<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws {
        _ = try await client.from(table).upsert(Self.withUserId(row, userId: userId), onConflict: "id").execute()
    }

    public func upsertMany<Row: Encodable & Sendable>(_ rows: [Row], table: String, userId: String) async throws {
        guard !rows.isEmpty else { return }
        let payloads = try rows.map { try Self.withUserId($0, userId: userId) }
        _ = try await client.from(table).upsert(payloads, onConflict: "id").execute()
    }

    public func delete(table: String, id: String) async throws {
        _ = try await client.from(table).delete().eq("id", value: id).execute()
    }

    /// Throws `RPCRefusedError` when the function returned `false` (see the
    /// error's doc): a 200 whose body says "nothing happened" must not be
    /// mistaken for an ack, or the optimistic row outlives the refused write.
    public func rpc(fn: String, paramsJSON: String) async throws {
        let params = try JSONDecoder().decode([String: AnyJSON].self, from: Data(paramsJSON.utf8))
        let response: PostgrestResponse<Void> = try await client.rpc(fn, params: params).execute()
        if Self.rpcReturnedFalse(response.data) { throw RPCRefusedError(fn: fn) }
    }

    /// True iff an RPC response body is the JSON boolean `false`. Decodes the
    /// boolean (a top-level scalar body); anything that isn't a boolean — an
    /// empty body, `null`, a row, an object — is not a refusal.
    static func rpcReturnedFalse(_ body: Data) -> Bool {
        guard !body.isEmpty else { return false }
        if let value = try? JSONDecoder().decode(Bool.self, from: body) { return value == false }
        // Belt and braces for a Foundation that rejects top-level scalars.
        return String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "false"
    }

    /// Re-serialize an encoded row into a `[String: AnyJSON]` and inject
    /// `user_id`. Preserves explicit JSON nulls produced by the row
    /// encoders (AnyJSON.null), so clearing a field still clears it.
    static func withUserId<Row: Encodable>(_ row: Row, userId: String) throws -> [String: AnyJSON] {
        let data = try JSONEncoder().encode(row)
        var obj = try JSONDecoder().decode([String: AnyJSON].self, from: data)
        obj["user_id"] = .string(userId)
        return obj
    }
}
