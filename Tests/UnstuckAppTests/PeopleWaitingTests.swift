// Unified sharing v1 §2 "One place for people" — Settings → People's "Waiting
// to join" on the CircleModel over a fake PeopleTransport: the rows come from
// `my_pending_invites` with the label per kind, Cancel calls
// `cancel_pending_invite(kind, id)` and drops the row, a refused cancel is
// honest, a circle invite is never listed twice, the roster stays whole on a
// server without the RPC, and the collab signals refresh the section.

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

    // Recorded calls.
    var circleLoads = 0
    var pendingLoads = 0
    var cancelled: [(kind: PendingInviteKind, id: String)] = []
    var removed: [String] = []

    func listCircle() async -> [CircleMember] { circleLoads += 1; return circle }
    func invite(email: String?) async -> CircleInviteResult { CircleInviteResult(ok: true, emailed: true) }
    func redeem(code: String) async -> CircleRedeemResult { CircleRedeemResult(ok: true) }
    func removeMember(id: String) async {
        removed.append(id)
        circle.removeAll { $0.id == id }
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
}

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

    func testRemovingARosterRowStillGoesThroughCircleRemove() async {
        let vm = model()
        await vm.refresh()
        await vm.remove(id: "c1")
        XCTAssertEqual(fake.removed, ["c1"])
        XCTAssertTrue(vm.roster.isEmpty)
        XCTAssertEqual(vm.waiting.count, 3, "the invites are untouched")
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
