// Unified sharing v1 §2 "One place for people" — the `my_pending_invites()`
// / `cancel_pending_invite(p_kind, p_id)` transport on CircleClient, decoded
// DEFENSIVELY (the RPCs land separately, so the build must work before and
// after they exist). No network: pure decoders over representative bodies +
// the exact param keys the migration signature takes.

import XCTest
import UnstuckCore
@testable import UnstuckSync

final class PendingInvitesClientTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: my_pending_invites → [PendingInvite]

    func testDecodesTheContractRowsForAllThreeKindsInOrder() {
        let rows = CircleClient.decodePendingInvites(data("""
        [
          {"kind":"task","id":"ti-1","itemId":"t-1","itemName":"Draft the deck","email":"new@x.com","access":"partner","createdAt":"2026-09-17T10:00:00Z"},
          {"kind":"collection","id":"col-1:a@b.com","itemId":"col-1","itemName":"Groceries","email":"a@b.com","access":"viewer","createdAt":"2026-09-17T09:00:00Z"},
          {"kind":"circle","id":"tc-1","itemId":null,"itemName":null,"email":"p@x.com","access":null,"createdAt":"2026-09-17T08:00:00Z"}
        ]
        """))
        XCTAssertEqual(rows.map(\.id), ["task:ti-1", "collection:col-1:a@b.com", "circle:tc-1"], "RPC order (createdAt desc) is kept")
        XCTAssertEqual(rows[0], PendingInvite(kind: .task, inviteId: "ti-1", itemId: "t-1", itemName: "Draft the deck",
                                              email: "new@x.com", access: "partner", createdAt: "2026-09-17T10:00:00Z"))
        XCTAssertEqual(rows[1], PendingInvite(kind: .collection, inviteId: "col-1:a@b.com", itemId: "col-1", itemName: "Groceries",
                                              email: "a@b.com", access: "viewer", createdAt: "2026-09-17T09:00:00Z"))
        XCTAssertEqual(rows[2], PendingInvite(kind: .circle, inviteId: "tc-1", email: "p@x.com", createdAt: "2026-09-17T08:00:00Z"))
        XCTAssertNil(rows[2].inviteCode, "the join code is the roster's to add, never the RPC's")
    }

    func testUnknownKindsAreIgnoredWithoutSinkingTheList() {
        let rows = CircleClient.decodePendingInvites(data("""
        [{"kind":"team","id":"x","email":"a@b.com"},{"kind":"task","id":"ti-2","email":"a@b.com"},{"kind":"","id":"y","email":"c"}]
        """))
        XCTAssertEqual(rows.map(\.id), ["task:ti-2"])
        // Kind is trimmed + case-insensitive.
        XCTAssertEqual(CircleClient.decodePendingInvites(data(#"[{"kind":" Circle ","id":"tc","email":"e"}]"#)).map(\.kind), [.circle])
    }

    func testMissingFieldsAreTolerated() {
        let rows = CircleClient.decodePendingInvites(data("""
        [{"kind":"task","id":"ti-2","email":"x@y.com"},{"kind":"circle","id":7},{"kind":"collection","id":"c","itemName":"","access":"","email":" a@b.com "}]
        """))
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows[0].itemName)
        XCTAssertNil(rows[0].access)
        XCTAssertNil(rows[0].createdAt)
        XCTAssertEqual(rows[1].inviteId, "7", "a numeric id is read as text")
        XCTAssertEqual(rows[1].email, "", "no address → empty, not a dropped row")
        XCTAssertNil(rows[2].itemName, "empty strings read as absent")
        XCTAssertNil(rows[2].access)
        XCTAssertEqual(rows[2].email, "a@b.com", "trimmed")
    }

    func testRowsWithoutAnIdOrMalformedElementsAreDroppedNotFatal() {
        let rows = CircleClient.decodePendingInvites(data("""
        [{"kind":"task","email":"no id"},"garbage",42,{"kind":"task","id":"","email":"blank id"},{"kind":"task","id":"ok","email":"e@x.com"}]
        """))
        XCTAssertEqual(rows.map(\.id), ["task:ok"])
    }

    func testANullElementDoesNotSinkTheList() {
        let rows = CircleClient.decodePendingInvites(data(#"[null,{"kind":"task","id":"ok","email":"e@x.com"}]"#))
        XCTAssertEqual(rows.map(\.id), ["task:ok"])
    }

    func testEmptyGarbageAndNonArrayBodiesAreEmpty() {
        for body in ["", "null", "{}", "garbage", "[]", "true", #"{"kind":"task","id":"not-an-array"}"#] {
            XCTAssertEqual(CircleClient.decodePendingInvites(data(body)), [], "body: \(body)")
        }
    }

    func testSnakeCaseTwinsAreAccepted() {
        let rows = CircleClient.decodePendingInvites(data("""
        [{"kind":"task","id":"1","item_id":"t","item_name":"Deck","invitee_email":"e@x.com","level":"view","created_at":"c"},
         {"kind":"collection","id":"2","item_id":"col","item_name":"Groceries","email":"f@x.com","role":"viewer"}]
        """))
        XCTAssertEqual(rows[0], PendingInvite(kind: .task, inviteId: "1", itemId: "t", itemName: "Deck", email: "e@x.com", access: "view", createdAt: "c"))
        XCTAssertEqual(rows[1].access, "viewer")
        XCTAssertEqual(rows[1].itemId, "col")
        // The contract's camelCase key wins when both are present.
        let both = CircleClient.decodePendingInvites(data(#"[{"kind":"task","id":"1","itemName":"New","item_name":"Old","email":"e"}]"#))
        XCTAssertEqual(both[0].itemName, "New")
    }

    // MARK: cancel_pending_invite → Bool

    func testCancelResultReadsPostgRESTsScalarBoolean() {
        XCTAssertTrue(CircleClient.decodeCancelPendingInvite(data("true")))
        XCTAssertTrue(CircleClient.decodeCancelPendingInvite(data(" true\n")))
        XCTAssertFalse(CircleClient.decodeCancelPendingInvite(data("false")))
    }

    func testCancelResultToleratesAReshapedFunction() {
        XCTAssertTrue(CircleClient.decodeCancelPendingInvite(data("[true]")))
        XCTAssertFalse(CircleClient.decodeCancelPendingInvite(data("[false]")))
        XCTAssertTrue(CircleClient.decodeCancelPendingInvite(data(#"{"ok":true}"#)))
        XCTAssertTrue(CircleClient.decodeCancelPendingInvite(data(#"{"cancel_pending_invite":true}"#)))
        XCTAssertFalse(CircleClient.decodeCancelPendingInvite(data(#"{"ok":false}"#)))
    }

    func testCancelResultNeverPretends() {
        for body in ["", "null", "garbage", "1", "[]", "{}", #"{"error":"not_found"}"#] {
            XCTAssertFalse(CircleClient.decodeCancelPendingInvite(data(body)), "body: \(body)")
        }
    }

    func testCancelParamsUseTheMigrationsKeys() throws {
        let obj = try JSONDecoder().decode([String: AnyCodableValue].self,
                                           from: JSONEncoder().encode(CancelPendingInviteParams(p_kind: "task", p_id: "ti-1")))
        XCTAssertEqual(obj["p_kind"]?.stringValue, "task")
        XCTAssertEqual(obj["p_id"]?.stringValue, "ti-1")
        XCTAssertEqual(obj.count, 2, "exactly the two parameters the signature takes")
        XCTAssertEqual(PendingInviteKind.allCases.map(\.rawValue), ["task", "collection", "circle"], "p_kind values")
    }
}
