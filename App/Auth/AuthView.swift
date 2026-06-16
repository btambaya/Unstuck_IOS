// Email/password + magic link + Google + Sign in with Apple. Laid out to
// match the Android AuthScreen 1:1 (Orbit mark, WELCOME BACK eyebrow, serif
// headline, outlined social buttons, footer line). Sign in with Apple is
// required by App Store Guideline 4.8 since we offer Google; it's the one
// iOS-only element (Android has no Apple sign-in).

import SwiftUI
import AuthenticationServices
import CryptoKit
import UIKit
import UnstuckDesign
import UnstuckSync

struct AuthView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var mode: Mode = .signIn
    @State private var status: String?
    @State private var statusIsError = true
    @State private var busy = false

    enum Mode { case signIn, signUp }
    private var signUp: Bool { mode == .signUp }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Mark(size: 36)
                    .padding(.top, 30)

                Text(signUp ? "BEGIN AGAIN" : "WELCOME BACK")
                    .font(UFont.mono(11, .medium)).tracking(0.8)
                    .foregroundStyle(theme.palette.primaryDeep)
                    .padding(.top, 16)

                Text(signUp ? "You don't need more discipline." : "Pick up where\nyou left off.")
                    .font(UFont.serifItalic(40)).foregroundStyle(theme.palette.ink)
                    .multilineTextAlignment(.center).padding(.top, 8)

                Text(signUp ? "Unstuck reduces friction at the moment behavior breaks." : "Quiet clarity, with momentum.")
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                    .multilineTextAlignment(.center).padding(.top, 10)

                VStack(spacing: 14) {
                    if signUp { field("Name (optional)", text: $name) }
                    field("Email", text: $email, keyboard: .emailAddress)
                    field("Password", text: $password, secure: true)
                }
                .padding(.top, 22)

                if let status { banner(status) }

                UButton(busy ? "…" : (signUp ? "Create account" : "Sign in"), kind: .dark) {
                    Task { await submit() }
                }
                .padding(.top, 20)

                socialButton("Continue with Google", systemIcon: nil) { Task { await google() } }
                    .padding(.top, 10)
                socialButton("Continue with Apple", systemIcon: "apple.logo") { Task { await apple() } }
                    .padding(.top, 10)

                Button(signUp ? "Already have an account? Sign in" : "New here? Create an account") {
                    mode = signUp ? .signIn : .signUp; status = nil
                }
                .font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.primaryDeep)
                .buttonStyle(.plain).padding(.top, 16).padding(.vertical, 10)

                Button("Email me a magic link instead") { Task { await magicLink() } }
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                    .buttonStyle(.plain).padding(.vertical, 10)

                if !signUp {
                    Button("Forgot your password?") { Task { await forgotPassword() } }
                        .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                        .buttonStyle(.plain).padding(.vertical, 10)
                }

                Text(signUp ? "Quiet clarity, with momentum." : "The anchor stays steady. You move around it.")
                    .font(UFont.sans(11)).foregroundStyle(theme.palette.ink3)
                    .multilineTextAlignment(.center).padding(.top, 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22).padding(.bottom, 30)
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .disabled(busy)
    }

    // MARK: field (Material-style outlined, matches Android MdField)

    private func field(_ label: String, text: Binding<String>, secure: Bool = false, keyboard: UIKeyboardType = .default) -> some View {
        Group {
            if secure { SecureField(label, text: text) } else { TextField(label, text: text) }
        }
        .textFieldStyle(.plain)
        .font(UFont.sans(14))
        .padding(.horizontal, 14).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(theme.palette.line2))
        .keyboardType(keyboard)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    // MARK: banner (rounded, soft fill + icon — matches Android message banner)

    private func banner(_ msg: String) -> some View {
        HStack(spacing: 11) {
            Text(statusIsError ? "!" : "✓")
                .font(UFont.sans(16, .bold))
                .foregroundStyle(statusIsError ? theme.palette.coralDeep : theme.palette.greenInk)
            Text(msg)
                .font(UFont.sans(14, .medium))
                .foregroundStyle(statusIsError ? theme.palette.coralDeep : theme.palette.greenInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusIsError ? theme.palette.coralSoft : theme.palette.greenSoft,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 16)
    }

    // MARK: outlined social button (pill, matches Android Google button)

    private func socialButton(_ title: String, systemIcon: String?, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                if let systemIcon {
                    Image(systemName: systemIcon).font(.system(size: 17)).foregroundStyle(theme.palette.ink)
                } else {
                    GoogleG().frame(width: 18, height: 18)
                }
                Text(title).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
            }
            .padding(.vertical, 14).frame(maxWidth: .infinity)
            .background(theme.palette.surface, in: Capsule())
            .overlay(Capsule().stroke(theme.palette.line2))
        }
        .buttonStyle(.plain)
    }

    // MARK: actions

    private func submit() async {
        guard let auth = model.coordinator?.auth else { return }
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { statusIsError = true; status = "Enter your email first."; return }
        guard !password.isEmpty else { statusIsError = true; status = "Enter your password."; return }
        busy = true; defer { busy = false }
        let outcome = signUp
            ? await auth.signUp(email: e, password: password, displayName: name)
            : await auth.signIn(email: e, password: password)
        apply(outcome)
    }

    private func google() async {
        guard let auth = model.coordinator?.auth else { return }
        busy = true; defer { busy = false }
        apply(await auth.signInWithGoogle())
    }

    private func apple() async {
        guard let auth = model.coordinator?.auth else { return }
        busy = true; defer { busy = false }
        do {
            let rawNonce = Self.randomNonce()
            let idToken = try await AppleSignInCoordinator(hashedNonce: Self.sha256(rawNonce)).run()
            apply(await auth.signInWithApple(idToken: idToken, nonce: rawNonce))
        } catch {
            // User-cancelled or dismissed — stay silent (matches a no-op tap).
        }
    }

    private func magicLink() async {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { statusIsError = true; status = "Enter your email first."; return }
        guard let auth = model.coordinator?.auth else { return }
        busy = true; defer { busy = false }
        switch await auth.sendMagicLink(email: e) {
        case .error(let m): statusIsError = true; status = m
        default: statusIsError = false; status = "Check your email for a one-tap sign-in link."
        }
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
        case .error(let m): statusIsError = true; status = m
        default: statusIsError = false; status = "Check your email — tap the link to set a new password."
        }
    }

    private func apply(_ outcome: AuthOutcome) {
        switch outcome {
        case .ok: status = nil
        case .needsConfirmation: statusIsError = false; status = "Check your email to confirm your account, then sign in."
        case .alreadyExists: statusIsError = true; status = "That account already exists — try signing in."
        case .error(let message): statusIsError = true; status = message
        }
    }

    // MARK: nonce helpers (Apple requires a SHA-256 nonce on the request)

    static func randomNonce(_ length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if Int(random) < chars.count { result.append(chars[Int(random)]); remaining -= 1 }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The official multicolor Google "G" (bundled asset, rendered from the same
/// brand paths Android uses).
private struct GoogleG: View {
    var body: some View {
        Image("GoogleG").resizable().scaledToFit()
    }
}

/// Self-retaining bridge from ASAuthorizationController's delegate callbacks to
/// async/await. Holds a strong ref to itself until the flow finishes so it
/// isn't deallocated mid-request.
private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let hashedNonce: String
    private var continuation: CheckedContinuation<String, Error>?
    private var selfRef: AppleSignInCoordinator?

    init(hashedNonce: String) { self.hashedNonce = hashedNonce }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.selfRef = self
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = hashedNonce
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { selfRef = nil }
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: AuthError.noToken); return
        }
        continuation?.resume(returning: token)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        defer { selfRef = nil }
        continuation?.resume(throwing: error)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    enum AuthError: Error { case noToken }
}

