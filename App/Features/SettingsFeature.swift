// Settings — the slim hub (PLAN.md "Slim Settings", approved 2026-09-24).
// Only what you set once: who you are, how Unstuck reaches you, what the AI
// can see, who you share with, and how the app looks.
//
//   ┌ Name / email                    › ┐  Account
//   Notifications & calls             ›    (section id "Notifications")
//   Assistant & privacy               ›    (section id "Assistant")
//   People                            ›
//   Appearance                        ›
//   Send feedback                          (the feedback sheet)
//   Replay the tour                        (locked while a tour runs)
//   Terms · Privacy · Unstuck 1.1.1 (96)
//
// Things that change one screen live on it now: focus options → the Focus
// screen's ⋯ Options, background noise → its speaker button, hold-to-talk →
// Talk, areas & tags → the Tasks "Edit" pill, Insights → Today's week pill.
// Every section is a PUSHED sub-screen: the guided tour's scoped lockdown
// needs the navigation stack deeper than the root (TourView
// `pushedSettingsSectionRect`), so Appearance is never inline on the hub.

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckDesign
import UnstuckSync

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    /// Deep-link a section on first appearance (the guided tour opens
    /// Settings on Notifications / Appearance; the assistant's open_screen and
    /// `unstuck://settings?section=…` land on any of them — old names too,
    /// via SettingsDestination's aliases).
    private let initialSection: String?
    @State private var path: [SettingsDestination] = []
    @State private var seeded = false
    @State private var showFeedback = false

    init(section: String? = nil) {
        self.initialSection = section
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Settings")
                        .padding(.top, 4)
                    Text("How Unstuck behaves.")
                        .font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink)
                        .padding(.top, 4).padding(.bottom, 14)

                    accountCard
                    screensCard.padding(.top, 14)
                    actionsCard.padding(.top, 14)
                    footer.padding(.top, 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 96)   // clear the floating bottom nav
            }
            .background(theme.palette.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .account: AccountSettingsView()
                case .notifications: NotificationSettingsView()
                case .assistant: AssistantPrivacySettingsView()
                case .people: ConnectionsView()
                case .appearance: AppearanceSettingsView()
                case .hub, .feedback, .focus, .areas: EmptyView()   // never pushed
                }
            }
            .sheet(isPresented: $showFeedback) { FeedbackSheet() }
            .onAppear {
                guard !seeded else { return }
                seeded = true
                let destination = SettingsDestination.from(section: initialSection)
                if destination.isSettingsScreen { path = [destination] }
                else if destination == .feedback { showFeedback = true }
            }
        }
    }

    // MARK: the account card — name + email, into Account

    private var accountCard: some View {
        NavigationLink(value: SettingsDestination.account) {
            HStack(spacing: 12) {
                Text(model.avatarInitials)
                    .font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.greenInk)
                    .frame(width: 40, height: 40)
                    .background(theme.palette.greenSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.currentUserName ?? "Your account")
                        .font(UFont.sans(15, .semibold)).foregroundStyle(theme.palette.ink)
                        .lineLimit(1)
                    Text(model.currentEmail ?? "Name, password, export, sign out")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                SettingsChevron()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Account, \(model.currentUserName ?? model.currentEmail ?? "your account")")
        // Fixed test handles — never the label (Settings is a SHEET over
        // Today, so labels collide with what's behind it).
        .accessibilityIdentifier("settings-row-account")
    }

    // MARK: the four screens

    private var screensCard: some View {
        SettingsCard {
            hubRow(.notifications, "Notifications & calls", sub: "Reminders, check-ins and calls", id: "notifications")
            CardDivider()
            hubRow(.assistant, "Assistant & privacy", sub: "The AI, and what it remembers", id: "assistant")
            CardDivider()
            hubRow(.people, "People", sub: "Who you share tasks and lists with", id: "people")
            CardDivider()
            hubRow(.appearance, "Appearance", sub: "Light or dark, and text size", id: "appearance")
        }
    }

    private func hubRow(_ destination: SettingsDestination, _ label: String, sub: String, id: String) -> some View {
        NavigationLink(value: destination) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink)
                    Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                }
                Spacer(minLength: 8)
                SettingsChevron()
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-row-\(id)")
    }

    // MARK: the two one-tap actions

    private var actionsCard: some View {
        SettingsCard {
            actionRow("Send feedback", sub: "Tell us what's working, or isn't", id: "feedback") {
                showFeedback = true
            }
            CardDivider()
            // Resume an UNFINISHED run at its saved step; a finished or fresh
            // tour restarts at the welcome card (web semantics). Locked while a
            // tour runs.
            actionRow("Replay the tour", sub: "A short walk through Unstuck", id: "tour",
                      locked: model.tourRunning) {
                model.tour.openExplicit()
            }
        }
    }

    private func actionRow(_ label: String, sub: String, id: String, locked: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink)
                    Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
        .accessibilityIdentifier("settings-row-\(id)")
    }

    // MARK: footer — Terms · Privacy · version

    /// Legal (App Store 1.2 / 5.1.1): Terms and Privacy stay one tap from the
    /// hub — real buttons with a 44-pt hit area and labels. The build, for
    /// bug reports.
    private var footer: some View {
        HStack(spacing: 0) {
            footerLink("Terms", url: "https://unstucknow.io/terms", label: "Terms of Use", id: "settings-terms")
            Text("·").accessibilityHidden(true)
            footerLink("Privacy", url: "https://unstucknow.io/privacy", label: "Privacy Policy", id: "settings-privacy")
            Text("·").accessibilityHidden(true)
            Text("Unstuck \(Self.appVersion)")
                .font(UFont.mono(11))
                .padding(.leading, 7)
                .accessibilityLabel("Version \(Self.appVersion)")
        }
        .font(UFont.sans(12))
        .foregroundStyle(theme.palette.ink3)
        .frame(maxWidth: .infinity)
    }

    private func footerLink(_ title: String, url: String, label: String, id: String) -> some View {
        Button {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        } label: {
            // Even padding (not a min width) keeps the "·" gaps equal; with it
            // "Terms" still clears 44 pt wide.
            Text(title).underline()
                .font(UFont.sans(12, .medium)).foregroundStyle(theme.palette.ink2)
                .padding(.horizontal, 7)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier(id)
    }

    /// "1.1.1 (96)" from the bundle — never hardcode (it drifted to 0.1.0 once).
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

// MARK: - shared sub-screen scaffolding

/// A settings sub-screen: the dark-bg scroll, the eyebrow + serif title, and a
/// single surface card. Mirrors the Android SettingsSubScreen layout.
/// Internal (not private) so sibling settings screens (e.g. ConnectionsView)
/// reuse the exact same chrome.
struct SettingsScaffold<Content: View>: View {
    @Environment(\.uTheme) private var theme
    let eyebrow: String
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(eyebrow).padding(.top, 4)
                Text(title)
                    .font(UFont.serifItalic(26)).foregroundStyle(theme.palette.ink)
                    .padding(.top, 4).padding(.bottom, 12)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 96)
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One grouped surface card for a settings section.
struct SettingsCard<Content: View>: View {
    @Environment(\.uTheme) private var theme
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }
}

