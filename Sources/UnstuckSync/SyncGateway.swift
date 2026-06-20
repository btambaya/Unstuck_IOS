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
}

public struct SyncGateway: Sendable, SyncGatewayProtocol, SyncReadGatewayProtocol {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    public func fetchAll<Row: Decodable & Sendable>(_ type: Row.Type, table: String) async throws -> [Row] {
        try await client.from(table).select().execute().value
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
