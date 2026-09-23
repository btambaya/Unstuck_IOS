// InsertMirrorGate — rule G of the deterministic occurrence ids (audit
// 2026-09-22 C21, stage 2; deterministic-occurrence-ids.md §3 c-bis).
//
// A minted occurrence is written with insert-if-absent. If another device
// already has that id, the server ignores this device's insert and keeps its
// own row. Pushing this device's copy to Google before knowing that would
// create a second Google event, and the stamp that follows (a whole-row upsert
// of the row with the new event id) would overwrite the other device's row —
// hazard c again, through the back door. So:
//  • while a row has an unresolved insert-family op (queued in the outbox, or
//    being sent by the flusher), no Google push for that row goes out; the
//    push only records "mirror wanted";
//  • once the insert resolves as inserted or retimed, the wanted mirror runs
//    ONCE, from the fresh local row;
//  • an ignored insert is never mirrored (the next pull brings the server's
//    row, which carries its own mapping).
//
// The flusher brackets every insert-family send with `begin` / `resolve`, and
// `resolve` runs only after the op is markDone'd. So from the moment the op is
// queued until `resolve`, either the outbox holds it or `begin` has marked it:
// a push request can never slip through the gap between the two. "Wanted" is
// in memory only: an app restart loses it, and the block then gets its event
// on its next edit (the spec's accepted residual).
//
// A confirmed push can find its row MISSING: the realtime DELETE echo of this
// device's own delete of the row's earlier incarnation ("Never" then "Daily",
// hazard d) is applied unconditionally and can land after the re-mint, just
// before the INSERT echo brings the row back. The push then waits for the row
// (`awaitRow`): the realtime INSERT/UPDATE (`rowLanded`) or the next
// successful cal_blocks pull (`sweepLandedRows`) releases it through
// `onAwaitedRowLanded`, so the owner's "every minted day is mirrored" holds.

import Foundation
import GRDB
import UnstuckCore
import UnstuckData

public final class InsertMirrorGate: @unchecked Sendable {
    private let lock = NSLock()
    private let db: AppDatabase
    private let table: String
    /// Rows the flusher is sending an insert-family op for right now.
    private var inFlight: Set<String> = []
    /// Rows whose Google push was deferred until their insert resolves.
    private var wanted: Set<String> = []
    /// Confirmed mints whose push found no local row (see the header).
    private var awaitingRow: Set<String> = []
    private var awaitedRowLanded: (@Sendable (String) -> Void)?

    public init(db: AppDatabase, table: String = "cal_blocks") {
        self.db = db
        self.table = table
    }

    /// The flusher is about to send an insert-family op for `rowId`.
    public func begin(rowId: String) {
        lock.withLock { _ = inFlight.insert(rowId) }
    }

    /// The send failed (transient, rejected, malformed): the op is still
    /// queued, so the outbox keeps the row unresolved.
    public func abandon(rowId: String) {
        lock.withLock { _ = inFlight.remove(rowId) }
    }

    /// The op resolved and has been markDone'd. Returns true iff a push was
    /// deferred for this row AND the outcome confirms the insert — the caller
    /// then mirrors it once, from the fresh local row. The wanted mark is
    /// consumed either way (an ignored insert is never mirrored).
    @discardableResult
    public func resolve(rowId: String, outcome: InsertOutcome) -> Bool {
        lock.withLock {
            inFlight.remove(rowId)
            let wasWanted = wanted.remove(rowId) != nil
            return wasWanted && outcome.isConfirmed
        }
    }

    /// A Google push of `rowId`: true = push now; false = the row's insert is
    /// unresolved, so the push is deferred ("mirror wanted" recorded).
    public func requestMirror(rowId: String) -> Bool {
        lock.withLock {
            guard unresolvedLocked(rowId) else { return true }
            wanted.insert(rowId)
            return false
        }
    }

    /// A MINT is about to be written and wants its push once the insert
    /// resolves. Recorded BEFORE the op is queued, so a flush that resolves
    /// the insert before the writer gets back to ask can't slip past the gate
    /// (it finds the mark and consumes it). Returns true when the mark is new
    /// — the caller undoes it with `forget` if nothing was written.
    @discardableResult
    public func expectMirror(rowId: String) -> Bool {
        lock.withLock { wanted.insert(rowId).inserted }
    }

