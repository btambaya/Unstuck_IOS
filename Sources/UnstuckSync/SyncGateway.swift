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
    /// Insert-if-absent (an `OutboxKind.insert` / `.insertOrRetime` op):
    /// `INSERT … ON CONFLICT (id) DO NOTHING`. True = the server inserted the
    /// row; false = it already had that id and left it untouched (another
    /// device minted the same day, or a retry after a lost ack).
    func insertIfAbsent<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws -> Bool
    /// Rule H's conditional retime: move ONLY an open occurrence on `date` to
    /// `startTime` / `durationMinutes`, nothing else. The server row (JSON) it
    /// changed, or nil when no row matched (moved, done, skipped or gone).
    func retimeIfOpen(table: String, id: String, date: String, startTime: String, durationMinutes: Int) async throws -> Data?
}

/// What an insert-family op did on the server (deterministic-occurrence-ids.md
/// §3). `inserted` and `retimed` are CONFIRMED: only those may be mirrored to
/// Google (rule G).
public enum InsertOutcome: String, Sendable, Equatable {
    case inserted, retimed, ignored
    public var isConfirmed: Bool { self != .ignored }
}

/// A gateway that doesn't do insert-if-absent (test fakes that predate stage
/// 2). A definite rejection, never a retry loop — and never a fallback to a
/// plain upsert: that would overwrite another device's row (hazard c).
public struct InsertUnsupportedError: Error, ServerRejectionClassifiable, Sendable {
    public let table: String
    public var isServerRejection: Bool { true }
    public init(table: String) { self.table = table }
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
    /// THROWS — a protocol extension cannot reach a client, and a default that
    /// upserted instead would reopen hazard c for any gateway that forgot to
    /// override it.
    func insertIfAbsent<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws -> Bool {
        throw InsertUnsupportedError(table: table)
    }
    func retimeIfOpen(table: String, id: String, date: String, startTime: String, durationMinutes: Int) async throws -> Data? {
        throw InsertUnsupportedError(table: table)
    }
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

    /// The CATCH-UP read: one page of rows whose `column` is at or after
    /// `atOrAfter`, ordered by `column` ascending, as per-row JSON. A nil
    /// `atOrAfter` means "from the beginning" — the first pull for a table,
    /// before this device has a cursor. Inclusive rather than strictly-greater
    /// so rows sharing a timestamp with a page boundary are never skipped; the
    /// caller de-duplicates by id.
    func fetchPageSince(table: String, column: String, atOrAfter: String?, limit: Int) async throws -> [Data]

    /// The DELETION read: just the ids the server still has for this user, one
    /// page at a time, ordered by id. A hard delete is invisible to a cursor
    /// pull, so the only way to see one is to ask what still exists.
    func fetchIdPage(table: String, afterId: String?, limit: Int) async throws -> [String]

    /// The SWEEP read: the id-page read plus, when `stampColumn` is given,
    /// each row's value of it — what the sweep compares with the local copy
    /// to find rows the cursor could not see (audit 2026-09-22, C29).
    func fetchIdStampPage(table: String, stampColumn: String?, afterId: String?, limit: Int) async throws -> [IdStamp]

    /// Whole rows by id (per-row JSON) — the sweep takes what it found missing.
    func fetchRowsByIds(table: String, ids: [String]) async throws -> [Data]
}

/// One row of the sweep read: its id and, when asked for, its stamp.
public struct IdStamp: Sendable, Equatable {
    public let id: String
    public let stamp: String?
    public init(id: String, stamp: String?) {
        self.id = id
        self.stamp = stamp
    }
}

public extension SyncReadGatewayProtocol {
    /// Default for gateways that predate the catch-up (test fakes): no delta
    /// support → the caller keeps its cursor and falls back to a full pull.
    func fetchPageSince(table: String, column: String, atOrAfter: String?, limit: Int) async throws -> [Data] {
        throw CatchUpUnsupportedError(table: table)
    }
    func fetchIdPage(table: String, afterId: String?, limit: Int) async throws -> [String] {
        throw CatchUpUnsupportedError(table: table)
    }
    /// Gateways that only list ids still drive the deletion sweep; with no
    /// stamps the sweep only takes rows missing here.
    func fetchIdStampPage(table: String, stampColumn: String?, afterId: String?, limit: Int) async throws -> [IdStamp] {
        try await fetchIdPage(table: table, afterId: afterId, limit: limit).map { IdStamp(id: $0, stamp: nil) }
    }
    /// No by-id read → the sweep takes nothing (it still deletes).
    func fetchRowsByIds(table: String, ids: [String]) async throws -> [Data] {
        throw CatchUpUnsupportedError(table: table)
    }
}

