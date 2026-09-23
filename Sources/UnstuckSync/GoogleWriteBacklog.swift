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
// once Google confirms it; a push is recorded when it is queued and cleared
// once one goes through (or there is nothing left to push). The app queues
// them again after every sync, and the pull treats a recorded delete's event
// id as ours, so it is never imported meanwhile.
//
// An INSERT asks Google for an id chosen here, kept until its answer lands on
// the row: an INSERT whose answer never came back (a timeout, a kill
// mid-flight) had created the event anyway, the retry created a second one,
// and the pull imported the first as a "meeting". The retry now asks for the
// same id and the server answers Google's duplicate-id 409 with it (calendar#5).
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

/// An INSERT asked for `eventId` and its answer has not reached the row yet:
/// Google may hold the event.
public struct PendingGoogleInsert: Codable, Sendable, Equatable {
    public let blockId: String
    public let eventId: String
    /// The connection the INSERT was sent on.
    public let connectionId: String

    public init(blockId: String, eventId: String, connectionId: String) {
        self.blockId = blockId
        self.eventId = eventId
        self.connectionId = connectionId
    }
}

public final class GoogleWriteBacklog: @unchecked Sendable {
    private struct Entries: Codable, Equatable {
        var deletes: [PendingGoogleDelete] = []
        var pushes: [String] = []
        var inserts: [PendingGoogleInsert] = []
    }

    /// Enough for a long offline stretch (a series edit is ~55 rows); past
    /// it the oldest entry goes, as the in-memory queue lost everything.
    static let cap = 500

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let currentUser: @Sendable () -> String?
    private let mintEventId: @Sendable () -> String
    private var cache: [String: Entries] = [:]

    /// `defaults: nil` keeps the backlog in memory only (tests, UI-test boot).
    /// `newEventId` mints an INSERT's id (tests pass a predictable one).
    public init(defaults: UserDefaults?, currentUser: @escaping @Sendable () -> String?,
                newEventId: @escaping @Sendable () -> String = GoogleWriteBacklog.newEventId) {
        self.defaults = defaults
        self.currentUser = currentUser
        self.mintEventId = newEventId
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

    public func pendingDeleteEventIds() -> Set<String> { Set(read().deletes.map(\.eventId)) }

    /// The event ids a pull must treat as ours: deletes Google has not
    /// confirmed, and INSERTs whose answer never came back.
    public func unconfirmedEventIds() -> Set<String> {
        let e = read()
        return Set(e.deletes.map(\.eventId)).union(e.inserts.map(\.eventId))
    }

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

    // MARK: inserts

    /// The id this block's INSERT asks Google for: the one an earlier attempt
    /// on the same connection sent (`reused` — its answer never came back, so
    /// Google may have the event), else a fresh one, recorded BEFORE the call
    /// so a kill mid-flight keeps it. Never the block id: Google keeps a
    /// deleted event's id taken, so a re-minted occurrence (stage 2's same id
    /// for the same day) asking for it again would get the deleted event back
    /// as "success". An earlier attempt on another connection becomes a
    /// delete there.
    public func insertEventId(blockId: String, connectionId: String) -> (eventId: String, reused: Bool) {
        var result: (eventId: String, reused: Bool)?
        mutate { e in
            if let i = e.inserts.firstIndex(where: { $0.blockId == blockId }) {
                let earlier = e.inserts[i]
                if earlier.connectionId == connectionId { result = (earlier.eventId, true); return }
                e.inserts.remove(at: i)
                e.deletes.removeAll { $0.eventId == earlier.eventId }
                e.deletes.append(PendingGoogleDelete(blockId: blockId, eventId: earlier.eventId,
                                                     connectionId: earlier.connectionId))
            }
            let fresh = mintEventId()
            result = (fresh, false)
            e.inserts.append(PendingGoogleInsert(blockId: blockId, eventId: fresh, connectionId: connectionId))
            if e.inserts.count > Self.cap { e.inserts.removeFirst(e.inserts.count - Self.cap) }
        }
        return result ?? (mintEventId(), false)   // signed out: nothing kept
    }

    /// The INSERT's answer reached the row (or its event is being dropped).
    public func clearInsert(blockId: String) {
        mutate { e in e.inserts.removeAll { $0.blockId == blockId } }
    }

    /// The block wants no event any more (deleted, skipped, mapped to another
    /// event) while an INSERT for it never answered: returned and forgotten —
    /// the caller deletes its event.
    public func takeInsert(blockId: String) -> PendingGoogleInsert? {
        var taken: PendingGoogleInsert?
        mutate { e in
            guard let i = e.inserts.firstIndex(where: { $0.blockId == blockId }) else { return }
            taken = e.inserts.remove(at: i)
        }
        return taken
    }

    public func inserts() -> [PendingGoogleInsert] { read().inserts }

    /// Google's event ids are base32hex (a–v, 0–9), 5–1024 characters; a
    /// UUID's hex digits are a subset.
    public static func newEventId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

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
            let before = load(uid)
            var entries = before
            change(&entries)
            // Every push is recorded when queued and every delete clears
            // what it may have left: most calls change nothing, and a
            // series edit makes ~55 of each.
            guard entries != before else { return }
            cache[uid] = entries
            if let data = try? JSONEncoder().encode(entries) { defaults?.set(data, forKey: key(uid)) }
        }
    }
}
