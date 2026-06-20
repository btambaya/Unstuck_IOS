// OutboxFlusher — drains the offline write-ahead queue to Supabase in
// op-seq order, honouring dependency ordering (a cal_block op stays
// queued until its parent task op flushes). Each op's payload is the row
// JSON written by WriteThrough; it's decoded back to the typed DbRowCodec
// row and re-sent through the gateway (which attaches user_id). Port of
// the Android OutboxFlusher (spec 02-sync-engine §1.2/§1.4):
//  • user-switch guard: every pass re-checks the LIVE user id so a
//    sign-out + sign-in mid-drain can't stamp queued ops with a new user.
//  • blockedRows: once an op for a row fails this pass, that row's LATER
//    ops are skipped — the server converges to the last-enqueued state in
//    seq order (an older retried upsert can't clobber a newer one).
//  • poison pill: after FAIL_CAP consecutive same-process failures an op
//    is dropped, along with the ops that depended on its row (their FK
//    parent will never exist server-side).

import Foundation
import UnstuckData

public actor OutboxFlusher {
    private let gateway: any SyncGatewayProtocol
    private let box: OutboxStore
    private let db: AppDatabase
    private let decoder = JSONDecoder()

    // Per-op consecutive-failure tally (keyed by outbox seq). In-memory and
    // resets on app restart, so a transient failure (offline) still gets
    // full retries next launch; only a genuinely poison op (a payload the
    // server rejects forever) is dropped after FAIL_CAP failures.
    private var failCounts: [Int64: Int] = [:]
    private static let failCap = 5

    // Quarantined (dead-lettered) op seqs: malformed ops we can't even build a
    // request for — an unknown tableName or a nil/undecodable upsert payload.
    // These can never succeed by retrying, but they must NOT be markDone'd
    // (that silently drops the user's local row) and must NOT be retried as if
    // transiently failing (that would poison-cap a healthy app or spin the
    // drain). We keep the outbox row, stop sending it, and skip it every pass —
    // the local row stays put, and hydrate's pending-row preservation still
    // protects it from a blanking replace. In-memory (resets on relaunch) so a
    // future build that learns the table/payload can flush it. Mirrors the
    // idea of a dead-letter queue without a schema change.
    private var quarantined: Set<Int64> = []

    public init(gateway: any SyncGatewayProtocol, db: AppDatabase) {
        self.gateway = gateway
        self.box = OutboxStore(db)
        self.db = db
    }

    /// The FK-parent table a child table's `dependsOn` rowId lives in:
    /// cal_block → tasks, capture → sessions. Other tables have no FK parent.
    static func dependsOnParentTable(_ childTable: String) -> String? {
        switch childTable {
        case "cal_blocks": return "tasks"
        case "captures":   return "sessions"
        default:           return nil
        }
    }

    // The in-flight drain. Swift actors are REENTRANT across `await`, so without
    // chaining, two of the four overlapping flush triggers (debounced post-write
    // kick / scenePhase syncNow / auth event / sign-out task group) interleave:
    // while one is suspended in `await apply(op)` before markDone, another re-reads
    // pending() and re-applies the same op + races failCounts (the per-pass
    // blockedRows set is task-local, defeating last-writer-wins). Android serializes
    // with a Mutex; we chain through this Task. Chaining (not bail-if-busy) so the
    // bounded sign-out drain actually completes a pass before clearAll() wipes the
    // outbox, instead of early-returning.
    private var draining: Task<Void, Never>?

    public func flush(userId: String) async {
        await flush(userId: userId, currentUserId: { userId })
    }

    public func flush(userId: String, currentUserId: @escaping @Sendable () -> String?) async {
        let prev = draining
        let work = Task { [weak self] in
            await prev?.value
            await self?.drainLoop(userId: userId, currentUserId: currentUserId)
        }
        draining = work
        await work.value
    }

    private func drainLoop(userId: String, currentUserId: @Sendable () -> String?) async {
        while true {
            // A cancelled drain (sign-out's 5s timeout, BG-task stop) is normal
            // control flow, not a failure — abort without burning the poison cap.
            if Task.isCancelled { return }
            // Bail if the signed-in user changed mid-drain (sign-out + sign-in
            // to a different account). RLS already blocks a cross-account
            // write, but this avoids confusing FK/RLS errors + a stuck op.
            if currentUserId() != userId { return }
            let all = (try? box.pending()) ?? []   // FIFO by seq
            if all.isEmpty { break }
            let pendingRowIds = Set(all.map(\.rowId))
            // Per-pass cache of a parent table's local row ids (only queried for
            // the dependsOn parent tables tasks / sessions).
            var localCache: [String: Set<String>] = [:]
            func localIds(_ table: String) -> Set<String> {
                if let c = localCache[table] { return c }
                let ids = (try? db.localRowIds(table: table)) ?? []
                localCache[table] = ids
                return ids
            }
            // An op is held back while its dependsOn rowId still has a pending op,
            // OR while its FK parent row doesn't exist locally yet — e.g. a capture
            // taken during a LIVE focus session (the sessions row is only written
            // at session end). A parent present locally with no pending op has been
            // flushed/hydrated, so the FK is satisfied server-side.
            let flushable = all.filter { op in
                // Skip dead-lettered ops: kept in the outbox (the local row
                // survives) but never re-sent, so they don't spin the loop.
                if let seq = op.opSeq, quarantined.contains(seq) { return false }
                guard let dep = op.dependsOn else { return true }
                if pendingRowIds.contains(dep) { return false }
                guard let parent = Self.dependsOnParentTable(op.tableName) else { return true }
                return localIds(parent).contains(dep)
            }
            if flushable.isEmpty { break }
            var progressed = false
            // Once an op for a given row fails this pass, skip that row's LATER
            // ops so a newer edit isn't applied (then clobbered when the older
            // one retries) — preserve per-row order / last-writer-wins.
            var blockedRows: Set<String> = []
            for op in flushable {
                guard let seq = op.opSeq else { continue }
                let rowKey = "\(op.tableName):\(op.rowId)"
                if blockedRows.contains(rowKey) { continue }
                do {
                    try await apply(op, userId: userId)
                    try box.markDone(seq)
                    failCounts[seq] = nil
                    progressed = true
                } catch let malformed as MalformedOpError {
                    // Structurally-invalid op (nil payload / unknown table): it
                    // can never become a request, so dead-letter it — keep the
                    // outbox row (the user's local row is untouched and stays on
                    // the UI via hydrate's pending-row preservation), stop
                    // re-sending it, and don't markDone (the old code's silent
                    // drop) or burn the poison cap (it isn't a server rejection).
                    // Block this row's later ops too, preserving per-row order.
                    print("[outbox] quarantining malformed op \(rowKey): \(malformed.reason)")
                    quarantined.insert(seq)
                    blockedRows.insert(rowKey)
                } catch {
                    // Cancellation (sign-out timeout / BG-task stop / URLSession
                    // cancelled) is NOT a server rejection — abort the drain
                    // without touching failCounts/blockedRows, or a repeated
                    // sign-out on a slow link would poison-drop a valid op + its
                    // FK dependents. Mirrors Android's `catch CancellationException`.
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        return
                    }
                    print("[outbox] \(rowKey) failed: \(error)")
                    blockedRows.insert(rowKey)
                    try? box.bumpAttempts(seq)   // persisted for field debugging only
                    let n = (failCounts[seq] ?? 0) + 1
                    failCounts[seq] = n
                    if n >= Self.failCap {
                        print("[outbox] dropping poison op \(rowKey) after \(n) failures")
                        try? box.markDone(seq)
                        failCounts[seq] = nil
                        progressed = true
                        // Also drop ops that depended on this row — their FK parent
                        // will never exist server-side, so flushing them would push
                        // a dangling reference (or fail forever in turn).
                        for dep in all where dep.dependsOn == op.rowId {
                            guard let depSeq = dep.opSeq else { continue }
                            print("[outbox] dropping orphaned dependent \(dep.tableName):\(dep.rowId)")
                            try? box.markDone(depSeq)
                            failCounts[depSeq] = nil
                        }
                    }
                }
            }
            if !progressed { break }   // all remaining ops errored — stop, retry later
        }
    }

    /// A structurally-invalid op the flusher can never turn into a request:
    /// an upsert with a nil payload, or a tableName the apply switch doesn't
    /// know. NOT a server rejection (so it must not feed the poison cap) and
    /// NOT success (so the op must not be markDone'd) — it's dead-lettered.
    struct MalformedOpError: Error {
        enum Reason { case missingPayload, unknownTable(String) }
        let reason: Reason
    }

    private func apply(_ op: OutboxOp, userId: String) async throws {
        if op.kind == .delete {
            try await gateway.delete(table: op.tableName, id: op.rowId)
            return
        }
        // A nil/empty upsert payload can never be sent. Surface it so the drain
        // quarantines the op instead of silently markDone'ing (= dropping the
        // user's local row) — the old `guard … else { return }` looked like
        // success to the caller.
        guard let data = op.payload?.data(using: .utf8) else {
            throw MalformedOpError(reason: .missingPayload)
        }
        switch op.tableName {
        case "tasks":        try await gateway.upsert(decoder.decode(TaskRow.self, from: data), table: op.tableName, userId: userId)
        case "cal_blocks":   try await gateway.upsert(decoder.decode(CalBlockRow.self, from: data), table: op.tableName, userId: userId)
        case "sessions":     try await gateway.upsert(decoder.decode(SessionRow.self, from: data), table: op.tableName, userId: userId)
        case "captures":     try await gateway.upsert(decoder.decode(CaptureRow.self, from: data), table: op.tableName, userId: userId)
        case "reason_logs":  try await gateway.upsert(decoder.decode(ReasonLogRow.self, from: data), table: op.tableName, userId: userId)
        case "collections":  try await gateway.upsert(decoder.decode(CollectionRow.self, from: data), table: op.tableName, userId: userId)
        case "tags":         try await gateway.upsert(decoder.decode(TagDbRow.self, from: data), table: op.tableName, userId: userId)
        case "life_areas":   try await gateway.upsert(decoder.decode(LifeAreaDbRow.self, from: data), table: op.tableName, userId: userId)
        // An unknown table can never be routed. Quarantine rather than the old
        // `default: break` (which fell through to markDone, dropping the row).
        default: throw MalformedOpError(reason: .unknownTable(op.tableName))
        }
    }
}
