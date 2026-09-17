// People / Connections — the iOS port of the web SharingPanel roster
// (components/settings/sharing-panel.tsx + lib/use-circle.ts). Your trusted
// circle: the people you share tasks + lists with. Reached from Settings ›
// People. Everyone you invite or who redeems your link lands here — one place,
// no double invites. You share a *specific* task from the task itself (M2); this
// screen is where you add / remove people and re-copy pending invite links.
//
// State comes from the CircleClient's SECURITY DEFINER RPCs. CircleModel mirrors
// the web `useCircle` hook: it holds the roster + refetches on the live collab
// signals (so a friend accepting your invite, or a shared collection connecting
// you, updates the list without a manual reload).
//
// Unified sharing v1 (spec §2 "One place for people"): the screen ALSO lists
// every email invite you sent from anywhere — a task's Share screen
// (`task_invites`), a list's (`collection_invites`) or "Add someone" here
// (`trusted_circle` invited-with-address) — under "Waiting to join", from ONE
// RPC (`my_pending_invites()`), each with a Cancel (`cancel_pending_invite`).
// The model talks to the backend through PeopleTransport (a seam, like
// ShareScreenTransport) so it is unit-tested with a fake; LivePeopleTransport
// wires it to CircleClient via AppModel.makeCircleModel().

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckDesign
import UnstuckSync

// MARK: - transport seam

/// Everything the People screen does over the network, behind one protocol
/// so CircleModel is unit-tested with a fake. Reads are tolerant (empty on
/// failure); the cancel reports what the SERVER did.
@MainActor
protocol PeopleTransport: AnyObject {
    /// `circle_list()` — active connections + pending circle invites.
    func listCircle() async -> [CircleMember]
    /// `circle-invite` edge fn — an email is emailed / added; blank → a link.
    func invite(email: String?) async -> CircleInviteResult
    /// `circle_redeem(p_code)` — join someone else's circle.
    func redeem(code: String) async -> CircleRedeemResult
    /// `circle_remove(p_id)` — a member, or a pending roster row.
    func removeMember(id: String) async
    /// `my_pending_invites()` — every invite I sent, all kinds (tolerant → []).
    func myPendingInvites() async -> [PendingInvite]
    /// `cancel_pending_invite(p_kind, p_id)` — true only when a row was deleted.
    func cancelPendingInvite(kind: PendingInviteKind, id: String) async -> Bool
}

/// The live seam over the shared CircleClient. A nil client (unconfigured /
/// demo boot, signed out) degrades to empty reads + `not_configured` —
/// mirrors the web `useCircle` no-`sb` guard.
@MainActor
final class LivePeopleTransport: PeopleTransport {
    private let client: CircleClient?

    init(client: CircleClient?) { self.client = client }

    func listCircle() async -> [CircleMember] { await client?.listCircle() ?? [] }
    func invite(email: String?) async -> CircleInviteResult {
        guard let client else { return CircleInviteResult(ok: false, error: "not_configured") }
        return await client.invite(email: email)
    }
    func redeem(code: String) async -> CircleRedeemResult {
        guard let client else { return CircleRedeemResult(ok: false, error: "not_configured") }
        return await client.redeem(code: code)
    }
    func removeMember(id: String) async { await client?.removeMember(id: id) }
    func myPendingInvites() async -> [PendingInvite] { await client?.myPendingInvites() ?? [] }
    func cancelPendingInvite(kind: PendingInviteKind, id: String) async -> Bool {
        await client?.cancelPendingInvite(kind: kind, id: id) ?? false
    }
}

// MARK: - model

