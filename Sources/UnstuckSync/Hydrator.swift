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
    private let gateway: SyncGateway
    private let db: AppDatabase

    public init(gateway: SyncGateway, db: AppDatabase) {
        self.gateway = gateway
        self.db = db
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
            let base = try await gateway.fetchAll(CollectionRow.self, table: "collections").map { $0.model() }
            let memberRows = (try? await gateway.fetchAll(MemberRow.self, table: "collection_members")) ?? []
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
            try db.replaceAll(ItemCollection.self, with: enriched)
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
            let rows = try await gateway.fetchAll(Row.self, table: table)
            try save(rows)
        } catch {
            print("[hydrate] \(table) failed, leaving local intact: \(error)")
        }
    }

    private func hydrateCalBlocks() async {
        do {
            let remote = try await gateway.fetchAll(CalBlockRow.self, table: "cal_blocks").map { $0.model() }
            let localExternal = (try? db.fetchExternalCalBlocks()) ?? []
            let merged = SyncDecision.mergeHydratedCalBlocks(remote: remote, localExternal: localExternal)
            try db.replaceAll(CalBlock.self, with: merged)
        } catch {
            print("[hydrate] cal_blocks failed, leaving local intact: \(error)")
        }
    }
}
