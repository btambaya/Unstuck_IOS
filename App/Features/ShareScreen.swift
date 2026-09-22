// The ONE Share screen (unified sharing v1 — docs/unified-sharing-spec.md §2 /
// §4) for tasks AND collections. Replaces the old per-task ShareSheet
// (Off/View/Partner/Assign) and CollectionShareView (email + Can edit/Can view)
// with a single surface and a single vocabulary:
//
//   Share · <item name>            [Can edit | Can view]   (default Can edit)
//   PEOPLE        everyone you are connected to, in ONE card — one tap on a
//                 row shares at the chosen grade; already-shared people sit
//                 first, show their grade and open a picker (Can edit / Can
//                 view / Remove). Past three rows the card collapses behind
//                 "Show N more" (someone who already has it is never hidden);
//                 expanded lists of ten or more get a Find field. The pure
//                 rule is `sharePeopleLayout` (UnifiedSharing.swift).
//   SOMEONE NEW   email + Share — an existing account is shared with at once
//                 (the server pushes them), anyone else gets an invite email
//                 that is claimed when they sign up. Pending invites listed.
//   SHARE A LINK  a one-shot join link (system share sheet + clipboard) that
//                 connects whoever opens it AND grants the item in one step.
//
// Under the button, the line is TRUE to what the server did ("Shared with
// Maya — they can edit." vs "Invite sent to x@y — waiting for them to sign
// up." vs "Link copied — …"), and refusals are shown ("That's you.", "You've
// blocked that person.", the rate-limit copy).
//
// "Hand over to…" (level `assign`) is the same people picker in `.handOver`
// mode — no grade control, one button per person, and the explainer "it
// becomes their task; you keep view".
//
// ShareScreenModel talks to the backends through ShareScreenTransport (a
// seam so the model is unit-tested with a fake); LiveShareTransport wires
// it to CircleClient (task_share / task_unshare / roster), TaskShareClient
// (share-task add / list / remove / link) and CollectionShareClient
// (share-collection add / list / remove / link) via AppModel.

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckDesign
import UnstuckSync

// MARK: - what is being shared

/// The item a Share screen is opened for. Identifiable so a `.sheet(item:)`
/// can present it from any row / card / editor.
enum ShareTarget: Identifiable, Equatable, Hashable {
    case task(id: String, name: String)
    case collection(id: String, name: String)

    var id: String {
        switch self {
        case .task(let id, _): return "task:\(id)"
        case .collection(let id, _): return "collection:\(id)"
        }
    }
    var itemId: String {
        switch self {
        case .task(let id, _), .collection(let id, _): return id
        }
    }
    var name: String {
        switch self {
        case .task(_, let name), .collection(_, let name): return name
        }
    }
    var kind: ShareItemKind {
        switch self {
        case .task: return .task
        case .collection: return .collection
        }
    }
}

// MARK: - transport seam

/// Everything the Share screen does over the network, behind one protocol so
/// the screen model is testable with a fake. Every call reports what the
/// SERVER did (a refusal is never a fabricated success).
@MainActor
protocol ShareScreenTransport: AnyObject {
    /// `circle_list()` — active connections + pending circle invites.
    func listCircle() async -> [CircleMember]
    /// `task_shares_for_task` — who holds the task, at what level.
    func taskShares(taskId: String) async -> [ShareForTask]
    /// `share-task list` → pending email invites (tolerant → []).
    func taskPendingInvites(taskId: String) async -> [TaskSharePendingInvite]
    /// `task_share(p_task_id, p_user, p_level)` — throws on a server refusal.
    func shareTask(taskId: String, userId: String, level: ShareLevel) async throws
    /// `task_unshare` — true only when confirmed.
    func unshareTask(shareId: String) async -> Bool
    /// `share-task add` — shared / invited / failed(reason).
    func shareTaskByEmail(taskId: String, email: String, level: ShareLevel) async -> TaskShareOutcome
    /// `share-task remove {inviteId}` — true only when confirmed.
    func cancelTaskInvite(taskId: String, inviteId: String) async -> Bool
    /// `share-task link`.
    func taskLink(taskId: String, level: ShareLevel) async -> ShareLinkOutcome
    /// `share-notify task_share` — the recipient's in-app card + push after a
    /// by-id share (the edge function does this itself for `add`).
    func notifyTaskShare(taskId: String, recipientId: String) async
    /// `share-collection list`.
    func collectionMembers(collectionId: String) async -> [CollectionMemberInfo]
    /// `share-collection add` by email (Someone new) or by user id (People).
    func shareCollection(collectionId: String, email: String?, userId: String?, role: String) async -> ShareOutcome
    /// `share-collection remove {userId}` — true only when confirmed.
    func unshareCollection(collectionId: String, userId: String) async -> Bool
    /// `share-collection remove {email}` — true only when confirmed.
    func cancelCollectionInvite(collectionId: String, email: String) async -> Bool
    /// `share-collection link`.
    func collectionLink(collectionId: String, role: String) async -> ShareLinkOutcome
    /// `block_user(p_user)` (migration 075, App Store 1.2 safety) — true only
    /// when the server blocked them. Replaces the device-local blocklist that
    /// nothing server-side read (audit 2026-09-22, C10).
    func block(userId: String) async -> Bool
}

