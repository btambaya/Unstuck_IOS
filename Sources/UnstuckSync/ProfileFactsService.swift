// ProfileFactsService — the app-facing API for the assistant's memory
// (port of the store half of lib/assistant/profile.ts). Local GRDB is the
// always-on source of truth for the UI (synchronous reads + writes, so a
// "Noted: … — Undo" receipt can show the stored fact immediately); the
// server `profile_facts` table syncs through the outbox (push), the
// Hydrator (pull + merge) and the RealtimeMirror (live). Every fact is
// visible + deletable in Settings — nothing is stored silently.
//
// Rules (refine-in-place, injection filter, style detection) are pure and
// live in UnstuckCore.ProfileFactsLogic; this type only sequences them
// against the store.

import Foundation
import GRDB
import UnstuckCore
import UnstuckData

public struct ProfileFactsService: Sendable {
    private let repo: ProfileFactsRepository
    private let write: WriteThrough?
    private let now: @Sendable () -> String

    /// - Parameters:
    ///   - write: the outbox write-through; nil runs local-only (the XCUITest
    ///     demo boot, previews) exactly like the web before migration 050.
    ///   - now: ISO-8601 instant source (injectable for tests).
    public init(db: AppDatabase, write: WriteThrough?, now: @escaping @Sendable () -> String = ProfileFactsService.isoNow) {
        self.repo = ProfileFactsRepository(db)
        self.write = write
        self.now = now
    }

    /// UTC ISO-8601 with millisecond precision — the same shape the web's
    /// `new Date().toISOString()` writes into `created_at` / `updated_at`.
    public static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    // MARK: - Reads

    /// The active facts, most recently updated first.
    public func all() -> [ProfileFact] {
        (try? repo.all(activeOnly: true)) ?? []
    }

    /// Live stream of the active facts for SwiftUI surfaces.
    public func observeAll() -> AsyncValueObservation<[ProfileFact]> {
        repo.observeValues(activeOnly: true)
    }

    /// The name they asked to be called, if any (beats the account name).
    public func preferredName() -> String? { ProfileFactsLogic.preferredName(all()) }

    /// True when they've asked not to be addressed by name.
    public func noNamePreference() -> Bool { ProfileFactsLogic.noNamePreference(all()) }

    /// The `context.profile` block for the model (≤15 lines, newest first).
    public func contextLines() -> [String] { ProfileFactsLogic.contextLines(all()) }

    // MARK: - Writes

    /// Add — or refine in place — a fact (web `saveProfileFact`). Returns the
    /// stored fact, or nil when the text is empty or, for MODEL-written
    /// sources (chat / derived), reads like an instruction — or when the
    /// local write failed. Callers that must tell those apart (the assistant's
    /// `save_profile_fact` reports a filter rejection and a store failure
    /// differently) use `store(…)`, which throws the reason.
    @discardableResult
    public func save(category: ProfileFactCategory, fact: String, source: ProfileFactSource,
                     whenIso: String? = nil) -> ProfileFact? {
        try? store(category: category, fact: fact, source: source, whenIso: whenIso)
    }

    /// `save`, with the failure reason: `.empty` / `.instructionLike` are
    /// rejections of the TEXT (nothing to retry), `.storeFailed` is the local
    /// GRDB write failing (worth a retry). The local write is synchronous; the
    /// server push is enqueued behind it.
    public func store(category: ProfileFactCategory, fact: String, source: ProfileFactSource,
                      whenIso: String? = nil) throws(ProfileFactSaveError) -> ProfileFact {
        guard let text = ProfileFactsLogic.prepareFact(fact) else { throw .empty }
        if ProfileFactsLogic.guardsAgainstInjection(source), ProfileFactsLogic.isInstructionLike(text) { throw .instructionLike }
        let when = ProfileFactsLogic.validWhenIso(whenIso)
        let nowISO = now()
        let existing = all()
        let stored: ProfileFact
        if let match = ProfileFactsLogic.refine(existing: existing, category: category, fact: text) {
            var next = match
            next.fact = text
            next.source = source
            if let when { next.whenIso = when }
            next.updatedAt = nowISO
            stored = next
        } else {
            stored = ProfileFact(id: newUUID(), category: category, fact: text, source: source,
                                 whenIso: when, active: true, createdAt: nowISO, updatedAt: nowISO)
        }
        do { try repo.upsert(stored) } catch { throw .storeFailed }
        push(id: stored.id, nowISO: nowISO)
        return stored
    }

    /// Persist a deterministically-detected style preference ("don't use my
    /// name" / "call me X") as the web does — a `preference` fact from the
    /// `chat` source.
    @discardableResult
    public func saveStylePreference(_ pref: StylePreference) -> ProfileFact? {
        save(category: pref.category, fact: pref.fact, source: .chat)
    }

    /// Forget one fact (web `removeProfileFact`): a soft delete — the row
    /// becomes a tombstone here and on the server so no device's cache can
    /// resurrect it. False when there is no active fact with that id.
    @discardableResult
    public func remove(id: String) -> Bool {
        let nowISO = now()
        guard (try? repo.softRemove(id: id, nowISO: nowISO)) == true else { return false }
        push(id: id, nowISO: nowISO)
        return true
    }

    /// Forget everything (web `clearProfileFacts`): soft-deletes every active
    /// fact so the tombstones propagate. NOT the sign-out wipe — see wipeLocal.
    public func clear() {
        for f in all() { remove(id: f.id) }
    }

    /// Sign-out / user-switch: drop every local row (tombstones included)
    /// without touching the server. Queued pushes keep their own payloads, so
    /// the pre-sign-out outbox drain still delivers them.
    public func wipeLocal() {
        try? repo.clear()
    }

    private func push(id: String, nowISO: String) {
        guard let write else { return }
        Task { try? await write.pushProfileFact(id: id, nowISO: nowISO) }
    }
}

/// Why a profile-fact save didn't store anything (see `ProfileFactsService.store`).
public enum ProfileFactSaveError: Error, Equatable, Sendable {
    /// Blank after trimming — nothing to remember.
    case empty
    /// A MODEL-written save that reads like an instruction (the injection filter).
    case instructionLike
    /// The local write failed (or no store exists) — transient, worth a retry.
    case storeFailed
}

/// The one way a `profile_facts` row is queued for the server, shared by the
/// write-through (saves / forgets) and the Hydrator (local-only rows found
/// on pull). Cancels the row's older queued upserts first so the outbox
/// always carries ONE op per fact — the latest state.
enum ProfileFactPush {
    static func enqueue(_ f: ProfileFact, box: OutboxStore, nowISO: String) throws {
        let payload = try Self.payload(f)
        try box.cancelPendingUpserts(table: "profile_facts", rowId: f.id)
        try box.enqueue(table: "profile_facts", rowId: f.id, kind: .upsert, payload: payload, nowISO: nowISO)
    }

    /// Same, inside an open write transaction (the hydrate merge commits its
    /// local-only pushes together with the rows they describe).
    static func enqueue(_ f: ProfileFact, in db: Database, nowISO: String) throws {
        let payload = try Self.payload(f)
        try OutboxStore.cancelPendingUpserts(in: db, table: "profile_facts", rowId: f.id)
        try OutboxStore.enqueue(in: db, table: "profile_facts", rowId: f.id, kind: .upsert, payload: payload, nowISO: nowISO)
    }

    private static func payload(_ f: ProfileFact) throws -> String {
        String(data: try JSONEncoder().encode(ProfileFactRow(f)), encoding: .utf8) ?? "{}"
    }
}
