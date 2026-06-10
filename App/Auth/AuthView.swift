// Minimal email/password + Google sign-in surface. The SyncCoordinator's
// auth-state stream flips RootView to the app on success.

import SwiftUI
import UnstuckDesign
import UnstuckSync

struct AuthView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    @State private var email = ""
    @State private var password = ""
    @State private var mode: Mode = .signIn
    @State private var status: String?
    @State private var statusIsError = true
    @State private var busy = false

    enum Mode { case signIn, signUp }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Wordmark(size: 28)
            Text("External executive function.")
                .font(UFont.serifItalic(20))
                .foregroundStyle(theme.palette.ink2)

            VStack(spacing: 10) {
                field("Email", text: $email, secure: false)
                field("Password", text: $password, secure: true)
            }
            .padding(.top, 8)

            if let status {
                Text(status).font(UFont.sans(13))
                    .foregroundStyle(statusIsError ? theme.palette.red : theme.palette.ink2)
                    .multilineTextAlignment(.center)
            }

            UButton(mode == .signIn ? "Sign in" : "Create account") { Task { await submit() } }
            UButton("Continue with Google", kind: .ghost) { Task { await google() } }

            // Forgot password → send a RESET link (not a sign-in link). Sign-in
            // mode only, matching Android. Tells the user to check their email and
            // tap the link to set a new password.
            if mode == .signIn {
                Button("Forgot your password?") { Task { await forgotPassword() } }
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                    .buttonStyle(.plain)
            }

            Button(mode == .signIn ? "New here? Create an account" : "Have an account? Sign in") {
                mode = mode == .signIn ? .signUp : .signIn
                status = nil
            }
            .font(UFont.sans(13)).foregroundStyle(theme.palette.primary)
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.bg.ignoresSafeArea())
        .disabled(busy)
    }

    private func field(_ label: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(label, text: text) } else { TextField(label, text: text) }
        }
        .textFieldStyle(.plain)
        .font(UFont.sans(15))
        .padding(12)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
    }

    private func submit() async {
        guard let auth = model.coordinator?.auth else { return }
        busy = true; defer { busy = false }
        let outcome = mode == .signIn
            ? await auth.signIn(email: email, password: password)
            : await auth.signUp(email: email, password: password, displayName: nil)
        apply(outcome)
    }

    private func google() async {
        guard let auth = model.coordinator?.auth else { return }
        busy = true; defer { busy = false }
        apply(await auth.signInWithGoogle())
    }

    private func forgotPassword() async {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else {
            statusIsError = true; status = "Enter your email first, then tap “Forgot your password?”."
            return
        }
        guard let auth = model.coordinator?.auth else { return }
        busy = true; defer { busy = false }
        switch await auth.resetPassword(email: e) {
        case .ok:
            statusIsError = false
            status = "Check your email — tap the link to set a new password."
        case .error(let message):
            statusIsError = true; status = message
        default:
            statusIsError = false
            status = "Check your email — tap the link to set a new password."
        }
    }

    private func apply(_ outcome: AuthOutcome) {
        switch outcome {
        case .ok: status = nil
        case .needsConfirmation: statusIsError = false; status = "Check your email to confirm."
        case .alreadyExists: statusIsError = true; status = "That account already exists — try signing in."
        case .error(let message): statusIsError = true; status = message
        }
    }
}

/// Shown after a "forgot password" recovery link lands: the recovery session is
/// authenticated, so the user just chooses a new password (no current one). On
/// success, consumeRecovery() drops them into the app. Mirrors the Android
/// SetNewPasswordScreen.
struct SetNewPasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    @State private var password = ""
    @State private var confirm = ""
    @State private var status: String?
    @State private var busy = false

    private var error: String? {
        if !password.isEmpty && password.count < 8 { return "At least 8 characters." }
        if !confirm.isEmpty && confirm != password { return "Passwords don't match." }
        return nil
    }
    private var canSave: Bool { password.count >= 8 && password == confirm }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Wordmark(size: 28)
            Text("Choose a new password.")
                .font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                field("New password", text: $password)
                field("Confirm password", text: $confirm)
            }
            .padding(.top, 8)

            if let msg = status ?? error {
                Text(msg).font(UFont.sans(13)).foregroundStyle(theme.palette.red)
            }

            UButton("Set password") { Task { await save() } }
                .opacity(canSave ? 1 : 0.5)
                .disabled(!canSave)

            // Escape hatch: if they didn't mean to reset, sign out back to login.
            Button("Cancel") { model.consumeRecovery(); model.signOut() }
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.bg.ignoresSafeArea())
        .disabled(busy)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        SecureField(label, text: text)
            .textFieldStyle(.plain)
            .font(UFont.sans(15))
            .padding(12)
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(theme.palette.line))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
    }

    private func save() async {
        guard canSave, let auth = model.coordinator?.auth else { return }
        busy = true; defer { busy = false }
        // The recovery session lets us set the password without the old one.
        switch await auth.changePassword(password) {
        case .ok: model.consumeRecovery()   // drops into the app
        case .error(let message): status = message
        default: model.consumeRecovery()
        }
    }
}
