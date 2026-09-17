// Unified sharing v1 §2 "One place for people" — the pure half of Settings →
// People's "Waiting to join": the row label per kind (ONE vocabulary) and the
// composition that lists every invite I sent exactly once alongside the
// roster, before and after the `my_pending_invites` RPC exists.

import XCTest
@testable import UnstuckCore

final class PendingInvitesTests: XCTestCase {

    private func member(_ id: String, status: String, email: String? = nil, code: String? = nil,
                        name: String? = nil, uid: String? = nil) -> CircleMember {
        CircleMember(id: id, relationshipLabel: nil, level: "view", status: status, inviteCode: code,
                     memberUserId: uid, memberName: name, createdAt: "2026-09-17T09:00:00Z", inviteeEmail: email)
    }

    private func task(_ id: String = "ti-1", name: String? = "Draft the deck", access: String? = "partner") -> PendingInvite {
        PendingInvite(kind: .task, inviteId: id, itemId: "t-1", itemName: name, email: "a@b.com", access: access)
    }

    private func list(_ id: String = "col-1:a@b.com", name: String? = "Groceries", access: String? = "editor") -> PendingInvite {
        PendingInvite(kind: .collection, inviteId: id, itemId: "col-1", itemName: name, email: "a@b.com", access: access)
    }

    // MARK: row labels — "<task name> · can edit", "<list name> · can view", "your people"

    func testTaskLabelsSpeakTheOneVocabulary() {
        XCTAssertEqual(pendingInviteLabel(task(access: "partner")), "Draft the deck · can edit")
        XCTAssertEqual(pendingInviteLabel(task(access: "view")), "Draft the deck · can view")
        XCTAssertEqual(pendingInviteLabel(task(access: "assign")), "Draft the deck · handed over")
        XCTAssertEqual(pendingInviteLabel(task(access: "Partner")), "Draft the deck · can edit", "grade is case-insensitive")
    }

    func testCollectionLabelsMapTheRoles() {
        XCTAssertEqual(pendingInviteLabel(list(access: "editor")), "Groceries · can edit")
        XCTAssertEqual(pendingInviteLabel(list(access: "viewer")), "Groceries · can view")
    }

    func testCircleLabelIsYourPeopleWhateverTheRowCarries() {
        XCTAssertEqual(pendingInviteLabel(PendingInvite(kind: .circle, inviteId: "tc-1", email: "a@b.com")), "your people")
        XCTAssertEqual(pendingInviteLabel(PendingInvite(kind: .circle, inviteId: "tc-1", itemName: "x", email: "a@b.com", access: "view")),
                       "your people")
    }

    func testMissingFieldsDegradeInsteadOfInventing() {
        XCTAssertEqual(pendingInviteLabel(task(name: nil)), "a task · can edit", "no title → the noun")
        XCTAssertEqual(pendingInviteLabel(task(name: "  ", access: nil)), "a task", "blank title + no grade")
        XCTAssertEqual(pendingInviteLabel(task(access: "future")), "Draft the deck", "an unknown grade drops the suffix")
        XCTAssertEqual(pendingInviteLabel(list(name: nil, access: nil)), "a list")
        XCTAssertEqual(pendingInviteLabel(list(access: "owner")), "Groceries")
    }

    func testTheRowIdIsKindScoped() {
        XCTAssertEqual(task("x").id, "task:x")
        XCTAssertNotEqual(task("x").id, PendingInvite(kind: .circle, inviteId: "x", email: "").id)
        XCTAssertEqual(PendingInviteKind.allCases.map(\.rawValue), ["task", "collection", "circle"], "the RPC's kind strings")
    }

    // MARK: composition — each invite once, the roster whole

    func testACircleInviteTheRPCReportsIsListedOnceUnderWaiting() {
        let circle = [
            member("c1", status: "active", name: "Maya", uid: "u1"),
            member("c2", status: "invited", email: "p@x.com", code: "code2"),
        ]
        let pending = [PendingInvite(kind: .circle, inviteId: "c2", email: "p@x.com", createdAt: "1")]
        let s = composePeopleSections(circle: circle, pending: pending)
        XCTAssertEqual(s.roster.map(\.id), ["c1"], "the pending roster row moved under Waiting to join")
        XCTAssertEqual(s.waiting.map(\.id), ["circle:c2"])
        XCTAssertEqual(s.waiting[0].inviteCode, "code2", "Copy link survives the move")
    }

    func testACircleInviteMatchesByAddressWhenTheIdsDiffer() {
        let circle = [member("row-9", status: "invited", email: "P@X.com", code: "k")]
        let pending = [PendingInvite(kind: .circle, inviteId: "other-id", email: "p@x.com")]
        let s = composePeopleSections(circle: circle, pending: pending)
        XCTAssertTrue(s.roster.isEmpty)
        XCTAssertEqual(s.waiting.count, 1)
        XCTAssertEqual(s.waiting[0].inviteCode, "k")
    }

    func testLinkOnlyAndUnreportedPendingRowsStayInTheRoster() {
        let circle = [
            member("c1", status: "active", name: "Maya", uid: "u1"),
            member("link", status: "invited", code: "lnk"),                 // no address → never in the RPC
            member("mail", status: "invited", email: "q@x.com", code: "m"),
        ]
        // A server without the RPC: the transport answers [] — nothing moves.
        let none = composePeopleSections(circle: circle, pending: [])
        XCTAssertEqual(none.roster.map(\.id), ["c1", "link", "mail"])
        XCTAssertTrue(none.waiting.isEmpty)
        // The RPC reports a task invite only: the roster is untouched, the task row waits.
        let t = composePeopleSections(circle: circle, pending: [task()])
        XCTAssertEqual(t.roster.map(\.id), ["c1", "link", "mail"])
        XCTAssertEqual(t.waiting.map(\.id), ["task:ti-1"])
    }

    func testRPCOrderIsKeptAndDuplicatesCollapseToTheFirst() {
        let pending = [task(), list(access: "viewer"), PendingInvite(kind: .circle, inviteId: "c9", email: "a@b.com"), task()]
        let s = composePeopleSections(circle: [], pending: pending)
        XCTAssertEqual(s.waiting.map(\.id), ["task:ti-1", "collection:col-1:a@b.com", "circle:c9"])
    }

    func testAnActiveMemberIsNeverDroppedEvenWhenAnIdOrAddressCollides() {
        let circle = [member("c1", status: "active", email: "p@x.com", name: "Maya", uid: "u1")]
        let s = composePeopleSections(circle: circle, pending: [PendingInvite(kind: .circle, inviteId: "c1", email: "p@x.com")])
        XCTAssertEqual(s.roster.map(\.id), ["c1"], "only INVITED roster rows are replaced")
        XCTAssertEqual(s.waiting.count, 1)
    }

    func testAWaitingCircleRowWithNoAddressBorrowsTheRosters() {
        let circle = [member("c2", status: "invited", email: "p@x.com", code: "k")]
        let s = composePeopleSections(circle: circle, pending: [PendingInvite(kind: .circle, inviteId: "c2", email: "")])
        XCTAssertEqual(s.waiting[0].email, "p@x.com")
        XCTAssertTrue(s.roster.isEmpty)
    }
}
