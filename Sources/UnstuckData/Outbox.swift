// Outbox — the offline write-ahead queue. Every optimistic local
// mutation enqueues an op; the OutboxFlusher (UnstuckSync) drains it in
// op-seq order, honouring `dependsOn` so a cal_block insert never reaches
// the server before its parent task (mirrors the web bridge's
// await-pending-upsert ordering). The server stays canonical: after a
// flush, a hydrate reconciles.

import Foundation
import GRDB

public enum OutboxKind: String, Codable, Sendable {
    case upsert, delete
}

public struct OutboxOp: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "outbox"

    public var opSeq: Int64?
    public var tableName: String
    public var rowId: String
    public var kind: OutboxKind
    public var payload: String?      // JSON row for upserts; nil for delete
    public var dependsOn: String?    // rowId this op must follow
    public var attempts: Int
    public var createdAt: String

    public init(opSeq: Int64? = nil, tableName: String, rowId: String, kind: OutboxKind,
                payload: String? = nil, dependsOn: String? = nil, attempts: Int = 0, createdAt: String) {
        self.opSeq = opSeq
        self.tableName = tableName
        self.rowId = rowId
        self.kind = kind
        self.payload = payload
        self.dependsOn = dependsOn
        self.attempts = attempts
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        opSeq = inserted.rowID
    }
}

public struct OutboxStore: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    @discardableResult
    public func enqueue(table: String, rowId: String, kind: OutboxKind,
                        payload: String? = nil, dependsOn: String? = nil, nowISO: String) throws -> OutboxOp {
        var op = OutboxOp(tableName: table, rowId: rowId, kind: kind,
                          payload: payload, dependsOn: dependsOn, createdAt: nowISO)
        try db.writer.write { try op.insert($0) }
        return op
    }

    /// All pending ops, oldest first.
    public func pending() throws -> [OutboxOp] {
        try db.writer.read { try OutboxOp.order(Column("opSeq")).fetchAll($0) }
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
        _ = try db.writer.write { try OutboxOp.deleteOne($0, key: opSeq) }
    }

    /// Drop any queued upsert ops for a row about to be deleted, so a
    /// held-back upsert (e.g. a cal_block waiting on its parent task via
    /// `dependsOn`) can't flush AFTER the delete and resurrect the row
    /// server-side (spec 02-sync-engine §1.6/§1.8).
    public func cancelPendingUpserts(table: String, rowId: String) throws {
        _ = try db.writer.write { db in
            try OutboxOp
                .filter(Column("tableName") == table)
                .filter(Column("rowId") == rowId)
                .filter(Column("kind") == OutboxKind.upsert.rawValue)
                .deleteAll(db)
        }
    }

    public func bumpAttempts(_ opSeq: Int64) throws {
        try db.writer.write { db in
            if var op = try OutboxOp.fetchOne(db, key: opSeq) {
                op.attempts += 1
                try op.update(db)
            }
        }
    }

    public func count() throws -> Int {
        try db.writer.read { try OutboxOp.fetchCount($0) }
    }
}
