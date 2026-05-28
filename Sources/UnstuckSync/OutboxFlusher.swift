// OutboxFlusher — drains the offline write-ahead queue to Supabase in
// op-seq order, honouring dependency ordering (a cal_block op stays
// queued until its parent task op flushes). Each op's payload is the row
// JSON written by WriteThrough; it's decoded back to the typed DbRowCodec
// row and re-sent through the gateway (which attaches user_id). On
// success the op is removed; on failure its attempts counter bumps and
// the drain stops for this pass (retried on the next reconnect/sign-in).

import Foundation
import UnstuckData

public actor OutboxFlusher {
    private let gateway: SyncGateway
    private let box: OutboxStore
    private let decoder = JSONDecoder()

    public init(gateway: SyncGateway, db: AppDatabase) {
        self.gateway = gateway
        self.box = OutboxStore(db)
    }

    public func flush(userId: String) async {
        while true {
            let ops = (try? box.nextFlushable()) ?? []
            if ops.isEmpty { break }
            var progressed = false
            for op in ops {
                guard let seq = op.opSeq else { continue }
                do {
                    try await apply(op, userId: userId)
                    try box.markDone(seq)
                    progressed = true
                } catch {
                    try? box.bumpAttempts(seq)
                    print("[outbox] \(op.tableName)#\(op.rowId) failed: \(error)")
                }
            }
            if !progressed { break }   // all remaining ops errored — stop, retry later
        }
    }

    private func apply(_ op: OutboxOp, userId: String) async throws {
        if op.kind == .delete {
            try await gateway.delete(table: op.tableName, id: op.rowId)
            return
        }
        guard let data = op.payload?.data(using: .utf8) else { return }
        switch op.tableName {
        case "tasks":        try await gateway.upsert(decoder.decode(TaskRow.self, from: data), table: op.tableName, userId: userId)
        case "cal_blocks":   try await gateway.upsert(decoder.decode(CalBlockRow.self, from: data), table: op.tableName, userId: userId)
        case "sessions":     try await gateway.upsert(decoder.decode(SessionRow.self, from: data), table: op.tableName, userId: userId)
        case "captures":     try await gateway.upsert(decoder.decode(CaptureRow.self, from: data), table: op.tableName, userId: userId)
        case "reason_logs":  try await gateway.upsert(decoder.decode(ReasonLogRow.self, from: data), table: op.tableName, userId: userId)
        case "collections":  try await gateway.upsert(decoder.decode(CollectionRow.self, from: data), table: op.tableName, userId: userId)
        case "tags":         try await gateway.upsert(decoder.decode(TagDbRow.self, from: data), table: op.tableName, userId: userId)
        case "life_areas":   try await gateway.upsert(decoder.decode(LifeAreaDbRow.self, from: data), table: op.tableName, userId: userId)
        default: break
        }
    }
}
