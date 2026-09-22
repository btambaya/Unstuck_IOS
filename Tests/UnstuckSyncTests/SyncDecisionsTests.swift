import XCTest
import Foundation
import Supabase
import UnstuckCore
@testable import UnstuckSync

final class SyncDecisionsTests: XCTestCase {

    func testSignedInWipesOnlyIfUserChanged() {
        // same-user re-auth must NOT wipe (would drop pending offline edits + live session)
        XCTAssertFalse(SyncDecision.shouldWipeCache(event: .signedIn, prevUserId: "u1", currentUserId: "u1"))
        XCTAssertTrue(SyncDecision.shouldWipeCache(event: .signedIn, prevUserId: nil, currentUserId: "u1"))
        XCTAssertTrue(SyncDecision.shouldWipeCache(event: .signedIn, prevUserId: "u1", currentUserId: "u2"))
    }

    func testInitialSessionWipesOnlyIfUserChanged() {
        XCTAssertFalse(SyncDecision.shouldWipeCache(event: .initialSession, prevUserId: "u1", currentUserId: "u1"))
        XCTAssertTrue(SyncDecision.shouldWipeCache(event: .initialSession, prevUserId: "u1", currentUserId: "u2"))
        XCTAssertTrue(SyncDecision.shouldWipeCache(event: .initialSession, prevUserId: nil, currentUserId: "u1"))
    }

    func testUserUpdatedNeverWipes() {
        XCTAssertFalse(SyncDecision.shouldWipeCache(event: .userUpdated, prevUserId: "u1", currentUserId: "u2"))
    }

    func testMergePreservesLocalExternalBlocks() {
        let remote = [
            CalBlock(id: "r1", taskId: "t1", taskName: "Task", startTime: "09:00", durationMinutes: 25, date: "2026-05-21", kind: .task),
        ]
        let localExternal = [
            CalBlock(id: "g_abc", taskId: nil, taskName: "Meeting", startTime: "10:00", durationMinutes: 30, date: "2026-05-21", externalEventId: "abc", kind: .external),
        ]
        let merged = SyncDecision.mergeHydratedCalBlocks(remote: remote, localExternal: localExternal)
        XCTAssertEqual(Set(merged.map(\.id)), ["r1", "g_abc"])
    }

    func testMergeDropsLocalNonExternalAndRemoteWinsOnClash() {
        let remote = [CalBlock(id: "x", taskId: "t1", taskName: "Server", startTime: "09:00", durationMinutes: 25, date: "2026-05-21", kind: .task)]
        // A local row with the same id but stale; and a local NON-external row that must be dropped.
        let local = [
            CalBlock(id: "x", taskId: "t1", taskName: "StaleLocal", startTime: "08:00", durationMinutes: 10, date: "2026-05-21", externalEventId: "e", kind: .external),
            CalBlock(id: "localTask", taskId: "t2", taskName: "LocalOnlyTask", startTime: "11:00", durationMinutes: 25, date: "2026-05-21", kind: .task),
        ]
        let merged = SyncDecision.mergeHydratedCalBlocks(remote: remote, localExternal: local)
        XCTAssertEqual(Set(merged.map(\.id)), ["x"])                       // localTask dropped (not external); g_/external 'x' overwritten by remote
        XCTAssertEqual(merged.first { $0.id == "x" }?.taskName, "Server")  // remote wins
    }
}


// MARK: - outbox failure classification (the CRITICAL poison-cap fix)

private struct FakeRejection: Error, ServerRejectionClassifiable { var isServerRejection: Bool { true } }
private struct FakeTransientClassified: Error, ServerRejectionClassifiable { var isServerRejection: Bool { false } }
private struct Unknown: Error {}

final class FlushFailureClassificationTests: XCTestCase {
    func testNetworkAndUnknownErrorsAreTransient() {
        for code in [URLError.notConnectedToInternet, .networkConnectionLost, .timedOut,
                     .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .badServerResponse] {
            XCTAssertEqual(SyncDecision.classifyFlushFailure(URLError(code)), .transient, "\(code)")
        }
        XCTAssertEqual(SyncDecision.classifyFlushFailure(Unknown()), .transient)
        XCTAssertEqual(SyncDecision.classifyFlushFailure(FakeTransientClassified()), .transient)
    }

    func testCancellationIsNotAFailure() {
        XCTAssertEqual(SyncDecision.classifyFlushFailure(CancellationError()), .cancelled)
        XCTAssertEqual(SyncDecision.classifyFlushFailure(URLError(.cancelled)), .cancelled)
    }

    func testOnlyDefiniteServerRejectionsCount() {
        XCTAssertEqual(SyncDecision.classifyFlushFailure(FakeRejection()), .rejected)
    }

