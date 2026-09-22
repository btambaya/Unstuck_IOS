// Unified sharing v1 §2 "One place for people" — Settings → People's "Waiting
// to join" on the CircleModel over a fake PeopleTransport: the rows come from
// `my_pending_invites` with the label per kind, Cancel calls
// `cancel_pending_invite(kind, id)` and drops the row, a refused cancel is
// honest (and its line clears on the next refresh), a circle invite is never
// listed twice, the roster stays whole on a server without the RPC, the collab
// signals refresh the section, and every Copy link button names its invite.
//
// Audit 2026-09-22: removing a connection re-hydrates the lists and the
// dialog says what removal really does (C11); "Remove and block", the Blocked
// section and Unblock go through the server (C10).

import XCTest
import SwiftUI
import UnstuckCore
import UnstuckSync
@testable import Unstuck

// MARK: - fake transport

@MainActor
private final class FakePeopleTransport: PeopleTransport {
    var circle: [CircleMember] = []
    var pending: [PendingInvite] = []
    var cancelOk = true
    var removeOk = true
    var blockOk = true
    var unblockOk = true
    var blockedList: [BlockedUser] = []

    // Recorded calls.
    var circleLoads = 0
    var pendingLoads = 0
    var cancelled: [(kind: PendingInviteKind, id: String)] = []
    var removed: [String] = []
    var blockedIds: [String] = []
    var unblockedIds: [String] = []
    var blockedLoads = 0

    func listCircle() async -> [CircleMember] { circleLoads += 1; return circle }
    func invite(email: String?) async -> CircleInviteResult { CircleInviteResult(ok: true, emailed: true) }
    func redeem(code: String) async -> CircleRedeemResult { CircleRedeemResult(ok: true) }
    func removeMember(id: String) async -> Bool {
        removed.append(id)
        guard removeOk else { return false }
        circle.removeAll { $0.id == id }
        return true
    }
    func myPendingInvites() async -> [PendingInvite] { pendingLoads += 1; return pending }
    func cancelPendingInvite(kind: PendingInviteKind, id: String) async -> Bool {
        cancelled.append((kind, id))
        guard cancelOk else { return false }
        pending.removeAll { $0.kind == kind && $0.inviteId == id }
        // The server deletes the trusted_circle row for a circle invite, so
        // circle_list() stops returning it too.
        if kind == .circle { circle.removeAll { $0.id == id } }
        return true
    }
    func block(userId: String) async -> Bool {
        blockedIds.append(userId)
        guard blockOk else { return false }
        // block_user severs the connection both ways server-side.
        let name = circle.first { $0.memberUserId == userId }?.memberName ?? "Someone"
        circle.removeAll { $0.memberUserId == userId }
        blockedList.insert(BlockedUser(userId: userId, name: name), at: 0)
        return true
    }
    func blockedUsers() async -> [BlockedUser] { blockedLoads += 1; return blockedList }
    func unblock(userId: String) async -> Bool {
        unblockedIds.append(userId)
        guard unblockOk else { return false }
        blockedList.removeAll { $0.userId == userId }
        return true
    }
}

/// Counts hook calls from a @MainActor closure without capturing a mutable
/// local (Swift 6 treats the hook as Sendable).
private final class Counter: @unchecked Sendable { var n = 0 }

// MARK: - the model

@MainActor
final class PeopleWaitingTests: XCTestCase {
    private var fake: FakePeopleTransport!

    override func setUp() {
        super.setUp()
        fake = FakePeopleTransport()
        fake.circle = [
            CircleMember(id: "c1", relationshipLabel: "Coach", level: "view", status: "active", inviteCode: nil,
                         memberUserId: "u1", memberName: "Maya Chen", createdAt: "2026-09-17T09:00:00Z"),
            CircleMember(id: "c3", relationshipLabel: nil, level: "view", status: "invited", inviteCode: "code3",
                         memberUserId: nil, memberName: nil, createdAt: "2026-09-17T09:02:00Z", inviteeEmail: "p@x.com"),
        ]
        fake.pending = [
            PendingInvite(kind: .task, inviteId: "ti-1", itemId: "t1", itemName: "Draft the deck",
                          email: "new@x.com", access: "partner", createdAt: "2026-09-17T10:00:00Z"),
            PendingInvite(kind: .collection, inviteId: "col1:l@x.com", itemId: "col1", itemName: "Groceries",
                          email: "l@x.com", access: "viewer", createdAt: "2026-09-17T09:30:00Z"),
            PendingInvite(kind: .circle, inviteId: "c3", email: "p@x.com", createdAt: "2026-09-17T09:02:00Z"),
        ]
    }

