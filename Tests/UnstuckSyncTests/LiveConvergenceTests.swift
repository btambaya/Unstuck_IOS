// LIVE PROOF — the iOS freshness layer against the REAL production Supabase.
//
// CatchUpConvergenceTests proves the policy against a fake server. This file
// proves the SEAM: that the real PostgREST accepts the queries the catch-up
// builds (a `gte` on a server stamp that carries a `+00:00` offset, an id-only
// page), that RLS returns the rows, and that a gap closes with no relaunch.
//
// OPT-IN — it needs network + credentials:
//   LIVE_SYNC=1 LIVE_URL=… LIVE_KEY=… LIVE_EMAIL=… LIVE_PASSWORD=… swift test --filter LiveConvergenceTests
//
// It never touches the keychain: the auth session is held in memory for the
// duration of the test only. Rows it creates carry a `zzz-verify-` name and are
// deleted again in tearDown.

import XCTest
import Supabase
import Auth
import UnstuckCore
import UnstuckData
@testable import UnstuckSync

/// Session storage that lives and dies with the test — NOT the keychain.
private final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

final class LiveConvergenceTests: XCTestCase {
    private var client: SupabaseClient!
    private var db: AppDatabase!
    private var gateway: SyncGateway!
    private var uid = ""
    private var created: [String] = []

    private var live: Bool { ProcessInfo.processInfo.environment["LIVE_SYNC"] == "1" }
    private func env(_ k: String) -> String { ProcessInfo.processInfo.environment[k] ?? "" }

    override func setUp() async throws {
        try XCTSkipUnless(live, "set LIVE_SYNC=1 (plus LIVE_URL/LIVE_KEY/LIVE_EMAIL/LIVE_PASSWORD) to run")
        client = SupabaseClient(
            supabaseURL: URL(string: env("LIVE_URL"))!,
            supabaseKey: env("LIVE_KEY"),
            options: .init(auth: .init(storage: InMemoryAuthStorage(), autoRefreshToken: false)))
        let session = try await client.auth.signIn(email: env("LIVE_EMAIL"), password: env("LIVE_PASSWORD"))
        uid = session.user.id.uuidString.lowercased()
        db = try AppDatabase.makeInMemory()
        gateway = SyncGateway(client)
    }

    override func tearDown() async throws {
        guard live, client != nil else { return }
        for id in created {
            _ = try? await client.from("tasks").delete().eq("id", value: id).execute()
        }
        created = []
        try? await client.auth.signOut()
    }

    /// Insert a task straight into production, as "another device" would.
    private func insertTask(_ name: String) async throws -> String {
        let id = UUID().uuidString.lowercased()
        created.append(id)
        struct NewTask: Encodable {
            let id: String, user_id: String, name: String
            let estimate_min: Int, total_focused: Int, done: Bool
        }
        _ = try await client.from("tasks")
            .insert(NewTask(id: id, user_id: uid, name: "zzz-verify-" + name,
                            estimate_min: 25, total_focused: 0, done: false))
            .execute()
        return id
    }

    /// THE GAP, against production. Realtime is never subscribed at all — the
    /// harshest version of "the channel delivered nothing".
    func testCatchUpConvergesAgainstProduction() async throws {
        let hydrator = Hydrator(gateway: gateway, db: db)
        let puller = CatchUpPuller(gateway: gateway, db: db,
                                   fullFallback: { table in await hydrator.hydrateFullReplaceTable(table) })
        actor Counter { private(set) var value = 0; func bump() { value += 1 } }
        let fullSyncs = Counter()
        let owner = FreshnessOwner(actions: FreshnessOwner.Actions(
            fullSync: { uid in await fullSyncs.bump(); await hydrator.hydrate(userId: uid) },
            catchUp: { uid, reconcile in await puller.catchUp(userId: uid, reconcileDeletions: reconcile) }))

        // Cold start: the real hydrate off production, then the marks armed.
        await owner.setUser(uid)
        await owner.report(.coldStart)
        await owner.awaitIdle()
        let hydrates = await fullSyncs.value
        XCTAssertEqual(hydrates, 1)
        let before = try db.localIds(table: "tasks").count
        XCTAssertGreaterThan(before, 0, "the demo account has tasks")
        // NB iOS arms the marks on the FIRST catch-up (the cold start is the
        // hydrate alone), so there is deliberately no mark yet here.
        XCTAssertNil(try SyncCursorStore(db).cursor(userId: uid, table: "tasks"))

        // ── the gap: a row appears on the server, nothing is delivered ──────
        let gapId = try await insertTask("written-during-the-gap")
        XCTAssertNil(try db.fetchById(TaskItem.self, id: gapId), "nothing delivered it")

        // The subscription comes back. postgres_changes replays nothing; the
        // catch-up is the only thing that can close this.
        await owner.report(.channelsSubscribed)
        await owner.awaitIdle()

        XCTAssertNotNil(try db.fetchById(TaskItem.self, id: gapId),
                        "the row written during the gap must be here after the catch-up")
        let after = await fullSyncs.value
        XCTAssertEqual(after, hydrates, "converged WITHOUT a second full pull — and without a relaunch")
        let mark = try XCTUnwrap(try SyncCursorStore(db).cursor(userId: uid, table: "tasks"),
                                 "a completed catch-up must leave a mark")
        XCTAssertFalse(mark.isEmpty)

        // …and the NEXT pull is a bounded delta from that mark, not a re-read.
        let quiet = await puller.catchUp(userId: uid, reconcileDeletions: false)
        XCTAssertFalse(quiet.seededTables.contains("tasks"), "the second pull is incremental, not a seed")
        // (A table that is EMPTY on the server never produces a stamp, so it has
        // no mark to arm and is reported as seeding every time — free, because
        // the pull returns nothing.)

        // ── a HARD DELETE during a gap: invisible to a cursor pull ──────────
        _ = try await client.from("tasks").delete().eq("id", value: gapId).execute()
        created.removeAll { $0 == gapId }
        let incremental = await puller.catchUp(userId: uid, reconcileDeletions: false)
        XCTAssertEqual(incremental.idsDropped, 0, "a timestamp cursor cannot see a delete")
        XCTAssertNotNil(try db.fetchById(TaskItem.self, id: gapId))

        let sweep = await puller.catchUp(userId: uid, reconcileDeletions: true)
        XCTAssertGreaterThanOrEqual(sweep.idsDropped, 1, "the id sweep is what sees it")
        XCTAssertNil(try db.fetchById(TaskItem.self, id: gapId), "and the row is gone locally")
    }

    /// The query shape itself: production returns `2026-09-07T11:56:58.473251+00:00`,
    /// and that value has to survive the round trip back into the filter. A `+`
    /// that reaches the query string unencoded is read as a SPACE and PostgREST
    /// answers 22007 — the catch-up would then fail for ever, silently.
    func testTheServerStampRoundTripsIntoTheFilter() async throws {
        let page = try await gateway.fetchPageSince(table: "tasks", column: "updated_at",
                                                    atOrAfter: nil, limit: 1)
        let stamp = try XCTUnwrap(page.first.flatMap { CatchUpPuller.stringField("updated_at", in: $0) })
        XCTAssertTrue(stamp.contains("+00:00") || stamp.hasSuffix("Z"), "stamp shape: \(stamp)")
        // Exactly what the puller does with it next.
        let again = try await gateway.fetchPageSince(table: "tasks", column: "updated_at",
                                                     atOrAfter: stamp, limit: 5)
        XCTAssertFalse(again.isEmpty, "an inclusive re-read must return at least the boundary row")
    }
}
