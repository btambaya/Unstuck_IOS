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

    public func hydrate() async {
        await replace("tasks", TaskRow.self) { try self.db.replaceAll(TaskItem.self, with: $0.map { $0.model() }) }
        await replace("sessions", SessionRow.self) { try self.db.replaceAll(Session.self, with: $0.map { $0.model() }) }
        await replace("captures", CaptureRow.self) { try self.db.replaceAll(Capture.self, with: $0.map { $0.model() }) }
        await replace("reason_logs", ReasonLogRow.self) { try self.db.replaceAll(ReasonLog.self, with: $0.map { $0.model() }) }
        await replace("collections", CollectionRow.self) { try self.db.replaceAll(ItemCollection.self, with: $0.map { $0.model() }) }
        await replace("tags", TagDbRow.self) { try self.db.replaceAll(TagRow.self, with: $0.map { $0.model() }) }
        await replace("life_areas", LifeAreaDbRow.self) { try self.db.replaceAll(LifeArea.self, with: $0.map { $0.model() }) }
        await replace("calendar_connections", CalendarConnectionRow.self) { try self.db.replaceAll(CalendarConnection.self, with: $0.map { $0.model() }) }
        await hydrateCalBlocks()
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