    private func model() -> CircleModel { CircleModel(transport: fake) }

    // MARK: rows + labels

    func testWaitingListsEveryInviteISentWithItsLabel() async {
        let vm = model()
        await vm.refresh()
        XCTAssertFalse(vm.loading)
        XCTAssertEqual(vm.waiting.map(\.email), ["new@x.com", "l@x.com", "p@x.com"], "RPC order — newest first")
        XCTAssertEqual(vm.waiting.map(pendingInviteLabel), ["Draft the deck · can edit", "Groceries · can view", "your people"])
    }

    func testACircleInviteIsShownOnceUnderWaitingNotInTheRoster() async {
        let vm = model()
        await vm.refresh()
        XCTAssertEqual(vm.roster.map(\.id), ["c1"], "the pending roster row is replaced by the RPC's circle row")
        XCTAssertEqual(vm.members.map(\.id), ["c1", "c3"], "members (the picker source) still carries everything circle_list returned")
        XCTAssertEqual(vm.waiting.filter { $0.kind == .circle }.map(\.inviteId), ["c3"])
        XCTAssertEqual(vm.waiting.last?.inviteCode, "code3", "Copy link survives the move")
        XCTAssertEqual(vm.rosterCount, 1)
        XCTAssertEqual(vm.activeCount, 2, "the web's activeCount still counts the invite")
    }

    func testBeforeTheRPCExistsTheRosterKeepsItsPendingRows() async {
        fake.pending = []   // a server without my_pending_invites → the transport answers []
        let vm = model()
        await vm.refresh()
        XCTAssertEqual(vm.roster.map(\.id), ["c1", "c3"])
        XCTAssertTrue(vm.waiting.isEmpty)
        XCTAssertEqual(vm.rosterCount, 2)
    }

    // MARK: cancel