/// Live trusted-circle roster + every pending invite I sent + mutations.
/// @MainActor @Observable so SwiftUI tracks `roster` / `waiting` / `loading`
/// directly — the iOS analogue of the web `useCircle()` hook.
@MainActor
@Observable
final class CircleModel {
    @ObservationIgnored private let transport: any PeopleTransport
    /// Everything `circle_list()` returned (active + pending) — the source for
    /// pickers elsewhere (NewTaskSheet reads the active ones).
    var members: [CircleMember] = []
    /// The rows the People list shows: `members` minus the pending circle
    /// invites that are listed under Waiting to join (never twice).
    private(set) var roster: [CircleMember] = []
    /// Waiting to join — every invite I sent that is still unclaimed, from
    /// `my_pending_invites()`, newest first, composed with the roster.
    private(set) var waiting: [PendingInvite] = []
    var loading = true
    /// The line under Waiting to join after a refused cancel.
    private(set) var waitingError: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(transport: any PeopleTransport) { self.transport = transport }

    /// Start observing the live collab signals (a connection of mine changed /
    /// went active, a share row changed) + foreground, and do the first fetch.
    /// Idempotent (guards a double-subscribe when the view re-appears).
    func start() {
        if observers.isEmpty {
            let names: [Notification.Name] = [
                .unstuckCollabCircleChanged, .unstuckCollabSharesChanged, .unstuckCollabConnectionActivated,
                UIApplication.willEnterForegroundNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in await self?.refresh() }
                })
            }
        }
        Task { await refresh() }
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    /// Re-read the roster + the pending invites and compose the two lists.
    func refresh() async {
        let circle = await transport.listCircle()
        let pending = await transport.myPendingInvites()
        members = circle
        let sections = composePeopleSections(circle: circle, pending: pending)
        roster = sections.roster
        waiting = sections.waiting
        loading = false
    }

    /// Invite by email (we email them) or blank → a shareable link. Refetches
    /// after (an existing account is added to the roster immediately; a new
    /// address lands under Waiting to join).
    func invite(email: String?) async -> CircleInviteResult {
        let r = await transport.invite(email: email)
        await refresh()
        return r
    }

    /// Redeem someone else's invite code → join their circle. Refetch only on
    /// success (a failed redeem leaves your own roster unchanged).
    func redeem(code: String) async -> CircleRedeemResult {
        let r = await transport.redeem(code: code)
        if r.ok { await refresh() }
        return r
    }

    /// Remove someone (or cancel a pending roster row). Server-side this also
    /// drops the task shares for the pair. Optimistic + refetch.
    func remove(id: String) async {
        members.removeAll { $0.id == id }
        roster.removeAll { $0.id == id }
        await transport.removeMember(id: id)
        await refresh()
    }

    /// Cancel a Waiting-to-join invite (`cancel_pending_invite`). Optimistic —
    /// the row leaves at once — then the refetch shows the server's truth: a
    /// refused cancel brings the row back with a line saying so. Returns
    /// whether the server deleted it.
    @discardableResult
    func cancelPending(_ p: PendingInvite) async -> Bool {
        waitingError = nil
        waiting.removeAll { $0.id == p.id }
        let ok = await transport.cancelPendingInvite(kind: p.kind, id: p.inviteId)
        if !ok { waitingError = "Couldn't cancel that invite — try again." }
        await refresh()
        return ok
    }

    /// People who count toward "connected" — active members + pending invites
    /// (mirrors the web `activeCount`).
    var activeCount: Int {
        members.filter { $0.status == "active" || $0.status == "invited" }.count
    }

    /// The count on the People label — the rows actually listed there.
    var rosterCount: Int {
        roster.filter { $0.status == "active" || $0.status == "invited" }.count
    }
}

/// The join link the inviter shares — same shape the circle-invite edge fn
/// returns (`APP_URL/circle/join?code=…`, APP_URL = unstucknow.io in prod).
func circleInviteLink(_ code: String) -> String {
    "https://unstucknow.io/circle/join?code=\(code)"
}

