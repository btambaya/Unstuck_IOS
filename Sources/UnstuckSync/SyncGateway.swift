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
