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
import UnstuckSync

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

    // MARK: - Google health (CalendarSyncBar · "Reconnect Google")

    /// True when a connected Google account's refresh token is dead (401 /
    /// invalid_grant on the last pull, or the server's `needs_reauth` flag):
    /// the sync bar should offer "Reconnect Google" (the normal connect flow
    /// re-consents the same account) instead of silently showing stale
    /// meetings. Its events are never deletion-reconciled meanwhile.
    var calendarNeedsReauth: Bool { calendarSyncStatus?.needsReauth ?? false }

    /// The server's last reason (e.g. `invalid_grant`), for the bar's caption.
    var calendarLastError: String? { calendarSyncStatus?.lastError }

    /// After a successful (re)connect: save the connection locally, then pull
    /// (which drops the stale verdict + any back-off first). A connect used to
    /// write nothing locally — calendar_connections is only filled by the full
    /// hydrate — so the bar stayed "Connect" and every block scheduled that
    /// session skipped the Google mirror until relaunch. The seed only lands
    /// when the id isn't stored yet, so a reconnect keeps the stored selection;
    /// the pull then replaces it with the server's own row. False = the first
    /// pull didn't finish (audit 2026-09-22, C18).
    @discardableResult
    func calendarDidConnect(_ response: CalendarClient.ConnectResponse) async -> Bool {
        // First, so a /connections answer read before the server stored this
        // connection can't land after the seed and delete it again.
        await coordinator?.noteLocalConnectionsWrite()
        if let db, ((try? db.fetchById(CalendarConnection.self, id: response.id)) ?? nil) == nil {
            try? db.save(response.localConnection(connectedAt: Self.isoNow()))
        }
        return await pullGoogleCalendar()
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
                // A /connections answer read before the revoke must not put
                // the row back (audit 2026-09-22, C18).
                await self.coordinator?.noteLocalConnectionsWrite()
                let external = ((try? db.fetchExternalCalBlocks()) ?? [])
                    .filter { $0.externalConnectionId == conn.id }
                for b in external {
                    try? await write.deleteCalBlock(id: b.id, nowISO: now)
                }
            }
            await self.coordinator?.resetCalendarStatus()
            self.calendarSyncStatus = nil
            // Re-read the server's post-disconnect list: a pull whose
            // /connections answer landed between the revoke and the local
            // delete can still be importing that account's meetings; with no
            // connection left this pull purges them (audit 2026-09-22, C18).
            await self.coordinator?.pullCalendar()
        }
    }
}
