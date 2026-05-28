// Device-local live focus session (mirrors the web `unstuck-session`
// localStorage record). Single-row table; NOT synced.

import Foundation
import GRDB
import UnstuckCore

public struct LiveSessionStore: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    private static let slot = "current"

    public func get() throws -> LiveSession? {
        try db.writer.read { db in
            guard let payload = try String.fetchOne(
                db, sql: "SELECT payload FROM live_session WHERE slot = ?", arguments: [Self.slot]),
                let data = payload.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(LiveSession.self, from: data)
        }
    }

    public func set(_ live: LiveSession?) throws {
        try db.writer.write { db in
            if let live {
                let json = String(data: try JSONEncoder().encode(live), encoding: .utf8)
                try db.execute(
                    sql: """
                    INSERT INTO live_session(slot, payload) VALUES(?, ?)
                    ON CONFLICT(slot) DO UPDATE SET payload = excluded.payload
                    """,
                    arguments: [Self.slot, json])
            } else {
                try db.execute(sql: "DELETE FROM live_session WHERE slot = ?", arguments: [Self.slot])
            }
        }
    }
}