/// The live seam — AppModel's coordinator clients. A nil coordinator (demo /
/// UITest boot, signed out) degrades to empty reads and `not_configured`.
@MainActor
final class LiveShareTransport: ShareScreenTransport {
    private weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    func listCircle() async -> [CircleMember] {
        await model?.coordinator?.circle.listCircle() ?? []
    }
    func taskShares(taskId: String) async -> [ShareForTask] {
        await model?.coordinator?.circle.sharesForTask(taskId: taskId) ?? []
    }
    func taskPendingInvites(taskId: String) async -> [TaskSharePendingInvite] {
        await model?.coordinator?.taskShare.list(taskId: taskId).pending ?? []
    }
    func shareTask(taskId: String, userId: String, level: ShareLevel) async throws {
        guard let model, let circle = model.coordinator?.circle else { throw ShareTransportError.notSignedIn }
        try await circle.shareTask(taskId: taskId, user: userId, level: level)
        await model.shareState.refresh()   // badges / Delegated update at once
    }
    func unshareTask(shareId: String) async -> Bool {
        guard let model, let circle = model.coordinator?.circle else { return false }
        let ok = await circle.unshareTask(shareId: shareId)
        if ok { await model.shareState.refresh() }
        return ok
    }
    func shareTaskByEmail(taskId: String, email: String, level: ShareLevel) async -> TaskShareOutcome {
        guard let model, let ts = model.coordinator?.taskShare else { return .failed(reason: "not_configured") }
        let r = await ts.add(taskId: taskId, email: email, level: level)
        if case .shared = r { await model.shareState.refresh() }
        return r
    }
    func cancelTaskInvite(taskId: String, inviteId: String) async -> Bool {
        await model?.coordinator?.taskShare.cancelInvite(taskId: taskId, inviteId: inviteId) ?? false
    }
    func taskLink(taskId: String, level: ShareLevel) async -> ShareLinkOutcome {
        await model?.coordinator?.taskShare.link(taskId: taskId, level: level) ?? .failed(reason: "not_configured")
    }
    func notifyTaskShare(taskId: String, recipientId: String) async {
        await model?.shareState.notifyShare(taskId: taskId, recipientId: recipientId)
    }
    func collectionMembers(collectionId: String) async -> [CollectionMemberInfo] {
        await model?.listCollectionMembers(collectionId) ?? []
    }
    func shareCollection(collectionId: String, email: String?, userId: String?, role: String) async -> ShareOutcome {
        await model?.shareCollection(collectionId, email: email, userId: userId, role: role) ?? .error
    }
    func unshareCollection(collectionId: String, userId: String) async -> Bool {
        await model?.unshareCollection(collectionId, userId: userId) ?? false
    }
    func cancelCollectionInvite(collectionId: String, email: String) async -> Bool {
        await model?.cancelCollectionInvite(collectionId, email: email) ?? false
    }
    func collectionLink(collectionId: String, role: String) async -> ShareLinkOutcome {
        await model?.coordinator?.share.link(collectionId: collectionId, role: role) ?? .failed(reason: "not_configured")
    }
    func block(userId: String) async -> Bool { await model?.blockUser(userId: userId) ?? false }
}

enum ShareTransportError: Error { case notSignedIn }

// MARK: - screen model

/// State + actions of the Share screen. @MainActor @Observable; every action
/// is serialised on `busyId` (one in-flight write at a time) and ends with a
/// roster reload so the rows show the server's truth, never an optimistic
/// guess. Refreshes on the live collab signals (a share row / a connection
/// of mine changed — e.g. the invitee just joined) and on foreground.
@MainActor
@Observable
final class ShareScreenModel {
    enum Mode: Equatable { case share, handOver }

    let target: ShareTarget
    let mode: Mode
    @ObservationIgnored private let transport: any ShareScreenTransport