/// Shown after a "forgot password" recovery link lands: the recovery session is
/// authenticated, so the user just chooses a new password. Mirrors the Android
/// SetNewPasswordScreen (eyebrow + serif headline).
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
        ScrollView {
            VStack(spacing: 0) {
                Mark(size: 36).padding(.top, 30)
                Text("SET A NEW PASSWORD")
                    .font(UFont.mono(11, .medium)).tracking(0.8)
                    .foregroundStyle(theme.palette.primaryDeep).padding(.top, 16)
                Text("Choose a new password.")
                    .font(UFont.serifItalic(34)).foregroundStyle(theme.palette.ink)
                    .multilineTextAlignment(.center).padding(.top, 8)

                VStack(spacing: 14) {
                    field("New password", text: $password)
                    field("Confirm password", text: $confirm)
                }
                .padding(.top, 22)

                if let msg = status ?? error {
                    Text(msg).font(UFont.sans(13)).foregroundStyle(theme.palette.coralDeep)
                        .multilineTextAlignment(.center).padding(.top, 12)
                }

                UButton(busy ? "…" : "Save password", kind: .dark) { Task { await save() } }
                    .opacity(canSave ? 1 : 0.5).disabled(!canSave).padding(.top, 20)

                Button("Cancel") { model.consumeRecovery(); model.signOut() }
                    .font(UFont.sans(13)).foregroundStyle(theme.palette.ink3)
                    .buttonStyle(.plain).padding(.top, 16)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22).padding(.bottom, 30)
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .disabled(busy)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        SecureField(label, text: text)
            .textFieldStyle(.plain).font(UFont.sans(14))
            .padding(.horizontal, 14).padding(.vertical, 14).frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(theme.palette.line2))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    private func save() async {
        guard canSave, let auth = model.coordinator?.auth else { return }
        busy = true; defer { busy = false }
        switch await auth.changePassword(password) {
        case .error(let message): status = message
        default: model.consumeRecovery()
        }
    }
}
