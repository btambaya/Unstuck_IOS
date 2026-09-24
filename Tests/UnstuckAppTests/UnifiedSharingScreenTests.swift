// Unified sharing v1 — the app half (docs/unified-sharing-spec.md §4):
//   • ShareScreenModel over a fake transport — section composition, the
//     default grade, level mapping per backend, the honest result line per
//     status, error mapping, hand-over mode, the link;
//   • the deep-link routing of a SHARED task (an id not in my store opens
//     the shared-task sheet, not the owner editor) + `unstuck://collections/<id>`;
//   • the assistant's email-targeted confirm.
// Runs on the in-memory AppModel (UI-test mode: GRDB in memory, no coordinator).

import XCTest
import Supabase
import UnstuckCore
import UnstuckData
import UnstuckSync
@testable import Unstuck

// MARK: - fake transport

@MainActor
private final class FakeShareTransport: ShareScreenTransport {
    var circle: [CircleMember] = []
    var taskSharesById: [String: [ShareForTask]] = [:]
    var pendingTask: [TaskSharePendingInvite] = []
    var members: [CollectionMemberInfo] = []

    // Scripted answers.
    var shareTaskError: Error?
    var emailOutcome: TaskShareOutcome = .invited
    var collectionOutcome: ShareOutcome = .ok
    var linkOutcome: ShareLinkOutcome = .ok(url: "https://unstucknow.io/circle/join?code=xyz")
    var unshareOk = true
    var blockOk = true

    // Recorded calls.
    var sharedTask: [(taskId: String, userId: String, level: ShareLevel)] = []
    var notified: [(String, String)] = []
    var unshared: [String] = []
    var emailShares: [(String, String, ShareLevel)] = []
    var collectionShares: [(String, String?, String?, String)] = []
    var cancelledTaskInvites: [String] = []
    var cancelledCollectionInvites: [String] = []
    var linkLevels: [ShareLevel] = []
    var linkRoles: [String] = []
    var loads = 0
    /// Each block call's user id + how many loads had happened before it (so
    /// a test can prove the reload came AFTER the server answered).
    var blocks: [(userId: String, loadsBefore: Int)] = []

    func listCircle() async -> [CircleMember] { loads += 1; return circle }
    func taskShares(taskId: String) async -> [ShareForTask] { taskSharesById[taskId] ?? [] }
    func taskPendingInvites(taskId: String) async -> [TaskSharePendingInvite] { pendingTask }
    func shareTask(taskId: String, userId: String, level: ShareLevel) async throws {
        if let shareTaskError { throw shareTaskError }
        sharedTask.append((taskId, userId, level))
        // The server now holds the share — reflect it for the reload.
        var rows = (taskSharesById[taskId] ?? []).filter { $0.recipientUserId != userId }
        let name = circle.first { $0.memberUserId == userId }?.memberName ?? userId
        rows.append(ShareForTask(shareId: "s-\(userId)", recipientUserId: userId, recipientName: name, level: level))
        taskSharesById[taskId] = rows
    }
    func unshareTask(shareId: String) async -> Bool {
        guard unshareOk else { return false }
        unshared.append(shareId)
        for k in taskSharesById.keys { taskSharesById[k] = taskSharesById[k]?.filter { $0.shareId != shareId } }
        return true
    }
    func shareTaskByEmail(taskId: String, email: String, level: ShareLevel) async -> TaskShareOutcome {
        emailShares.append((taskId, email, level))
        return emailOutcome
    }
    func cancelTaskInvite(taskId: String, inviteId: String) async -> Bool {
        cancelledTaskInvites.append(inviteId)
        pendingTask.removeAll { $0.id == inviteId }
        return true
    }
    func taskLink(taskId: String, level: ShareLevel) async -> ShareLinkOutcome { linkLevels.append(level); return linkOutcome }
    func notifyTaskShare(taskId: String, recipientId: String) async { notified.append((taskId, recipientId)) }
    func collectionMembers(collectionId: String) async -> [CollectionMemberInfo] { members }
    func shareCollection(collectionId: String, email: String?, userId: String?, role: String) async -> ShareOutcome {
        collectionShares.append((collectionId, email, userId, role))
        if collectionOutcome == .ok, let userId {
            members.removeAll { $0.userId == userId }
            members.append(CollectionMemberInfo(userId: userId, email: email ?? "", role: role, pending: false))
        }
        return collectionOutcome
    }
    func unshareCollection(collectionId: String, userId: String) async -> Bool {
        guard unshareOk else { return false }
        members.removeAll { $0.userId == userId }
        return true
    }
    func cancelCollectionInvite(collectionId: String, email: String) async -> Bool {
        cancelledCollectionInvites.append(email)
        members.removeAll { $0.pending && $0.email == email }
        return true
    }
    func collectionLink(collectionId: String, role: String) async -> ShareLinkOutcome { linkRoles.append(role); return linkOutcome }
    var connectInviteOutcome: ShareLinkOutcome = .ok(url: "https://unstucknow.io/circle/join?code=connect")
    var connectInvites = 0
    func inviteToConnect() async -> ShareLinkOutcome { connectInvites += 1; return connectInviteOutcome }
    func block(userId: String) async -> Bool {
        blocks.append((userId, loads))
        guard blockOk else { return false }
        // block_user severs everything between the pair server-side.
        circle.removeAll { $0.memberUserId == userId }
        members.removeAll { $0.userId == userId }
        for k in taskSharesById.keys { taskSharesById[k] = taskSharesById[k]?.filter { $0.recipientUserId != userId } }
        return true
    }
}

private struct RPCError: LocalizedError {
    let code: String
    var errorDescription: String? { code }
}

// MARK: - the screen model

@MainActor
final class ShareScreenModelTests: XCTestCase {
    private var fake: FakeShareTransport!

    override func setUp() {
        super.setUp()
        fake = FakeShareTransport()
        fake.circle = [
            CircleMember(id: "c1", relationshipLabel: "Coach", level: "view", status: "active", inviteCode: nil,
                         memberUserId: "u1", memberName: "Maya Chen", createdAt: "2026-09-17T09:00:00Z"),
            CircleMember(id: "c2", relationshipLabel: nil, level: "view", status: "active", inviteCode: nil,
                         memberUserId: "u2", memberName: "Zubair", createdAt: "2026-09-17T09:01:00Z"),
            CircleMember(id: "c3", relationshipLabel: nil, level: "view", status: "invited", inviteCode: "code",
                         memberUserId: nil, memberName: nil, createdAt: "2026-09-17T09:02:00Z", inviteeEmail: "p@x.com"),
        ]
    }