struct CardDivider: View {
    @Environment(\.uTheme) private var theme
    var body: some View { Rectangle().fill(theme.palette.line).frame(height: 1) }
}

struct SettingsChevron: View {
    @Environment(\.uTheme) private var theme
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.palette.ink3)
            .accessibilityHidden(true)
    }
}

/// A small plain line under a card or row.
struct SettingsNote: View {
    @Environment(\.uTheme) private var theme
    let text: String
    var body: some View {
        Text(text)
            .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A label (+ an optional plain line) and a row of choices. Selection is the
/// app's black-and-white pair (ink fill, bg text) — never a colour accent.
/// Generic over (key, label) options; `selected` holds the key.
struct SettingsChoiceRow: View {
    @Environment(\.uTheme) private var theme
    let label: String
    var sub: String? = nil
    let options: [(key: String, label: String)]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                if let sub {
                    Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                ForEach(options, id: \.key) { opt in
                    let isOn = opt.key == selected
                    Button { onSelect(opt.key) } label: {
                        Text(opt.label)
                            .font(UFont.sans(13, isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? theme.palette.bg : theme.palette.ink2)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(isOn ? theme.palette.ink : theme.palette.bg2, in: Capsule())
                            .overlay(Capsule().stroke(theme.palette.line2))
                            // 44pt hit area; negative padding keeps the drawn height.
                            .frame(minHeight: 44).contentShape(Capsule()).padding(.vertical, -7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(label): \(opt.label)")
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// A label (+ an optional plain line) and a switch. The whole row is tappable.
struct SettingsToggleRow: View {
    @Environment(\.uTheme) private var theme
    let label: String
    var sub: String? = nil
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                if let sub {
                    Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .unstuckSwitch()
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// A tappable label + value row (Android's SettingRow).
struct SettingTapRow: View {
    @Environment(\.uTheme) private var theme
    let label: String
    let value: String?
    var destructive = false
    /// Locked out for now (the guided tour holds the screen): the row still
    /// reads, but it can't be tapped and looks inert. Belt-and-braces behind
    /// the tour's hit-test lockdown — see AppModel.tourRunning.
    var locked = false
    var chevron = true
    var onTap: (() -> Void)?

    var body: some View {
        Button { onTap?() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(UFont.sans(13, .semibold))
                        .foregroundStyle(destructive ? theme.palette.red : theme.palette.ink)
                    if let value {
                        Text(value).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if onTap != nil && chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.palette.ink3)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil || locked)
        .opacity(locked ? 0.45 : 1)
    }
}

// MARK: - Appearance

/// Theme + Text size — the only look controls left (Decision 1). Accent, High
/// contrast and the in-app Reduce motion are gone: the default palette stays
/// as it is, and the phone's own settings cover the rest.
struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        SettingsScaffold(eyebrow: "Settings · Appearance", title: "How it looks.") {
            SettingsCard {
                SettingsChoiceRow(label: "Theme",
                                  options: [("system", "System"), ("light", "Light"), ("dark", "Dark")],
                                  selected: settings.theme.rawValue) { v in
                    settings.theme = ThemePref(rawValue: v) ?? .system
                }
                CardDivider()
                SettingsChoiceRow(label: "Text size",
                                  sub: "On top of your iPhone's own text size.",
                                  options: TextSizePref.allCases.map { ($0.rawValue, $0.label) },
                                  selected: settings.textSize.rawValue) { v in
                    settings.textSize = TextSizePref(rawValue: v) ?? .standard
                }
            }
            SettingsNote(text: "Areas and tags live on Tasks. Focus options live on the Focus screen.")
                .padding(.top, 10)
        }
        .navigationTitle("Appearance")
    }
}

// MARK: - Assistant & privacy

/// The AI switch, the OK to share with OpenAI, what it remembers, and the
/// stored conversations. The whole screen stays when the Assistant is off —
/// you can still see and delete what it knows.
struct AssistantPrivacySettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    /// nil = idle; otherwise the line shown under "Delete conversation history".
    @State private var clearHistoryResult: String?
    @State private var clearing = false

    private var clearHistoryState: String {
        if clearing { return "Deleting…" }
        return clearHistoryResult ?? "What you've said to it is kept 90 days. Delete it now."
    }

    /// Server-side delete of this user's stored conversations
    /// (`delete_my_assistant_turns`, migration 074). Local chat threads are
    /// untouched: this is the copy the backend keeps.
    private func clearAssistantHistory() {
        guard !clearing, let prefs = model.coordinator?.preferences else { return }
        clearing = true
        clearHistoryResult = nil
        Task { @MainActor in
            defer { clearing = false }
            do {
                let n = try await prefs.deleteAssistantHistory()
                clearHistoryResult = n == 0 ? "Nothing was stored." : "Deleted \(n) stored line\(n == 1 ? "" : "s")."
            } catch {
                clearHistoryResult = "Couldn't delete it. Try again."
            }
        }
    }

    var body: some View {
        @Bindable var settings = model.settings
        SettingsScaffold(eyebrow: "Settings · Assistant & privacy", title: "What the AI can see.") {
            SettingsCard {
                // The AI kill-switch the privacy policy promises. OFF removes
                // the ✦ launcher, the panel and voice entirely, open-assistant
                // deep links are ignored, and calls are declined on arrival.
                SettingsToggleRow(label: "AI Assistant",
                                  sub: "Off hides the Assistant, Talk and calls.",
                                  isOn: $settings.assistantEnabled)
                    .accessibilityIdentifier("settings-ai-assistant")
                CardDivider()
                // The OK to send what they type or say to OpenAI (AIConsent).
                AIDataSharingRow()
                CardDivider()
                NavigationLink {
                    FactsPanelView()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What Unstuck remembers")
                                .font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                            Text("See, change or forget what it has learned about you.")
                                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        }
                        Spacer()
                        SettingsChevron()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-remembers")
                CardDivider()
                // The control the privacy policy promises (§9.5, §17):
                // conversations are kept 90 days, and the user can delete them
                // now. Always shown — turning the Assistant off only stops
                // FUTURE logging. Locked during the tour.
                SettingTapRow(label: "Delete conversation history",
                              value: clearHistoryState, locked: model.tourRunning, chevron: false) {
                    clearAssistantHistory()
                }
            }
        }
        .navigationTitle("Assistant & privacy")
        // AI data sharing → on asks with the same sheet as everywhere else.
        .aiConsentSheet(.settings)
    }
}

/// "AI data sharing" (AIConsent, guideline 5.1.2(i)): whether the account has
/// agreed to its words and voice going to OpenAI. Off clears the OK on every
/// device and turns Calls off; on shows the consent sheet.
private struct AIDataSharingRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    var body: some View {
        let on = model.aiConsentGranted
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { on }, set: { want in
                if want { model.withAIConsent(.settings, from: .settings) {} } else { model.revokeAIConsent() }
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI data sharing").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                    Text(on ? "On. What you ask the Assistant goes to OpenAI so it can answer."
                            : "Off. The Assistant asks before anything is sent.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .unstuckSwitch()
            .disabled(model.tourRunning)
            .accessibilityIdentifier("settings-ai-data-sharing")
            AIConsentNoteLine(host: .settings)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    @State private var exportURL: URL?
    @State private var showName = false
    @State private var showPassword = false
    @State private var showDelete = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var signOutWarning: String?

    var body: some View {
        SettingsScaffold(eyebrow: "Settings · Account", title: "Your account.") {
            SettingsCard {
                SettingTapRow(label: "Display name", value: model.currentUserName ?? "Set a name") { showName = true }
                CardDivider()
                SettingTapRow(label: model.hasPassword ? "Change password" : "Add a password",
                              value: model.hasPassword ? "Update the password you sign in with"
                                                       : "Sign in with a password as well") { showPassword = true }
                CardDivider()
                // The account-danger rows are LOCKED while the guided tour is
                // running (round 4): the tour's hit-test lockdown already
                // scopes the settings exemption to the pushed section, and
                // this is the belt-and-braces the contract asks for — a
                // sign-out / delete / export mid-tour used to leave the
                // running lockdown live over AuthView. The label stays
                // "Export everything": the privacy policy names it.
                SettingTapRow(label: "Export everything",
                              value: "Download a copy of everything you've put in Unstuck",
                              locked: model.tourRunning) {
                    exportURL = model.makeExportFile()
                }
                CardDivider()
                SettingTapRow(label: "Sign out", value: "End this session on this iPhone",
                              locked: model.tourRunning, chevron: false) {
                    // Edits still queued: say where they go before they're
                    // parked (audit 2026-09-22, C36). What the server refused
                    // — and everything held behind it — never syncs from a
                    // later sign-in, so it's told apart (C28's stuck count).
                    signOutWarning = AppModel.unsyncedSignOutWarning(
                        pending: model.pendingSyncCount,
                        quarantined: max(model.quarantinedSyncCount, model.stuckChanges))
                    if signOutWarning == nil { model.signOut(); dismiss() }
                }
                CardDivider()
                // Last row, same path and depth as before (App Store 5.1.1(v)).
                SettingTapRow(label: "Delete my account", value: "Permanently removes your data",
                              destructive: true, locked: model.tourRunning) { showDelete = true }
            }
            if let message {
                Text(message)
                    .font(UFont.sans(12))
                    .foregroundStyle(messageIsError ? theme.palette.red : theme.palette.green)
                    .padding(.top, 10)
            }
        }
        .navigationTitle("Account")
        .sheet(item: $exportURL) { url in
            // Delete the full-PII dump once the share finishes/cancels so it
            // doesn't linger in tmp (makeExportFile sweeps stragglers).
            ActivityView(items: [url]) { AppModel.removeExportFile(url) }
        }
        .alert("Sign out with changes unsynced?",
               isPresented: Binding(get: { signOutWarning != nil }, set: { if !$0 { signOutWarning = nil } })) {
            Button("Sign out", role: .destructive) { model.signOut(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(signOutWarning ?? "")
        }
        .sheet(isPresented: $showName) {
            DisplayNameSheet(initial: model.currentUserName ?? "") { name in
                Task {
                    let r = await model.updateDisplayName(name)
                    apply(r, success: "Name updated.")
                }
            }
        }
        .sheet(isPresented: $showPassword) {
            PasswordSheet(hasPassword: model.hasPassword) { current, newPw in
                Task {
                    let r = await model.changePassword(current: current, new: newPw)
                    apply(r, success: "Password updated.")
                }
            }
        }
        .sheet(isPresented: $showDelete) {
            // Type-to-confirm (Android parity): an irreversible wipe must not be a
            // single mistap. Require the account email (or "DELETE" when no email).
            DeleteAccountSheet(email: model.currentEmail) {
                Task {
                    let r = await model.deleteAccount()
                    apply(r, success: "")   // on .ok the app drops to the auth screen
                }
            }
        }
    }

    /// Surface the AuthOutcome message (errors in red, success in green).
    private func apply(_ outcome: AuthOutcome, success: String) {
        switch outcome {
        case .ok:
            messageIsError = false
            message = success.isEmpty ? nil : success
        case .error(let msg):
            messageIsError = true
            message = msg
        case .needsConfirmation:
            messageIsError = false
            message = "Check your email to confirm."
        case .alreadyExists:
            messageIsError = true
            message = "That's already in use."
        }
    }
}

// MARK: - Account dialogs (sheets — the iOS analog of Android's AlertDialogs)

/// Display-name editor. Type a name → Save calls updateDisplayName.
private struct DisplayNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme
    let initial: String
    let onSave: (String) -> Void
    @State private var value: String

    init(initial: String, onSave: @escaping (String) -> Void) {
        self.initial = initial; self.onSave = onSave
        _value = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Display name")
            TextField("Your name", text: $value)
                .font(UFont.sans(16)).textFieldStyle(.plain)
                .padding(12).background(theme.palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))
                // Return = Save when non-empty; else just drops the keyboard.
                .submitLabel(.done)
                .onSubmit(save)
            UButton("Save") { save() }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.height(220)])
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed); dismiss()
    }
}

/// Change / add password. Current (if hasPassword) + new + confirm. Validates
/// length + match before enabling Save; Save calls changePassword.
private struct PasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme
    let hasPassword: Bool
    let onSave: (_ current: String?, _ newPw: String) -> Void
    @State private var current = ""
    @State private var pw = ""
    @State private var confirm = ""
    @SwiftUI.FocusState private var focus: Field?

    private enum Field: Hashable { case current, pw, confirm }

    private var error: String? {
        if !pw.isEmpty && pw.count < 8 { return "At least 8 characters." }
        if !confirm.isEmpty && confirm != pw { return "Passwords don't match." }
        return nil
    }
    private var canSave: Bool { pw.count >= 8 && pw == confirm && (!hasPassword || !current.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(hasPassword ? "Change password" : "Add a password")
            if hasPassword {
                secureField("Current password", text: $current, field: .current, submit: .next) { focus = .pw }
            }
            secureField("New password", text: $pw, field: .pw, submit: .next) { focus = .confirm }
            // Last field: Done saves when valid, else just drops focus.
            secureField("Confirm password", text: $confirm, field: .confirm, submit: .done) {
                if canSave { onSave(hasPassword ? current : nil, pw); dismiss() }
            }
            if let error {
                Text(error).font(UFont.sans(12)).foregroundStyle(theme.palette.red)
            }
            UButton("Save") {
                onSave(hasPassword ? current : nil, pw); dismiss()
            }
            .opacity(canSave ? 1 : 0.4)
            .disabled(!canSave)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func secureField(_ placeholder: String, text: Binding<String>, field: Field,
                             submit: SubmitLabel, onSubmit: @escaping () -> Void) -> some View {
        SecureField(placeholder, text: text)
            .font(UFont.sans(16)).textFieldStyle(.plain)
            .padding(12).background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))
            .focused($focus, equals: field)
            .submitLabel(submit)
            .onSubmit(onSubmit)
    }
}

/// Delete-account confirmation. Type-to-confirm (the email, or "DELETE" when no
/// email is set) before the destructive action unlocks — 1:1 with Android's
/// delete dialog. The wipe itself runs in AppModel.deleteAccount (server +
/// local). The sheet dismisses on confirm; the app drops to the auth screen.
private struct DeleteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme
    let email: String?
    let onConfirm: () -> Void
    @State private var typed = ""

    private var target: String { (email?.isEmpty == false) ? email! : "DELETE" }
    private var matches: Bool { typed.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(target) == .orderedSame }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Delete your account")
            Text("This permanently removes everything and cannot be undone. Type \(target) to confirm.")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
            TextField(target, text: $typed)
                .font(UFont.sans(16)).textFieldStyle(.plain)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .padding(12).background(theme.palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))
                // Return = the type-to-confirm gate: only an exact match fires
                // the destructive action; anything else just drops the keyboard.
                .submitLabel(.done)
                .onSubmit { if matches { onConfirm(); dismiss() } }
            Button {
                onConfirm(); dismiss()
            } label: {
                Text("Delete forever")
                    .font(UFont.sans(15, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(theme.palette.red, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(matches ? 1 : 0.4)
            .disabled(!matches)
            Button("Cancel") { dismiss() }
                .font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.ink2)
                .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.height(280)])
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// UIActivityViewController bridge for the export share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: () -> Void = {}
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return vc
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
