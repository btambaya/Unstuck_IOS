// Outbox — the offline write-ahead queue. Every optimistic local
// mutation enqueues an op; the OutboxFlusher (UnstuckSync) drains it in
// op-seq order, honouring `dependsOn` so a cal_block insert never reaches
// the server before its parent task (mirrors the web bridge's
// await-pending-upsert ordering). The server stays canonical: after a
// flush, a hydrate reconciles.
//
// Two extras beyond the plain queue:
//  • `baseUpdatedAt` / `basePayload` — for `tasks` upserts, the row AS THIS
//    DEVICE LAST SAW IT before the edit (a server-stamped `updated_at` when
//    the row came from a hydrate / realtime echo). The prune-before-flush
//    compares the SERVER's updated_at with this base — both server clocks,
//    so device-clock skew can't misjudge an offline edit — and, on a real
//    conflict, does a 3-way field merge instead of dropping the whole op.
//    A SECOND queued edit's base is the first edit's local row (device
//    clock), so the prune judges a row's queued edits as one chain, by its
//    oldest op (audit 2026-09-22, C9).
//  • `attempts` counts SERVER REJECTIONS only (never offline / 5xx / auth
//    failures). At `OutboxStore.quarantineCap` rejections the op is
//    quarantined: kept in the outbox (so hydrate keeps the local row and a
//    future build can retry it), skipped by every drain. It is never
//    silently deleted — that was the old poison-pill data-loss path.

import Foundation
import GRDB

public enum OutboxKind: String, Codable, Sendable {
    case upsert, delete
    /// A server-side RPC (a shared collection's atomic item mutation —
    /// `collection_add_item` etc.). `payload` is an `OutboxRPCPayload`;
    /// `tableName`/`rowId` name the row it mutates so per-row ordering and
    /// the pending-row preservation apply. Retried on transient failure like
    /// any op; a server REJECTION is terminal on the first strike (the same
    /// bytes can never succeed) — the flusher drops it and reports it so the
    /// optimistic local row is rolled back with a visible error.
    case rpc
}

/// The payload of an `OutboxKind.rpc` op: the function name and its
/// parameters as a JSON object string (kept as text so this module stays free
/// of the transport's JSON type; the gateway decodes it when sending).
public struct OutboxRPCPayload: Codable, Equatable, Sendable {
    public var fn: String
    public var paramsJSON: String

    public init(fn: String, paramsJSON: String) {
        self.fn = fn
        self.paramsJSON = paramsJSON
    }

    public func encoded() throws -> String {
        String(data: try JSONEncoder().encode(self), encoding: .utf8) ?? "{}"
    }

    public static func decode(_ payload: String?) -> OutboxRPCPayload? {
        guard let data = payload?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OutboxRPCPayload.self, from: data)
    }
}

public struct OutboxOp: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "outbox"

    public var opSeq: Int64?
    public var tableName: String
    public var rowId: String
    public var kind: OutboxKind
    public var payload: String?      // JSON row for upserts; nil for delete
    public var dependsOn: String?    // rowId this op must follow
    /// Server REJECTIONS so far (see the header). Transient failures don't count.
    public var attempts: Int
    public var createdAt: String
    /// `updated_at` of the local row this edit was made ON TOP OF (nil for a
    /// brand-new row / non-task tables / legacy ops).
    public var baseUpdatedAt: String?
    /// The full row JSON this edit was made on top of (same shape as `payload`),
    /// the third input of the prune's 3-way merge. nil = no base.
    public var basePayload: String?

    public init(opSeq: Int64? = nil, tableName: String, rowId: String, kind: OutboxKind,
                payload: String? = nil, dependsOn: String? = nil, attempts: Int = 0, createdAt: String,
                baseUpdatedAt: String? = nil, basePayload: String? = nil) {
        self.opSeq = opSeq
        self.tableName = tableName
        self.rowId = rowId
        self.kind = kind
        self.payload = payload
        self.dependsOn = dependsOn
        self.attempts = attempts
        self.createdAt = createdAt
        self.baseUpdatedAt = baseUpdatedAt
        self.basePayload = basePayload
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        opSeq = inserted.rowID
    }

    /// True once the op has been rejected by the server `quarantineCap` times:
    /// the drain skips it (kept, never re-sent, never deleted).
    public var isQuarantined: Bool { attempts >= OutboxStore.quarantineCap }
}