    func testPostgrestErrorCodesClassifyBySQLState() {
        func pg(_ code: String?) -> SyncDecision.FlushFailure {
            SyncDecision.classifyFlushFailure(PostgrestError(detail: nil, hint: nil, code: code, message: "x"))
        }
        // Integrity / data / unknown-column / PL-pgSQL raise: the server refused these bytes.
        for code in ["23503", "23505", "23514", "22P02", "42703", "42501", "P0001", "PGRST204", "PGRST102"] {
            XCTAssertEqual(pg(code), .rejected, code)
        }
        // Connection / resources / JWT / serialisation retry / no code: try again later.
        for code in ["08006", "53300", "57014", "40001", "PGRST301", "PGRST000", "", nil] {
            XCTAssertEqual(pg(code), .transient, code ?? "nil")
        }
    }

    func testHTTPStatusesClassifyByClass() {
        func http(_ status: Int) -> SyncDecision.FlushFailure {
            let resp = HTTPURLResponse(url: URL(string: "https://x.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return SyncDecision.classifyFlushFailure(HTTPError(data: Data(), response: resp))
        }
        for status in [400, 404, 409, 422] { XCTAssertEqual(http(status), .rejected, "\(status)") }
        for status in [401, 403, 408, 425, 429, 500, 502, 503, 504] { XCTAssertEqual(http(status), .transient, "\(status)") }
    }
}

// MARK: - skew-safe prune decision + 3-way merge + pending-row hydrate merge

final class PruneAndMergeDecisionTests: XCTestCase {
    func testBaseAwareDecisionComparesServerClockWithServerClock() {
        // Server hasn't moved since the base → keep, whatever the device clock said.
        XCTAssertEqual(SyncDecision.staleTaskOpDecision(serverUpdatedAtMs: 1_000, baseUpdatedAtMs: 1_000, opUpdatedAtMs: 500), .keep)
        XCTAssertEqual(SyncDecision.staleTaskOpDecision(serverUpdatedAtMs: 1_000.5, baseUpdatedAtMs: 1_000, opUpdatedAtMs: 500), .keep)
        // Server moved → a conflict to merge, NEVER a drop.
        XCTAssertEqual(SyncDecision.staleTaskOpDecision(serverUpdatedAtMs: 5_000, baseUpdatedAtMs: 1_000, opUpdatedAtMs: 900_000), .conflict)
    }

    func testLegacyDecisionToleratesClockSkewBeforePruning() {
        let margin = SyncDecision.clockSkewMarginMs
        XCTAssertEqual(SyncDecision.staleTaskOpDecision(serverUpdatedAtMs: 10_000 + margin, baseUpdatedAtMs: nil, opUpdatedAtMs: 10_000), .keep)
        XCTAssertEqual(SyncDecision.staleTaskOpDecision(serverUpdatedAtMs: 10_000 + margin + 1, baseUpdatedAtMs: nil, opUpdatedAtMs: 10_000), .prune)
        XCTAssertEqual(SyncDecision.staleTaskOpDecision(serverUpdatedAtMs: 10_000, baseUpdatedAtMs: nil, opUpdatedAtMs: nil), .keep)
    }

    func testThreeWayMergeTakesLocalChangesOverAnUnchangedServerField() throws {
        let base = #"{"id":"t","name":"old","done":false,"tags":["a"],"updated_at":"1"}"#.data(using: .utf8)!
        let op = #"{"id":"t","name":"new","done":false,"tags":["a"],"updated_at":"2"}"#.data(using: .utf8)!
        let server = #"{"id":"t","name":"old","done":true,"tags":["a","b"],"updated_at":"3","extra":1}"#.data(using: .utf8)!
        let merged = try XCTUnwrap(SyncDecision.threeWayMergeRow(op: op, base: base, server: server))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "new", "local edit kept")
        XCTAssertEqual(obj["done"] as? Bool, true, "server change kept")
        XCTAssertEqual(obj["tags"] as? [String], ["a", "b"], "untouched-by-op field follows the server")
        XCTAssertEqual(obj["updated_at"] as? String, "2", "ignored keys take the op's value")
        XCTAssertEqual(obj["extra"] as? Int, 1, "server-only keys survive")
        XCTAssertNil(SyncDecision.threeWayMergeRow(op: Data("[]".utf8), base: base, server: server))
    }

    private func t(_ id: String, _ name: String, at: String) -> TaskItem {
        TaskItem(id: id, name: name, estimateMin: 25, createdAt: at, updatedAt: at)
    }

    func testMergeHydratedRowsKeepsPendingLocalRowsAndResolvesCollisions() {
        let remote = [t("a", "server-a", at: "2026-05-21T10:00:00.000Z"), t("b", "server-b", at: "2026-05-21T10:00:00.000Z")]
        let local = [t("a", "local-a", at: "2026-05-21T11:00:00.000Z"),      // pending, newer
                     t("c", "local-c", at: "2026-05-21T09:00:00.000Z"),      // pending, offline-created
                     t("d", "stale-d", at: "2026-05-21T09:00:00.000Z")]      // not pending → dropped (server-canonical)
        let out = SyncDecision.mergeHydratedRows(remote: remote, local: local, pendingIds: ["a", "c"]) {
            SyncDecision.newerWins($0, $1, updatedAt: \.updatedAt)
        }
        XCTAssertEqual(out.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(out.first { $0.id == "a" }?.name, "local-a")
        XCTAssertEqual(SyncDecision.mergeHydratedRows(remote: remote, local: local, pendingIds: []) { l, _ in l }.map(\.id), ["a", "b"])
    }

    func testResolvePendingTaskTrustsLocalWhileServerHasNotMovedPastTheBase() {
        let local = t("a", "local", at: "2026-05-21T09:57:00.000Z")     // slow device clock
        let remote = t("a", "server", at: "2026-05-21T10:00:00.000Z")
        XCTAssertEqual(SyncDecision.resolvePendingTask(local: local, remote: remote, baseUpdatedAt: "2026-05-21T10:00:00.000Z").name, "local")
        XCTAssertEqual(SyncDecision.resolvePendingTask(local: local, remote: remote, baseUpdatedAt: "2026-05-21T09:00:00.000Z").name, "server",
                       "server moved past the base → LWW → server")
        XCTAssertEqual(SyncDecision.resolvePendingTask(local: local, remote: remote, baseUpdatedAt: nil).name, "server", "no base → LWW")
    }
}

// MARK: - the voice dial's fresh token (audit 2026-09-22, C14/C15)

/// A call answered on the lock screen of an app suspended overnight dialled the
/// voice proxy with last night's token (the SDK refreshes only while ACTIVE) and
/// the proxy's 401 hung it up; a token with minutes left outlived the session
/// and the proxy cut it as "daily voice limit reached". `resolveFreshToken`
/// refreshes both, and `firstWithin` bounds the wait without sitting out a
/// refresh that ignores cancellation.
final class FreshAccessTokenTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _current = 0
        private var _refresh = 0
        func current() { lock.withLock { _current += 1 } }
        func refresh() { lock.withLock { _refresh += 1 } }
        var currentCount: Int { lock.withLock { _current } }
        var refreshCount: Int { lock.withLock { _refresh } }
    }
    private struct Boom: Error {}