    private func taskModel(mode: ShareScreenModel.Mode = .share) -> ShareScreenModel {
        ShareScreenModel(target: .task(id: "t1", name: "Draft the deck"), mode: mode, transport: fake)
    }
    private func collectionModel() -> ShareScreenModel {
        ShareScreenModel(target: .collection(id: "col1", name: "Groceries"), transport: fake)
    }

    // MARK: composition

    func testSectionsComposeFromTheRosterTheGrantsAndThePendingInvites() async {
        fake.taskSharesById["t1"] = [ShareForTask(shareId: "s1", recipientUserId: "u2", recipientName: "Zubair", level: .view)]
        fake.pendingTask = [TaskSharePendingInvite(id: "i1", email: "new@x.com", level: .partner)]
        let vm = taskModel()
        await vm.load()
        XCTAssertFalse(vm.loading)
        XCTAssertEqual(vm.access, .edit, "default grade is Can edit")
        XCTAssertEqual(vm.people.map(\.userId), ["u1", "u2"], "active connections only — the pending circle row is not a person")
        XCTAssertNil(vm.people[0].access)
        XCTAssertEqual(vm.people[1].access, .view)
        XCTAssertEqual(vm.people[1].shareId, "s1")
        XCTAssertEqual(vm.pending, [SharePendingRow(id: "i1", email: "new@x.com", access: .edit)])
    }

    func testCollectionSectionsUseTheMemberListAndRoles() async {
        fake.members = [
            CollectionMemberInfo(userId: "u1", email: "maya@x.com", role: "viewer", pending: false),
            CollectionMemberInfo(userId: "", email: "later@x.com", role: "editor", pending: true),
        ]
        let vm = collectionModel()
        await vm.load()
        XCTAssertEqual(vm.people[0].access, .view)
        XCTAssertEqual(vm.people[0].email, "maya@x.com")
        XCTAssertNil(vm.people[1].access)
        XCTAssertEqual(vm.pending, [SharePendingRow(id: "pending:later@x.com", email: "later@x.com", access: .edit)])
    }

    // MARK: People — one tap shares at the default grade