    /// True while an insert-family op for `rowId` is queued or being sent.
    public func isUnresolved(rowId: String) -> Bool {
        lock.withLock { unresolvedLocked(rowId) }
    }

    /// The row was deleted (its queued insert cancelled with it): nothing is
    /// left to mirror.
    public func forget(rowId: String) {
        lock.withLock {
            wanted.remove(rowId)
            awaitingRow.remove(rowId)
        }
    }

    /// Where a push that waited for its row goes once the row is back.
    public func setOnAwaitedRowLanded(_ hook: (@Sendable (String) -> Void)?) {
        lock.withLock { awaitedRowLanded = hook }
    }

    /// A CONFIRMED insert's push found no local row. True = the row is back
    /// already (push now); false = the push waits for `rowLanded` or
    /// `sweepLandedRows`. Marked before the store is read, so a row that lands
    /// between the caller's read and this call is never missed.
    public func awaitRow(rowId: String) -> Bool {
        lock.withLock {
            awaitingRow.insert(rowId)
            guard rowExistsLocked(rowId) else { return false }
            awaitingRow.remove(rowId)
            return true
        }
    }

    /// A cal_blocks row was just written from the server (a realtime INSERT or
    /// UPDATE). Written BEFORE this is called, so with `awaitRow`'s
    /// mark-then-read either side sees the other.
    public func rowLanded(rowId: String) {
        let hook: (@Sendable (String) -> Void)? = lock.withLock {
            awaitingRow.remove(rowId) != nil ? awaitedRowLanded : nil
        }
        hook?(rowId)
    }

    /// A cal_blocks pull succeeded: release every awaited row it brought back.
    public func sweepLandedRows() {
        let (landed, hook): ([String], (@Sendable (String) -> Void)?) = lock.withLock {
            guard !awaitingRow.isEmpty else { return ([], nil) }
            let back = awaitingRow.filter { rowExistsLocked($0) }
            awaitingRow.subtract(back)
            return (Array(back), awaitedRowLanded)
        }
        guard let hook else { return }
        for id in landed { hook(id) }
    }

    /// Test seam: is a confirmed push waiting for this row to come back?
    public func isAwaitingRow(rowId: String) -> Bool {
        lock.withLock { awaitingRow.contains(rowId) }
    }

    /// Test seam: is a mirror waiting on this row's insert?
    public func isMirrorWanted(rowId: String) -> Bool {
        lock.withLock { wanted.contains(rowId) }
    }

    private func rowExistsLocked(_ rowId: String) -> Bool {
        ((try? db.writer.read { try CalBlock.fetchOne($0, key: rowId) }) ?? nil) != nil
    }

    private func unresolvedLocked(_ rowId: String) -> Bool {
        if inFlight.contains(rowId) { return true }
        // A failed read counts as unresolved: deferring a push is recoverable
        // (the next edit pushes), a push over another device's row is not.
        return (try? db.writer.read { try OutboxStore.hasInsertFamilyOp(in: $0, table: table, rowId: rowId) }) ?? true
    }
}

extension RealtimeMirror {
    /// Rule H's `retimed` answer, applied like a realtime echo of that UPDATE
    /// (deterministic-occurrence-ids.md §3c): the server row — the other
    /// device's occurrence, now at this device's time, with ITS Google mapping
    /// — replaces the local copy at once, so nothing mirrors the stale one.
    /// Skipped while the row still has a pending op of its own (a newer local
    /// edit, or a delete): that op is the newer intent and flushes over it.
    /// Returns true when the row was written.
    @discardableResult
    static func applyResolvedCalBlock(_ serverRow: Data, db: AppDatabase) -> Bool {
        guard let row = try? JSONDecoder().decode(CalBlockRow.self, from: serverRow) else { return false }
        let block = row.model()
        return (try? db.writer.write { conn -> Bool in
            let pending = try OutboxStore.pending(in: conn).contains { $0.tableName == "cal_blocks" && $0.rowId == block.id }
            guard !pending else { return false }
            try block.upsert(conn)
            return true
        }) ?? false
    }
}
