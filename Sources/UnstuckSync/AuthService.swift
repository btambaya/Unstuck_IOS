// AuthService — thin wrapper over supabase-swift Auth. Email/password,
// magic link, Google OAuth, deep-link session exchange, sign-out, and
// the auth-state stream. Error copy reuses UnstuckCore.humanizeAuthError.

import Foundation
import Supabase
import UnstuckCore

public enum AuthOutcome: Sendable, Equatable {
    case ok
    case error(String)
    case needsConfirmation
    case alreadyExists
}

public struct AuthService: Sendable {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    private func friendly(_ error: Error) -> String {
        // The supabase AuthError's description carries the server message
        // (e.g. "Invalid login credentials"), which humanizeAuthError keys on.
        humanizeAuthError(AuthErrorInfo(message: "\(error)"))
    }

    public func signIn(email: String, password: String) async -> AuthOutcome {
        do { _ = try await client.auth.signIn(email: email, password: password); return .ok }
        catch { return .error(friendly(error)) }
    }

    public func signUp(email: String, password: String, displayName: String?) async -> AuthOutcome {
        do {
            let data: [String: AnyJSON]? = displayName.flatMap { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : ["full_name": .string(trimmed), "display_name": .string(trimmed)]
            }
            let response = try await client.auth.signUp(email: email, password: password, data: data)
            let user = response.user
            let hasSession = client.auth.currentSession != nil
            // Supabase's anti-enumeration returns a "successful" obfuscated user for an
            // already-registered email (no session, empty identities). Surface it instead
            // of the misleading "check your email" — otherwise a returning user is stuck.
            let exists = detectSignupAlreadyExists(
                identitiesCount: user.identities?.count,
                emailConfirmedAt: user.emailConfirmedAt.map { "\($0)" },
                lastSignInAt: user.lastSignInAt.map { "\($0)" },
                hasSession: hasSession)
            if exists { return .alreadyExists }
            // A genuine new sign-up with no session yet needs email confirmation; with a
            // session (instant confirm) the auth-state stream navigates into the app.
            return hasSession ? .ok : .needsConfirmation
        } catch { return .error(friendly(error)) }
    }

    public func sendMagicLink(email: String) async -> AuthOutcome {
        do { try await client.auth.signInWithOTP(email: email); return .ok }
        catch { return .error(friendly(error)) }
    }

    /// Google sign-in (app auth, not calendar). The SDK presents
    /// ASWebAuthenticationSession internally and returns on the redirect.
    public func signInWithGoogle() async -> AuthOutcome {
        do { _ = try await client.auth.signInWithOAuth(provider: .google); return .ok }
        catch { return .error(friendly(error)) }
    }

    /// Sign in with Apple via a native ID token (ASAuthorization → Supabase
    /// signInWithIdToken). Required by App Store Guideline 4.8 because we also
    /// offer Google sign-in. `nonce` is the RAW nonce; Apple's request carried
    /// its SHA-256, and Supabase/GoTrue compares the hash against the token.
    public func signInWithApple(idToken: String, nonce: String) async -> AuthOutcome {
        do {
            _ = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
            return .ok
        } catch { return .error(friendly(error)) }
    }

    public func resetPassword(email: String) async -> AuthOutcome {
        do { try await client.auth.resetPasswordForEmail(email); return .ok }
        catch { return .error(friendly(error)) }
    }

    /// Change / add the account password (auth.updateUser). Mirrors Android.
    public func changePassword(_ newPassword: String) async -> AuthOutcome {
        do { _ = try await client.auth.update(user: UserAttributes(password: newPassword)); return .ok }
        catch { return .error(friendly(error)) }
    }

