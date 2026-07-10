// People / Connections — the iOS port of the web SharingPanel roster
// (components/settings/sharing-panel.tsx + lib/use-circle.ts). Your trusted
// circle: the people you share tasks + lists with. Reached from Settings ›
// People. Everyone you invite or who redeems your link lands here — one place,
// no double invites. You share a *specific* task from the task itself (M2); this
// screen is where you add / remove people and re-copy pending invite links.
//
// State comes from the CircleClient's SECURITY DEFINER RPCs. CircleModel mirrors
// the web `useCircle` hook: it holds the roster + refetches on the live
// `unstuckCollabCircleChanged` signal (so a friend accepting your invite, or a
// shared collection connecting you, updates the list without a manual reload).

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckDesign
import UnstuckSync

/// Live trusted-circle roster + mutations, bound to the shared CircleClient.
/// @MainActor @Observable so SwiftUI tracks `members` / `loading` directly —
/// the iOS analogue of the web `useCircle()` hook.
@MainActor
@Observable
final class CircleModel {
    private let client: CircleClient?
    var members: [CircleMember] = []
    var loading = true
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(client: CircleClient?) { self.client = client }

    /// Start observing the live circle-changed signal + do the first fetch.
    /// Idempotent (guards a double-subscribe when the view re-appears).
    func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .unstuckCollabCircleChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        Task { await refresh() }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refresh() async {
        guard let client else { loading = false; return }
        members = await client.listCircle()
        loading = false
    }

    /// Invite by email (we email them) or blank → a shareable link. Refetches
    /// after (an existing account is added to the roster immediately).
    func invite(email: String?) async -> CircleInviteResult {
        guard let client else { return CircleInviteResult(ok: false, error: "not_configured") }
        let r = await client.invite(email: email)
        await refresh()
        return r
    }

    /// Redeem someone else's invite code → join their circle. Refetch only on
    /// success (a failed redeem leaves your own roster unchanged).
    func redeem(code: String) async -> CircleRedeemResult {
        guard let client else { return CircleRedeemResult(ok: false, error: "not_configured") }
        let r = await client.redeem(code: code)
        if r.ok { await refresh() }
        return r
    }

    /// Remove someone (or cancel a pending invite). Server-side this also drops
    /// the task shares for the pair. Optimistic + refetch.
    func remove(id: String) async {
        members.removeAll { $0.id == id }
        await client?.removeMember(id: id)
        await refresh()
    }

    /// People who count toward "connected" — active members + pending invites
    /// (mirrors the web `activeCount`).
    var activeCount: Int {
        members.filter { $0.status == "active" || $0.status == "invited" }.count
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
            SectionLabel("People · \(vm.activeCount)")
            if vm.loading {
                Text("Loading…").font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
            } else if vm.members.isEmpty {
                Text("No one yet. Add anyone you want to share with.")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
            } else {
                SettingsCard {
                    ForEach(Array(vm.members.enumerated()), id: \.element.id) { idx, m in
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
                 ? "Cancels this pending invite."
                 : "\(m.memberName ?? "They") will no longer see anything you've shared, and any tasks you shared with them are revoked.")
        }
    }

    @ViewBuilder
    private func memberRow(_ m: CircleMember) -> some View {
        let pending = m.status == "invited"
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pending ? "Invite pending" : (m.memberName ?? "Member"))
                    .font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                Text(m.relationshipLabel ?? (pending ? "waiting to be accepted" : "connected"))
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