    func testCancelCallsTheRPCWithTheKindAndIdAndRemovesTheRow() async {
        let vm = model()
        await vm.refresh()
        let ok = await vm.cancelPending(vm.waiting[0])
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.cancelled.count, 1)
        XCTAssertEqual(fake.cancelled[0].kind, .task)
        XCTAssertEqual(fake.cancelled[0].id, "ti-1")
        XCTAssertEqual(vm.waiting.map(\.id), ["collection:col1:l@x.com", "circle:c3"])
        XCTAssertNil(vm.waitingError)
        XCTAssertEqual(fake.pendingLoads, 2, "refreshed after the cancel")
    }

    func testCancellingACollectionAndACircleInviteUseTheirKinds() async {
        let vm = model()
        await vm.refresh()
        await vm.cancelPending(vm.waiting[1])
        await vm.cancelPending(vm.waiting.last!)
        XCTAssertEqual(fake.cancelled.map(\.kind), [.collection, .circle])
        XCTAssertEqual(fake.cancelled.map(\.id), ["col1:l@x.com", "c3"])
        XCTAssertEqual(vm.waiting.map(\.id), ["task:ti-1"])
        XCTAssertEqual(vm.roster.map(\.id), ["c1"], "the cancelled circle invite does not resurface in the roster")
    }

    func testARefusedCancelBringsTheRowBackAndSaysSo() async {
        fake.cancelOk = false
        let vm = model()
        await vm.refresh()
        let ok = await vm.cancelPending(vm.waiting[0])
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.waiting.count, 3, "the server still has it — the refetch shows the truth")
        XCTAssertEqual(vm.waitingError, "Couldn't cancel that invite — try again.")
        // The next successful action clears the line.
        fake.cancelOk = true
        await vm.cancelPending(vm.waiting[0])
        XCTAssertNil(vm.waitingError)
        XCTAssertEqual(vm.waiting.count, 2)
    }

    /// Prior-round finding: the line a refused cancel left stayed under the
    /// section through every later refresh (a collab signal, foreground) until
    /// the next cancel attempt or leaving the screen. A refresh is a fresh
    /// answer now — but the line must still survive the refetch that the
    /// cancel itself performs, or it would never be seen at all.
    func testTheNextRefreshClearsTheRefusedCancelLine() async {
        fake.cancelOk = false
        let vm = model()
        await vm.refresh()
        await vm.cancelPending(vm.waiting[0])
        XCTAssertEqual(vm.waitingError, "Couldn't cancel that invite — try again.",
                       "set AFTER the cancel's own refetch, so it is actually shown")
        await vm.refresh()   // a collab signal / foreground
        XCTAssertNil(vm.waitingError, "a later refresh clears the stale line")
        XCTAssertEqual(vm.waiting.count, 3, "the invite is still there — only the line went")
    }

    func testRemovingARosterRowStillGoesThroughCircleRemove() async {
        let vm = model()
        await vm.refresh()
        await vm.remove(id: "c1")
        XCTAssertEqual(fake.removed, ["c1"])
        XCTAssertTrue(vm.roster.isEmpty)
        XCTAssertEqual(vm.waiting.count, 3, "the invites are untouched")
    }

    // MARK: removal takes the lists too (audit 2026-09-22, C11)

    /// circle_remove now also ends the list memberships between the pair,
    /// both ways (075). The owner's membership channel only carries MY rows,
    /// so the lists are re-read at once — otherwise my own lists keep listing
    /// the person I just removed.
    func testRemovingAConnectionReHydratesTheLists() async {
        let vm = model()
        let calls = Counter()
        vm.onConnectionRemoved = { calls.n += 1 }
        await vm.refresh()
        await vm.remove(id: "c1")   // active, memberUserId u1
        XCTAssertEqual(fake.removed, ["c1"])
        XCTAssertEqual(calls.n, 1)
        XCTAssertTrue(vm.roster.isEmpty)
    }

    func testCancellingAPendingRosterInviteDoesNotReHydrateLists() async {
        fake.pending = []   // c3 stays a real roster row (no Waiting-to-join twin)
        let vm = model()
        let calls = Counter()
        vm.onConnectionRemoved = { calls.n += 1 }
        await vm.refresh()
        XCTAssertEqual(vm.roster.map(\.id), ["c1", "c3"])
        await vm.remove(id: "c3")   // status invited, memberUserId nil
        XCTAssertEqual(fake.removed, ["c3"], "still goes through circle_remove")
        XCTAssertEqual(calls.n, 0, "a pending invite changes no list")
    }

    /// A removal the server didn't accept (offline) must not re-read the
    /// shared state: offline those reads come back [] and would blank
    /// Shared-with-you and the delegation badges.
    func testARefusedRemovalDoesNotReHydrate() async {
        fake.removeOk = false
        let vm = model()
        let calls = Counter()
        vm.onConnectionRemoved = { calls.n += 1 }
        await vm.refresh()
        await vm.remove(id: "c1")
        XCTAssertEqual(fake.removed, ["c1"], "the removal was attempted")
        XCTAssertEqual(calls.n, 0, "nothing was severed, so nothing is re-read")
        XCTAssertEqual(vm.roster.map(\.id), ["c1"], "the refetch shows they're still connected")
    }

    /// The dialog used to promise "will no longer see anything you've shared"
    /// while every shared list stayed shared.
    func testTheRemoveDialogSaysWhatRemovalDoes() {
        let maya = fake.circle[0]
        XCTAssertEqual(removeConnectionMessage(maya),
                       "Maya Chen will no longer see the tasks and lists you've shared with them, and you'll lose access to the ones they shared with you.")
        var unnamed = maya
        unnamed.memberName = nil
        XCTAssertEqual(removeConnectionMessage(unnamed),
                       "They will no longer see the tasks and lists you've shared with them, and you'll lose access to the ones they shared with you.")
        XCTAssertEqual(removeConnectionMessage(fake.circle[1]), "Cancels this pending invite to p@x.com.")
        XCTAssertTrue(removeConnectionMessage(maya).contains("lists"))
        XCTAssertFalse(removeConnectionMessage(maya).contains("anything you've shared"), "the C11 overclaim is gone")
    }

    // MARK: server-side block (audit 2026-09-22, C10)

    func testRefreshLoadsTheBlockedList() async {
        fake.blockedList = [BlockedUser(userId: "u7", name: "Sam", createdAt: "2026-09-22T09:00:00Z")]
        let vm = model()
        await vm.refresh()
        XCTAssertEqual(fake.blockedLoads, 1)
        XCTAssertEqual(vm.blocked.map(\.userId), ["u7"])
    }

    func testRemoveAndBlockBlocksTheMemberServerSide() async {
        let vm = model()
        let calls = Counter()
        vm.onConnectionRemoved = { calls.n += 1 }
        await vm.refresh()
        let ok = await vm.block(vm.roster[0])
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.blockedIds, ["u1"], "block_user takes the member's USER id, not the circle row id")
        XCTAssertTrue(fake.removed.isEmpty, "the block severs the connection itself — no separate circle_remove")
        XCTAssertTrue(vm.roster.isEmpty)
        XCTAssertEqual(vm.blocked.map(\.name), ["Maya Chen"], "the refetch lists them under Blocked")
        XCTAssertEqual(calls.n, 1, "a block also takes the lists + task shares between us — re-read them")
        XCTAssertNil(vm.blockError)
    }

    func testARefusedBlockBringsTheRowBackAndSaysSo() async {
        fake.blockOk = false
        let vm = model()
        let calls = Counter()
        vm.onConnectionRemoved = { calls.n += 1 }
        await vm.refresh()
        let ok = await vm.block(vm.roster[0])
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.roster.map(\.id), ["c1"], "the server still has the connection — the refetch shows it")
        XCTAssertTrue(vm.blocked.isEmpty)
        XCTAssertEqual(vm.blockError, "Couldn't block — try again.")
        XCTAssertEqual(calls.n, 0)
    }

    func testAPendingRowCannotBeBlocked() async {
        fake.pending = []
        let vm = model()
        await vm.refresh()
        let ok = await vm.block(vm.roster[1])   // c3: invited, no user yet
        XCTAssertFalse(ok)
        XCTAssertTrue(fake.blockedIds.isEmpty)
    }

    func testUnblockLiftsTheBlockAndDropsTheRow() async {
        fake.blockedList = [BlockedUser(userId: "u7", name: "Sam")]
        let vm = model()
        await vm.refresh()
        let ok = await vm.unblock(vm.blocked[0])
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.unblockedIds, ["u7"])
        XCTAssertTrue(vm.blocked.isEmpty)

        fake.blockedList = [BlockedUser(userId: "u8", name: "Kai")]
        fake.unblockOk = false
        await vm.refresh()
        let refused = await vm.unblock(vm.blocked[0])
        XCTAssertFalse(refused)
        XCTAssertEqual(vm.blocked.map(\.userId), ["u8"], "a refused unblock keeps the row")
        XCTAssertEqual(vm.blockError, "Couldn't unblock — try again.")
        await vm.refresh()
        XCTAssertNil(vm.blockError, "the next refresh clears the line")
    }

    // MARK: accessibility sizes

    /// Found live on the iPhone 17 simulator at AX XXXL: both row texts were
    /// pinned to one line, so the address truncated to "unified-…" and what the
    /// invite is for to "Write the projec…" — the whole content of the row, and
    /// the grade the one vocabulary promises, gone. At accessibility sizes the
    /// rows wrap instead; the compact single line stays everywhere else.
    func testWaitingRowsWrapAtAccessibilitySizesInsteadOfTruncating() {
        for size in DynamicTypeSize.allCases where !size.isAccessibilitySize {
            XCTAssertEqual(waitingRowLineLimit(size), 1, "\(size) should keep the compact one-line row")
        }
        for size in DynamicTypeSize.allCases where size.isAccessibilitySize {
            XCTAssertNil(waitingRowLineLimit(size), "\(size) must wrap, not truncate the address / the label")
        }
        XCTAssertEqual(waitingRowLineLimit(.large), 1)
        XCTAssertNil(waitingRowLineLimit(.accessibility5), "AX XXXL — the size this was found at")
    }

    // MARK: accessibility labels

    /// Prior-round finding: with the roster's pending rows on the same screen,
    /// VoiceOver read up to four identical "Copy link" buttons. Each now names
    /// its address and speaks the copied state (the visible text flips to
    /// "Copied!", which a fixed label would hide); a link-only roster invite
    /// has no address and keeps the bare form.
    func testCopyLinkButtonsNameTheirInvite() {
        XCTAssertEqual(copyInviteLinkLabel(email: "p@x.com", copied: false), "Copy invite link for p@x.com")
        XCTAssertEqual(copyInviteLinkLabel(email: "p@x.com", copied: true), "Copied invite link for p@x.com")
        XCTAssertEqual(copyInviteLinkLabel(email: nil, copied: false), "Copy invite link", "link-only roster invite")
        XCTAssertEqual(copyInviteLinkLabel(email: "", copied: true), "Copied invite link")
    }

    // MARK: live refresh

    func testTheCollabSignalsRefreshTheSection() async {
        let vm = model()
        vm.start()
        defer { vm.stop() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let before = fake.pendingLoads
        NotificationCenter.default.post(name: .unstuckCollabCircleChanged, object: nil)
        NotificationCenter.default.post(name: .unstuckCollabSharesChanged, object: nil)
        NotificationCenter.default.post(name: .unstuckCollabConnectionActivated, object: nil)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertGreaterThanOrEqual(fake.pendingLoads, before + 3)
        XCTAssertGreaterThanOrEqual(fake.circleLoads, before + 3)
    }
}