/// An outbox op parked for a signed-out user (see `OutboxStore.park`). Same
/// shape as `OutboxOp` plus the owner, in its original seq order.
public struct ParkedOutboxOp: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "parked_outbox"

    public var parkSeq: Int64?
    public var userId: String
    public var tableName: String
    public var rowId: String
    public var kind: OutboxKind
    public var payload: String?
    public var dependsOn: String?
    public var attempts: Int
    public var createdAt: String
    public var baseUpdatedAt: String?
    public var basePayload: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        parkSeq = inserted.rowID
    }
}

public struct OutboxStore: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Server rejections before an op is quarantined (kept, no longer sent).
    public static let quarantineCap = 5

    @discardableResult
    public func enqueue(table: String, rowId: String, kind: OutboxKind,
                        payload: String? = nil, dependsOn: String? = nil, nowISO: String,
                        baseUpdatedAt: String? = nil, basePayload: String? = nil) throws -> OutboxOp {
        try db.writer.write {
            try Self.enqueue(in: $0, table: table, rowId: rowId, kind: kind, payload: payload,
                             dependsOn: dependsOn, nowISO: nowISO,
                             baseUpdatedAt: baseUpdatedAt, basePayload: basePayload)
        }
    }

    /// Enqueue on an OPEN connection — for callers already inside a write
    /// transaction (the hydrate merge, WriteThrough's row+op transaction),
    /// where a fresh `writer.write` would be a re-entrant call. Same op shape
    /// as `enqueue(table:…)`.
    @discardableResult
    public static func enqueue(in db: Database, table: String, rowId: String, kind: OutboxKind,
                               payload: String? = nil, dependsOn: String? = nil, nowISO: String,
                               baseUpdatedAt: String? = nil, basePayload: String? = nil) throws -> OutboxOp {
        var op = OutboxOp(tableName: table, rowId: rowId, kind: kind,
                          payload: payload, dependsOn: dependsOn, createdAt: nowISO,
                          baseUpdatedAt: baseUpdatedAt, basePayload: basePayload)
        try op.insert(db)
        return op
    }

    /// All pending ops, oldest first (quarantined ones included — callers
    /// that send filter on `isQuarantined`).
    public func pending() throws -> [OutboxOp] {
        try db.writer.read { try Self.pending(in: $0) }
    }

    /// Same, on an OPEN connection.
    public static func pending(in db: Database) throws -> [OutboxOp] {
        try OutboxOp.order(Column("opSeq")).fetchAll(db)
    }

    /// Ops ready to flush now, op-seq order. An op is held back while its
    /// `dependsOn` rowId still has any pending op (so the parent flushes
    /// first).
    public func nextFlushable() throws -> [OutboxOp] {
        let all = try pending()
        let pendingRowIds = Set(all.map(\.rowId))
        return all.filter { op in
            guard let dep = op.dependsOn else { return true }
            return !pendingRowIds.contains(dep)
        }
    }

    public func markDone(_ opSeq: Int64) throws {
        try db.writer.write { try Self.markDone(in: $0, opSeq) }
    }

    /// Same, on an OPEN connection (see `enqueue(in:…)`).
    public static func markDone(in db: Database, _ opSeq: Int64) throws {
        _ = try OutboxOp.deleteOne(db, key: opSeq)
    }

    /// Drop any queued upsert (and rpc-mutation) ops for a row about to be
    /// deleted, so a held-back upsert (e.g. a cal_block waiting on its parent
    /// task via `dependsOn`) can't flush AFTER the delete and resurrect the
    /// row server-side (spec 02-sync-engine §1.6/§1.8), and a shared-list item
    /// RPC doesn't fire on a list that no longer exists.
    public func cancelPendingUpserts(table: String, rowId: String) throws {
        try db.writer.write { try Self.cancelPendingUpserts(in: $0, table: table, rowId: rowId) }
    }

    /// Same, on an OPEN connection (see `enqueue(in:…)`).
    public static func cancelPendingUpserts(in db: Database, table: String, rowId: String) throws {
        _ = try OutboxOp
            .filter(Column("tableName") == table)
            .filter(Column("rowId") == rowId)
            .filter(Column("kind") != OutboxKind.delete.rawValue)
            .deleteAll(db)
    }

    /// Record one SERVER REJECTION of an op (persisted, so the quarantine
    /// survives a relaunch). Returns the new count.
    @discardableResult
    public func bumpAttempts(_ opSeq: Int64) throws -> Int {
        try db.writer.write { db in
            guard var op = try OutboxOp.fetchOne(db, key: opSeq) else { return 0 }
            op.attempts += 1
            try op.update(db)
            return op.attempts
        }
    }

    /// Replace an op's payload + base in place (the prune's 3-way merge
    /// rewrites a conflicting task op as "local diff on top of the server row").
    public func replacePayload(_ opSeq: Int64, payload: String, baseUpdatedAt: String?, basePayload: String?) throws {
        try db.writer.write {
            try Self.replacePayload(in: $0, opSeq, payload: payload, baseUpdatedAt: baseUpdatedAt, basePayload: basePayload)
        }
    }

    /// Same, on an OPEN connection (see `enqueue(in:…)`) — the prune rewrites
    /// a row's whole chain of queued edits in one transaction.
    public static func replacePayload(in db: Database, _ opSeq: Int64, payload: String,
                                      baseUpdatedAt: String?, basePayload: String?) throws {
        guard var op = try OutboxOp.fetchOne(db, key: opSeq) else { return }
        op.payload = payload
        op.baseUpdatedAt = baseUpdatedAt
        op.basePayload = basePayload
        try op.update(db)
    }

    public func count() throws -> Int {
        try db.writer.read { try OutboxOp.fetchCount($0) }
    }

    /// Ops the server rejected `quarantineCap` times — stuck, kept for a
    /// future build / support. Surfaced so the UI can say "N changes couldn't
    /// sync" instead of silently losing them.
    public func quarantinedCount() throws -> Int {
        try db.writer.read {
            try OutboxOp.filter(Column("attempts") >= Self.quarantineCap).fetchCount($0)
        }
    }

    // MARK: - parking (sign-out while edits are still queued)

    /// Move EVERY pending op into `parked_outbox` under `userId`, in seq
    /// order. Sign-out wipes the outbox (the next account must never replay
    /// another user's ops); parking first keeps an offline user's un-pushed
    /// edits for THEIR next sign-in instead of discarding them. The op
    /// payloads carry the full rows, so the flush re-creates them server-side
    /// even though the local rows are wiped. Returns how many were parked.
    @discardableResult
    public func park(userId: String) throws -> Int {
        try db.writer.write { db in
            let ops = try OutboxOp.order(Column("opSeq")).fetchAll(db)
            for op in ops {
                var parked = ParkedOutboxOp(userId: userId, tableName: op.tableName, rowId: op.rowId, kind: op.kind,
                                            payload: op.payload, dependsOn: op.dependsOn, attempts: op.attempts,
                                            createdAt: op.createdAt, baseUpdatedAt: op.baseUpdatedAt,
                                            basePayload: op.basePayload)
                try parked.insert(db)
            }
            _ = try OutboxOp.deleteAll(db)
            return ops.count
        }
    }

    /// Re-enqueue the ops parked for `userId` (original order, appended after
    /// anything already queued) and drop them from the parking table. Ops
    /// parked for OTHER users stay parked. Returns how many were restored.
    @discardableResult
    public func restoreParked(userId: String) throws -> Int {
        try db.writer.write { db in
            let parked = try ParkedOutboxOp.filter(Column("userId") == userId).order(Column("parkSeq")).fetchAll(db)
            for p in parked {
                var op = OutboxOp(tableName: p.tableName, rowId: p.rowId, kind: p.kind, payload: p.payload,
                                  dependsOn: p.dependsOn, attempts: p.attempts, createdAt: p.createdAt,
                                  baseUpdatedAt: p.baseUpdatedAt, basePayload: p.basePayload)
                try op.insert(db)
            }
            _ = try ParkedOutboxOp.filter(Column("userId") == userId).deleteAll(db)
            return parked.count
        }
    }

    /// How many ops are parked for `userId` (nil = for anyone).
    public func parkedCount(userId: String? = nil) throws -> Int {
        try db.writer.read { db in
            if let userId { return try ParkedOutboxOp.filter(Column("userId") == userId).fetchCount(db) }
            return try ParkedOutboxOp.fetchCount(db)
        }
    }
}
