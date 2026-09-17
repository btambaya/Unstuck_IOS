// Unified sharing v1 (docs/unified-sharing-spec.md §2 / §4) — the pure half:
// the ONE vocabulary and its mapping onto the two backends, the People
// section composition, the honest result lines, the failure copy, and the
// assistant's email-targeted share request.

import XCTest
@testable import UnstuckCore

final class UnifiedSharingTests: XCTestCase {

    // MARK: vocabulary → backend levels

    func testCanEditAndCanViewMapOntoBothBackends() {
        XCTAssertEqual(ShareAccess.edit.taskLevel, .partner)
        XCTAssertEqual(ShareAccess.view.taskLevel, .view)
        XCTAssertEqual(ShareAccess.edit.collectionRole, "editor")
        XCTAssertEqual(ShareAccess.view.collectionRole, "viewer")
        XCTAssertEqual(ShareAccess.edit.label, "Can edit")
        XCTAssertEqual(ShareAccess.view.label, "Can view")
        // Default is Can edit (the first case).
        XCTAssertEqual(ShareAccess.allCases.first, .edit)
    }

    func testReverseMappingTreatsAssignAsHandedOverNotAGrade() {
        XCTAssertEqual(ShareAccess(taskLevel: .partner), .edit)
        XCTAssertEqual(ShareAccess(taskLevel: .view), .view)
        XCTAssertNil(ShareAccess(taskLevel: .assign), "assign is 'Hand over to…', never a picker grade")
        XCTAssertEqual(ShareAccess(collectionRole: "viewer"), .view)
        XCTAssertEqual(ShareAccess(collectionRole: "editor"), .edit)
        XCTAssertEqual(ShareAccess(collectionRole: "owner-ish"), .edit, "the server coerces unknown roles to editor")
    }

    // MARK: People composition

    private func member(_ id: String, uid: String?, name: String?, status: String = "active", label: String? = nil) -> CircleMember {
        CircleMember(id: id, relationshipLabel: label, level: "view", status: status, inviteCode: nil,
                     memberUserId: uid, memberName: name, createdAt: "2026-09-17T09:00:00Z")
    }

    func testPeopleAreTheActiveConnectionsAnnotatedWithTheirGrant() {
        let circle = [
            member("c1", uid: "u1", name: "Maya Chen", label: "Coach"),
            member("c2", uid: "u2", name: "Zubair"),
            member("c3", uid: nil, name: nil, status: "invited"),   // pending → not a person here
            member("c4", uid: "u4", name: "Gone", status: "revoked"),
        ]
        let grants = [
            ShareExistingGrant(userId: "u1", access: .view, shareId: "s1"),
            ShareExistingGrant(userId: "u2", access: nil, handedOver: true, shareId: "s2"),
        ]
        let rows = composeSharePeople(circle: circle, grants: grants)
        XCTAssertEqual(rows.map(\.userId), ["u1", "u2"])
        XCTAssertEqual(rows[0].name, "Maya Chen")
        XCTAssertEqual(rows[0].subtitle, "Coach")
        XCTAssertEqual(rows[0].access, .view)
        XCTAssertEqual(rows[0].shareId, "s1")
        XCTAssertEqual(rows[0].statusLabel, "Can view")
        XCTAssertTrue(rows[1].handedOver)
        XCTAssertNil(rows[1].access)
        XCTAssertEqual(rows[1].statusLabel, "Handed over")
        XCTAssertTrue(rows[1].isShared)
    }

