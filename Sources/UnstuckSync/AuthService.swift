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
            _ = try await client.auth.signUp(email: email, password: password, data: data)
            return .ok
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

    public func resetPassword(email: String) async -> AuthOutcome {
        do { try await client.auth.resetPasswordForEmail(email); return .ok }
        catch { return .error(friendly(error)) }
    }

    /// Exchange a deep-link callback URL for a session (PKCE).
    public func handleCallback(url: URL) async -> AuthOutcome {
        do { _ = try await client.auth.session(from: url); return .ok }
        catch { return .error(friendly(error)) }
    }

    public func signOut() async {
        try? await client.auth.signOut()
    }

    public var currentUserId: String? {
        client.auth.currentSession?.user.id.uuidString
    }

    public var authStateChanges: AsyncStream<(event: AuthChangeEvent, session: Supabase.Session?)> {
        client.auth.authStateChanges
    }
}