    private let now: TimeInterval = 1_000_000
    private let minValidity: TimeInterval = 16 * 60

    private func resolve(left: TimeInterval?, force: Bool = false, calls: Calls,
                         topUp: TimeInterval = 5,
                         refresh: @escaping @Sendable () async throws -> String = { "refreshed" }) async -> String? {
        let now = self.now
        return await AuthService.resolveFreshToken(
            minValidity: minValidity, forceRefresh: force, topUpDeadline: topUp,
            now: { now },
            current: {
                calls.current()
                guard let left else { throw Boom() }
                return ("stored", now + left)
            },
            refresh: { calls.refresh(); return try await refresh() })
    }

    func testATokenThatOutlivesTheSessionIsUsedAsItIs() async {
        let calls = Calls()
        let t = await resolve(left: 3600, calls: calls)
        XCTAssertEqual(t, "stored")
        XCTAssertEqual(calls.refreshCount, 0)
    }

    func testATokenThatWouldExpireMidSessionIsRefreshedFirst() async {
        let calls = Calls()
        let t = await resolve(left: 600, calls: calls)
        XCTAssertEqual(t, "refreshed")
        XCTAssertEqual(calls.refreshCount, 1)
    }

    func testAFailedTopUpFallsBackToTheStillValidToken() async {
        let calls = Calls()
        let t = await resolve(left: 600, calls: calls, refresh: { throw Boom() })
        XCTAssertEqual(t, "stored", "still valid — auth.session refreshes anything inside its 30 s margin")
        XCTAssertEqual(calls.refreshCount, 1)
    }

    func testAStalledTopUpDoesNotHoldTheDial() async {
        let calls = Calls()
        let started = Date()
        let t = await resolve(left: 600, calls: calls, topUp: 0.1, refresh: {
            try await Task.sleep(nanoseconds: 3_000_000_000); return "late"
        })
        XCTAssertEqual(t, "stored")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testAForcedRefreshNeverHandsBackTheStoredToken() async {
        let calls = Calls()
        let t = await resolve(left: 3600, force: true, calls: calls)
        XCTAssertEqual(t, "refreshed")
        XCTAssertEqual(calls.refreshCount, 1)
        XCTAssertEqual(calls.currentCount, 0, "the stored token is the one the server refused")

        let failed = Calls()
        let none = await resolve(left: 3600, force: true, calls: failed, refresh: { throw Boom() })
        XCTAssertNil(none)
        XCTAssertEqual(failed.currentCount, 0)
    }

    func testNoReadableSessionIsNilWithoutARefresh() async {
        let calls = Calls()
        let t = await resolve(left: nil, calls: calls)
        XCTAssertNil(t)
        XCTAssertEqual(calls.refreshCount, 0)
    }

    func testFirstWithinGivesUpOnAStalledOperation() async {
        let started = Date()
        let v: String? = await AuthService.firstWithin(0.1) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return "late"
        }
        XCTAssertNil(v)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the stalled refresh is not awaited")
    }

    func testFirstWithinReturnsAPromptAnswer() async {
        let started = Date()
        let v: String? = await AuthService.firstWithin(5) { "tok" }
        XCTAssertEqual(v, "tok")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }
}