    /// The grade the next share uses (People tap, Someone new, the link).
    var access: ShareAccess = .edit
    /// The Someone-new field.
    var email = ""
    private(set) var people: [SharePersonRow] = []
    private(set) var pending: [SharePendingRow] = []
    private(set) var loading = true
    /// The row (or "email" / "link") with a write in flight.
    private(set) var busyId: String?
    /// The honest line under the button after the last successful action.
    private(set) var result: String?
    /// The shown refusal / failure after the last action.
    private(set) var error: String?
    /// The last join link minted (the view hands it to the system share sheet).
    private(set) var lastLink: String?
    /// The ids that already held the item when this screen opened. Fixed by
    /// the FIRST load and never recomputed, so a row you just shared changes
    /// its monogram and its trailing word IN PLACE and only floats to the top
    /// the next time the sheet is opened. In hand-over mode only a hand-over
    /// pins. The view orders + collapses with `sharePeopleLayout`; `people`
    /// itself keeps roster order.
    private(set) var pinnedIds: Set<String> = []
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var circle: [CircleMember] = []

    static let emailBusyId = "email"
    static let linkBusyId = "link"

    init(target: ShareTarget, mode: Mode = .share, transport: any ShareScreenTransport) {
        self.target = target
        self.mode = mode
        self.transport = transport
    }

