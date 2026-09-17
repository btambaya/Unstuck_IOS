// Unified sharing v1 — the app half (docs/unified-sharing-spec.md §4):
//   • ShareScreenModel over a fake transport — section composition, the
//     default grade, level mapping per backend, the honest result line per
//     status, error mapping, hand-over mode, the link;
//   • the deep-link routing of a SHARED task (an id not in my store opens
//     the shared-task sheet, not the owner editor) + `unstuck://collections/<id>`;
//   • the assistant's email-targeted confirm.
// Runs on the in-memory AppModel (UI-test mode: GRDB in memory, no coordinator).

import XCTest
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
    var blocked: Set<String> = []

    // Scripted answers.
    var shareTaskError: Error?
    var emailOutcome: TaskShareOutcome = .invited
    var collectionOutcome: ShareOutcome = .ok
    var linkOutcome: ShareLinkOutcome = .ok(url: "https://unstucknow.io/circle/join?code=xyz")
    var unshareOk = true

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
    func isBlocked(_ email: String) -> Bool { blocked.contains(email) }
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

        fake.blocked = ["bad@x.com"]
        vm.email = "bad@x.com"
        await vm.shareWithEmail()
        XCTAssertEqual(vm.error, "You've blocked that person.")
        XCTAssertTrue(fake.emailShares.isEmpty)

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
