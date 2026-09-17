// Unified sharing v1 transport (docs/unified-sharing-spec.md §3.3 / §4): the
// `share-task` edge-fn contract decoded HONESTLY ("shared" vs "invited" vs a
// named refusal), the `share-collection` decoder fix (the old function
// answered `invited: true` on BOTH branches — `status` must win), `link`,
// the People roster's optional `invitee_email`, and the realtime "went
// active" verdict. No network: pure decoders over representative bodies.

import XCTest
import Supabase
import UnstuckCore
@testable import UnstuckSync

final class TaskShareClientTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }
    private func encodedObject(_ value: Encodable) throws -> [String: AnyCodableValue] {
        try JSONDecoder().decode([String: AnyCodableValue].self, from: JSONEncoder().encode(value))
    }

    // MARK: share-task add

    func testAddDecodesSharedAndInvitedHonestly() {
        XCTAssertEqual(TaskShareClient.decodeAdd(data(#"{"ok":true,"status":"shared","userId":"u2","displayName":"Maya Chen"}"#)),
                       .shared(userId: "u2", displayName: "Maya Chen"))
        XCTAssertEqual(TaskShareClient.decodeAdd(data(#"{"ok":true,"status":"invited"}"#)), .invited)
        // Status is case-insensitive; a missing displayName is empty, not a crash.
        XCTAssertEqual(TaskShareClient.decodeAdd(data(#"{"ok":true,"status":"Shared","userId":"u2"}"#)),
                       .shared(userId: "u2", displayName: ""))
    }

    func testAddRefusalsCarryTheServersReason() {
        XCTAssertEqual(TaskShareClient.decodeAdd(data(#"{"ok":false,"reason":"self"}"#)), .failed(reason: "self"))
        XCTAssertEqual(TaskShareClient.decodeAdd(data(#"{"ok":false,"reason":"blocked"}"#)), .failed(reason: "blocked"))
        XCTAssertEqual(TaskShareClient.decodeAdd(data(#"{"error":"rate_limited"}"#)), .failed(reason: "rate_limited"))
        XCTAssertEqual(TaskShareClient.decodeAdd(data(#"{"error":"forbidden"}"#)), .failed(reason: "forbidden"))
    }

    func testAddNeverFabricatesAnOutcome() {
        // No status, no user → not a success. An empty / garbage body → failure.
        XCTAssertEqual(TaskShareClient.decodeAdd(data(#"{"ok":true}"#)), .failed(reason: "bad_response"))
        XCTAssertEqual(TaskShareClient.decodeAdd(data(#"{}"#)), .failed(reason: "bad_response"))
        XCTAssertEqual(TaskShareClient.decodeAdd(data("nope")), .failed(reason: "bad_response"))
        // A 2xx with ok + a resolved user but no status (older function) is a share.
        XCTAssertEqual(TaskShareClient.decodeAdd(data(#"{"ok":true,"userId":"u7"}"#)), .shared(userId: "u7", displayName: ""))
    }

    func testThrownBodiesYieldTheirCodeElseNetwork() {
        XCTAssertEqual(TaskShareClient.failureReason(fromBody: data(#"{"error":"rate_limited"}"#)), "rate_limited")
        XCTAssertEqual(TaskShareClient.failureReason(fromBody: data(#"{"ok":false,"reason":"self"}"#)), "self")
        XCTAssertEqual(TaskShareClient.failureReason(fromBody: data("")), "network")
        XCTAssertEqual(TaskShareClient.failureReason(from: FunctionsError.httpError(code: 429, data: data(#"{"error":"rate_limited"}"#))), "rate_limited")
        XCTAssertEqual(TaskShareClient.failureReason(from: URLError(.notConnectedToInternet)), "network")
    }

    // MARK: share-task list / link

    func testListDecodesMembersAndPendingWithLeastPrivilegeFallbacks() {
        let r = TaskShareClient.decodeList(data("""
        {"members":[{"userId":"u1","displayName":"Maya","level":"partner"},{"userId":"u2","displayName":"Z","level":"future"}],
         "pending":[{"id":"i1","email":"x@y.com","level":"view"},{"id":"i2","email":"a@b.com"}]}
        """))
        XCTAssertEqual(r.members.map(\.userId), ["u1", "u2"])
        XCTAssertEqual(r.members[0].level, .partner)
        XCTAssertEqual(r.members[1].level, .view, "an unknown level degrades to view")
        XCTAssertEqual(r.pending.map(\.email), ["x@y.com", "a@b.com"])
        XCTAssertEqual(r.pending[0].level, .view)
        XCTAssertEqual(r.pending[1].level, .partner, "a pending invite defaults to the spec's default level")
        // Rows missing their key are dropped, not fatal; an empty / bad body is empty.
        XCTAssertEqual(TaskShareClient.decodeList(data(#"{"members":[{"displayName":"no id"}],"pending":[{"id":"i9"}]}"#)), .empty)
        XCTAssertEqual(TaskShareClient.decodeList(data("garbage")), .empty)
    }

    func testLinkDecodesTheUrlOrTheReason() {
        XCTAssertEqual(TaskShareClient.decodeLink(data(#"{"ok":true,"url":"https://unstucknow.io/circle/join?code=abc"}"#)),
                       .ok(url: "https://unstucknow.io/circle/join?code=abc"))
        XCTAssertEqual(TaskShareClient.decodeLink(data(#"{"ok":false,"reason":"forbidden"}"#)), .failed(reason: "forbidden"))
        XCTAssertEqual(TaskShareClient.decodeLink(data(#"{"error":"rate_limited"}"#)), .failed(reason: "rate_limited"))
        XCTAssertEqual(TaskShareClient.decodeLink(data(#"{}"#)), .failed(reason: "bad_response"))
    }

    func testBodiesUseTheContractsCamelCaseKeysAndOmitNils() throws {
        let add = try encodedObject(TaskShareClient.Body(action: "add", taskId: "t1", email: "x@y.com", level: "partner"))
        XCTAssertEqual(Set(add.keys), ["action", "taskId", "email", "level"])
        XCTAssertEqual(add["level"]?.stringValue, "partner")
        let removeUser = try encodedObject(TaskShareClient.Body(action: "remove", taskId: "t1", userId: "u2"))
        XCTAssertEqual(Set(removeUser.keys), ["action", "taskId", "userId"])
        let removeInvite = try encodedObject(TaskShareClient.Body(action: "remove", taskId: "t1", inviteId: "i1"))
        XCTAssertEqual(Set(removeInvite.keys), ["action", "taskId", "inviteId"])
        let link = try encodedObject(TaskShareClient.Body(action: "link", taskId: "t1", level: "view"))
        XCTAssertEqual(Set(link.keys), ["action", "taskId", "level"])
        XCTAssertEqual(Set(try encodedObject(TaskShareClient.Body(action: "list", taskId: "t1")).keys), ["action", "taskId"])
    }

    // MARK: share-collection add — the "always Invited" fix

    func testCollectionAddReadsStatusBeforeTheLegacyInvitedFlag() {
        // The new function: honest status + the legacy flag still present.
        let shared = CollectionShareClient.decodeShareAdd(data(#"{"ok":true,"status":"shared","invited":true,"userId":"u2","members":[{"user_id":"u2","email":"m@x.com","role":"editor"}]}"#))
        XCTAssertEqual(shared.outcome, .ok)
        XCTAssertEqual(shared.memberUserIds, ["u2"])
        let invited = CollectionShareClient.decodeShareAdd(data(#"{"ok":true,"status":"invited","invited":true,"email":"n@x.com"}"#))
        XCTAssertEqual(invited.outcome, .invited)
        // The DEPLOYED uniform shape (no status, no userId, `invited:true` on
        // both branches): the client can't know which → `accepted` (neutral
        // copy), never a fabricated "invited" and never ok.
        XCTAssertEqual(CollectionShareClient.decodeShareAdd(data(#"{"ok":true,"invited":true,"email":"x@y.com","role":"editor"}"#)).outcome, .accepted)
        // …and the field the function answers alongside may be a COUNT — it
        // must not sink the decode.
        let counted = CollectionShareClient.decodeShareAdd(data(#"{"ok":true,"invited":true,"members":2}"#))
        XCTAssertEqual(counted.outcome, .accepted)
        XCTAssertEqual(counted.memberUserIds, [])
        XCTAssertTrue(ShareOutcome.accepted.isSuccess)
        XCTAssertNil(ShareOutcome.accepted.failureReason)
        // ok + a resolved user without status → shared.
        XCTAssertEqual(CollectionShareClient.decodeShareAdd(data(#"{"ok":true,"userId":"u3"}"#)).outcome, .ok)
    }

    func testCollectionAddRefusalsIncludingThrownBodies() {
        XCTAssertEqual(CollectionShareClient.decodeShareAdd(data(#"{"error":"self"}"#)).outcome, .selfError)
        XCTAssertEqual(CollectionShareClient.decodeShareAdd(data(#"{"error":"not_found"}"#)).outcome, .notFound)
        XCTAssertEqual(CollectionShareClient.decodeShareAdd(data(#"{"ok":false,"reason":"blocked"}"#)).outcome, .blocked)
        // A 429 arrives as a thrown httpError whose body names the limiter.
        XCTAssertEqual(CollectionShareClient.decodeShareAdd(data(#"{"error":"rate_limited"}"#), thrown: true).outcome, .rateLimited)
        XCTAssertEqual(CollectionShareClient.decodeShareAdd(data(#"{"error":"forbidden"}"#), thrown: true).outcome, .error)
        // A 400 (no / malformed email — e.g. a by-userId add) is named, so the
        // Share screen can say what to do instead of "try again".
        XCTAssertEqual(CollectionShareClient.decodeShareAdd(data(#"{"error":"bad_request"}"#), thrown: true).outcome, .invalid)
        XCTAssertEqual(ShareOutcome.invalid.failureReason, "bad_request")
        XCTAssertEqual(CollectionShareClient.decodeShareAdd(data(#"{"ok":true,"status":"shared"}"#), thrown: true).outcome, .error,
                       "a thrown call is never a success, whatever the body claims")
        XCTAssertEqual(CollectionShareClient.decodeShareAdd(data("nope")).outcome, .error)
        XCTAssertEqual(ShareOutcome.rateLimited.failureReason, "rate_limited")
        XCTAssertNil(ShareOutcome.ok.failureReason)
    }

    // MARK: circle_list gains invitee_email (optional both ways)

    func testCircleMemberRowDecodesInviteeEmailWhenPresentAndWithoutIt() throws {
        let with = try JSONDecoder().decode(CircleMemberRow.self, from: data("""
        {"id":"c2","relationship_label":null,"level":"view","status":"invited","invite_code":"abc",
         "member_user_id":null,"member_name":null,"created_at":"2026-09-17T10:00:00Z","invitee_email":"x@y.com"}
        """)).model()
        XCTAssertEqual(with.inviteeEmail, "x@y.com")
        let legacy = try JSONDecoder().decode(CircleMemberRow.self, from: data("""
        {"id":"c2","relationship_label":null,"level":"view","status":"invited","invite_code":"abc",
         "member_user_id":null,"member_name":null,"created_at":"2026-09-17T10:00:00Z"}
        """)).model()
        XCTAssertNil(legacy.inviteeEmail, "a pre-065 projection omits the column and still decodes")
        let blank = try JSONDecoder().decode(CircleMemberRow.self, from: data("""
        {"id":"c3","relationship_label":null,"level":"view","status":"invited","invite_code":"def",
         "member_user_id":null,"member_name":null,"created_at":"2026-09-17T10:00:00Z","invitee_email":""}
        """)).model()
        XCTAssertNil(blank.inviteeEmail, "a link-only invite has no address")
    }

    // MARK: circle_redeem carries the granted item (065)

    func testRedeemResultDecodesTheGrantedItemAndStaysBackwardCompatible() throws {
        let dec = JSONDecoder()
        let task = try dec.decode(CircleRedeemResult.self, from: data(#"{"ok":true,"owner_name":"Dana","granted":{"task_id":"t9"}}"#))
        XCTAssertTrue(task.ok)
        XCTAssertEqual(task.ownerName, "Dana")
        XCTAssertEqual(task.grantedTaskId, "t9")
        XCTAssertNil(task.grantedCollectionId)
        XCTAssertTrue(task.grantedItem)
        let list = try dec.decode(CircleRedeemResult.self, from: data(#"{"ok":true,"owner_name":"Dana","granted":{"collection_id":"c1"},"already_connected":true}"#))
        XCTAssertEqual(list.grantedCollectionId, "c1")
        XCTAssertEqual(list.alreadyConnected, true)
        // Pre-065 shapes still decode exactly as before.
        let legacy = try dec.decode(CircleRedeemResult.self, from: data(#"{"ok":true,"owner_name":"Dana"}"#))
        XCTAssertFalse(legacy.grantedItem)
        XCTAssertNil(legacy.alreadyConnected)
        let bad = try dec.decode(CircleRedeemResult.self, from: data(#"{"ok":false,"error":"invalid_or_expired"}"#))
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error, "invalid_or_expired")
        // An empty `granted` object / null is not a grant.
        XCTAssertFalse(try dec.decode(CircleRedeemResult.self, from: data(#"{"ok":true,"granted":{}}"#)).grantedItem)
        XCTAssertFalse(try dec.decode(CircleRedeemResult.self, from: data(#"{"ok":true,"granted":null}"#)).grantedItem)
    }

    // MARK: realtime — "my connection went active"

    func testCircleRowWentActiveVerdict() {
        XCTAssertTrue(CollabRealtime.circleRowWentActive(old: ["status": .string("invited")], new: ["status": .string("active")]))
        XCTAssertTrue(CollabRealtime.circleRowWentActive(old: [:], new: ["status": .string("active")]),
                      "the old record may carry only the PK (default replica identity) — count it")
        XCTAssertFalse(CollabRealtime.circleRowWentActive(old: ["status": .string("active")], new: ["status": .string("active")]),
                       "a relabel of an already-active row is not a join")
        XCTAssertFalse(CollabRealtime.circleRowWentActive(old: [:], new: ["status": .string("invited")]))
        XCTAssertFalse(CollabRealtime.circleRowWentActive(old: [:], new: [:]))
    }

    // MARK: the RPC failure reason the Share screen maps

    func testRpcFailureReasonExtractsPostgrestCodes() {
        let pg = PostgrestError(message: "not_in_circle")
        XCTAssertEqual(CircleClient.rpcFailureReason(pg), "not_in_circle")
        XCTAssertEqual(CircleClient.rpcFailureReason(PostgrestError(message: "ERROR: not_your_task (P0001)")), "not_your_task")
        XCTAssertEqual(CircleClient.rpcFailureReason(URLError(.timedOut)), "network")
        XCTAssertEqual(CircleClient.rpcFailureReason(FunctionsError.httpError(code: 403, data: data(#"{"error":"forbidden"}"#))), "forbidden")
    }
}