    func testTappingAPersonSharesATaskAtPartnerAndSaysSo() async {
        let vm = taskModel()
        await vm.load()
        await vm.tap(vm.people[0])
        XCTAssertEqual(fake.sharedTask.count, 1)
        XCTAssertEqual(fake.sharedTask[0].userId, "u1")
        XCTAssertEqual(fake.sharedTask[0].level, .partner, "Can edit → partner")
        XCTAssertEqual(fake.notified.first?.1, "u1", "a by-id share pings the recipient")
        XCTAssertEqual(vm.result, "Shared with Maya — they can edit.")
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.people[0].access, .edit, "the row now shows what they have (reloaded from the server)")
        XCTAssertNil(vm.busyId)
    }

    func testCanViewTapSharesATaskAtView() async {
        let vm = taskModel()
        await vm.load()
        vm.access = .view
        await vm.tap(vm.people[1])
        XCTAssertEqual(fake.sharedTask[0].level, .view)
        XCTAssertEqual(vm.result, "Shared with Zubair — they can view.")
    }

    func testTappingAPersonSharesACollectionByUserIdWithTheMappedRole() async {
        let vm = collectionModel()
        await vm.load()
        await vm.tap(vm.people[0])
        XCTAssertEqual(fake.collectionShares.count, 1)
        XCTAssertEqual(fake.collectionShares[0].2, "u1")
        XCTAssertEqual(fake.collectionShares[0].3, "editor", "Can edit → editor")
        XCTAssertEqual(vm.result, "Shared with Maya — they can edit.")
        vm.access = .view
        await vm.tap(vm.people[1])
        XCTAssertEqual(fake.collectionShares[1].3, "viewer")
    }

    func testAListPeopleTapAgainstAnEmailOnlyBackendSaysWhatToDo() async {
        // Contract gap: share-collection add resolves emails only; the roster
        // has none → the server answers bad_request → a pointed line, not
        // "try again".
        fake.collectionOutcome = .invalid
        let vm = collectionModel()
        await vm.load()
        await vm.tap(vm.people[0])
        XCTAssertEqual(fake.collectionShares[0].2, "u1", "the by-userId add is attempted (the contract may grow it)")
        XCTAssertEqual(vm.error, "Lists can't be shared by name yet — enter their email below.")
        XCTAssertNil(vm.result)
    }

    func testAnAlreadySharedPersonIsNotResharedByABareTap() async {
        fake.taskSharesById["t1"] = [ShareForTask(shareId: "s1", recipientUserId: "u1", recipientName: "Maya Chen", level: .partner)]
        let vm = taskModel()
        await vm.load()
        await vm.tap(vm.people[0])
        XCTAssertTrue(fake.sharedTask.isEmpty)
        XCTAssertNil(vm.result)
    }

    func testChangingAndRemovingAccess() async {
        fake.taskSharesById["t1"] = [ShareForTask(shareId: "s1", recipientUserId: "u1", recipientName: "Maya Chen", level: .partner)]
        let vm = taskModel()
        await vm.load()
        await vm.setAccess(vm.people[0], .view)
        XCTAssertEqual(fake.sharedTask.last?.level, .view)
        XCTAssertTrue(fake.notified.isEmpty, "a grade change is not a new share — no ping")
        XCTAssertEqual(vm.result, "Maya can now view.")
        await vm.setAccess(vm.people[0], nil)
        XCTAssertEqual(fake.unshared, ["s-u1"])
        XCTAssertEqual(vm.result, "Maya no longer has this.")
        XCTAssertNil(vm.people[0].access)
    }

    func testARefusedRemoveIsShownNotPretended() async {
        fake.taskSharesById["t1"] = [ShareForTask(shareId: "s1", recipientUserId: "u1", recipientName: "Maya Chen", level: .partner)]
        fake.unshareOk = false
        let vm = taskModel()
        await vm.load()
        await vm.setAccess(vm.people[0], nil)
        XCTAssertEqual(vm.error, "Couldn't share — try again.")
        XCTAssertEqual(vm.people[0].access, .edit, "they still have it")
    }

    func testAServerRefusalOnTheRPCMapsToTheShownCopy() async {
        fake.shareTaskError = RPCError(code: "not_in_circle")
        let vm = taskModel()
        await vm.load()
        await vm.tap(vm.people[0])
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.result)
        XCTAssertTrue(fake.notified.isEmpty, "a failed share never pings")
    }

    // MARK: Someone new — the honest line per status

    func testEmailShareWithAnExistingAccountSaysShared() async {
        fake.emailOutcome = .shared(userId: "u9", displayName: "Nadia Ali")
        let vm = taskModel()
        await vm.load()
        vm.email = " Nadia@Example.com "
        await vm.shareWithEmail()
        XCTAssertEqual(fake.emailShares.count, 1)
        XCTAssertEqual(fake.emailShares[0].1, "nadia@example.com", "trimmed + lower-cased like the server")
        XCTAssertEqual(fake.emailShares[0].2, .partner)
        XCTAssertEqual(vm.result, "Shared with Nadia — they can edit.")
        XCTAssertEqual(vm.email, "", "the field clears on success")
        XCTAssertTrue(fake.notified.isEmpty, "share-task add notifies server-side")
    }

    func testEmailShareWithNoAccountSaysInvited() async {
        fake.emailOutcome = .invited
        let vm = taskModel()
        await vm.load()
        vm.access = .view
        vm.email = "new@x.com"
        await vm.shareWithEmail()
        XCTAssertEqual(fake.emailShares[0].2, .view)
        XCTAssertEqual(vm.result, "Invite sent to new@x.com — waiting for them to sign up.")
    }

    func testEmailShareRefusalsAreShown() async {
        let vm = taskModel()
        await vm.load()
        vm.email = "not an email"
        await vm.shareWithEmail()
        XCTAssertEqual(vm.error, "That doesn't look like an email address.")
        XCTAssertTrue(fake.emailShares.isEmpty, "no round trip for a malformed address")

        // A block is the SERVER's answer now (audit 2026-09-22, C10) — the
        // device-local list that only this field read is gone.
        fake.emailOutcome = .failed(reason: "blocked")
        vm.email = "bad@x.com"
        await vm.shareWithEmail()
        XCTAssertEqual(vm.error, "You've blocked that person.")
        XCTAssertEqual(fake.emailShares.map(\.1), ["bad@x.com"], "the server decides, so the round trip happens")

        fake.emailOutcome = .failed(reason: "self")
        vm.email = "me@x.com"
        await vm.shareWithEmail()
        XCTAssertEqual(vm.error, "That's you.")
        XCTAssertEqual(vm.email, "me@x.com", "the field keeps the address on a refusal")

        fake.emailOutcome = .failed(reason: "rate_limited")
        await vm.shareWithEmail()
        XCTAssertEqual(vm.error, "Too many invites right now — try again in a few minutes.")

        fake.emailOutcome = .failed(reason: "network")
        await vm.shareWithEmail()
        XCTAssertEqual(vm.error, "Couldn't share — try again.")
    }

    func testCollectionEmailShareMapsTheOutcome() async {
        let vm = collectionModel()
        await vm.load()
        fake.collectionOutcome = .invited
        vm.email = "new@x.com"
        await vm.shareWithEmail()
        XCTAssertEqual(fake.collectionShares[0].1, "new@x.com")
        XCTAssertNil(fake.collectionShares[0].2)
        XCTAssertEqual(fake.collectionShares[0].3, "editor")
        XCTAssertEqual(vm.result, "Invite sent to new@x.com — waiting for them to sign up.")
        // The DEPLOYED share-collection add answers the same for both branches
        // → the neutral line, never a guess.
        fake.collectionOutcome = .accepted
        vm.email = "other@x.com"
        await vm.shareWithEmail()
        XCTAssertEqual(vm.result, "Shared with other@x.com — they'll see it as soon as they're in.")
        fake.collectionOutcome = .selfError
        vm.email = "me@x.com"
        await vm.shareWithEmail()
        XCTAssertEqual(vm.error, "That's you.")
        fake.collectionOutcome = .blocked
        await vm.shareWithEmail()
        XCTAssertEqual(vm.error, "You've blocked that person.")
    }

    /// Audit 2026-09-22, C10: a People tap on a list for someone who is no
    /// longer connected (a stale row) answers `not_in_circle` since 075 — say
    /// so, not "try again".
    func testAListShareToAStaleConnectionSaysNotConnected() async {
        fake.collectionOutcome = .notConnected
        let vm = collectionModel()
        await vm.load()
        await vm.tap(vm.people[0])
        XCTAssertEqual(vm.error, "You're not connected yet — share by email or a link below.")
        XCTAssertNil(vm.result)
    }

    // MARK: Block (server-side, audit 2026-09-22 C10)

    func testBlockingSomeoneOnATaskGoesToTheServerThenReloads() async {
        fake.taskSharesById["t1"] = [ShareForTask(shareId: "s1", recipientUserId: "u1", recipientName: "Maya Chen", level: .partner)]
        let vm = taskModel()
        await vm.load()
        let loads = fake.loads
        await vm.block(vm.people[0])
        XCTAssertEqual(fake.blocks.map(\.userId), ["u1"], "block_user takes the person's user id")
        XCTAssertEqual(fake.blocks[0].loadsBefore, loads, "no reload BEFORE the server answered")
        XCTAssertGreaterThan(fake.loads, loads, "reloaded after the block")
        XCTAssertEqual(vm.result, "Blocked Maya — they can't share with you, and nothing is shared between you now.")
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.people.contains { $0.userId == "u1" }, "they are gone from the screen — the server cut them off")
        XCTAssertNil(vm.busyId)
    }

    func testBlockingSomeoneOnAListBlocksTheirAccountNotAnEmail() async {
        // The old list Block stored the member's EMAIL on this device and
        // removed them from this one list; now the account is blocked
        // server-side and the reload follows the answer.
        fake.members = [CollectionMemberInfo(userId: "u2", email: "z@x.com", role: "editor", pending: false)]
        let vm = collectionModel()
        await vm.load()
        let row = vm.people.first { $0.userId == "u2" }!
        await vm.block(row)
        XCTAssertEqual(fake.blocks.map(\.userId), ["u2"])
        XCTAssertEqual(vm.result, "Blocked Zubair — they can't share with you, and nothing is shared between you now.")
        XCTAssertFalse(vm.people.contains { $0.userId == "u2" })
    }

    func testARefusedBlockIsShownAndNeverClaimsSuccess() async {
        fake.taskSharesById["t1"] = [ShareForTask(shareId: "s1", recipientUserId: "u1", recipientName: "Maya Chen", level: .partner)]
        fake.blockOk = false
        let vm = taskModel()
        await vm.load()
        await vm.block(vm.people[0])
        // The refusal names the BLOCK — "Couldn't share" read as though a
        // share had failed, on a safety action whose failure matters.
        XCTAssertEqual(vm.error, "Couldn't block Maya — try again.")
        XCTAssertNil(vm.result)
        XCTAssertEqual(vm.people[0].access, .edit, "they still have it")
    }

    func testCancellingAPendingInvite() async {
        fake.pendingTask = [TaskSharePendingInvite(id: "i1", email: "new@x.com", level: .partner)]
        let vm = taskModel()
        await vm.load()
        await vm.cancelPending(vm.pending[0])
        XCTAssertEqual(fake.cancelledTaskInvites, ["i1"])
        XCTAssertEqual(vm.result, "Invite to new@x.com cancelled.")
        XCTAssertTrue(vm.pending.isEmpty)
    }

    // MARK: Share a link

    func testTheLinkCarriesTheGradeAndSaysWhatItDoes() async {
        let vm = taskModel()
        await vm.load()
        vm.access = .view
        let url = await vm.makeLink()
        XCTAssertEqual(url, "https://unstucknow.io/circle/join?code=xyz")
        XCTAssertEqual(vm.lastLink, url)
        XCTAssertEqual(fake.linkLevels, [.view])
        XCTAssertEqual(vm.result, "Link copied — whoever opens it gets this task.")

        let cm = collectionModel()
        await cm.load()
        _ = await cm.makeLink()
        XCTAssertEqual(fake.linkRoles, ["editor"])
        XCTAssertEqual(cm.result, "Link copied — whoever opens it gets this list.")
    }

    func testAFailedLinkIsShown() async {
        fake.linkOutcome = .failed(reason: "rate_limited")
        let vm = taskModel()
        await vm.load()
        let url = await vm.makeLink()
        XCTAssertNil(url)
        XCTAssertNil(vm.lastLink)
        XCTAssertEqual(vm.error, "Too many invites right now — try again in a few minutes.")
    }

    // MARK: Hand over to…

    func testHandOverModeAssignsAndExplains() async {
        let vm = taskModel(mode: .handOver)
        await vm.load()
        await vm.tap(vm.people[0])
        XCTAssertEqual(fake.sharedTask[0].level, .assign)
        XCTAssertEqual(fake.notified.first?.1, "u1")
        XCTAssertEqual(vm.result, "Handed over to Maya — it's their task now; you keep view.")
        XCTAssertTrue(vm.people[0].handedOver)
        XCTAssertEqual(vm.people[0].statusLabel, "Handed over")
        XCTAssertNil(vm.people[0].access)
        XCTAssertTrue(handOverExplainer.contains("you keep view"))
    }

    // MARK: People card — pinned at open (order + collapse are the pure layout's job)

    func testPinnedIdsAreFixedByTheFirstLoadAndSurviveAReload() async {
        fake.taskSharesById["t1"] = [ShareForTask(shareId: "s1", recipientUserId: "u2", recipientName: "Zubair", level: .view)]
        let vm = taskModel()
        XCTAssertTrue(vm.pinnedIds.isEmpty, "nothing is pinned before the first load")
        await vm.load()
        XCTAssertEqual(vm.pinnedIds, ["c2"], "the row id of who already held it at open")
        await vm.tap(vm.people[0])   // share with Maya — perform() reloads
        XCTAssertEqual(vm.people[0].access, .edit)
        XCTAssertEqual(vm.pinnedIds, ["c2"], "a share made while the sheet is open does NOT pin")
        XCTAssertEqual(vm.people.map(\.userId), ["u1", "u2"], "vm.people keeps roster order")
        let layout = sharePeopleLayout(vm.people, pinned: vm.pinnedIds, expanded: false, query: "")
        XCTAssertEqual(layout.rows.map(\.userId), ["u2", "u1"], "Zubair (pinned) first; Maya stays where she was")
        await vm.setAccess(vm.people[1], nil)   // remove Zubair
        XCTAssertNil(vm.people[1].access)
        XCTAssertEqual(vm.pinnedIds, ["c2"], "frozen — never recomputed, even after a remove")
    }

    func testPinningWaitsForTheFirstNonEmptyLoad() async {
        let circle = fake.circle
        fake.circle = []
        fake.taskSharesById["t1"] = [ShareForTask(shareId: "s1", recipientUserId: "u1", recipientName: "Maya Chen", level: .partner)]
        let vm = taskModel()
        await vm.load()
        XCTAssertEqual(vm.people.count, 1, "a grant outside the roster is still a person")
        XCTAssertEqual(vm.pinnedIds, ["grant:u1"])
        fake.circle = circle
        await vm.load()
        XCTAssertEqual(vm.pinnedIds, ["grant:u1"], "the first non-empty load fixed it; the roster arriving later does not re-pin")
    }

    func testHandOverModePinsOnlyTheHolder() async {
        fake.taskSharesById["t1"] = [
            ShareForTask(shareId: "s1", recipientUserId: "u1", recipientName: "Maya Chen", level: .partner),
            ShareForTask(shareId: "s2", recipientUserId: "u2", recipientName: "Zubair", level: .assign),
        ]
        let vm = taskModel(mode: .handOver)
        await vm.load()
        XCTAssertEqual(vm.pinnedIds, ["c2"], "an edit grant is not a hand-over")
        let share = taskModel(mode: .share)
        await share.load()
        XCTAssertEqual(share.pinnedIds, ["c1", "c2"], "share mode pins every grant, the hand-over included")
    }

    // MARK: live refresh

    func testTheCollabSignalsReloadTheScreen() async {
        let vm = taskModel()
        vm.start()
        defer { vm.stop() }
        // Give the initial load a moment, then poke the signal.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let before = fake.loads
        NotificationCenter.default.post(name: .unstuckCollabConnectionActivated, object: nil)
        NotificationCenter.default.post(name: .unstuckCollabSharesChanged, object: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(fake.loads, before + 2)
    }
}

