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

/// The result of an app-confirm email link (see AppConfirmLink).
public enum EmailLinkOutcome: Sendable, Equatable {
    /// A session came back; the SDK has emitted `.signedIn`.
    case signedIn
    /// The email is confirmed but there's no session — sign in.
    case confirmedNoSession
    case failed(EmailLinkFailure)
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
            // The app-confirm redirect: the confirmation email then links to
            // https://unstucknow.io/auth/app-confirm/?token_hash=… — the app on a
            // phone, a web page on a computer (AppConfirmLink).
            let response = try await client.auth.signUp(email: email, password: password, data: data,
                                                        redirectTo: AppConfirmLink.redirectURL)
            return Self.signUpOutcome(user: response.user, hasSession: client.auth.currentSession != nil)
        } catch { return .error(friendly(error)) }
    }

    /// What a sign-up response means. Supabase's anti-enumeration answers an
    /// ALREADY-registered, confirmed email with 200, NO session, NO email sent,
    /// and an obfuscated user whose `identities` is `[]` (GoTrue sanitizeUser;
    /// a genuine new sign-up has one identity). supabase-swift decodes that
    /// body as `AuthResponse.user` with `identities == []` (User.init(from:)
    /// uses decodeIfPresent, so a missing key is nil — which must NOT count).
    /// Surfaced as `.alreadyExists` instead of the dead-end "check your email".
    static func signUpOutcome(user: User, hasSession: Bool) -> AuthOutcome {
        let exists = detectSignupAlreadyExists(
            identitiesCount: user.identities?.count,
            emailConfirmedAt: user.emailConfirmedAt.map { "\($0)" },
            lastSignInAt: user.lastSignInAt.map { "\($0)" },
            hasSession: hasSession)
        if exists { return .alreadyExists }
        // A genuine new sign-up with no session yet needs email confirmation; with a
        // session (instant confirm) the auth-state stream navigates into the app.
        return hasSession ? .ok : .needsConfirmation
    }

    /// Same app-confirm redirect as sign-up (a magic link for a new address
    /// is sent as the sign-up confirmation).
    public func sendMagicLink(email: String) async -> AuthOutcome {
        do { try await client.auth.signInWithOTP(email: email, redirectTo: AppConfirmLink.redirectURL); return .ok }
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

    /// Keeps the client default `unstuck://auth-callback` (the PKCE `?code`
    /// link + the JWT `amr` recovery probe) — deliberately NOT app-confirm.
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

    /// Trade an app-confirm link's token hash for a session
    /// (verifyOTP(tokenHash:type:) — needs no PKCE verifier, so it works
    /// whichever device asked for the email). On success the SDK stores the
    /// session and emits `.signedIn`, exactly as the auth-callback exchange does.
    public func verifyEmailLink(tokenHash: String, kind: EmailLinkKind) async -> EmailLinkOutcome {
        let type: EmailOTPType
        switch kind {
        case .signup: type = .signup
        case .magiclink: type = .magiclink
        case .email: type = .email
        }
        do {
            let response = try await client.auth.verifyOTP(tokenHash: tokenHash, type: type)
            return response.session != nil ? .signedIn : .confirmedNoSession
        } catch {
            return .failed(classifyEmailLinkVerifyError(Self.errorInfo(error)))
        }
    }

    /// Supabase's own PKCE redirect to `unstuck://auth-confirm?code=…` (a
    /// template that still used {{ .ConfirmationURL }}). A code means the
    /// server already confirmed the email, so a failed exchange (no verifier
    /// here — the email was asked for elsewhere) is "confirmed, sign in"
    /// unless it looks like the network.
    public func exchangeEmailLinkCode(url: URL) async -> EmailLinkOutcome {
        do { _ = try await client.auth.session(from: url); return .signedIn }
        catch { return Self.isNetworkError(error) ? .failed(.retry) : .confirmedNoSession }
    }

    /// The SDK error in the shape `classifyEmailLinkVerifyError` reads.
    static func errorInfo(_ error: Error) -> AuthErrorInfo {
        guard let e = error as? AuthError else { return AuthErrorInfo(message: "\(error)") }
        var status: Int?
        if case let .api(_, _, _, response) = e { status = response.statusCode }
        return AuthErrorInfo(code: e.errorCode.rawValue, message: e.message, status: status)
    }

    static func isNetworkError(_ error: Error) -> Bool {
        error is URLError || (error as NSError).domain == NSURLErrorDomain
    }

    /// The ordinary Sign out row signs out THIS device only. The SDK default
    /// is `.global`, which revoked every session on the account — the other
    /// devices then took a reactive sign-out that destroyed their in-progress
    /// focus session. A "sign out everywhere" action would pass `.global`.
    public static let signOutScope: SignOutScope = .local

    public func signOut(scope: SignOutScope = AuthService.signOutScope) async {
        try? await client.auth.signOut(scope: scope)
    }

    /// Lowercased to match the server: Foundation's UUID.uuidString is
    /// UPPERCASE, but every user_id string PostgREST/realtime returns is
    /// lowercase — an uppercase uid breaks every ownership/membership
    /// comparison (collections myRole/isOwner) and realtime filters.
    /// Matches UnstuckCore.newUUID(), which also lowercases.
    public var currentUserId: String? {
        client.auth.currentSession?.user.id.uuidString.lowercased()
    }

    /// The STORED session's JWT access token (`currentSession`) — it may be
    /// hours expired: the SDK refreshes only while the app is ACTIVE. A caller
    /// that hands the JWT to a service itself (the voice proxy) dials with
    /// `freshAccessToken` instead (audit 2026-09-22, C14).
    public var accessToken: String? {
        client.auth.currentSession?.accessToken
    }

    /// A JWT that is valid NOW and still has `minValidity` seconds left, for a
    /// caller that hands it to a service itself rather than going through the
    /// SDK (the voice proxy, which validates it at connect and keeps using it
    /// for the whole session). Why (audit 2026-09-22, C14/C15): supabase-swift
    /// auto-refreshes only while the app is ACTIVE, and a call answered on the
    /// lock screen never activates it, so the stored token can be hours
    /// expired; and `auth.session` alone refreshes only inside its 30 s
    /// margin, so a session could still outlive its token.
    ///
    /// `forceRefresh` (after the server rejected the token) always refreshes
    /// and never returns the stored token. nil = no session, a failed forced
    /// refresh, or `deadline` passed; a refresh that loses the deadline keeps
    /// running and still lands through `.tokenRefreshed`. A still-valid token
    /// that is only short of `minValidity` waits at most `topUpDeadline` for
    /// its top-up, then is used as it is.
    public func freshAccessToken(minValidity: TimeInterval, forceRefresh: Bool = false,
                                 deadline: TimeInterval, topUpDeadline: TimeInterval) async -> String? {
        let client = self.client
        return await Self.firstWithin(deadline) {
            await Self.resolveFreshToken(
                minValidity: minValidity, forceRefresh: forceRefresh, topUpDeadline: topUpDeadline,
                now: { Date().timeIntervalSince1970 },
                // `auth.session` refreshes an expired token (or one inside
                // its 30 s margin) and joins a refresh already in flight.
                current: { let s = try await client.auth.session; return (s.accessToken, s.expiresAt) },
                // NO argument: the refresh token is read at call time. Passing
                // one read earlier could race a rotation into
                // `refresh_token_already_used`, which the SDK treats as a sign-out.
                refresh: { try await client.auth.refreshSession().accessToken })
        }
    }

    /// The rules of `freshAccessToken`, over injected closures so they are
    /// testable without a server. `expiresAt` is the session's `expires_at`
    /// (the JWT's `exp`), in epoch seconds like `now`.
    static func resolveFreshToken(
        minValidity: TimeInterval, forceRefresh: Bool, topUpDeadline: TimeInterval,
        now: @escaping @Sendable () -> TimeInterval,
        current: @escaping @Sendable () async throws -> (token: String, expiresAt: TimeInterval),
        refresh: @escaping @Sendable () async throws -> String
    ) async -> String? {
        // The server just refused the stored token — never hand it back.
        if forceRefresh {
            guard let t = try? await refresh(), !t.isEmpty else { return nil }
            return t
        }
        guard let cur = try? await current(), !cur.token.isEmpty else { return nil }
        if cur.expiresAt - now() >= minValidity { return cur.token }
        // Valid (`current` refreshes anything inside the SDK's 30 s margin),
        // just short of `minValidity`: top it up, but never make a dial wait
        // long for a token it doesn't strictly need.
        let topped = await firstWithin(topUpDeadline) { try? await refresh() }
        if let topped, !topped.isEmpty { return topped }
        return cur.token
    }

    /// `op`'s answer, or nil once `seconds` pass — whichever comes first. Not
    /// a task group (AppModel's `withDeadline`): the SDK's refresh is awaited
    /// through `inFlightRefreshTask.value`, which ignores cancellation, so a
    /// group would sit out the whole stalled refresh (URLSession's 60 s × the
    /// SDK's retries). The losing `op` keeps running; its result is dropped.
    public static func firstWithin<T: Sendable>(_ seconds: TimeInterval,
                                                _ op: @escaping @Sendable () async -> T?) async -> T? {
        let claimed = MutableFlag(false)
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let sleeper = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if !claimed.swap(true) { cont.resume(returning: nil) }
            }
            Task {
                let value = await op()
                if !claimed.swap(true) {
                    sleeper.cancel()
                    cont.resume(returning: value)
                }
            }
        }
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
