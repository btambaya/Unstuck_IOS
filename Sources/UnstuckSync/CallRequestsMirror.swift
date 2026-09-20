// CallRequestsMirror — the LOCAL copy of `call_requests` (calls build-out,
// docs/calls-build-out.md iOS §4), kept the way every other synced table is:
//
//   hydrate   Hydrator.hydrateCallRequests — server-canonical replace on
//             sign-in / full sync (local-only rows newer than every server
//             row survive: they are a booking whose echo the fetch predated);
//   realtime  RealtimeMirror subscribes `call_requests` (published with
//             replica identity full since migration 051) — an OPTIMISATION;
//   catch-up  CatchUpPuller pulls by the `updated_at` cursor (the table has a
//             touch trigger) + id-reconciles the 30-day prune — the
//             CORRECTNESS path (cross-platform-sync-rules).
//
// Writes never go through the outbox: booking / updating / cancelling a call
// is a direct PostgREST write (CallsClient — migration 053's status guard
// owns `status`), and the row the server returns is upserted here at once so
// get_calls, the task editor's "Call me" row and the deep link see it before
// the realtime echo lands. Last-write-wins on `updated_at` for every apply,
// so a stale echo can't clobber a newer row.
//
// Readers: `get_calls` (CallTools via MirrorFirstCallStore), CallMeSection,
// AppModel.openCall. They fall back to the live read ONLY when the mirror is
// empty — offline, the mirror IS the answer.

import Foundation
import GRDB
import UnstuckCore
import UnstuckData

/// The server row IS the local record (columns = the snake_case Codable keys;
/// `notes` / `outcome_notes` stored as JSON text — GRDB's Codable support).
extension CallRequest: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "call_requests"
}

public struct CallRequestsMirror: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Every mirrored row, soonest first.
    public func all() throws -> [CallRequest] {
        try db.writer.read { try CallRequest.order(Column("call_at")).fetchAll($0) }
    }

    /// Rows that still mean "a call is coming" (scheduled / snoozed / calling),
    /// by their EFFECTIVE ring time — what get_calls lists.
    public func live() throws -> [CallRequest] {
        try all().filter(\.isLive)
            .sorted { ($0.effectiveAtDate ?? .distantFuture) < ($1.effectiveAtDate ?? .distantFuture) }
    }

    /// The live call anchored to a task (soonest), if any.
    public func forTask(taskId: String) throws -> CallRequest? {
        try live().first { $0.taskId == taskId }
    }

    public func get(id: String) throws -> CallRequest? {
        try db.writer.read { try CallRequest.fetchOne($0, key: id) }
    }

    /// True when nothing has been mirrored yet (fresh sign-in before the
    /// hydrate, or a user with no calls) — the ONLY case a reader goes to the
    /// network instead.
    public func isEmpty() throws -> Bool {
        try db.writer.read { try CallRequest.fetchCount($0) == 0 }
    }

    /// Write-through after a direct server write: the row the server returned
    /// lands here at once (LWW — a row we already hold that is newer stays).
    public func upsert(_ row: CallRequest) throws {
        try db.writer.write { conn in
            guard Self.incomingWins(row, in: conn) else { return }
            try row.upsert(conn)
        }
    }

    /// Live stream of the live calls (soonest first) for SwiftUI surfaces.
    public func observeLive() -> AsyncValueObservation<[CallRequest]> {
        ValueObservation.tracking { conn in
            try CallRequest.order(Column("call_at")).fetchAll(conn).filter(\.isLive)
                .sorted { ($0.effectiveAtDate ?? .distantFuture) < ($1.effectiveAtDate ?? .distantFuture) }
        }.values(in: db.writer)
    }

    /// Live stream of the live call anchored to a task (nil when none).
    public func observeForTask(taskId: String) -> AsyncValueObservation<CallRequest?> {
        ValueObservation.tracking { conn in
            try CallRequest.filter(Column("task_id") == taskId).order(Column("call_at")).fetchAll(conn)
                .filter(\.isLive).first
        }.values(in: db.writer)
    }

    // MARK: - merge rules (pure over a connection; tested)

    /// Last-write-wins on `updated_at`: apply when there is no local row, when
    /// either stamp is unparseable, or when the incoming row is at-or-after the
    /// local one. A stale realtime echo / catch-up page never rewinds a row.
    public static func incomingWins(_ incoming: CallRequest, in conn: Database) -> Bool {
        guard let local = try? CallRequest.fetchOne(conn, key: incoming.id),
              let localMs = local.updatedAt.flatMap(Time.parseMillis),
              let incomingMs = incoming.updatedAt.flatMap(Time.parseMillis) else { return true }
        return incomingMs >= localMs
    }

    /// The hydrate merge: the server rows, plus any LOCAL-ONLY row stamped
    /// newer than the newest server row — a booking made after the fetch
    /// started, whose echo the fetch predated (the next catch-up / realtime
    /// event confirms it). Everything else the server doesn't have is gone
    /// (the 30-day prune, or a row from another account's session).
    public static func mergeHydrated(remote: [CallRequest], local: [CallRequest]) -> [CallRequest] {
        let remoteIds = Set(remote.map(\.id))
        let newestServer = remote.compactMap { $0.updatedAt.flatMap(Time.parseMillis) }.max()
        let keep = local.filter { row in
            guard !remoteIds.contains(row.id) else { return false }
            guard let ms = row.updatedAt.flatMap(Time.parseMillis) else { return false }
            guard let newestServer else { return true }
            return ms > newestServer
        }
        return remote + keep
    }
}
