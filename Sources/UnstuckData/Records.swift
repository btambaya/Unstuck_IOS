// GRDB persistence conformances for the UnstuckCore models. Declared
// here (not in UnstuckCore) so UnstuckCore stays free of any GRDB
// dependency. The models are Codable, so GRDB synthesizes row
// encoding/decoding; nested arrays + Codable values (tags, objectives,
// comments, recurrence, selectedCalendarIds, collection items) are stored
// as JSON text, and String-raw enums (priority, kind, tag, action,
// provider) as their raw string. Local column names match the Swift
// property names.

import Foundation
import GRDB
import UnstuckCore

extension TaskItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tasks"
}

extension CalBlock: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "cal_blocks"
}

extension Session: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sessions"
}

extension Capture: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "captures"
}

extension ReasonLog: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "reason_logs"
}

extension ItemCollection: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "collections"
}

extension TagRow: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tags"
}

extension LifeArea: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "life_areas"
}

extension CalendarConnection: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "calendar_connections"
}
