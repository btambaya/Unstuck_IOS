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
//  • quarantine (was: poison pill): an op the server REJECTS (PostgREST
//    4xx — FK / check / unknown column) `OutboxStore.quarantineCap` times is
//    quarantined — KEPT in the outbox (the local row survives every hydrate
//    via the pending-row preservation, and a future build / support can
//    retry it), skipped by every drain, never deleted. Ops that depend on it
//    stay held back behind it. Offline / timeout / 5xx / auth-refresh
//    failures are TRANSIENT: they never count — the old cap counted plain
//    airplane-mode failures and silently dropped valid writes after five.

import Foundation
import Supabase
import UnstuckData

public actor OutboxFlusher {
    private let gateway: any SyncGatewayProtocol
    private let box: OutboxStore
    private let db: AppDatabase
    private let decoder = JSONDecoder()

    // Quarantined (dead-lettered) op seqs for MALFORMED ops: ones we can't even
    // build a request for — an unknown tableName or a nil/undecodable upsert
    // payload. These can never succeed by retrying, but they must NOT be
    // markDone'd (that silently drops the user's local row) and must NOT be
    // retried as if transiently failing. In-memory (resets on relaunch) so a
    // future build that learns the table/payload can flush it. Server-rejected
    // ops use the PERSISTED `attempts` counter instead (OutboxOp.isQuarantined).
    private var malformed: Set<Int64> = []

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
    // pending() and re-applies the same op (the per-pass blockedRows set is
    // task-local, defeating last-writer-wins). Android serializes with a Mutex;
    // we chain through this Task. Chaining (not bail-if-busy) so the bounded
    // sign-out drain actually completes a pass before the outbox is parked.
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
            // control flow, not a failure — abort without counting anything.
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
                // Skip quarantined ops: kept in the outbox (the local row
                // survives) but never re-sent, so they don't spin the loop.
                if op.isQuarantined { return false }
                if let seq = op.opSeq, malformed.contains(seq) { return false }
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
                    progressed = true
                } catch let bad as MalformedOpError {
                    // Structurally-invalid op (nil payload / unknown table): it
                    // can never become a request, so dead-letter it — keep the
                    // outbox row (the user's local row is untouched and stays on
                    // the UI via hydrate's pending-row preservation), stop
                    // re-sending it, and don't markDone (the old code's silent
                    // drop). Block this row's later ops too, preserving per-row order.
                    print("[outbox] quarantining malformed op \(rowKey): \(bad.reason)")
                    malformed.insert(seq)
                    blockedRows.insert(rowKey)
                } catch {
                    switch SyncDecision.classifyFlushFailure(error) {
                    case .cancelled:
                        // Sign-out timeout / BG-task stop / URLSession cancelled —
                        // not a server verdict. Abort the drain untouched.
                        return
                    case .transient:
                        // Offline, timeout, 5xx, JWT refresh in flight: the op is
                        // fine, the network isn't. Block the row for this pass
                        // (per-row order) and retry on the next drain. NEVER
                        // counted — five airplane-mode passes used to drop a
                        // valid write and its FK dependents for good.
                        print("[outbox] \(rowKey) transient failure, will retry: \(error)")
                        blockedRows.insert(rowKey)
                    case .rejected:
                        // The server understood and refused these exact bytes.
                        // Count it (persisted); at the cap the op is quarantined:
                        // kept, skipped, never deleted — and its dependents stay
                        // held back behind it rather than being dropped too.
                        print("[outbox] \(rowKey) rejected by server: \(error)")
                        blockedRows.insert(rowKey)
                        let n = (try? box.bumpAttempts(seq)) ?? 0
                        if n >= OutboxStore.quarantineCap {
                            print("[outbox] quarantining \(rowKey) after \(n) rejections (kept, no longer sent)")
                        }
                    }
                }
            }
            if !progressed { break }   // all remaining ops errored — stop, retry later
        }
    }

    /// A structurally-invalid op the flusher can never turn into a request:
    /// an upsert with a nil payload, or a tableName the apply switch doesn't
    /// know. NOT a server rejection (so it must not feed the cap) and NOT
    /// success (so the op must not be markDone'd) — it's dead-lettered.
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
        // Soft deletes travel as upserts with active=false (see WriteThrough.
        // pushProfileFact); profile_facts never enqueues a `delete` op.
        case "profile_facts": try await gateway.upsert(decoder.decode(ProfileFactRow.self, from: data), table: op.tableName, userId: userId)
        // An unknown table can never be routed. Quarantine rather than the old
        // `default: break` (which fell through to markDone, dropping the row).
        default: throw MalformedOpError(reason: .unknownTable(op.tableName))
        }
    }
}

// MARK: - supabase-swift error classification

/// PostgREST error body (`{code, message, details, hint}`). The `code` is a
/// Postgres SQLSTATE or a `PGRSTnnn` code. Definite rejections: integrity /
/// data / syntax classes (23xxx FK+unique+check, 22xxx bad value, 42xxx
/// unknown column / permission) and the PostgREST request-shape codes
/// (PGRST1xx / PGRST2xx — e.g. PGRST204 unknown column). Transient: the JWT
/// codes (PGRST30x — the SDK refreshes the token), connection / pool errors
/// (PGRST00x, 08xxx, 53xxx, 57xxx), serialization retries (40001) and any
/// body without a code (a gateway / edge error page).
extension PostgrestError: ServerRejectionClassifiable {
    public var isServerRejection: Bool {
        guard let code, !code.isEmpty else { return false }
        if code.hasPrefix("PGRST") {
            let n = Int(code.dropFirst(5)) ?? 0
            return (100..<300).contains(n)
        }
        guard code.count == 5 else { return false }
        let cls = code.prefix(2)
        switch cls {
        case "22", "23", "42", "P0": return true     // data, integrity, syntax/access, PL/pgSQL raise
        case "08", "53", "57", "40": return false    // connection, resources, operator intervention, tx retry
        default: return false
        }
    }
}

/// A non-2xx response whose body wasn't a PostgREST error object. 4xx is the
/// server refusing the request; 401 / 403 / 408 / 425 / 429 are auth-refresh
/// / timing / rate-limit shapes that a retry can clear, and 5xx is the
/// server's problem — all transient.
extension HTTPError: ServerRejectionClassifiable {
    public var isServerRejection: Bool {
        let status = response.statusCode
        guard (400..<500).contains(status) else { return false }
        return ![401, 403, 408, 425, 429].contains(status)
    }
}