// MARK: - Screen

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @State private var vm: CircleModel?

    var body: some View {
        SettingsScaffold(eyebrow: "Settings · People", title: "Sit with someone.") {
            Text("Everyone you share a task or a list with lands here — one place, no double invites. You share from the task itself; this is where you add or remove people.")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                .padding(.bottom, 16)

            if let vm {
                RosterSection(vm: vm)
                WaitingSection(vm: vm)
                AddSomeoneSection(vm: vm).padding(.top, 22)
                RedeemSection(vm: vm).padding(.top, 22)
            } else {
                Text("Loading…").font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
            }
        }
        .task {
            let m = vm ?? model.makeCircleModel()
            vm = m
            m.start()
        }
        .onDisappear { vm?.stop() }
    }
}

// MARK: - Roster

private struct RosterSection: View {
    @Environment(\.uTheme) private var theme
    let vm: CircleModel
    @State private var copiedId: String?
    @State private var removeTarget: CircleMember?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("People · \(vm.rosterCount)")
            if vm.loading {
                Text("Loading…").font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
            } else if vm.roster.isEmpty {
                Text(vm.waiting.isEmpty
                     ? "No one yet. Add anyone you want to share with."
                     : "No one has joined yet — your invites are below.")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
            } else {
                SettingsCard {
                    ForEach(Array(vm.roster.enumerated()), id: \.element.id) { idx, m in
                        if idx > 0 { CardDivider() }
                        memberRow(m)
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove this connection?",
            isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
            titleVisibility: .visible, presenting: removeTarget
        ) { m in
            Button("Remove", role: .destructive) {
                Task { await vm.remove(id: m.id) }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: { m in
            Text(m.status == "invited"
                 ? "Cancels this pending invite\(m.inviteeEmail.map { " to \($0)" } ?? "")."
                 : "\(m.memberName ?? "They") will no longer see anything you've shared, and any tasks you shared with them are revoked.")
        }
    }

    @ViewBuilder
    private func memberRow(_ m: CircleMember) -> some View {
        let pending = m.status == "invited"
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // A pending invite shows WHO was invited (unified sharing v1:
                // `circle_list.invitee_email`); link-only invites have no address.
                Text(pending ? (m.inviteeEmail ?? "Invite pending") : (m.memberName ?? "Member"))
                    .font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                Text(m.relationshipLabel
                     ?? (pending ? (m.inviteeEmail == nil ? "waiting to be accepted" : "invited · waiting for them to sign up")
                                 : "connected"))
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
            Spacer()
            if pending, let code = m.inviteCode {
                Button {
                    UIPasteboard.general.string = circleInviteLink(code)
                    copiedId = m.id
                    Task { try? await Task.sleep(nanoseconds: 1_800_000_000); if copiedId == m.id { copiedId = nil } }
                } label: {
                    Text(copiedId == m.id ? "Copied!" : "Copy link")
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                }.buttonStyle(.plain)
            }
            Button { removeTarget = m } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.palette.ink3)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pending ? "Cancel invite" : "Remove \(m.memberName ?? "member")")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: - Waiting to join (every invite I sent, whichever screen sent it)

/// How many lines a Waiting-to-join row's two texts get. One each at normal
/// sizes (the compact row the rest of Settings uses); at an ACCESSIBILITY size
/// they wrap instead — found live at AX XXXL, where the one-line rule truncated
/// the address to "unified-…" and what the invite is for to "Write the projec…",
/// which is the entire content of the row: you could not tell the invites apart
/// or read the grade ("· can edit" / "· can view") the one vocabulary promises.
func waitingRowLineLimit(_ size: DynamicTypeSize) -> Int? {
    size.isAccessibilitySize ? nil : 1
}

/// Unified sharing v1 §2 "One place for people": the email invites that are
/// still unclaimed — a task's ("Draft the deck · can edit"), a list's
/// ("Groceries · can view") and "Add someone"'s ("your people") — one row
/// each, with Cancel (and Copy link when the invite has a join code). Hidden
/// while there is nothing waiting; on a server without `my_pending_invites`
/// the roster keeps showing its pending rows exactly as before.
private struct WaitingSection: View {
    @Environment(\.uTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let vm: CircleModel
    @State private var copiedId: String?
    @State private var cancelTarget: PendingInvite?

    var body: some View {
        if !vm.waiting.isEmpty || vm.waitingError != nil {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Waiting to join · \(vm.waiting.count)")
                Text("Invites you've sent that haven't been claimed. They get in the moment they sign up with that address.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                if let err = vm.waitingError {
                    Text(err).font(UFont.sans(12)).foregroundStyle(theme.palette.coralDeep)
                }
                if !vm.waiting.isEmpty {
                    SettingsCard {
                        ForEach(Array(vm.waiting.enumerated()), id: \.element.id) { idx, p in
                            if idx > 0 { CardDivider() }
                            inviteRow(p)
                        }
                    }
                }
            }
            .padding(.top, 22)
            .confirmationDialog(
                "Cancel this invite?",
                isPresented: Binding(get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } }),
                titleVisibility: .visible, presenting: cancelTarget
            ) { p in
                Button("Cancel invite", role: .destructive) {
                    Task { await vm.cancelPending(p) }
                    cancelTarget = nil
                }
                Button("Keep it", role: .cancel) { cancelTarget = nil }
            } message: { p in
                Text(cancelMessage(p))
            }
        }
    }

    @ViewBuilder
    private func inviteRow(_ p: PendingInvite) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.email.isEmpty ? "Invite pending" : p.email)
                    .font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    .lineLimit(waitingRowLineLimit(typeSize))
                    .fixedSize(horizontal: false, vertical: true)
                Text(pendingInviteLabel(p))
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    .lineLimit(waitingRowLineLimit(typeSize))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let code = p.inviteCode {
                Button {
                    UIPasteboard.general.string = circleInviteLink(code)
                    copiedId = p.id
                    Task { try? await Task.sleep(nanoseconds: 1_800_000_000); if copiedId == p.id { copiedId = nil } }
                } label: {
                    Text(copiedId == p.id ? "Copied!" : "Copy link")
                        .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.primaryDeep)
                }.buttonStyle(.plain)
            }
            Button { cancelTarget = p } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.palette.ink3)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel invite\(p.email.isEmpty ? "" : " to \(p.email)")")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// What cancelling takes away, in the row's own words.
    private func cancelMessage(_ p: PendingInvite) -> String {
        let who = p.email.isEmpty ? "They" : p.email
        switch p.kind {
        case .circle: return "\(who) won't be added to your people when they sign up."
        case .task: return "\(who) won't get \(p.itemName.map { "“\($0)”" } ?? "the task") when they sign up."
        case .collection: return "\(who) won't get \(p.itemName.map { "“\($0)”" } ?? "the list") when they sign up."
        }
    }
}

