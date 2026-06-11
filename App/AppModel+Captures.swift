// Capture Inbox triage — 1:1 with the Android AppViewModel capture block.
//
// A Capture is a quick thought parked during a focus session (or on the fly).
// The Inbox is where untriaged captures are reviewed and turned into a task,
// archived out of the open inbox, or discarded.
//
//  • promoteCapture — build a standalone task from the capture body. The capture
//    is PRESERVED (never deleted); the screen archives it after promoting, exactly
//    like Android (`vm.promoteCapture(cap); vm.archiveCapture(cap.id)`).
//  • archiveCapture / unarchiveCapture — "Done"/"Restore". Archived ids are
//    DEVICE-LOCAL (UserDefaults Set<String>), NOT a DB column — captures have no
//    `archived` field. Mirrors Android's SettingsStore archivedCaptureIds (which
//    is cleared on sign-out, like dismissed nudges).
//  • discardCapture — delete the capture row (and drop any device-local archived
//    flag so the set doesn't leak ids), matching Android's deleteCapture.

import Foundation
import UnstuckCore
import UnstuckSync

extension AppModel {

    /// UserDefaults key for the device-local archived-capture id set.
    private static let archivedCaptureIdsKey = "unstuck.archivedCaptureIds"

    /// Capture ids the user has archived from the Inbox (triaged without
    /// deleting). Device-local; survives relaunch; cleared on sign-out so a
    /// different account on this device starts clean. The Inbox observes this
    /// (it's a stored property on the @Observable AppModel) so toggling
    /// archive/restore refreshes the open + archived lists immediately.
    var archivedCaptureIds: Set<String> {
        get { archivedCaptureIdsBacking }
        set {
            archivedCaptureIdsBacking = newValue
            UserDefaults.standard.set(Array(newValue), forKey: Self.archivedCaptureIdsKey)
        }
    }

    /// Load the persisted archived-id set into the in-memory backing store.
    /// Call once at startup so a relaunch restores the archived view.
    func loadArchivedCaptureIds() {
        let ids = UserDefaults.standard.stringArray(forKey: Self.archivedCaptureIdsKey) ?? []
        archivedCaptureIdsBacking = Set(ids)
    }

    /// Archive a capture out of the open inbox ("Done"). Device-local only.
    func archiveCapture(_ id: String) {
        archivedCaptureIds.insert(id)
    }

    /// Restore a capture back into the open inbox ("Restore"). Device-local.
    func unarchiveCapture(_ id: String) {
        archivedCaptureIds.remove(id)
    }

    /// Promote a capture into a standalone task. Mirrors the web/Android
    /// capture-actions: the capture is PRESERVED (not deleted), and the new task
    /// is seeded with estimate 25, lifeArea "Work", and tags
    /// ["from-capture", <captureTag>]. The Inbox archives the capture after
    /// calling this (Android parity), so promote itself does not archive.
    @discardableResult
    func promoteCapture(_ capture: Capture) -> TaskItem {
        // One write (estimate 25, lifeArea "Work", tags [from-capture, <tag>]) —
        // 1:1 with Android's promoteCapture; no mutate-then-resave double upsert.
        addTask(name: capture.body, estimateMin: 25, tags: ["from-capture", capture.tag.rawValue],
                lifeArea: "Work")
    }

    /// Discard a capture for good ("Discard"): delete the row + drop any
    /// device-local archived flag so the set doesn't leak ids. Matches Android's
    /// deleteCapture (which also calls unarchiveCapture).
    func discardCapture(_ id: String) {
        guard let write else { return }
        let now = Self.isoNow()
        Task { try? await write.deleteCapture(id: id, nowISO: now) }
        unarchiveCapture(id)
    }
}