// MARK: - deep links

@MainActor
final class SharedTaskDeepLinkTests: XCTestCase {

    func testPureRouteVerdicts() {
        XCTAssertEqual(AppModel.taskLinkRoute(id: "t-proposal", isLocal: true), .owner)
        XCTAssertEqual(AppModel.taskLinkRoute(id: "someone-elses", isLocal: false), .shared)
        XCTAssertEqual(AppModel.taskLinkRoute(id: "  ", isLocal: false), .today)
        XCTAssertEqual(AppModel.collectionLinkId("unstuck://collections/c1"), "c1")
        XCTAssertEqual(AppModel.collectionLinkId("unstuck://collections/c1?x=1"), "c1")
        XCTAssertNil(AppModel.collectionLinkId("unstuck://collections"))
        XCTAssertNil(AppModel.collectionLinkId("unstuck://collections/"))
    }

    func testAPushForATaskInMyStoreOpensTheOwnerEditor() {
        let model = AppModel()
        model.startUITestMode()
        model.routeDeepLink("unstuck://task/t-proposal")
        XCTAssertEqual(model.router.detailTask?.id, "t-proposal")
        XCTAssertNil(model.router.sharedDetail)
        XCTAssertEqual(model.router.tab, .today)
    }

    func testAPushForATaskSharedWithMeOpensTheSharedSheetNotTheEditor() {
        let model = AppModel()
        model.startUITestMode()
        model.routeDeepLink("unstuck://task/8b1e2c1a-not-in-my-store")
        XCTAssertNil(model.router.detailTask, "no local row ⇒ never the owner editor")
        XCTAssertEqual(model.router.sharedDetail?.id, "8b1e2c1a-not-in-my-store")
        XCTAssertTrue(model.router.hasActivePresentation, "the shared sheet counts as a presentation for the dismiss-then-present guard")
        model.router.dismissAllPresentations()
        XCTAssertNil(model.router.sharedDetail)
    }

