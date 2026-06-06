// Data export — a real "Backup" that writes the local store to a JSON file the
// user can save/share. Same ExportBundle shape as the web/Android exporters
// (snake_case top-level table keys; each row is the camelCase model JSON), plus
// the locally-stored preferences (adhd_struggles).

import Foundation
import UnstuckCore
import UnstuckData

private struct ExportBundle: Encodable {
    let schemaVersion = 1
    let exportedAt: String
    let user: User
    let tasks: [TaskItem]
    let sessions: [Session]
    let cal_blocks: [CalBlock]
    let reason_logs: [ReasonLog]
    let captures: [Capture]
    let life_areas: [LifeArea]
    let tags: [TagRow]
    let collections: [ItemCollection]
    let calendar_connections: [CalendarConnection]
    let preferences: Preferences

    struct User: Encodable { let email: String?; let displayName: String? }
    struct Preferences: Encodable { let adhd_struggles: [String] }
}

extension AppModel {
    /// Build the export JSON. nil if the store isn't ready.
    func exportBundleData() -> Data? {
        guard let db else { return nil }
        let bundle = ExportBundle(
            exportedAt: Self.isoNow(),
            user: .init(email: currentEmail, displayName: currentUserName),
            tasks: (try? taskRepo?.all()) ?? [],
            sessions: (try? Repository<Session>(db, orderColumn: "completedAt").all()) ?? [],
            cal_blocks: (try? Repository<CalBlock>(db, orderColumn: "date").all()) ?? [],
            reason_logs: (try? Repository<ReasonLog>(db, orderColumn: "at").all()) ?? [],
            captures: (try? Repository<Capture>(db, orderColumn: "at").all()) ?? [],
            life_areas: (try? Repository<LifeArea>(db, orderColumn: "sortOrder").all()) ?? [],
            tags: (try? Repository<TagRow>(db, orderColumn: "sortOrder").all()) ?? [],
            collections: (try? Repository<ItemCollection>(db, orderColumn: "sortOrder").all()) ?? [],
            calendar_connections: (try? Repository<CalendarConnection>(db, orderColumn: "connectedAt").all()) ?? [],
            preferences: .init(adhd_struggles: UserDefaults.standard.stringArray(forKey: "unstuck.adhdStruggles") ?? []))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(bundle)
    }

    /// Write the export to a temp .json file and return its URL (for the share
    /// sheet). nil on failure.
    func makeExportFile() -> URL? {
        guard let data = exportBundleData() else { return nil }
        let day = String(Self.isoNow().prefix(10))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unstuck-backup-\(day).json")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
