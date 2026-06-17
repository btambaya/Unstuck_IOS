// Calendar block controls + Google disconnect — the AppModel surface behind the
// Calendar block-edit sheet and the connected-state sync bar. 1:1 with the
// Android AppViewModel.resizeBlock / unschedule / disconnectCalendar.
//
// These mirror Android's block-edit affordances (resize 15–360, unschedule) and
// the destructive disconnect (which purges the connection row + its external
// blocks locally so the bar flips back to "Connect" immediately — the Android
// SyncCoordinator.disconnectCalendar behavior, replicated here since the iOS
// coordinator exposes no equivalent and this extension may only add methods).

import Foundation
import UnstuckCore
import UnstuckData

extension AppModel {

    // MARK: - block edit (CalBlockEditSheet)

    /// Resize a block to a new duration (block-edit sheet's Duration chips).
    /// Clamped 15–360 to match Android resizeBlock; routes through saveBlock so
    /// the Google PATCH (end-time change) fires for task blocks.
    func resizeBlock(_ block: CalBlock, durationMinutes: Int) {
        var next = block
        next.durationMinutes = min(360, max(15, durationMinutes))
        saveBlock(next)
    }

    /// Unschedule a block — a local + server delete via the WriteThrough
    /// (which also reconciles Google for our task blocks; external g_ rows are
    /// local-only). 1:1 with Android unschedule(blockId).
    func unschedule(_ blockId: String) {
        guard let write = coordinator?.write else { return }
        // Reconcile Google for a pushed task block before dropping it locally —
        // deleteBlock handles the external-vs-task gating; fall back to a plain
        // delete when the block isn't in the live store (e.g. already gone).
        if let block = (try? db?.fetchAllCalBlocks())?.first(where: { $0.id == blockId }) {
            deleteBlock(block)
        } else {
            Task { try? await write.deleteCalBlock(id: blockId, nowISO: Self.isoNow()) }
        }
    }

    // MARK: - Google disconnect (CalendarSyncBar · destructive)

    /// Disconnect ALL connected Google accounts: revoke each server-side via the
    /// edge function, then purge its local connection row + external blocks so the
    /// sync bar flips back to "Connect" immediately (a later hydrate reaches the
    /// same state). Mirrors Android SyncCoordinator.disconnectCalendar, looped
    /// over every connection.
    func disconnectCalendar() {
        guard let db, let calendar = coordinator?.calendar,
              let write = coordinator?.write else { return }
        let connections = (try? Repository<CalendarConnection>(db, orderColumn: "connectedAt").all()) ?? []
        guard !connections.isEmpty else { return }
        let now = Self.isoNow()
        Task {
            for conn in connections {
                // Best-effort server revoke — a failure still purges locally
                // (the row's gone server-side or will be on the next hydrate).
                try? await calendar.disconnect(connectionId: conn.id)
                // Drop the connection row + its external mirror blocks locally.
                try? db.deleteById(CalendarConnection.self, id: conn.id)
                let external = ((try? db.fetchExternalCalBlocks()) ?? [])
                    .filter { $0.externalConnectionId == conn.id }
                for b in external {
                    try? await write.deleteCalBlock(id: b.id, nowISO: now)
                }
            }
        }
    }
}