    func testACollectionPushLandsOnTheTabAndParksTheId() {
        let model = AppModel()
        model.startUITestMode()
        model.routeDeepLink("unstuck://collections/col-9")
        XCTAssertEqual(model.router.tab, .lists)
        XCTAssertEqual(model.router.openCollectionId, "col-9")
        model.routeDeepLink("unstuck://collections")
        XCTAssertEqual(model.router.openCollectionId, "col-9", "the bare tab link doesn't clear a parked id")
    }
}

// MARK: - recipient-side controls (audit 2026-09-22, C10)

/// A recipient used to have no way to drop, report or block a task shared
/// with them, and Block was a device-local email set. The confirms say what
/// happens, the report names the share, and nothing claims success without
/// the server.
@MainActor
final class RecipientShareControlsTests: XCTestCase {

    func testTheConfirmsSayWhatHappens() {
        XCTAssertEqual(RecipientShareAction.leave.title(owner: "maya@x.com"), "Remove from my list?")
        XCTAssertEqual(RecipientShareAction.leave.message(owner: "maya@x.com"), "You'll stop seeing this task. maya isn't told.")
        XCTAssertEqual(RecipientShareAction.leave.confirmLabel, "Remove")
        XCTAssertEqual(RecipientShareAction.block.title(owner: "Maya Chen"), "Block Maya Chen?")
        XCTAssertEqual(RecipientShareAction.block.message(owner: "Maya Chen"),
                       "Maya Chen won't be able to share tasks or lists with you, and everything shared between you stops. You can unblock them in Settings › People.")
        XCTAssertEqual(RecipientShareAction.block.confirmLabel, "Block")
    }

    func testTheReportNamesTheTaskTheShareAndTheOwner() {
        XCTAssertEqual(AppModel.sharedTaskReportBody(taskId: "t1", shareId: "s1", ownerName: "Maya", reason: "Spam"),
                       "⚠️ REPORT — task shared with me t1 (share s1) from Maya: Spam")
        XCTAssertEqual(AppModel.sharedTaskReportBody(taskId: "t1", shareId: nil, ownerName: "Maya", reason: "Other"),
                       "⚠️ REPORT — task shared with me t1 from Maya: Other")
    }

    func testWithoutAServerNothingClaimsSuccessOrDropsTheRow() async {
        let model = AppModel()
        model.startUITestMode()   // no coordinator
        let row = SharedWithMe(shareId: "s1", taskId: "t1", ownerName: "Maya", level: .view, title: "Deck", done: false)
        model.shareState.sharedWithMe = [row]
        let left = await model.leaveSharedTask(shareId: "s1")
        XCTAssertFalse(left)
        XCTAssertEqual(model.shareState.sharedWithMe, [row], "a leave that never reached the server keeps the row")
        let blockedSharer = await model.blockTaskSharer(shareId: "s1")
        XCTAssertFalse(blockedSharer)
        let blockedUser = await model.blockUser(userId: "u1")
        XCTAssertFalse(blockedUser)
    }

    /// A refused leave used to count on the refetch to bring the row back —
    /// offline that refetch reads [] too, so it blanked every Shared-with-you
    /// row and delegation badge. The row now comes back in place and nothing
    /// else is touched.
    func testAnOfflineLeaveKeepsTheRowAndEverythingElse() async {
        let share = ShareModel(client: Self.offlineCircle())
        let a = SharedWithMe(shareId: "s1", taskId: "t1", ownerName: "Maya", level: .view, title: "Deck", done: false)
        let b = SharedWithMe(shareId: "s2", taskId: "t2", ownerName: "Zubair", level: .partner, title: "Run", done: false)
        share.sharedWithMe = [a, b]
        share.badges = ["t9": [ShareBadge(taskId: "t9", level: .assign, recipientName: "Maya")]]
        let revision = share.revision
        let left = await share.leave(shareId: "s1")
        XCTAssertFalse(left)
        XCTAssertEqual(share.sharedWithMe, [a, b], "the row is back in place; the others were never touched")
        XCTAssertEqual(share.assignedOutIds, ["t9"], "the delegation badge survives")
        XCTAssertEqual(share.revision, revision, "no re-read")
        // The re-read the old path ran really does blank it all offline.
        await share.refresh()
        XCTAssertTrue(share.sharedWithMe.isEmpty)
        XCTAssertTrue(share.badges.isEmpty)
    }

    /// A CircleClient that fails every call fast, like an offline phone's:
    /// nothing listens on this loopback port. The session lives in memory,
    /// never the keychain.
    private static func offlineCircle() -> CircleClient {
        CircleClient(SupabaseClient(
            supabaseURL: URL(string: "http://127.0.0.1:1")!, supabaseKey: "offline",
            options: SupabaseClientOptions(auth: .init(storage: MemoryAuthStorage(), autoRefreshToken: false,
                                                       emitLocalSessionAsInitialSession: true))))
    }
}

private final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

// MARK: - assistant email confirm

@MainActor
private final class EmailSpyPerformer: AssistantSharePerformer {
    var outcome: TaskShareOutcome = .invited
    var emailCalls: [(String, String, ShareLevel)] = []
    var idCalls = 0
    func share(taskId: String, user: String, level: ShareLevel) async throws { idCalls += 1 }
    func notify(taskId: String, recipientId: String) async {}
    func shareByEmail(taskId: String, email: String, level: ShareLevel) async -> TaskShareOutcome {
        emailCalls.append((taskId, email, level))
        return outcome
    }
}

@MainActor
final class AssistantEmailShareConfirmTests: XCTestCase {
    private let pending = PendingShare(id: "p1", taskId: "t1", taskName: "Grocery run", recipientUserId: "",
                                       recipientName: "maya@x.com", level: .partner, recipientEmail: "maya@x.com")

    func testAnEmailRequestGoesThroughShareTaskAddWithTheHonestLine() async {
        let spy = EmailSpyPerformer()
        spy.outcome = .shared(userId: "u1", displayName: "Maya Chen")
        let (outcome, line) = await performConfirmedEmailShare(pending, using: spy)
        XCTAssertEqual(outcome, .shared)
        XCTAssertEqual(line, "Shared with Maya — they can edit.")
        XCTAssertEqual(spy.emailCalls.count, 1)
        XCTAssertEqual(spy.emailCalls[0].1, "maya@x.com")
        XCTAssertEqual(spy.emailCalls[0].2, .partner)
        XCTAssertEqual(spy.idCalls, 0, "never the by-id RPC for an email")

        spy.outcome = .invited
        let invited = await performConfirmedEmailShare(pending, using: spy)
        XCTAssertEqual(invited.0, .shared)
        XCTAssertEqual(invited.1, "Invite sent to maya@x.com — waiting for them to sign up.")

        spy.outcome = .failed(reason: "self")
        let failed = await performConfirmedEmailShare(pending, using: spy)
        XCTAssertEqual(failed.0, .failed)
        XCTAssertEqual(failed.1, "That's you.")
    }