// MARK: - Add someone (email → invite / emailed, blank → shareable link)

private struct AddSomeoneSection: View {
    @Environment(\.uTheme) private var theme
    let vm: CircleModel

    @State private var email = ""
    @State private var busy = false
    @State private var result: InviteResult?
    @State private var error: String?
    @State private var copied = false

    /// The successful outcome we render (parity with the web's `result` state).
    private struct InviteResult { let added: Bool; let emailed: Bool; let link: String?; let email: String }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Add someone")
            SettingsCard {
                if let result {
                    resultBody(result).padding(16)
                } else {
                    formBody.padding(16)
                }
            }
        }
    }

    @ViewBuilder
    private var formBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Their email (optional)").font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
            TextField("name@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(submit)
            Text("We'll email them the invite. Or leave it blank for a link you send yourself.")
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            if let error {
                Text(error).font(UFont.sans(12)).foregroundStyle(theme.palette.coralDeep)
            }
            HStack(spacing: 8) {
                Button(action: submit) {
                    Text(busy ? "Working…" : (email.trimmingCharacters(in: .whitespaces).isEmpty ? "Generate link" : "Send invite"))
                        .font(UFont.sans(14, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(theme.palette.ink).clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }.buttonStyle(.plain).disabled(busy)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func resultBody(_ r: InviteResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if r.added {
                Text("✓ Added\(r.email.isEmpty ? "" : " (\(r.email))").")
                    .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.greenInk)
            } else if r.emailed {
                Text("✓ Invite sent to \(r.email).")
                    .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.greenInk)
            } else if let link = r.link {
                Text("Invite link ready\(copied ? " · copied!" : "")")
                    .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                Text(link)
                    .font(UFont.mono(12)).foregroundStyle(theme.palette.ink2)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.palette.bg2).clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .textSelection(.enabled)
                Text(r.email.isEmpty
                     ? "Send this to them however you like — it's the only way in."
                     : "We couldn't email them — send this link instead.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
            HStack(spacing: 8) {
                if let link = r.link {
                    Button {
                        UIPasteboard.general.string = link
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copied = false }
                    } label: {
                        Text("Copy link").font(UFont.sans(14, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(theme.palette.ink).clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }.buttonStyle(.plain)
                }
                Button {
                    result = nil; error = nil; email = ""
                } label: {
                    Text("Done").font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink2)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(theme.palette.bg2).clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }.buttonStyle(.plain)
            }
        }
    }

    private func submit() {
        guard !busy else { return }
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; error = nil
        Task {
            let r = await vm.invite(email: e.isEmpty ? nil : e)
            busy = false
            if r.ok == false, r.added != true, r.emailed != true, r.link == nil {
                error = friendlyInviteError(r.error)
                return
            }
            let res = InviteResult(added: r.added == true, emailed: r.emailed == true, link: r.link, email: e)
            result = res
            if let link = res.link, !res.added, !res.emailed {
                UIPasteboard.general.string = link   // auto-copy a fresh link (web parity)
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copied = false }
            }
        }
    }

    private func friendlyInviteError(_ code: String?) -> String {
        switch code {
        case "circle_full": return "Your circle is full."
        case "not_configured": return "Sign in to invite people."
        default: return "Could not create invite. Try again."
        }
    }
}