    /// Subscribe to the live signals (once) + load. Idempotent.
    func start() {
        if observers.isEmpty {
            let names: [Notification.Name] = [
                .unstuckCollabCircleChanged, .unstuckCollabSharesChanged, .unstuckCollabConnectionActivated,
                UIApplication.willEnterForegroundNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in await self?.load() }
                })
            }
        }
        Task { await load() }
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    /// Re-read the roster + the item's grants and compose the sections.
    func load() async {
        let circle = await transport.listCircle()
        self.circle = circle
        switch target {
        case .task(let id, _):
            let shares = await transport.taskShares(taskId: id)
            let invites = await transport.taskPendingInvites(taskId: id)
            let grants = shares.map { s in
                ShareExistingGrant(userId: s.recipientUserId, name: s.recipientName, email: nil,
                                   access: ShareAccess(taskLevel: s.level), handedOver: s.level == .assign,
                                   shareId: s.shareId)
            }
            people = composeSharePeople(circle: circle, grants: grants)
            pending = invites.map { SharePendingRow(id: $0.id, email: $0.email, access: ShareAccess(taskLevel: $0.level) ?? .edit) }
        case .collection(let id, _):
            let members = await transport.collectionMembers(collectionId: id)
            let grants = members.filter { !$0.pending && !$0.userId.isEmpty }.map { m in
                ShareExistingGrant(userId: m.userId, name: nil, email: m.email,
                                   access: ShareAccess(collectionRole: m.role), handedOver: false, shareId: nil)
            }
            people = composeSharePeople(circle: circle, grants: grants)
            pending = members.filter(\.pending).map {
                SharePendingRow(id: "pending:\($0.email)", email: $0.email, access: ShareAccess(collectionRole: $0.role))
            }
        }
        loading = false
        if !pinned, !people.isEmpty {
            pinned = true
            pinnedIds = Set(people.filter { mode == .handOver ? $0.handedOver : $0.isShared }.map(\.id))
        }
    }

    // MARK: people

    /// One tap on a person: share at `access` (share mode) or hand the task
    /// over (hand-over mode). An already-shared person in share mode is
    /// changed through `setAccess` (the row's picker) — a bare tap is a no-op.
    func tap(_ row: SharePersonRow) async {
        guard busyId == nil else { return }
        switch mode {
        case .handOver:
            guard case .task(let id, _) = target else { return }
            await perform(row.id) {
                try await self.transport.shareTask(taskId: id, userId: row.userId, level: .assign)
                await self.transport.notifyTaskShare(taskId: id, recipientId: row.userId)
                return .handedOver(name: row.name)
            }
        case .share:
            guard !row.isShared else { return }
            await grant(row, access: access, isNew: true)
        }
    }

    /// Change what a shared person has; nil = remove them.
    func setAccess(_ row: SharePersonRow, _ next: ShareAccess?) async {
        guard busyId == nil else { return }
        guard let next else { await remove(row); return }
        await grant(row, access: next, isNew: !row.isShared)
    }

    private func grant(_ row: SharePersonRow, access: ShareAccess, isNew: Bool) async {
        switch target {
        case .task(let id, _):
            await perform(row.id) {
                try await self.transport.shareTask(taskId: id, userId: row.userId, level: access.taskLevel)
                if isNew { await self.transport.notifyTaskShare(taskId: id, recipientId: row.userId) }
                return isNew ? .shared(name: row.name, access: access) : .accessChanged(name: row.name, access: access)
            }
        case .collection(let id, _):
            await perform(row.id) {
                let outcome = await self.transport.shareCollection(collectionId: id, email: row.email, userId: row.userId,
                                                                   role: access.collectionRole)
                switch outcome {
                case .ok, .accepted:
                    return isNew ? .shared(name: row.name, access: access) : .accessChanged(name: row.name, access: access)
                case .invited:
                    return .invited(email: row.email ?? row.name)
                case .invalid where row.email == nil:
                    // `share-collection add` now takes `{userId}` (v22, verified
                    // live 2026-09-17), so this is only the fallback for an older
                    // deployment that resolves emails only — say what to do then.
                    throw ShareActionError(.listNeedsEmail)
                default:
                    throw ShareActionError(ShareFailure(reason: outcome.failureReason))
                }
            }
        }
    }

    private func remove(_ row: SharePersonRow) async {
        switch target {
        case .task:
            guard let shareId = row.shareId else { return }
            await perform(row.id) {
                guard await self.transport.unshareTask(shareId: shareId) else { throw ShareActionError(.network) }
                return .removed(name: row.name)
            }
        case .collection(let id, _):
            await perform(row.id) {
                guard await self.transport.unshareCollection(collectionId: id, userId: row.userId) else { throw ShareActionError(.network) }
                return .removed(name: row.name)
            }
        }
    }

    /// Block someone who has this item (task OR list). Server-side the block
    /// cuts everything between you — the connection, task shares and list
    /// memberships both ways — and refuses anything they share with you until
    /// you unblock them in Settings › People. The old block was device-local,
    /// lists-only, and reloaded BEFORE its removal ran with no failure path, so
    /// the person often still showed "Can edit"; now the reload follows the
    /// server's answer and a refusal says the BLOCK didn't land, not that a
    /// share failed (audit 2026-09-22, C10).
    func block(_ row: SharePersonRow) async {
        guard busyId == nil else { return }
        await perform(row.id) {
            guard await self.transport.block(userId: row.userId) else { throw ShareActionError(.blockFailed(name: row.name)) }
            return .blocked(name: row.name)
        }
    }

    // MARK: someone new

    /// Share with the typed email. The address shape is checked locally; a
    /// block is the server's answer (`blocked`), not a device-local list.
    func shareWithEmail() async {
        guard busyId == nil else { return }
        // Put the keyboard away first: it covers the result line, and the
        // answer to "did that work?" is the whole point of the screen.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let addr = normalizedShareEmail(email)
        error = nil
        guard isEmailLike(addr) else { error = ShareFailure.invalidEmail.message; return }
        switch target {
        case .task(let id, _):
            await perform(Self.emailBusyId) {
                switch await self.transport.shareTaskByEmail(taskId: id, email: addr, level: self.access.taskLevel) {
                case .shared(_, let displayName):
                    return .shared(name: displayName.isEmpty ? addr : displayName, access: self.access)
                case .invited:
                    return .invited(email: addr)
                case .failed(let reason):
                    throw ShareActionError(ShareFailure(reason: reason))
                }
            }
        case .collection(let id, _):
            await perform(Self.emailBusyId) {
                let outcome = await self.transport.shareCollection(collectionId: id, email: addr, userId: nil,
                                                                   role: self.access.collectionRole)
                switch outcome {
                case .ok: return .shared(name: addr, access: self.access)
                case .invited: return .invited(email: addr)
                // `share-collection add` doesn't say shared-vs-invited (by
                // design) — a neutral line that is still true.
                case .accepted: return .accepted(email: addr)
                default: throw ShareActionError(ShareFailure(reason: outcome.failureReason))
                }
            }
        }
        if error == nil { email = "" }
    }

    /// Cancel a pending email invite.
    func cancelPending(_ row: SharePendingRow) async {
        guard busyId == nil else { return }
        switch target {
        case .task(let id, _):
            await perform(row.id) {
                guard await self.transport.cancelTaskInvite(taskId: id, inviteId: row.id) else { throw ShareActionError(.network) }
                return .inviteCancelled(email: row.email)
            }
        case .collection(let id, _):
            await perform(row.id) {
                guard await self.transport.cancelCollectionInvite(collectionId: id, email: row.email) else { throw ShareActionError(.network) }
                return .inviteCancelled(email: row.email)
            }
        }
    }

    // MARK: link

    /// Mint a one-shot join link at `access`. Returns it (the view copies it
    /// + hands it to the system share sheet) and sets the "Link copied" line.
    @discardableResult
    func makeLink() async -> String? {
        guard busyId == nil else { return nil }
        busyId = Self.linkBusyId
        error = nil
        defer { busyId = nil }
        let outcome: ShareLinkOutcome
        switch target {
        case .task(let id, _): outcome = await transport.taskLink(taskId: id, level: access.taskLevel)
        case .collection(let id, _): outcome = await transport.collectionLink(collectionId: id, role: access.collectionRole)
        }
        switch outcome {
        case .ok(let url):
            lastLink = url
            result = shareResultLine(.linkCopied(kind: target.kind))
            return url
        case .failed(let reason):
            error = ShareFailure(reason: reason).message
            return nil
        }
    }

    // MARK: plumbing

    /// Run one write under `busyId`, translate its outcome into the result /
    /// error lines, then reload so the rows show the server's state.
    private func perform(_ id: String, _ op: @MainActor () async throws -> ShareResult) async {
        busyId = id
        error = nil
        defer { busyId = nil }
        do {
            let r = try await op()
            result = shareResultLine(r)
        } catch let e as ShareActionError {
            error = e.failure.message
        } catch {
            self.error = Self.failure(from: error).message
        }
        await load()
    }

    /// A thrown RPC error → failure. PostgREST surfaces the function's `raise
    /// exception '<code>'` in its message; CircleClient extracts it.
    static func failure(from error: Error) -> ShareFailure {
        if error is ShareTransportError { return .notSignedIn }
        return ShareFailure(reason: CircleClient.rpcFailureReason(error))
    }
}