    func testTheGenericConfirmRoutesAnEmailRequestToTheEmailPath() async {
        let spy = EmailSpyPerformer()
        spy.outcome = .failed(reason: "rate_limited")
        let (outcome, message) = await performConfirmedShare(pending, using: spy)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(message, "Too many invites right now — try again in a few minutes.")
        XCTAssertEqual(spy.idCalls, 0)
        spy.outcome = .invited
        let ok = await performConfirmedShare(pending, using: spy)
        XCTAssertEqual(ok.0, .shared)
        XCTAssertNil(ok.1, "success carries no failure message on the generic path")
    }
}

// MARK: - repeating series entry points (audit 2026-09-22, C3)
//
// Every path that used to hand the hidden TEMPLATE of a series to a screen
// whose "Mark done" / "Done" then ended the whole series (or ticked nothing):
// reminder task links, the month peek, the Today live card / PAUSED chip, and
// the store-level toggleDone / setRecurrence rules behind the editor.

@MainActor
final class RecurringEntryPointTests: XCTestCase {
    private var model: AppModel!
    private var db: AppDatabase!
    private let today = Clock.todayISO()
    private var tomorrow: String { LocalDate.addDays(today, 1) }

    override func setUp() async throws {
        try await super.setUp()
        model = AppModel()
        model.startUITestMode()
        db = try XCTUnwrap(model.db)
    }

    private func seedSeries(id: String = "c3-tpl", done: Bool = false, todayDone: Bool = false,
                            blocks: Bool = true) throws -> TaskItem {
        let tpl = TaskItem(id: id, name: "C3 meds", estimateMin: 10, done: done, recurrence: .daily(until: nil),
                           createdAt: "2026-09-01T08:00:00.000Z", updatedAt: "2026-09-01T08:00:00.000Z")
        try db.save(tpl)
        if blocks {
            try db.save(CalBlock(id: "\(id)-td", taskId: id, taskName: "C3 meds", startTime: "08:00", durationMinutes: 10,
                                 date: today, kind: .task, done: todayDone,
                                 completedAt: todayDone ? "\(today)T08:10:00.000Z" : nil))
            try db.save(CalBlock(id: "\(id)-tm", taskId: id, taskName: "C3 meds", startTime: "08:00", durationMinutes: 10,
                                 date: tomorrow, kind: .task))
        }
        return tpl
    }

    private func stored(_ id: String) throws -> TaskItem? { try model.taskRepo?.fetch(id: id) }

    /// A reminder tap carries the template id: the day's OCCURRENCE opens,
    /// so its Mark done ticks the day instead of ending the series.
    func testAReminderLinkOpensTodaysOccurrenceNotTheSeries() throws {
        _ = try seedSeries()
        model.routeDeepLink("unstuck://task/c3-tpl")
        XCTAssertEqual(model.router.detailTask?.id, "c3-tpl-td")
        XCTAssertNil(model.router.detailTask?.recurrence)
        XCTAssertNil(model.router.sharedDetail)
    }

    /// The month peek sends the day's block id: that exact day opens.
    func testABlockIdLinkOpensThatDay() throws {
        _ = try seedSeries()
        model.routeDeepLink("unstuck://task/c3-tpl-tm")
        XCTAssertEqual(model.router.detailTask?.id, "c3-tpl-tm")
        XCTAssertNil(model.router.sharedDetail, "a block id is mine, never a share")
    }

    func testASeriesWithNoOccurrenceOpensTheSeries() throws {
        _ = try seedSeries(blocks: false)
        model.routeDeepLink("unstuck://task/c3-tpl")
        XCTAssertEqual(model.router.detailTask?.id, "c3-tpl")
    }

    /// Owner decision: call-anchored links and open_screen keep opening the
    /// SERIES (its "Call me" section) — the exact link is never re-resolved.
    func testAnExactLinkOpensTheSeriesItself() throws {
        _ = try seedSeries()
        XCTAssertEqual(AppModel.exactTaskLink("c3-tpl"), "unstuck://task/c3-tpl?exact")
        model.routeDeepLink(AppModel.exactTaskLink("c3-tpl"))
        XCTAssertEqual(model.router.detailTask?.id, "c3-tpl")
        XCTAssertNotNil(model.router.detailTask?.recurrence)
        model.router.dismissAllPresentations()
        XCTAssertTrue(model.openScreen("tasks", id: "c3-tpl"))
        XCTAssertEqual(model.router.detailTask?.id, "c3-tpl", "the assistant's open_screen names the task itself")
        model.router.dismissAllPresentations()
        model.routeDeepLink(AppModel.exactTaskLink("someone-elses"))
        XCTAssertEqual(model.router.sharedDetail?.id, "someone-elses", "the marker never leaks into the id")
    }

