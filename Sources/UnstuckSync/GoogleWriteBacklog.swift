// GoogleWriteBacklog — the Google Calendar write-backs that have not reached
// Google yet (audit 2026-09-22, C24 / lens-silent#9).
//
// Every Google call for a cal_block runs on the app's one serial worker, and
// that queue lives in memory. A delete that failed (offline, a 5xx, a kill
// before its turn) was simply lost: its block is gone, so nothing ever tried
// again, the event stayed in the user's Google Calendar, and the next pull —
// which knows an event is ours only while a local task block carries its id —
// imported it as an undeletable "meeting" with the task's name. A push that
// failed the same way (scheduling offline) left the block without its event
// until the user happened to edit it again.
//
// So a delete of a pushed event is recorded BEFORE it is queued and cleared
// once Google confirms it; a push is recorded when it fails and cleared once
// one goes through (or there is nothing left to push). The app queues them
// again after every sync, and the pull treats a recorded delete's event id as
// ours, so it is never imported meanwhile.
//
// Per user, persisted in UserDefaults — ids only, never a task name — and
// capped (the oldest entries go first).

import Foundation

/// A pushed event whose block is gone and whose Google delete has not been
/// confirmed yet.
public struct PendingGoogleDelete: Codable, Sendable, Equatable {
    public let blockId: String
    public let eventId: String
    /// The connection the block was stamped with (nil = a legacy row).
    public let connectionId: String?

    public init(blockId: String, eventId: String, connectionId: String?) {
        self.blockId = blockId
        self.eventId = eventId
        self.connectionId = connectionId
    }
}

public final class GoogleWriteBacklog: @unchecked Sendable {
    private struct Entries: Codable {
        var deletes: [PendingGoogleDelete] = []
        var pushes: [String] = []
    }

    /// Enough for a long offline stretch (a series edit is ~55 rows); past
    /// it the oldest entry goes, as the in-memory queue lost everything.
    static let cap = 500

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let currentUser: @Sendable () -> String?
    private var cache: [String: Entries] = [:]

    /// `defaults: nil` keeps the backlog in memory only (tests, UI-test boot).
    public init(defaults: UserDefaults?, currentUser: @escaping @Sendable () -> String?) {
        self.defaults = defaults
        self.currentUser = currentUser
    }

    // MARK: deletes

    public func recordDelete(_ d: PendingGoogleDelete) {
        mutate { e in
            e.deletes.removeAll { $0.eventId == d.eventId }
            e.deletes.append(d)
            if e.deletes.count > Self.cap { e.deletes.removeFirst(e.deletes.count - Self.cap) }
        }
    }

    /// Google confirmed the delete (or the event is in use again).
    public func clearDelete(eventId: String) {
        mutate { e in e.deletes.removeAll { $0.eventId == eventId } }
    }

    public func deletes() -> [PendingGoogleDelete] { read().deletes }

    /// The event ids a pull must treat as ours.
    public func pendingDeleteEventIds() -> Set<String> { Set(read().deletes.map(\.eventId)) }

    // MARK: pushes

    public func recordPush(blockId: String) {
        mutate { e in
            guard !e.pushes.contains(blockId) else { return }
            e.pushes.append(blockId)
            if e.pushes.count > Self.cap { e.pushes.removeFirst(e.pushes.count - Self.cap) }
        }
    }

    public func clearPush(blockId: String) {
        mutate { e in e.pushes.removeAll { $0 == blockId } }
    }

    public func pushes() -> [String] { read().pushes }

    // MARK: storage

    private func key(_ uid: String) -> String { "unstuck.googleBacklog.\(uid)" }

    private func load(_ uid: String) -> Entries {
        if let hit = cache[uid] { return hit }
        let stored = defaults?.data(forKey: key(uid)).flatMap { try? JSONDecoder().decode(Entries.self, from: $0) }
        let entries = stored ?? Entries()
        cache[uid] = entries
        return entries
    }

    private func read() -> Entries {
        guard let uid = currentUser() else { return Entries() }
        return lock.withLock { load(uid) }
    }

    private func mutate(_ change: (inout Entries) -> Void) {
        guard let uid = currentUser() else { return }
        lock.withLock {
            var entries = load(uid)
            change(&entries)
            cache[uid] = entries
            if let data = try? JSONEncoder().encode(entries) { defaults?.set(data, forKey: key(uid)) }
        }
    }
}
