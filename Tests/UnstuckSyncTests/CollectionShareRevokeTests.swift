// Revoking access must report what the SERVER did. `unshare` / `cancelInvite`
// / `leave` used to be `_ = try? await call(…)`, which swallowed a 403 (not the
// owner / no longer a member), a 5xx and an offline failure alike — so the
// share sheet removed the row and told the owner the person was gone while
// they kept full access to the list. Cross-platform review 2026-09-12; the web
// fix is lib/use-collections.ts `invokeShare`.

import XCTest
@testable import UnstuckSync

final class CollectionShareRevokeTests: XCTestCase {

    private func verdict(_ json: String) -> Bool {
        CollectionShareClient.revokeConfirmed(responseJSON: Data(json.utf8))
    }

    /// share-collection's success shapes: `remove` answers ok + the remaining
    /// membership, `leave` answers ok + how many promotions were released.
    func testOnlyAnExplicitOkCountsAsDone() {
        XCTAssertTrue(verdict(#"{"ok":true,"released":0}"#))
        XCTAssertTrue(verdict(#"{"ok":true,"members":[],"pending":[],"isOwner":true}"#))
    }

    /// The refusal shapes: a 403 body (`{"error":"forbidden"}`), a server error,
    /// and an empty/unknown body a gateway may substitute.
    func testEveryRefusalShapeIsAFailure() {
        XCTAssertFalse(verdict(#"{"error":"forbidden"}"#))
        XCTAssertFalse(verdict(#"{"error":"not_found"}"#))
        XCTAssertFalse(verdict(#"{"ok":false}"#))
        XCTAssertFalse(verdict(#"{}"#))
        XCTAssertFalse(verdict("not json at all"))
    }

    /// `ok` alongside an `error` is not a confirmation — the body has to be
    /// clean before the UI is allowed to say access was revoked.
    func testOkWithAnErrorIsStillARefusal() {
        XCTAssertFalse(CollectionShareClient.revokeConfirmed(ok: true, error: "forbidden"))
        XCTAssertTrue(CollectionShareClient.revokeConfirmed(ok: true, error: nil))
        XCTAssertTrue(CollectionShareClient.revokeConfirmed(ok: true, error: ""))
        XCTAssertFalse(CollectionShareClient.revokeConfirmed(ok: nil, error: nil))
    }
}