    /// Defense in depth behind the hidden button: an OPEN template never takes
    /// a done flip; one the old path already ended can still be reopened.
    func testToggleDoneNeverEndsASeriesButCanReopenAnEndedOne() async throws {
        let open = try seedSeries()
        model.toggleDone(open)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(try stored("c3-tpl")?.done, false)
        XCTAssertTrue(try OutboxStore(db).pending().filter { $0.tableName == "tasks" && $0.rowId == "c3-tpl" }.isEmpty)

        let ended = try seedSeries(id: "c3-ended", done: true, blocks: false)
        model.toggleDone(ended)
        for _ in 0..<60 {
            if try stored("c3-ended")?.done == false { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try stored("c3-ended")?.done, false, "a series the old path ended is recoverable")
    }

    /// "Never" on a ticked day carries the tick onto the task. (Block
    /// regeneration needs the coordinator's writer, absent in this boot — the
    /// pure regenerateForTask covers the future-block deletes.)
    func testNeverOnATickedDayLeavesTheTaskDone() async throws {
        let tpl = try seedSeries(todayDone: true)
        model.setRecurrence(tpl, nil)
        for _ in 0..<60 {
            if try stored("c3-tpl")?.recurrence == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let after = try XCTUnwrap(stored("c3-tpl"))
        XCTAssertNil(after.recurrence)
        XCTAssertTrue(after.done)
        XCTAssertEqual(after.completedAt, "\(today)T08:10:00.000Z")
    }

    /// The other way round: a plain task ticked today, then made daily. The
    /// series is open (a done template is an ended one) and today's slot keeps
    /// the tick — it never reappears in Today to be done again.
    func testMakingATaskDoneTodayRepeatKeepsTodaysTick() async throws {
        let stamp = AppModel.isoNow()
        let plain = TaskItem(id: "c3-stretch", name: "Stretch", estimateMin: 10, done: true, completedAt: stamp,
                             createdAt: "2026-09-01T08:00:00.000Z", updatedAt: "2026-09-01T08:00:00.000Z")
        try db.save(plain)
        try db.save(CalBlock(id: "c3-stretch-td", taskId: "c3-stretch", taskName: "Stretch", startTime: "07:30",
                             durationMinutes: 10, date: today, kind: .task))
        func todaySlot() throws -> CalBlock? { try db.fetchAllCalBlocks().first { $0.id == "c3-stretch-td" } }

        model.setRecurrence(plain, .daily(until: nil))
        for _ in 0..<60 {
            if try stored("c3-stretch")?.recurrence != nil, try todaySlot()?.done == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let after = try XCTUnwrap(stored("c3-stretch"))
        XCTAssertEqual(after.recurrence, .daily(until: nil))
        XCTAssertFalse(after.done, "a done template is an ended series")
        let slot = try XCTUnwrap(todaySlot())
        XCTAssertTrue(slot.done, "today's slot keeps the tick")
        XCTAssertEqual(slot.completedAt, stamp)
        XCTAssertEqual(slot.startTime, "07:30")
        XCTAssertEqual(projectOccurrences([after], [slot], fromISO: today).first?.done, true,
                       "Today shows the day ticked, not open")
    }

    /// The Today live card / PAUSED chip hold the TEMPLATE of a paused
    /// occurrence session: reopening lands on the session's OWN day, so
    /// FocusModel re-attaches the paused session instead of resuming it.
    func testReopeningAPausedOccurrenceSessionOpensItsOwnDay() throws {
        let tpl = try seedSeries()
        let store = try XCTUnwrap(model.liveStore)
        let now = Date().timeIntervalSince1970 * 1000
        let started = FocusTimer.start(FocusTimer.empty, taskId: "c3-tpl", estimateMin: 10, now: now - 60_000,
                                       occurrenceBlockId: "c3-tpl-td")
        let paused = FocusTimer.pause(started, now: now)
        try store.set(paused)
        model.refreshLiveSession()

        model.reopenLiveFocus(tpl)
        XCTAssertEqual(model.router.focusTask?.id, "c3-tpl-td")
        XCTAssertNil(model.router.focusTask?.recurrence)
        let live = try XCTUnwrap(store.get())
        XCTAssertTrue(FocusModel.reopensExistingSession(live, focusId: "c3-tpl", occurrenceBlockId: "c3-tpl-td"),
                      "the paused session re-attaches as-is")
    }

    /// A repeating share's finish never claims (or sends) a tick the server
    /// refuses; a plain partner share still may.
    func testASharedRepeatingTaskNeverTakesAFocusTick() {
        model.shareState.sharedWithMe = [
            SharedWithMe(shareId: "s1", taskId: "rep", ownerName: "Anna", level: .partner, title: "Gym", done: false,
                         recurrence: .weekly(daysOfWeek: [1, 3, 5], until: nil)),
            SharedWithMe(shareId: "s2", taskId: "plain", ownerName: "Anna", level: .partner, title: "Tax", done: false),
        ]
        XCTAssertFalse(model.sharedTaskAllowsTick("rep"))
        XCTAssertTrue(model.sharedTaskAllowsTick("plain"))
        XCTAssertTrue(model.sharedTaskAllowsTick("not-loaded-yet"), "the level (checked by every caller) decides")
    }
}

// MARK: - pre-create (New task → "Share with…", 2026-09-24)

/// The Share screen for a task that doesn't exist yet: the SAME model over a
/// DraftShareTransport. Every pick is held locally (nothing reaches the
/// server until the New task sheet submits), the lines say what WILL happen,
/// and the draft maps to the calls submit makes.
@MainActor
final class ShareScreenPreCreateTests: XCTestCase {
    private var fake: FakeShareTransport!
    private var draft: DraftShareTransport!

    override func setUp() {
        super.setUp()
        fake = FakeShareTransport()
        fake.circle = [
            CircleMember(id: "c1", relationshipLabel: "Coach", level: "view", status: "active", inviteCode: nil,
                         memberUserId: "u1", memberName: "Maya Chen", createdAt: "2026-09-17T09:00:00Z"),
            CircleMember(id: "c2", relationshipLabel: nil, level: "view", status: "active", inviteCode: nil,
                         memberUserId: "u2", memberName: "Zubair", createdAt: "2026-09-17T09:01:00Z"),
        ]
        draft = DraftShareTransport(base: fake)
    }

    private func preCreateModel() -> ShareScreenModel {
        ShareScreenModel(target: .task(id: "", name: "Draft the deck"), transport: draft, preCreate: true)
    }

    private func assertNothingReachedTheServer(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(fake.sharedTask.isEmpty, "no task_share before the task exists", file: file, line: line)
        XCTAssertTrue(fake.notified.isEmpty, "no share-notify before the task exists", file: file, line: line)
        XCTAssertTrue(fake.unshared.isEmpty, file: file, line: line)
        XCTAssertTrue(fake.emailShares.isEmpty, "no share-task add before the task exists", file: file, line: line)
        XCTAssertTrue(fake.cancelledTaskInvites.isEmpty, file: file, line: line)
        XCTAssertTrue(fake.linkLevels.isEmpty, "no task link before the task exists", file: file, line: line)
    }

    func testTheRosterComesFromTheLiveTransportAndNothingIsPickedYet() async {
        let vm = preCreateModel()
        await vm.load()
        XCTAssertEqual(vm.people.map(\.userId), ["u1", "u2"])
        XCTAssertTrue(vm.people.allSatisfy { !$0.isShared })
        XCTAssertEqual(vm.access, .edit, "default grade is Can edit, as on the Share screen")
        XCTAssertTrue(draft.draft.isEmpty)
        XCTAssertEqual(shareDraftSummary(draft.draft.picks).text, "Only you")
    }

    func testATapHoldsThePickLocallyAtTheChosenGrade() async {
        let vm = preCreateModel()
        await vm.load()
        await vm.tap(vm.people[0])
        assertNothingReachedTheServer()
        XCTAssertEqual(draft.draft.userShares, [ShareDraftUserShare(userId: "u1", level: .partner)])
        XCTAssertEqual(draft.draft.picks.first?.name, "Maya Chen", "the name comes from the roster")
        XCTAssertEqual(vm.people[0].access, .edit, "the row shows the pick (reloaded from the draft)")
        XCTAssertEqual(vm.result, "Maya will get it when you add the task — they can edit.")
        XCTAssertNil(vm.error)

        vm.access = .view
        await vm.tap(vm.people[1])
        XCTAssertEqual(draft.draft.userShares, [ShareDraftUserShare(userId: "u1", level: .partner),
                                                ShareDraftUserShare(userId: "u2", level: .view)])
        XCTAssertEqual(shareDraftSummary(draft.draft.picks).text, "Maya · edit, Zubair · view")
        assertNothingReachedTheServer()
    }

    func testChangingAndRemovingAPickStaysLocal() async {
        let vm = preCreateModel()
        await vm.load()
        await vm.tap(vm.people[1])
        await vm.setAccess(vm.people[1], .view)
        XCTAssertEqual(draft.draft.userShares, [ShareDraftUserShare(userId: "u2", level: .view)])
        XCTAssertEqual(vm.result, "Zubair will be able to view.")
        await vm.setAccess(vm.people[1], nil)
        XCTAssertTrue(draft.draft.isEmpty)
        XCTAssertNil(vm.people[1].access)
        XCTAssertEqual(vm.result, "Zubair won't get it.")
        assertNothingReachedTheServer()
    }

    func testSomeoneNewQueuesTheAddressForSubmit() async {
        let vm = preCreateModel()
        await vm.load()
        vm.email = "  Sam@Example.com "
        await vm.shareWithEmail()
        assertNothingReachedTheServer()
        XCTAssertEqual(draft.draft.emailShares, [ShareDraftEmailShare(email: "sam@example.com", level: .partner)])
        XCTAssertEqual(vm.pending, [SharePendingRow(id: "email:sam@example.com", email: "sam@example.com", access: .edit)])
        XCTAssertEqual(vm.result, "sam@example.com will get it when you add the task.")
        XCTAssertEqual(vm.email, "", "the field clears after a queued address")

        await vm.cancelPending(vm.pending[0])
        XCTAssertTrue(draft.draft.isEmpty)
        XCTAssertTrue(vm.pending.isEmpty)
        XCTAssertEqual(vm.result, "sam@example.com won't get it.")
        assertNothingReachedTheServer()
    }

    func testAnAddressThatIsNotOneIsRefusedLocally() async {
        let vm = preCreateModel()
        await vm.load()
        vm.email = "not an email"
        await vm.shareWithEmail()
        XCTAssertEqual(vm.error, "That doesn't look like an email address.")
        XCTAssertTrue(draft.draft.isEmpty)
    }

    func testReopeningPinsThePicksWithTheirGrades() async {
        let first = preCreateModel()
        await first.load()
        await first.tap(first.people[1])
        // The sheet is closed and "Share with…" tapped again: a NEW model over
        // the SAME draft — the picks sit first, with their grade.
        let again = preCreateModel()
        await again.load()
        XCTAssertEqual(again.pinnedIds, [again.people[1].id])
        let split = sharePeopleSplit(again.people, pinned: again.pinnedIds, handOver: false)
        XCTAssertEqual(split.withAccess.map(\.userId), ["u2"])
        XCTAssertEqual(split.withAccess.first?.statusLabel, "Can edit")
        XCTAssertEqual(split.candidates.map(\.userId), ["u1"])
    }

    func testTheSelectionMapsToTheCallsSubmitMakes() async {
        let vm = preCreateModel()
        await vm.load()
        await vm.tap(vm.people[0])                     // Maya · Can edit
        vm.access = .view
        await vm.tap(vm.people[1])                     // Zubair · Can view
        vm.email = "sam@example.com"
        await vm.shareWithEmail()                      // sam · Can view
        await vm.setAccess(vm.people[0], .view)        // Maya → Can view
        // Exactly what NewTaskSheet.submit hands applyCreateShares.
        let shares = draft.draft.userShares.map { (user: $0.userId, level: $0.level) }
        let emails = draft.draft.emailShares.map { (email: $0.email, level: $0.level) }
        XCTAssertEqual(shares.map(\.user), ["u1", "u2"])
        XCTAssertEqual(shares.map(\.level), [.view, .view])
        XCTAssertEqual(emails.map(\.email), ["sam@example.com"])
        XCTAssertEqual(emails.map(\.level), [.view])
        XCTAssertEqual(shareDraftSummary(draft.draft.picks).text, "Maya, Zubair, sam · can view")
        assertNothingReachedTheServer()
    }

    func testTheInviteLinkIsAConnectInviteNotATaskLink() async {
        let vm = preCreateModel()
        await vm.load()
        let url = await vm.makeInviteLink()
        XCTAssertEqual(url, "https://unstucknow.io/circle/join?code=connect")
        XCTAssertEqual(fake.connectInvites, 1)
        XCTAssertTrue(fake.linkLevels.isEmpty, "the task can't ride on a link before it exists")
        XCTAssertEqual(vm.lastLink, url)
        XCTAssertTrue(vm.result?.hasPrefix("Invite link copied") == true)

        fake.connectInviteOutcome = .failed(reason: "circle_full")
        let none = await vm.makeInviteLink()
        XCTAssertNil(none)
        XCTAssertEqual(vm.error, "Your circle is full.")
        fake.connectInviteOutcome = .failed(reason: "invite_failed")
        _ = await vm.makeInviteLink()
        XCTAssertEqual(vm.error, "Couldn't make a link — try again.")
    }

    func testTheExistingTaskScreenIsUnchanged() async {
        // Same fake, NOT pre-create: a tap still shares on the server with
        // the server's line.
        let vm = ShareScreenModel(target: .task(id: "t1", name: "Draft the deck"), transport: fake)
        await vm.load()
        XCTAssertFalse(vm.preCreate)
        await vm.tap(vm.people[0])
        XCTAssertEqual(fake.sharedTask.count, 1)
        XCTAssertEqual(vm.result, "Shared with Maya — they can edit.")
    }

    func testTheAppModelHandsOutAnEmptyDraft() {
        let model = AppModel()
        model.startUITestMode()
        let d = model.makeShareDraftTransport()
        XCTAssertTrue(d.draft.isEmpty)
        XCTAssertEqual(shareDraftSummary(d.draft.picks), ShareDraftSummary(text: "Only you", spoken: "Only you"))
    }

    func testCreateSharesWithoutABackendReportTheAddressesAndNeverThrow() async {
        let model = AppModel()
        model.startUITestMode()
        let task = TaskItem(id: "t-new", name: "Buy stamps", estimateMin: 25, createdAt: AppModel.isoNow(), updatedAt: AppModel.isoNow())
        let none = await model.applyCreateShares(task: task, shares: [], emails: [])
        XCTAssertEqual(none, [])
        let failed = await model.applyCreateShares(task: task, shares: [], emails: [(email: "sam@example.com", level: .partner)])
        XCTAssertEqual(failed, ["sam@example.com"], "no coordinator ⇒ the address is reported, creation is untouched")
    }
}