/// The injected read gateway can't do cursor/id reads (an older test fake).
public struct CatchUpUnsupportedError: Error, Sendable {
    public let table: String
    public init(table: String) { self.table = table }
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

    /// One catch-up page. RLS scopes the read to the signed-in user, exactly
    /// like the full hydrate — the cursor only narrows it in time.
    public func fetchPageSince(table: String, column: String, atOrAfter: String?, limit: Int) async throws -> [Data] {
        var query = client.from(table).select()
        if let atOrAfter { query = query.gte(column, value: atOrAfter) }
        let rows: [AnyJSON] = try await query.order(column, ascending: true).limit(limit).execute().value
        let encoder = JSONEncoder()
        return try rows.map { try encoder.encode($0) }
    }

    /// One page of surviving ids, ordered by id so paging is stable.
    public func fetchIdPage(table: String, afterId: String?, limit: Int) async throws -> [String] {
        struct IdRow: Decodable { let id: String }
        var query = client.from(table).select("id")
        if let afterId { query = query.gt("id", value: afterId) }
        let rows: [IdRow] = try await query.order("id", ascending: true).limit(limit).execute().value
        return rows.map(\.id)
    }

    /// `select=id[,stampColumn]`, ordered by id — the id page plus the stamp.
    public func fetchIdStampPage(table: String, stampColumn: String?, afterId: String?, limit: Int) async throws -> [IdStamp] {
        var query = client.from(table).select(stampColumn.map { "id,\($0)" } ?? "id")
        if let afterId { query = query.gt("id", value: afterId) }
        let rows: [AnyJSON] = try await query.order("id", ascending: true).limit(limit).execute().value
        return rows.compactMap { row in
            guard case .object(let obj) = row, let id = obj["id"]?.stringValue else { return nil }
            return IdStamp(id: id, stamp: stampColumn.flatMap { obj[$0]?.stringValue })
        }
    }

    /// `id=in.(…)`: the rows themselves, RLS-scoped like every other read.
    public func fetchRowsByIds(table: String, ids: [String]) async throws -> [Data] {
        guard !ids.isEmpty else { return [] }
        let rows: [AnyJSON] = try await client.from(table).select().in("id", values: ids).execute().value
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

    /// `POST /<table>?on_conflict=id&select=id` with
    /// `Prefer: resolution=ignore-duplicates,return=representation` — i.e.
    /// `INSERT … ON CONFLICT (id) DO NOTHING RETURNING id`, which returns only
    /// the rows it inserted: one row = inserted, `[]` = the id was taken.
    /// Shapes verified live on 2026-09-23 (audit/parity-2026-09-23,
    /// stage2-check.mjs); the request itself is pinned by
    /// `testGatewayInsertIfAbsentRequestShape`.
    public func insertIfAbsent<Row: Encodable & Sendable>(_ row: Row, table: String, userId: String) async throws -> Bool {
        let rows: [AnyJSON] = try await client.from(table)
            .upsert(Self.withUserId(row, userId: userId), onConflict: "id", returning: .representation, ignoreDuplicates: true)
            .select("id")
            .execute().value
        return !rows.isEmpty
    }

    /// `PATCH /<table>?id=eq.X&date=eq.D&done=is.false&skipped=is.false` with
    /// `Prefer: return=representation` and a body of ONLY `start_time` +
    /// `duration_minutes`: it never touches the Google mapping, the name, the
    /// done state or the date (rule H).
    public func retimeIfOpen(table: String, id: String, date: String, startTime: String,
                             durationMinutes: Int) async throws -> Data? {
        let body: [String: AnyJSON] = ["start_time": .string(startTime), "duration_minutes": .integer(durationMinutes)]
        let rows: [AnyJSON] = try await client.from(table)
            .update(body, returning: .representation)
            .eq("id", value: id)
            .eq("date", value: date)
            .is("done", value: false)
            .is("skipped", value: false)
            .execute().value
        guard let first = rows.first else { return nil }
        return try JSONEncoder().encode(first)
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