/// An action's refusal, carried through `perform`.
struct ShareActionError: Error {
    let failure: ShareFailure
    init(_ failure: ShareFailure) { self.failure = failure }
}

// MARK: - the screen

struct ShareScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The monogram disc — scaled with the body text so the letter never
    /// overflows its circle at accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var monogramSize: CGFloat = 22
    let target: ShareTarget
    var mode: ShareScreenModel.Mode = .share

    @State private var vm: ShareScreenModel?
    @State private var linkToShare: ShareLinkItem?
    @State private var reportTarget: SharePersonRow?
    /// The row whose "Block…" is awaiting its confirm.
    @State private var blockTarget: SharePersonRow?
    /// The searchable "Choose someone" picker (Ahmad, 2026-09-17: never list
    /// everyone — ten people is a wall; a dropdown you can search).
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let vm {
                        if mode == .share { accessControl(vm) }
                        // The honest line lives HIGH on the screen. It used to
                        // be the last row — below the fold and, after a
                        // "Someone new" share, behind the keyboard — so the one
                        // answer §2 promises ("Shared with …" / "Invite sent
                        // to …") was invisible in the commonest path.
                        feedback(vm)
                        peopleSection(vm)
                        if mode == .share {
                            someoneNewSection(vm)
                            linkSection(vm)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle(mode == .share ? "Share" : "Hand over")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .task {
            let m = vm ?? model.makeShareScreenModel(target: target, mode: mode)
            vm = m
            m.start()
        }
        .onDisappear { vm?.stop() }
        .sheet(item: $linkToShare) { item in
            ShareActivitySheet(url: item.url).presentationDetents([.medium, .large])
        }
        .confirmationDialog("Report this person?", isPresented: Binding(
            get: { reportTarget != nil }, set: { if !$0 { reportTarget = nil } }),
            titleVisibility: .visible, presenting: reportTarget) { row in
            ForEach(["Objectionable content", "Spam", "Harassment", "Other"], id: \.self) { reason in
                Button(reason) {
                    let who = row.email ?? row.name
                    Task { await model.reportShareConcern(target: target, about: who, reason: reason) }
                    reportTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { reportTarget = nil }
        } message: { row in
            Text("Send a report about \(row.email ?? row.name) to the Unstuck team. We review reports and take action.")
        }
        .confirmationDialog("Block \(blockTarget?.name ?? "them")?", isPresented: Binding(
            get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } }),
            titleVisibility: .visible, presenting: blockTarget) { row in
            Button("Block", role: .destructive) {
                blockTarget = nil
                if let vm { Task { await vm.block(row) } }
            }
            Button("Cancel", role: .cancel) { blockTarget = nil }
        } message: { _ in
            Text("They won't be able to share tasks or lists with you, and everything shared between you stops. You can unblock them in Settings › People.")
        }
    }

    // MARK: header + grade

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(target.name.isEmpty ? (target.kind == .task ? "Untitled task" : "Untitled list") : target.name)
                .font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(mode == .share
                 ? "Anyone you share with sees this \(target.kind.noun) in their “Shared with you”."
                 : handOverExplainer)
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func accessControl(_ vm: ShareScreenModel) -> some View {
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Access", selection: $vm.access) {
                ForEach(ShareAccess.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Access level")
            Text(vm.access.blurb(for: target.kind))
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: people

    /// The People card. Rows abut inside ONE 12pt surface card (the Share
    /// screen's own card radius — `linkSection` / `pendingRow`), divided by
    /// `CardDivider`. Order + collapse + search are the pure
    /// The section shows ONLY the people who already have the item (usually
    /// none to a few), each a row with its access menu, and one "Choose
    /// someone" control that opens a searchable picker of everyone else.
    /// Nobody's whole roster is ever listed inline (Ahmad, 2026-09-17).
    @ViewBuilder
    private func peopleSection(_ vm: ShareScreenModel) -> some View {
        let split = sharePeopleSplit(vm.people, pinned: vm.pinnedIds, handOver: mode == .handOver)
        let noun = mode == .share ? "People" : "Hand over to"
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(split.withAccess.isEmpty ? noun : "\(noun) · \(split.withAccess.count)")
                .accessibilityLabel("\(noun), \(split.withAccess.count)")
            if vm.loading && vm.people.isEmpty {
                Text("Loading…").font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
            } else if vm.people.isEmpty {
                Text(mode == .share
                     ? "No one yet — add someone by email below, or share a link."
                     : "No one to hand this to yet — connect with someone from the Share screen first.")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(split.withAccess.enumerated()), id: \.element.id) { idx, row in
                        if idx > 0 { CardDivider() }
                        personRow(vm, row)
                    }
                    if !split.candidates.isEmpty {
                        if !split.withAccess.isEmpty { CardDivider() }
                        chooseRow(vm, count: split.candidates.count)
                    }
                }
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.palette.line))
                .accessibilityElement(children: .contain)
            }
        }
        .sheet(isPresented: $showPicker) {
            PeoplePickerSheet(title: mode == .share ? "Share with" : "Hand over to",
                              action: mode == .share ? "Share" : "Hand over",
                              people: split.candidates) { row in
                showPicker = false
                Task { await vm.tap(row) }
            }
        }
    }

    /// The dropdown: "Choose someone ⌄" — opens the searchable picker.
    private func chooseRow(_ vm: ShareScreenModel, count: Int) -> some View {
        Button { showPicker = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 18, weight: .regular)).foregroundStyle(theme.palette.ink2)
                    .frame(width: monogramSize, height: monogramSize)
                Text(mode == .share ? "Choose someone" : "Choose who gets it")
                    .font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                Text("· \(count)").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.ink3)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(vm.busyId != nil)
        .opacity(vm.busyId != nil ? 0.6 : 1)
        .accessibilityLabel("Choose someone, \(count) people")
        .accessibilityHint("Opens a searchable list")
    }

    /// One 44pt row. The WHOLE row is the control (a Button that shares /
    /// hands over, or the Menu for someone who already has it) — semantics
    /// identical to the old per-row pill: a busy row is inert, the hand-over
    /// holder's row is inert (a state, not a dimmed control), every other row
    /// dims while a write is in flight.
    private func personRow(_ vm: ShareScreenModel, _ row: SharePersonRow) -> some View {
        let busy = vm.busyId == row.id
        return Group {
            if busy {
                personRowContent(vm, row, busy: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.name), working")
                    .accessibilityAddTraits(.updatesFrequently)
            } else if mode == .handOver, row.handedOver {
                // The holder is a STATE, not a dimmed control: plain content
                // (a disabled Button would grey the whole row, monogram included).
                personRowContent(vm, row, busy: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.name), already handed over")
            } else if mode == .handOver {
                Button { Task { await vm.tap(row) } } label: { personRowContent(vm, row, busy: false) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hand over to \(row.name)")
            } else if row.isShared {
                Menu { accessMenu(vm, row) } label: { personRowContent(vm, row, busy: false) }
                    .buttonStyle(.plain)
                    .disabled(vm.busyId != nil)   // a second tap must not open the menu mid-write
                    .accessibilityLabel("\(row.name), \(row.statusLabel ?? "shared"). Change access")
                    .accessibilityHint("Report or remove them")
            } else {
                Button { Task { await vm.tap(row) } } label: { personRowContent(vm, row, busy: false) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share with \(row.name), \(vm.access.label)")
            }
        }
        .opacity(vm.busyId != nil && !busy ? 0.6 : 1)
    }

    /// monogram · name · relationship … trailing word. At accessibility text
    /// sizes the row becomes two lines (monogram · VStack{name, trailing}) with
    /// wrapping texts — the `waitingRowLineLimit` idiom from People.
    private func personRowContent(_ vm: ShareScreenModel, _ row: SharePersonRow, busy: Bool) -> some View {
        let ax = typeSize.isAccessibilitySize
        let on = mode == .handOver ? row.handedOver : row.isShared
        return HStack(alignment: ax ? .top : .center, spacing: 10) {
            monogram(row, on: on)
            if ax {
                VStack(alignment: .leading, spacing: 4) {
                    nameLine(row, ax: true)
                    trailing(vm, row, busy: busy)
                }
            } else {
                nameLine(row, ax: false)
                Spacer(minLength: 8)
                trailing(vm, row, busy: busy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, ax ? 12 : 0)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The app's selected / unselected pair: filled `ink` with a `bg` letter
    /// when they hold the item, `bg2` / `ink2` with a `line2` ring when not
    /// (Ahmad, 2026-09-17: selection is black-and-white everywhere; coral is
    /// only the brand accent — the + button, Focus, the orb). Colour is never the only signal — the trailing word says the
    /// same thing.
    private func monogram(_ row: SharePersonRow, on: Bool) -> some View {
        Text(String(row.name.prefix(1)).uppercased())
            .font(UFont.sans(10, .semibold))
            .foregroundStyle(on ? theme.palette.bg : theme.palette.ink2)
            .frame(width: monogramSize, height: monogramSize)
            .background(on ? theme.palette.ink : theme.palette.bg2, in: Circle())
            .overlay(Circle().stroke(on ? Color.clear : theme.palette.line2))
            .accessibilityHidden(true)
    }

    /// Name + the relationship label ("· Coach"). The email is NOT shown on
    /// the row: it only exists for a legacy list member, it is long, and it
    /// already appears in the report dialog. One line at normal sizes —
    /// `layoutPriority(1)` (the OUTERMOST modifier, or the HStack never sees
    /// it) makes the label truncate first.
    /// At accessibility sizes the two STACK: side by side, a full-width name
    /// left the label one character wide, wrapping letter by letter.
    @ViewBuilder
    private func nameLine(_ row: SharePersonRow, ax: Bool) -> some View {
        if ax {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = row.subtitle {
                    Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(spacing: 6) {
                Text(row.name).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let sub = row.subtitle {
                    Text("· \(sub)").font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Exactly one of: the action word ("Share" / "Hand over", `ink`
    /// semibold), the state word ("Can edit" / "Can view" / "Handed over",
    /// `ink2` + a chevron because it opens the menu), the disabled hand-over
    /// state (`ink3`), or the busy spinner. Every Text / Image sets its own
    /// foreground: a Menu label otherwise inherits the accent tint.
    @ViewBuilder
    private func trailing(_ vm: ShareScreenModel, _ row: SharePersonRow, busy: Bool) -> some View {
        if busy {
            ProgressView().controlSize(.small).tint(theme.palette.ink2)
        } else if mode == .handOver {
            if row.handedOver {
                Text(row.statusLabel ?? "Handed over").font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Hand over").font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(theme.palette.ink, in: Capsule())
            }
        } else if row.isShared {
            HStack(spacing: 4) {
                Text(row.statusLabel ?? "Shared").font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.bg)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(theme.palette.ink, in: Capsule())
        } else {
            Text("Share").font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(theme.palette.ink, in: Capsule())
        }
    }

    /// The picker for someone who already has the item: Can edit ✓ / Can
    /// view / Report… / Block… / Remove or "Take it back". Block is offered
    /// on EVERY shared row, task or list, and confirms first — it used to be
    /// lists-with-an-email only (audit 2026-09-22, C10).
    /// System menus own their colours — not restyled.
    @ViewBuilder
    private func accessMenu(_ vm: ShareScreenModel, _ row: SharePersonRow) -> some View {
        ForEach(ShareAccess.allCases, id: \.self) { a in
            Button {
                Task { await vm.setAccess(row, a) }
            } label: {
                if row.access == a { Label(a.label, systemImage: "checkmark") } else { Text(a.label) }
            }
        }
        Divider()
        if row.email != nil || target.kind == .task {
            Button { reportTarget = row } label: { Label("Report…", systemImage: "flag") }
        }
        Button(role: .destructive) { blockTarget = row } label: {
            Label("Block \(row.name)…", systemImage: "hand.raised")
        }
        Button(role: .destructive) {
            Task { await vm.setAccess(row, nil) }
        } label: { Label(row.handedOver ? "Take it back" : "Remove", systemImage: "xmark") }
    }

    /// The Find field — the unselected chip capsule stretched to a field.
    /// Only when EXPANDED with ten or more people, and never auto-focused:
    /// the default collapsed view must not put a second text field 40pt
    /// above the "Someone new" email field.
    // MARK: someone new

    private func someoneNewSection(_ vm: ShareScreenModel) -> some View {
        @Bindable var vm = vm
        let busy = vm.busyId == ShareScreenModel.emailBusyId
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Someone new")
            HStack(spacing: 8) {
                TextField("name@example.com", text: $vm.email)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit { Task { await vm.shareWithEmail() } }
                    .accessibilityLabel("Email address")
                Button { Task { await vm.shareWithEmail() } } label: {
                    // `bg` on `ink` (the app's filled-chip pair) — a literal
                    // white on dark `ink` (L 0.96) was invisible in dark mode.
                    Text(busy ? "Sharing…" : "Share").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.bg)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(theme.palette.ink, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy || vm.email.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Share by email")
            }
            Text("Has an account? They get it right away. No account yet? We email them an invite — it's theirs the moment they sign up.")
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if !vm.pending.isEmpty {
                VStack(spacing: 6) {
                    ForEach(vm.pending) { p in pendingRow(vm, p) }
                }
            }
        }
    }

    private func pendingRow(_ vm: ShareScreenModel, _ p: SharePendingRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.email).font(UFont.sans(13)).foregroundStyle(theme.palette.ink2).lineLimit(1)
                Text("Invited · waiting for them to sign up · \(p.access.label.lowercased())")
                    .font(UFont.sans(11)).foregroundStyle(theme.palette.amberInk)
            }
            Spacer(minLength: 8)
            if vm.busyId == p.id {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await vm.cancelPending(p) } } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.ink3)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel invite to \(p.email)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: link

    private func linkSection(_ vm: ShareScreenModel) -> some View {
        let busy = vm.busyId == ShareScreenModel.linkBusyId
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Share a link")
            Button {
                Task {
                    if let url = await vm.makeLink() {
                        UIPasteboard.general.string = url
                        if let u = URL(string: url) { linkToShare = ShareLinkItem(url: u) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "link").font(.system(size: 13, weight: .semibold))
                    Text(busy ? "Making a link…" : "Share a link").font(UFont.sans(14, .medium))
                    Spacer()
                    Image(systemName: "square.and.arrow.up").font(.system(size: 13))
                }
                .foregroundStyle(theme.palette.ink)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.palette.line))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel("Share a link, \(vm.access.label)")
            .accessibilityHint("Whoever opens it is connected to you and gets this \(target.kind.noun)")
            Text("Whoever opens it is connected to you and gets this \(target.kind.noun) — \(vm.access.label.lowercased()). The link works once and expires in 14 days.")
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: result / error

    @ViewBuilder
    private func feedback(_ vm: ShareScreenModel) -> some View {
        if let e = vm.error {
            Text(e).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        } else if let r = vm.result {
            Text("✓ \(r)").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.greenInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// A minted join link, wrapped so `.sheet(item:)` can present the system
/// share sheet for it.
struct ShareLinkItem: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The system share sheet (UIActivityViewController) for a join link.
private struct ShareActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The searchable dropdown behind "Choose someone": a system list of everyone
/// you are connected to who does NOT have the item yet, a search field, one
/// tap to share / hand over. Medium detent, grows to large.
private struct PeoplePickerSheet: View {
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let title: String
    let action: String
    let people: [SharePersonRow]
    let onPick: (SharePersonRow) -> Void
    @State private var query = ""

    private var rows: [SharePersonRow] { sharePeopleCandidates(people, query: query) }

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    Text(people.isEmpty ? "Everyone you're connected to already has it."
                                        : "No one matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                        .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(rows) { row in
                        Button { onPick(row) } label: {
                            HStack(spacing: 12) {
                                Text(String(row.name.prefix(1)).uppercased())
                                    .font(UFont.sans(11, .semibold)).foregroundStyle(theme.palette.ink2)
                                    .frame(width: 30, height: 30)
                                    .background(theme.palette.bg2, in: Circle())
                                    .overlay(Circle().stroke(theme.palette.line2))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).font(UFont.sans(15, .medium)).foregroundStyle(theme.palette.ink)
                                    if let sub = row.subtitle {
                                        Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(action).font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(theme.palette.ink, in: Capsule())
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(action) with \(row.name)")
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search people")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .background(theme.palette.bg)
        }
        .presentationDetents([.medium, .large])
    }
}
