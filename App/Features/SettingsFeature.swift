// Settings — matches the Android SettingsScreen hub: a "SETTINGS" eyebrow, a
// "How Unstuck behaves." serif-italic title, and a single rounded surface card
// of hairline-separated rows. The hub links to pushed sub-screens (Account,
// Focus, Sound, Accessibility, Interface) plus the existing Notifications,
// Insights, Backup, and Areas/Tags rows — each wired to live behavior via
// model.settings (device-local UserDefaults store) or the AppModel account
// methods. No dead toggles: every control here drives real behavior.

import SwiftUI
import UIKit
import UnstuckCore
import UnstuckDesign
import UnstuckSync

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Settings").foregroundStyle(theme.palette.primaryDeep)
                        .padding(.top, 4)
                    Text("How Unstuck behaves.")
                        .font(UFont.serifItalic(28)).foregroundStyle(theme.palette.ink)
                        .padding(.top, 4).padding(.bottom, 14)

                    hubCard

                    Text("Your data is yours — export a complete copy any time.")
                        .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                        .padding(.top, 14)

                    aboutCard.padding(.top, 18)
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
            .sheet(item: $exportURL) { url in
                // Delete the full-PII dump once the share finishes/cancels so
                // it doesn't linger in tmp (makeExportFile sweeps stragglers).
                ActivityView(items: [url]) { AppModel.removeExportFile(url) }
            }
        }
    }

    // MARK: hub card — one grouped surface, hairline-separated rows

    private var hubCard: some View {
        VStack(spacing: 0) {
            navRow("Account") { AccountSettingsView() }
            divider
            navRow("Focus") { FocusSettingsView() }
            divider
            navRow("Sound") { SoundSettingsView() }
            divider
            navRow("Accessibility") { AccessibilitySettingsView() }
            divider
            navRow("Interface") { InterfaceSettingsView() }

            divider
            // Notification level (Calm/Balanced/Coach) + reminder lead.
            navRow("Notifications") { NotificationSettingsView() }

            divider
            navRow("Insights") { AnalyticsView() }

            divider
            // Backup: export everything as a JSON snapshot you keep.
            actionRow("Backup", sub: "A full JSON snapshot of your data.") {
                exportURL = model.makeExportFile()
            }

            divider
            navRow("Areas & tags") { TagsAreasView() }

            divider
            // Legal (App Store 1.2 / 5.1.1 — terms + privacy reachable in-app).
            actionRow("Terms of Use", sub: "unstucknow.io/terms") {
                if let u = URL(string: "https://unstucknow.io/terms") { UIApplication.shared.open(u) }
            }
            divider
            actionRow("Privacy Policy", sub: "unstucknow.io/privacy") {
                if let u = URL(string: "https://unstucknow.io/privacy") { UIApplication.shared.open(u) }
            }
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }

    // MARK: about card

    private var aboutCard: some View {
        VStack(spacing: 0) {
            aboutLine("Theme", themeLabel(model.settings.theme))
            divider
            aboutLine("Version", Self.appVersion)
            divider
            aboutLine("Backend", "Supabase")
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }

    /// "1.0 (5)" from the bundle — never hardcode (it drifted to 0.1.0 once).
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func themeLabel(_ t: ThemePref) -> String {
        switch t {
        case .system: return "Follows system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    // MARK: row builders

    private var divider: some View {
        Rectangle().fill(theme.palette.line).frame(height: 1)
    }

    /// A row that navigates to `destination`, with a trailing chevron.
    @ViewBuilder
    private func navRow<Destination: View>(_ label: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink { destination() } label: {
            HStack {
                Text(label).font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink)
                Spacer()
                chevron
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// A tappable row with a label, a subtitle, and a trailing chevron.
    private func actionRow(_ label: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(UFont.sans(14, .medium)).foregroundStyle(theme.palette.ink)
                    Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                }
                Spacer()
                chevron
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.palette.ink3)
    }

    /// Static About row.
    private func aboutLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
            Spacer()
            Text(value).font(UFont.mono(12)).foregroundStyle(theme.palette.ink3).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

// MARK: - shared sub-screen scaffolding

/// A settings sub-screen: the dark-bg scroll, the eyebrow + serif title, and a
/// single surface card. Mirrors the Android SettingsSubScreen layout.
private struct SettingsScaffold<Content: View>: View {
    @Environment(\.uTheme) private var theme
    let eyebrow: String
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(eyebrow).foregroundStyle(theme.palette.primaryDeep).padding(.top, 4)
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
private struct SettingsCard<Content: View>: View {
    @Environment(\.uTheme) private var theme
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }
}

private struct CardDivider: View {
    @Environment(\.uTheme) private var theme
    var body: some View { Rectangle().fill(theme.palette.line).frame(height: 1) }
}

/// A label + segmented-choice row (Android's SegRow). Generic over a list of
/// (key, label) options; the binding holds the key.
private struct SegRow: View {
    @Environment(\.uTheme) private var theme
    let label: String
    let options: [(key: String, label: String)]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
            Spacer()
            HStack(spacing: 4) {
                ForEach(options, id: \.key) { opt in
                    let isOn = opt.key == selected
                    Button { onSelect(opt.key) } label: {
                        Text(opt.label)
                            .font(UFont.sans(12, .medium))
                            .foregroundStyle(isOn ? Color.white : theme.palette.ink2)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(isOn ? AnyShapeStyle(theme.palette.primary) : AnyShapeStyle(theme.palette.bg2),
                                        in: Capsule())
                            // 44pt hit area; negative padding keeps the row's drawn height.
                            .frame(minHeight: 44).contentShape(Capsule()).padding(.vertical, -9)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(opt.label)
                        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// A label + Switch row (Android's ToggleRow). The whole row is tappable.
private struct ToggleRow: View {
    @Environment(\.uTheme) private var theme
    let label: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            Text(label).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
        }
        .tint(theme.palette.primary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

/// A tappable label + value row (Android's SettingRow). Used for Account fields.
private struct SettingTapRow: View {
    @Environment(\.uTheme) private var theme
    let label: String
    let value: String?
    var destructive = false
    var onTap: (() -> Void)?

    var body: some View {
        Button { onTap?() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(UFont.sans(13, .semibold))
                        .foregroundStyle(destructive ? theme.palette.red : theme.palette.ink)
                    if let value { Text(value).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3) }
                }
                Spacer()
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.palette.ink3)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }
}

// MARK: - Focus

private struct FocusSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    var body: some View {
        @Bindable var settings = model.settings
        SettingsScaffold(eyebrow: "Settings · Focus", title: "How focus mode behaves.") {
            SettingsCard {
                SegRow(label: "Default focus length",
                       options: [("15", "15"), ("25", "25"), ("45", "45")],
                       selected: String(settings.focusDefaultMin)) { v in
                    settings.focusDefaultMin = Int(v) ?? 25
                }
                CardDivider()
                SegRow(label: "Soft overrun",
                       options: [("0", "Off"), ("5", "5"), ("10", "10")],
                       selected: String(settings.focusOverrunMin)) { v in
                    settings.focusOverrunMin = Int(v) ?? 0
                }
                CardDivider()
                ToggleRow(label: "Hide right rail while focusing", isOn: $settings.focusCollapseRail)
                CardDivider()
                ToggleRow(label: "Soft exit", isOn: $settings.focusSoftExit)
                CardDivider()
                ToggleRow(label: "Pause reasons", isOn: $settings.focusPauseReasons)
                CardDivider()
                // Hands-Free Focus Copilot (Phase 1): on-device spoken progress
                // alerts during a block; Voice replies adds a short mic window
                // after a prompt. Coach off disables Voice replies.
                ToggleRow(label: "Spoken focus coach", isOn: $settings.focusSpokenCoach)
                CardDivider()
                ToggleRow(label: "Voice replies", isOn: $settings.focusVoiceReplies)
                    .opacity(settings.focusSpokenCoach ? 1 : 0.4)
                    .disabled(!settings.focusSpokenCoach)
            }
            Text("Default focus length sets the estimate on a new task. Soft overrun decides how long past the estimate before the check-in appears.")
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                .padding(.top, 10)
            Text("Spoken focus coach reads gentle progress alerts aloud while you focus — how often follows your Notifications level (Calm / Balanced / Coach). Voice replies opens a brief on-device mic after a prompt so you can say \u{201C}add ten\u{201D}, \u{201C}stop\u{201D}, or \u{201C}keep going\u{201D} hands-free. Both stay on your device — no recording is ever stored or sent.")
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                .padding(.top, 10)
        }
    }
}

// MARK: - Sound

private struct SoundSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    var body: some View {
        @Bindable var settings = model.settings
        SettingsScaffold(eyebrow: "Settings · Sound", title: "Quiet by default.") {
            SettingsCard {
                ToggleRow(label: "Start chime", isOn: $settings.soundStartChime)
                CardDivider()
                ToggleRow(label: "Overrun bell", isOn: $settings.soundOverrunBell)
                CardDivider()
                ToggleRow(label: "Completion sound", isOn: $settings.soundCompletion)
                CardDivider()
                SegRow(label: "Ambient",
                       options: [("off", "Off"), ("brown", "Brown"), ("pink", "Pink")],
                       selected: settings.ambient.rawValue) { v in
                    settings.ambient = AmbientSound(rawValue: v) ?? .off
                }
            }
            Text("Ambient plays a soft noise bed while you focus. iOS generates one procedural brown-noise bed — “Pink” maps to the same loop.")
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                .padding(.top, 10)
        }
    }
}

// MARK: - Accessibility

private struct AccessibilitySettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        SettingsScaffold(eyebrow: "Settings · Accessibility", title: "Adjust to your brain.") {
            SettingsCard {
                ToggleRow(label: "Reduce motion", isOn: $settings.reduceMotion)
                CardDivider()
                // +2 DynamicTypeSize steps on top of Density — Android's
                // largerType 1.15× fontScale analogue.
                ToggleRow(label: "Larger type", isOn: $settings.largerType)
                CardDivider()
                // Android `highContrast`. Stored for parity (SettingsState); the
                // palette can stiffen hairlines/contrast off this flag.
                ToggleRow(label: "High contrast", isOn: $settings.highContrast)
            }
        }
    }
}

// MARK: - Interface

private struct InterfaceSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        SettingsScaffold(eyebrow: "Settings · Interface", title: "How things look.") {
            SettingsCard {
                SegRow(label: "Theme",
                       options: [("system", "System"), ("light", "Light"), ("dark", "Dark")],
                       selected: settings.theme.rawValue) { v in
                    settings.theme = ThemePref(rawValue: v) ?? .system
                }
                CardDivider()
                SegRow(label: "Accent",
                       options: [("indigo", "Indigo"), ("rose", "Rose"), ("forest", "Forest")],
                       selected: settings.accent.rawValue) { v in
                    settings.accent = Accent(rawValue: v) ?? .indigo
                }
                CardDivider()
                SegRow(label: "Density",
                       options: [("compact", "Compact"), ("regular", "Regular"), ("comfy", "Comfy")],
                       selected: settings.density.rawValue) { v in
                    settings.density = DensityPref(rawValue: v) ?? .regular
                }
            }
        }
    }
}

// MARK: - Account

private struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uTheme) private var theme

    @State private var exportURL: URL?
    @State private var showName = false
    @State private var showPassword = false
    @State private var showDelete = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        SettingsScaffold(eyebrow: "Settings · Account", title: "Your account.") {
            SettingsCard {
                SettingTapRow(label: "Display name", value: model.currentUserName ?? "Set a name") { showName = true }
                CardDivider()
                SettingTapRow(label: "Signed in", value: model.currentEmail ?? "—")   // static info — no tap
                CardDivider()
                SettingTapRow(label: model.hasPassword ? "Change password" : "Add a password",
                              value: "Update your sign-in password") { showPassword = true }
                CardDivider()
                SettingTapRow(label: "Export everything", value: "A full JSON snapshot of your data.") {
                    exportURL = model.makeExportFile()
                }
                CardDivider()
                SettingTapRow(label: "Delete my account", value: "Permanently removes your data",
                              destructive: true) { showDelete = true }
                CardDivider()
                SettingTapRow(label: "Sign out", value: "End this session", destructive: true) {
                    model.signOut(); dismiss()
                }
            }
            if let message {
                Text(message)
                    .font(UFont.sans(12))
                    .foregroundStyle(messageIsError ? theme.palette.red : theme.palette.green)
                    .padding(.top, 10)
            }
        }
        .sheet(item: $exportURL) { url in
            ActivityView(items: [url]) { AppModel.removeExportFile(url) }
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
            UButton("Save") {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onSave(trimmed); dismiss()
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.bg.ignoresSafeArea())
        .presentationDetents([.height(220)])
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

    private var error: String? {
        if !pw.isEmpty && pw.count < 8 { return "At least 8 characters." }
        if !confirm.isEmpty && confirm != pw { return "Passwords don't match." }
        return nil
    }
    private var canSave: Bool { pw.count >= 8 && pw == confirm && (!hasPassword || !current.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(hasPassword ? "Change password" : "Add a password")
            if hasPassword { secureField("Current password", text: $current) }
            secureField("New password", text: $pw)
            secureField("Confirm password", text: $confirm)
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

    private func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .font(UFont.sans(16)).textFieldStyle(.plain)
            .padding(12).background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))
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
