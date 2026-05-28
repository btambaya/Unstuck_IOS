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
                Text(status).font(UFont.sans(13)).foregroundStyle(theme.palette.red)
            }

            UButton(mode == .signIn ? "Sign in" : "Create account") { Task { await submit() } }
            UButton("Continue with Google", kind: .ghost) { Task { await google() } }

            Button(mode == .signIn ? "New here? Create an account" : "Have an account? Sign in") {
                mode = mode == .signIn ? .signUp : .signIn
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

    private func apply(_ outcome: AuthOutcome) {
        switch outcome {
        case .ok: status = nil
        case .needsConfirmation: status = "Check your email to confirm."
        case .alreadyExists: status = "That account already exists — try signing in."
        case .error(let message): status = message
        }
    }
}