    func testAnUnsharedConnectionHasNoGrantAndAGrantOutsideTheCircleStillShows() {
        let circle = [member("c1", uid: "u1", name: "Maya")]
        let grants = [ShareExistingGrant(userId: "u9", email: "old@member.com", access: .edit)]
        let rows = composeSharePeople(circle: circle, grants: grants)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0].access)
        XCTAssertFalse(rows[0].isShared)
        XCTAssertNil(rows[0].statusLabel)
        // The legacy member (never a connection) is listed by their email so the
        // owner can still change / revoke what they hold.
        XCTAssertEqual(rows[1].userId, "u9")
        XCTAssertEqual(rows[1].name, "old@member.com")
        XCTAssertEqual(rows[1].access, .edit)
    }

    func testDuplicateRosterRowsForOneUserCollapse() {
        let circle = [member("c1", uid: "u1", name: "Maya"), member("c2", uid: "u1", name: "Maya")]
        XCTAssertEqual(composeSharePeople(circle: circle, grants: []).count, 1)
    }

    // MARK: result lines (§2 "Feedback that is true")

    func testResultLinesPerStatus() {
        XCTAssertEqual(shareResultLine(.shared(name: "Maya Chen", access: .edit)), "Shared with Maya — they can edit.")
        XCTAssertEqual(shareResultLine(.shared(name: "maya@x.com", access: .view)), "Shared with maya — they can view.")
        XCTAssertEqual(shareResultLine(.invited(email: "x@y.com")), "Invite sent to x@y.com — waiting for them to sign up.")
        // A backend that won't say shared-vs-invited (share-collection add) gets
        // a neutral line that is still true.
        XCTAssertEqual(shareResultLine(.accepted(email: "x@y.com")), "Shared with x@y.com — they'll see it as soon as they're in.")
        XCTAssertEqual(shareResultLine(.linkCopied(kind: .task)), "Link copied — whoever opens it gets this task.")
        XCTAssertEqual(shareResultLine(.linkCopied(kind: .collection)), "Link copied — whoever opens it gets this list.")
        XCTAssertEqual(shareResultLine(.handedOver(name: "Maya")), "Handed over to Maya — it's their task now; you keep view.")
        XCTAssertEqual(shareResultLine(.accessChanged(name: "Maya", access: .view)), "Maya can now view.")
        XCTAssertEqual(shareResultLine(.removed(name: "Maya")), "Maya no longer has this.")
        XCTAssertEqual(shareResultLine(.inviteCancelled(email: "x@y.com")), "Invite to x@y.com cancelled.")
    }

    // MARK: failure mapping

    func testServerReasonCodesMapToTheShownCopy() {
        XCTAssertEqual(ShareFailure(reason: "self"), .selfShare)
        XCTAssertEqual(ShareFailure(reason: "self").message, "That's you.")
        XCTAssertEqual(ShareFailure(reason: "blocked").message, "You've blocked that person.")
        XCTAssertEqual(ShareFailure(reason: "rate_limited"), .rateLimited)
        XCTAssertTrue(ShareFailure(reason: "rate_limited").message.contains("Too many"))
        XCTAssertEqual(ShareFailure(reason: "circle_full"), .rateLimited)
        XCTAssertEqual(ShareFailure(reason: "not_found"), .notFound)
        XCTAssertEqual(ShareFailure(reason: "forbidden"), .notAllowed)
        XCTAssertEqual(ShareFailure(reason: "not_your_task"), .notAllowed)
        XCTAssertEqual(ShareFailure(reason: "invalid_email"), .invalidEmail)
        XCTAssertEqual(ShareFailure(reason: "bad_request"), .invalidEmail)
        XCTAssertEqual(ShareFailure(reason: "not_in_circle"), .notConnected)
        XCTAssertEqual(ShareFailure.listNeedsEmail.message, "Lists can't be shared by name yet — enter their email below.")
        XCTAssertEqual(ShareFailure(reason: "not_configured"), .notSignedIn)
        XCTAssertEqual(ShareFailure(reason: nil), .network)
        XCTAssertEqual(ShareFailure(reason: "network").message, "Couldn't share — try again.")
        XCTAssertEqual(ShareFailure(reason: "SELF "), .selfShare, "codes are trimmed + case-folded")
        XCTAssertEqual(ShareFailure(reason: "something_new"), .server("something_new"))
        XCTAssertEqual(ShareFailure(reason: "something_new").message, "Couldn't share — try again.")
    }

    // MARK: helpers

    func testEmailShapeGuard() {
        XCTAssertTrue(isEmailLike("maya@example.com"))
        XCTAssertTrue(isEmailLike("  Maya.Chen+x@sub.example.co  "))
        XCTAssertFalse(isEmailLike("Maya"))
        XCTAssertFalse(isEmailLike("@example.com"))
        XCTAssertFalse(isEmailLike("maya@"))
        XCTAssertFalse(isEmailLike("maya@localhost"))
        XCTAssertFalse(isEmailLike("maya@@x.com"))
        XCTAssertFalse(isEmailLike("maya @x.com"))
        XCTAssertEqual(normalizedShareEmail("  Maya@Example.COM "), "maya@example.com")
    }

    func testShortNameForResultLines() {
        XCTAssertEqual(shareShortName("Maya Chen"), "Maya")
        XCTAssertEqual(shareShortName("maya@x.com"), "maya")
        XCTAssertEqual(shareShortName("   "), "them")
    }

    // MARK: assistant share_task accepts an email

    private func task(_ name: String) -> TaskItem {
        TaskItem(id: name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name, estimateMin: 25,
                 totalFocused: 0, done: false, createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z")
    }

    func testAnEmailPersonStagesAnEmailShareEvenWithAnEmptyCircle() {
        let r = resolveShareRequest(taskName: "Grocery run", person: " Maya@Example.com ", level: "partner",
                                    tasks: [task("Grocery run")], people: [], newId: { "id1" })
        let p = r.pending
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.recipientEmail, "maya@example.com")
        XCTAssertEqual(p?.recipientName, "maya@example.com")
        XCTAssertEqual(p?.recipientUserId, "")
        XCTAssertEqual(p?.level, .partner)
        XCTAssertTrue(r.message.contains("CONFIRM"))
        XCTAssertTrue(r.message.contains("do not claim it is shared"))
        XCTAssertTrue(r.message.contains("invite"), "the model is told what happens for a no-account address")
    }

    func testANameStillResolvesAgainstTheCircleAndCarriesNoEmail() {
        let people = [ShareCandidate(userId: "u1", name: "Maya Chen")]
        let r = resolveShareRequest(taskName: "Grocery run", person: "Maya",
                                    tasks: [task("Grocery run")], people: people, newId: { "id1" })
        XCTAssertEqual(r.pending?.recipientUserId, "u1")
        XCTAssertNil(r.pending?.recipientEmail)
    }
}