// MARK: - Redeem a code (join someone else's circle)

private struct RedeemSection: View {
    @Environment(\.uTheme) private var theme
    let vm: CircleModel

    @State private var code = ""
    @State private var busy = false
    @State private var message: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Have an invite code?")
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paste a code (or the code from a join link) someone shared with you.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    HStack(spacing: 8) {
                        TextField("code", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit(submit)
                        Button(action: submit) {
                            Text(busy ? "Joining…" : "Join")
                                .font(UFont.sans(14, .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(theme.palette.ink).clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        }.buttonStyle(.plain)
                            .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let m = message {
                        Text(m.text).font(UFont.sans(12))
                            .foregroundStyle(m.ok ? theme.palette.greenInk : theme.palette.coralDeep)
                    }
                }
                .padding(16)
            }
        }
    }

    private func submit() {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !busy else { return }
        busy = true; message = nil
        Task {
            let r = await vm.redeem(code: extractCode(c))
            busy = false
            if r.ok {
                message = (true, "Joined \(r.ownerName ?? "their")'s circle.")
                code = ""
            } else {
                message = (false, friendlyRedeemError(r.error))
            }
        }
    }

    /// Accept either a bare code or a full join link (…/circle/join?code=XXXX).
    private func extractCode(_ input: String) -> String {
        if let range = input.range(of: "code=") {
            return String(input[range.upperBound...]).components(separatedBy: CharacterSet(charactersIn: "&#")).first ?? input
        }
        return input
    }

    private func friendlyRedeemError(_ code: String?) -> String {
        switch code {
        case "invalid_or_expired": return "That code isn't valid anymore."
        case "self": return "That's your own invite."
        case "already_in_circle": return "You're already connected."
        case "not_configured": return "Sign in to join a circle."
        default: return "Couldn't join. Try again."
        }
    }
}
