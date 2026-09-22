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

    /// A list is never started or focused: the task blurb read as nonsense
    /// under a collection's name on the Share screen.
    func testTheAccessBlurbSpeaksAboutTheKindOfItem() {
        XCTAssertEqual(ShareAccess.edit.blurb(for: .task), ShareAccess.edit.blurb,
                       "the bare blurb stays the task wording (NewTaskSheet)")
        for access in ShareAccess.allCases {
            let task = access.blurb(for: .task)
            let list = access.blurb(for: .collection)
            XCTAssertNotEqual(task, list)
            XCTAssertFalse(list.contains("focus"), "a list is not focused: \(list)")
            XCTAssertFalse(list.contains("start"), "a list is not started: \(list)")
            XCTAssertTrue(list.contains("list"), "the list blurb should name the list: \(list)")
        }
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
        // Audit 2026-09-22, C10: a block is server-side and says what it did.
        XCTAssertEqual(shareResultLine(.blocked(name: "Maya Chen")),
                       "Blocked Maya — they can't share with you, and nothing is shared between you now.")
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
        // Audit 2026-09-22, C10: a refused Block says the block didn't land.
        XCTAssertEqual(ShareFailure.blockFailed(name: "Maya Chen").message, "Couldn't block Maya — try again.")
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

    // MARK: People card — shared-first order, the collapse rule, Find

    private func person(_ id: String, _ name: String, subtitle: String? = nil, email: String? = nil,
                        shared: Bool = false) -> SharePersonRow {
        SharePersonRow(id: id, userId: "u-\(id)", name: name, subtitle: subtitle, email: email,
                       access: shared ? .edit : nil)
    }

    /// n people named p1…pn, the first `shared` of them (roster order) holding the item.
    private func roster(_ n: Int, shared: Int = 0) -> [SharePersonRow] {
        (1...max(n, 1)).prefix(n).map { i in person("p\(i)", "Person \(i)", shared: i <= shared) }
    }

    private func layout(_ people: [SharePersonRow], pinned: Set<String>? = nil,
                        expanded: Bool = false, query: String = "") -> SharePeopleLayout {
        sharePeopleLayout(people, pinned: pinned ?? Set(people.filter(\.isShared).map(\.id)),
                          expanded: expanded, query: query)
    }

    func testSharedPeopleComeFirstAndRosterOrderIsKeptInsideEachHalf() {
        let people = [person("a", "A"), person("b", "B", shared: true), person("c", "C"),
                      person("d", "D", shared: true), person("e", "E")]
        let ordered = sharePeopleOrdered(people, pinned: ["b", "d"])
        XCTAssertEqual(ordered.map(\.id), ["b", "d", "a", "c", "e"])
        // Pinning is by id at OPEN time — a share made while the sheet is up
        // does not reorder (the row must not move under the finger).
        XCTAssertEqual(sharePeopleOrdered(people, pinned: ["d"]).map(\.id), ["d", "a", "b", "c", "e"])
        XCTAssertEqual(sharePeopleOrdered(people, pinned: []).map(\.id), ["a", "b", "c", "d", "e"])
    }

    func testTheCapNeverHidesSomeoneWhoAlreadyHasIt() {
        let five = layout(roster(7, shared: 5))
        XCTAssertEqual(five.rows.count, 5, "cap lifts to the number pinned")
        XCTAssertTrue(five.rows.allSatisfy(\.isShared))
        XCTAssertEqual(five.hiddenCount, 2)
        XCTAssertTrue(five.canCollapse)
        let six = layout(roster(7, shared: 6))
        XCTAssertEqual(six.rows.count, 7, "cap 6 would hide one row — not worth a disclosure")
        XCTAssertEqual(six.hiddenCount, 0)
        XCTAssertFalse(six.canCollapse)
        let ten = layout(roster(20, shared: 10))
        XCTAssertEqual(ten.rows.count, 10)
        XCTAssertEqual(ten.hiddenCount, 10)
        XCTAssertTrue(ten.rows.allSatisfy(\.isShared))
    }

    func testHidingExactlyOneRowIsNotWorthADisclosure() {
        let four = layout(roster(4))
        XCTAssertEqual(four.rows.count, 4)
        XCTAssertFalse(four.canCollapse)
        XCTAssertEqual(four.hiddenCount, 0)
        let five = layout(roster(5))
        XCTAssertEqual(five.rows.count, 3)
        XCTAssertEqual(five.hiddenCount, 2)
        XCTAssertTrue(five.canCollapse)
    }

    func testCollapseCasesOneThreeFourFiveSevenTwenty() {
        XCTAssertEqual(layout(roster(0)).rows.count, 0)
        XCTAssertFalse(layout(roster(0)).canCollapse)
        XCTAssertEqual(layout(roster(1)).rows.count, 1)
        XCTAssertFalse(layout(roster(1)).canCollapse)
        XCTAssertEqual(layout(roster(3)).rows.count, 3)
        XCTAssertFalse(layout(roster(3)).canCollapse)
        XCTAssertEqual(layout(roster(4)).rows.count, 4)
        XCTAssertFalse(layout(roster(4)).canCollapse)
        let five = layout(roster(5))
        XCTAssertEqual((five.rows.count, five.hiddenCount).0, 3)
        XCTAssertEqual(five.hiddenCount, 2)
        let seven = layout(roster(7))
        XCTAssertEqual(seven.rows.count, 3, "Ahmad's screenshot: seven full rows → three + Show 4 more")
        XCTAssertEqual(seven.hiddenCount, 4)
        XCTAssertTrue(seven.canCollapse)
        let sevenTwoShared = layout([person("a", "A"), person("b", "B"), person("c", "C", shared: true),
                                     person("d", "D"), person("e", "E"), person("f", "F", shared: true),
                                     person("g", "G")])
        XCTAssertEqual(sevenTwoShared.rows.map(\.id), ["c", "f", "a"], "both shared first, then roster order")
        XCTAssertEqual(sevenTwoShared.hiddenCount, 4)
        let twenty = layout(roster(20, shared: 2))
        XCTAssertEqual(twenty.rows.count, 3)
        XCTAssertEqual(twenty.hiddenCount, 17)
        XCTAssertFalse(twenty.showsSearch, "the Find field only appears expanded")
    }

    func testExpandedShowsEverythingAndSearchOnlyAppearsAtTen() {
        let seven = layout(roster(7), expanded: true)
        XCTAssertEqual(seven.rows.count, 7)
        XCTAssertEqual(seven.hiddenCount, 0)
        XCTAssertTrue(seven.canCollapse, "the disclosure stays so it can say Show less")
        XCTAssertFalse(seven.showsSearch)
        let nine = layout(roster(9), expanded: true)
        XCTAssertFalse(nine.showsSearch)
        let ten = layout(roster(10), expanded: true)
        XCTAssertTrue(ten.showsSearch)
        XCTAssertEqual(ten.rows.count, 10)
        let twenty = layout(roster(20), expanded: true)
        XCTAssertTrue(twenty.showsSearch)
        XCTAssertEqual(twenty.rows.count, 20)
        XCTAssertTrue(twenty.canCollapse)
        // A pinned set that happens to cover everyone: nothing to collapse.
        let allShared = layout(roster(4, shared: 4), expanded: true)
        XCTAssertFalse(allShared.canCollapse)
    }

    func testSearchLiftsTheCapAndHidesTheDisclosure() {
        let people = roster(20, shared: 2)
        let searching = layout(people, expanded: true, query: "Person 1")
        XCTAssertTrue(searching.showsSearch)
        XCTAssertFalse(searching.canCollapse)
        XCTAssertEqual(searching.hiddenCount, 0)
        // "Person 1" prefixes Person 1, 10…19 — eleven rows, well past the cap of 3.
        XCTAssertEqual(searching.rows.count, 11)
        XCTAssertEqual(searching.rows.first?.id, "p1", "shared-first order survives a search")
        // Whitespace-only is not a search.
        let blank = layout(people, expanded: true, query: "   ")
        XCTAssertEqual(blank.rows.count, 20)
        XCTAssertTrue(blank.canCollapse)
        // Below the threshold there is no field, so a stray query is ignored.
        let small = layout(roster(5), expanded: true, query: "zzz")
        XCTAssertEqual(small.rows.count, 5)
    }

    func testSearchIsDiacriticAndCaseInsensitiveAndMatchesNameRelationshipAndEmail() {
        let zoe = person("z", "Zoë Müller", subtitle: "Coach", email: "zoe.m@example.com")
        XCTAssertTrue(sharePersonMatches(zoe, query: "zoe"))
        XCTAssertTrue(sharePersonMatches(zoe, query: "ZOË"))
        XCTAssertTrue(sharePersonMatches(zoe, query: "mul"), "diacritics fold: mül → mul")
        XCTAssertTrue(sharePersonMatches(zoe, query: "coa"), "the relationship label")
        XCTAssertTrue(sharePersonMatches(zoe, query: "example"), "the email's domain word")
        XCTAssertTrue(sharePersonMatches(zoe, query: "zoe mul"), "every term must prefix some word")
        XCTAssertFalse(sharePersonMatches(zoe, query: "oë"), "prefix-of-word, not substring")
        XCTAssertFalse(sharePersonMatches(zoe, query: "zoe x"))
        XCTAssertTrue(sharePersonMatches(zoe, query: ""), "an empty query matches everyone")
        let plain = person("p", "Zubair")
        XCTAssertTrue(sharePersonMatches(plain, query: "zu"))
        XCTAssertFalse(sharePersonMatches(plain, query: "coach"), "no subtitle / email → nothing to match")
    }

    func testNoMatchReturnsNoRows() {
        let none = layout(roster(12), expanded: true, query: "nobody")
        XCTAssertTrue(none.rows.isEmpty)
        XCTAssertTrue(none.showsSearch, "the field stays so the query can be corrected")
        XCTAssertFalse(none.canCollapse)
        XCTAssertEqual(none.hiddenCount, 0)
    }

    func testDisclosureTitle() {
        XCTAssertEqual(sharePeopleDisclosureTitle(hiddenCount: 4, expanded: false), "Show 4 more")
        XCTAssertEqual(sharePeopleDisclosureTitle(hiddenCount: 17, expanded: false), "Show 17 more")
        XCTAssertEqual(sharePeopleDisclosureTitle(hiddenCount: 0, expanded: true), "Show less")
        XCTAssertEqual(sharePeopleCollapsedCap, 3)
        XCTAssertEqual(sharePeopleSearchThreshold, 10)
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

    // MARK: - picker split (2026-09-17: never list the whole roster)

    private func person(_ id: String, _ name: String, access: ShareAccess? = nil, handedOver: Bool = false, subtitle: String? = nil, email: String? = nil) -> SharePersonRow {
        SharePersonRow(id: id, userId: id, name: name, subtitle: subtitle, email: email, access: access, handedOver: handedOver, shareId: access == nil ? nil : "s-\(id)")
    }

    func testSplitPutsOnlyPeopleWithAccessInline() {
        let people = [person("a", "Amara"), person("b", "Bola", access: .edit), person("c", "Chidi"), person("d", "Dara", access: .view)] + (0..<6).map { person("x\($0)", "Extra \($0)") }
        let split = sharePeopleSplit(people, pinned: [], handOver: false)
        XCTAssertEqual(split.withAccess.map(\.name), ["Bola", "Dara"], "shared first, in roster order")
        XCTAssertEqual(split.candidates.count, 8)
        XCTAssertFalse(split.candidates.contains { $0.isShared })
    }

    func testSplitKeepsAPinnedRowInlineThroughAReload() {
        let people = [person("a", "Amara"), person("b", "Bola")]
        let split = sharePeopleSplit(people, pinned: ["b"], handOver: false)
        XCTAssertEqual(split.withAccess.map(\.id), ["b"], "the row just tapped stays put until the reload lands")
        XCTAssertEqual(split.candidates.map(\.id), ["a"])
    }

    func testSplitInHandOverModeIsAboutTheHolder() {
        let people = [person("a", "Amara", access: .edit), person("b", "Bola", handedOver: true)]
        let split = sharePeopleSplit(people, pinned: [], handOver: true)
        XCTAssertEqual(split.withAccess.map(\.id), ["b"], "only the holder is inline; an editor is still a candidate to hand it to")
        XCTAssertEqual(split.candidates.map(\.id), ["a"])
    }

    func testCandidatesFilterByNameLabelAndEmailCaseInsensitively() {
        let people = [person("a", "Amara Okafor", subtitle: "Coach"), person("b", "Bola", email: "bola@example.com"), person("c", "Chidi")]
        XCTAssertEqual(sharePeopleCandidates(people, query: "").count, 3)
        XCTAssertEqual(sharePeopleCandidates(people, query: "  ").count, 3, "blank query is no filter")
        XCTAssertEqual(sharePeopleCandidates(people, query: "oka").map(\.id), ["a"])
        XCTAssertEqual(sharePeopleCandidates(people, query: "COACH").map(\.id), ["a"])
        XCTAssertEqual(sharePeopleCandidates(people, query: "example").map(\.id), ["b"])
        XCTAssertTrue(sharePeopleCandidates(people, query: "zzz").isEmpty)
    }
}
