// Hydrator — pulls every synced table and replaces the local store
// (server-canonical). Per-table error isolation: a table whose fetch
// fails is left intact rather than blanked (mirrors hydrate.ts's
// `if (res.ok) replace(...)`). cal_blocks additionally preserves locally
// cached Google external blocks across the replace. RLS auto-scopes
// reads to the signed-in user.

import Foundation
import UnstuckCore
import UnstuckData

public actor Hydrator {
    private let gateway: any SyncReadGatewayProtocol
    private let db: AppDatabase
    private let box: OutboxStore
    private let decoder = JSONDecoder()

    public init(gateway: any SyncReadGatewayProtocol, db: AppDatabase) {
        self.gateway = gateway
        self.db = db
        self.box = OutboxStore(db)
    }

    /// Drop queued `tasks` upsert ops the server already supersedes (its row is
    /// STRICTLY newer by updatedAt). Run BEFORE the flush: without it, a stale
    /// local op — e.g. an old `done=false` edit still sitting in the outbox —
    /// re-pushes and clobbers a newer server change (a completion made on the
    /// WEB), which the following hydrate then faithfully pulls back as not-done.
    /// This is the load-bearing fix for "completed on web, didn't reflect on the
    /// phone". Only reads the server when task ops are actually queued, so it's
    /// free in the common empty-outbox case. (Genuine offline edits — whose op is
    /// newer than the server — survive and flush normally.)
    public func pruneStaleTaskOps() async {
        let ops = (try? box.pending()) ?? []
        let taskOps = ops.filter { $0.tableName == "tasks" && $0.kind == .upsert }
        guard !taskOps.isEmpty else { return }
        // Per-row tolerant: one un-decodable server task must not make the whole
        // prune a no-op (which would let stale local ops re-push and clobber).
        guard let serverRows = try? await gateway.fetchAllTolerant(TaskRow.self, table: "tasks") else { return }
        var serverUpdatedAt: [String: String] = [:]
        for r in serverRows { serverUpdatedAt[r.id] = r.updatedAt }
        for op in taskOps {
            guard let seq = op.opSeq, let data = op.payload?.data(using: .utf8),
                  let row = try? decoder.decode(TaskRow.self, from: data),
                  let serverTime = serverUpdatedAt[op.rowId] else { continue }
            if serverTime > row.updatedAt {
                print("[outbox] pruning stale tasks op \(op.rowId) — server is newer")
                try? box.markDone(seq)
            }
        }
    }

    public func hydrate(userId: String) async {
        await replace("tasks", TaskRow.self) { try self.db.replaceAll(TaskItem.self, with: $0.map { $0.model() }) }
        await replace("sessions", SessionRow.self) { try self.db.replaceAll(Session.self, with: $0.map { $0.model() }) }
        await replace("captures", CaptureRow.self) { try self.db.replaceAll(Capture.self, with: $0.map { $0.model() }) }
        await replace("reason_logs", ReasonLogRow.self) { try self.db.replaceAll(ReasonLog.self, with: $0.map { $0.model() }) }
        await hydrateCollections(userId: userId)
        await replace("tags", TagDbRow.self) { try self.db.replaceAll(TagRow.self, with: $0.map { $0.model() }) }
        await replace("life_areas", LifeAreaDbRow.self) { try self.db.replaceAll(LifeArea.self, with: $0.map { $0.model() }) }
        await replace("calendar_connections", CalendarConnectionRow.self) { try self.db.replaceAll(CalendarConnection.self, with: $0.map { $0.model() }) }
        await hydrateCalBlocks()
    }

    /// Collections + their membership. RLS returns own AND shared-with-me rows;
    /// `collection_members` (visible to member or owner) supplies each row's
    /// members[] + the current user's myRole. Mirrors hydrate.ts / the Android
    /// Hydrator. Also invoked standalone when a collection_members realtime
    /// event fires.
    public func hydrateCollections(userId: String) async {
        do {
            // Per-row tolerant decode (see replace()): a single bad collection
            // row mustn't drop the user's entire list of collections.
            let base = try await gateway.fetchAllTolerant(CollectionRow.self, table: "collections").map { $0.model() }
            let memberRows = (try? await gateway.fetchAllTolerant(MemberRow.self, table: "collection_members")) ?? []
            var byColl: [String: [(String, String)]] = [:]   // collectionId -> [(userId, role)]
            for m in memberRows {
                byColl[m.collectionId, default: []].append((m.userId, m.role ?? "editor"))
            }
            let enriched = base.map { c -> ItemCollection in
                let ms = byColl[c.id] ?? []
                var out = c
                out.members = ms.map { $0.0 }
                out.myRole = c.ownerId == userId ? "owner" : ms.first { $0.0 == userId }?.1
                return out
            }
            // Preserve unsynced optimistic collections (those with a pending
            // collections upsert op in the outbox): a just-created/edited list
            // isn't in `base` yet, so the replace would wipe it off the UI until
            // the next flush (spec 02-sync-engine §1.3 localPending — same guard
            // as hydrateCalBlocks).
            let serverIds = Set(enriched.map(\.id))
            let pendingIds = Set(((try? box.pending()) ?? [])
                .filter { $0.tableName == "collections" && $0.kind == .upsert }
                .map(\.rowId))
            let localPending = (try? db.fetchAllCollections())?.filter {
                pendingIds.contains($0.id) && !serverIds.contains($0.id)
            } ?? []
            try db.replaceAll(ItemCollection.self, with: enriched + localPending)
        } catch {
            print("[hydrate] collections failed, leaving local intact: \(error)")
        }
    }

    private struct MemberRow: Decodable, Sendable {
        let collectionId: String
        let userId: String
        let role: String?
        enum CodingKeys: String, CodingKey {
            case collectionId = "collection_id"
            case userId = "user_id"
            case role
        }
    }

    private func replace<Row: Decodable & Sendable>(_ table: String, _ rowType: Row.Type, save: ([Row]) throws -> Void) async {
        do {
            // Per-ROW tolerant decode: one un-decodable row (e.g. a forward-compat
            // shape this build can't parse — an unknown recurrence kind already
            // degrades, but any other new enum value could still throw) must not
            // abort the whole table and wipe every good row off the UI. Drop only
            // the bad row. Mirrors the Android Hydrator.
            let rows = try await gateway.fetchAllTolerant(Row.self, table: table)
            try save(rows)
        } catch {
            print("[hydrate] \(table) failed, leaving local intact: \(error)")
        }
    }

    private func hydrateCalBlocks() async {
        do {
            // Per-row tolerant decode (see replace()): a single bad cal_block row
            // mustn't wipe the whole schedule.
            let remote = try await gateway.fetchAllTolerant(CalBlockRow.self, table: "cal_blocks").map { $0.model() }
            let local = (try? db.fetchAllCalBlocks()) ?? []
            let localExternal = local.filter { isExternalBlock($0) }
            let merged = SyncDecision.mergeHydratedCalBlocks(remote: remote, localExternal: localExternal)
            // Preserve unsynced optimistic TASK blocks (those with a pending
            // cal_blocks upsert op in the outbox): they're in neither `remote`
            // nor `localExternal`, so the replace would wipe a just-scheduled
            // block off the UI until the next flush (spec 02-sync-engine §1.3
            // localPending). Keep any not already present from the server.
            let pendingIds = Set(((try? box.pending()) ?? [])
                .filter { $0.tableName == "cal_blocks" && $0.kind == .upsert }
                .map(\.rowId))
            let mergedIds = Set(merged.map(\.id))
            let localPending = local.filter {
                pendingIds.contains($0.id) && !mergedIds.contains($0.id) && !isExternalBlock($0)
            }
            try db.replaceAll(CalBlock.self, with: merged + localPending)
        } catch {
            print("[hydrate] cal_blocks failed, leaving local intact: \(error)")
        }
    }
}