    /// Update the display name in user metadata (both keys, like sign-up).
    public func updateDisplayName(_ name: String) async -> AuthOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .error("Name can't be empty.") }
        do {
            _ = try await client.auth.update(user: UserAttributes(
                data: ["full_name": .string(trimmed), "display_name": .string(trimmed)]))
            return .ok
        } catch { return .error(friendly(error)) }
    }

    /// Delete the account via the server-side `account-delete` Edge Function
    /// (service-role wipe of every owned row + the auth user), then sign out.
    public func deleteAccount() async -> AuthOutcome {
        struct Empty: Encodable {}
        do {
            try await client.functions.invoke("account-delete",
                options: FunctionInvokeOptions(method: .post, body: Empty()))
            try? await client.auth.signOut()
            return .ok
        } catch { return .error(friendly(error)) }
    }

    /// True if the account has an email/password identity (vs Google-only) —
    /// gates "Change password" vs "Add a password" in Settings.
    public var hasPassword: Bool {
        client.auth.currentSession?.user.identities?.contains { $0.provider == "email" } ?? true
    }

    /// Re-authenticate with the current password before a sensitive change
    /// (password update). Returns .ok if the password is correct. Mirrors the
    /// Android Settings change-password reauth guard.
    public func reauthenticate(email: String, password: String) async -> AuthOutcome {
        do { _ = try await client.auth.signIn(email: email, password: password); return .ok }
        catch { return .error("Current password incorrect.") }
    }

    /// Exchange a deep-link callback URL for a session (PKCE).
    public func handleCallback(url: URL) async -> AuthOutcome {
        do { _ = try await client.auth.session(from: url); return .ok }
        catch { return .error(friendly(error)) }
    }

    public func signOut() async {
        try? await client.auth.signOut()
    }

    /// Lowercased to match the server: Foundation's UUID.uuidString is
    /// UPPERCASE, but every user_id string PostgREST/realtime returns is
    /// lowercase — an uppercase uid breaks every ownership/membership
    /// comparison (collections myRole/isOwner) and realtime filters.
    /// Matches UnstuckCore.newUUID(), which also lowercases.
    public var currentUserId: String? {
        client.auth.currentSession?.user.id.uuidString.lowercased()
    }

    /// The current session's JWT access token. The voice realtime proxy (CF
    /// Worker) validates it before bridging to DashScope, so the realtime client
    /// sends it as the `Authorization: Bearer` header.
    public var accessToken: String? {
        client.auth.currentSession?.accessToken
    }

    /// Signed-in user's email (denormalized into feedback + "who's on it" labels).
    public var currentEmail: String? {
        client.auth.currentSession?.user.email
    }

    /// Display name from auth metadata, falling back to the email's local-part.
    /// Mirrors the web `currentUserName` helper used for accountability chips.
    public var currentUserName: String? {
        Self.displayName(from: client.auth.currentSession)
    }

    /// Pure derivation of the display name from a session (full_name /
    /// display_name metadata → email local-part → email). Kept `static` so the
    /// app can cache identity from the `authStateChanges` session it ALREADY
    /// holds, instead of calling `currentSession` — that accessor runs storage
    /// migrations + a SYNCHRONOUS keychain read (SecItemCopyMatching) + a JSON
    /// decode on EVERY call, and doing that on the main thread during a SwiftUI
    /// view body (the avatar top-bar) stalled the CATransaction commit that a
    /// notification-tap state-restoration snapshot asserts on → SIGABRT on
    /// TestFlight (crash reported on build ≤22).
    public static func displayName(from session: Supabase.Session?) -> String? {
        let meta = session?.user.userMetadata
        if let v = meta?["full_name"], case let .string(s) = v, !s.isEmpty { return s }
        if let v = meta?["display_name"], case let .string(s) = v, !s.isEmpty { return s }
        let email = session?.user.email
        if let email, let at = email.firstIndex(of: "@") { return String(email[..<at]) }
        return email
    }

    /// Email from a session (companion to `displayName(from:)` for cached identity).
    public static func email(from session: Supabase.Session?) -> String? { session?.user.email }

    /// Lowercased user id from a session (server uuids are lowercase — see
    /// `currentUserId`). For caching identity off the authStateChanges session so
    /// render-path callers (isShared/isOwner) don't hit `currentSession` (a
    /// synchronous keychain read) during a view body — the T4 crash class.
    public static func userId(from session: Supabase.Session?) -> String? {
        session?.user.id.uuidString.lowercased()
    }

    /// Whether the session's user has an email/password identity (vs Google-only).
    /// Cached companion to `hasPassword` so Settings doesn't read `currentSession`
    /// during render. Defaults true (matches the instance accessor).
    public static func hasPassword(from session: Supabase.Session?) -> Bool {
        session?.user.identities?.contains { $0.provider == "email" } ?? true
    }

    public var authStateChanges: AsyncStream<(event: AuthChangeEvent, session: Supabase.Session?)> {
        client.auth.authStateChanges
    }
}
