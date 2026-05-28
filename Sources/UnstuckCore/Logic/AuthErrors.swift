// Pure auth helpers. Port of the testable parts of lib/auth-helpers.ts:
// the humanizeAuthError mapping table, the nextSafePath open-redirect
// guard, and the pure "already exists" anti-enumeration detector. The
// networked sign-in/up/out calls (Supabase) live in UnstuckSync.

import Foundation

/// Minimal shape of a Supabase AuthError for the mapping table.
public struct AuthErrorInfo: Sendable, Equatable {
    public var code: String?
    public var message: String?
    public var status: Int?
    public init(code: String? = nil, message: String? = nil, status: Int? = nil) {
        self.code = code
        self.message = message
        self.status = status
    }
}

/// Map Supabase's technical error messages to copy a human can act on.
public func humanizeAuthError(_ err: AuthErrorInfo?) -> String {
    guard let err else { return "Something went wrong. Try again in a moment." }
    let code = err.code ?? ""
    let message = (err.message ?? "").lowercased()
    let status = err.status

    if code == "over_email_send_rate_limit" || message.contains("rate limit") {
        return "We can only send a few sign-up emails per hour. Wait ~30 min and try again — or use a different email."
    }
    if code == "invalid_credentials" || message.contains("invalid login credentials") || message.contains("invalid_credentials") {
        return "That email and password don't match. Try again, or use Forgot password."
    }
    if code == "user_already_exists" || message.contains("already registered") || message.contains("user already") {
        return "An account with that email already exists. Try signing in instead."
    }
    if code == "email_not_confirmed" || message.contains("email not confirmed") {
        return "Your email isn't confirmed yet. Check your inbox for the verification link."
    }
    if code == "weak_password" || message.contains("password should be") {
        return "Password needs at least 8 characters."
    }
    if code == "over_request_rate_limit" || status == 429 {
        return "You hit a rate limit. Slow down for a minute and try again."
    }
    if message.contains("network") || message.contains("failed to fetch") || message.contains("timed out") {
        return "Couldn't reach the server. Check your connection and try again."
    }
    if message.contains("invalid email") || code == "validation_failed" {
        return "That email address looks off. Double-check it."
    }
    // Fallback — capitalise the first letter, keep the rest readable.
    let raw = err.message ?? "Unknown error"
    guard let first = raw.first else { return raw }
    return first.uppercased() + raw.dropFirst()
}

/// Validate a `?next=` redirect: allow only same-origin paths starting
/// with a single `/` (open-redirect guard). Mirrors `nextSafePath`.
public func nextSafePath(_ raw: String?, fallback: String = "/dashboard") -> String {
    guard let raw, !raw.isEmpty else { return fallback }
    // decodeURIComponent throws on malformed encoding → fallback.
    guard let decoded = raw.removingPercentEncoding else { return fallback }
    if !decoded.hasPrefix("/") { return fallback }
    if decoded.hasPrefix("//") { return fallback }
    return decoded
}

/// Supabase's sign-up anti-enumeration response is "successful" even for
/// an already-registered email; these are the tells (any one ⇒ exists).
/// Pure so UnstuckSync can feed it the decoded signup response fields.
public func detectSignupAlreadyExists(
    identitiesCount: Int?,
    emailConfirmedAt: String?,
    lastSignInAt: String?,
    hasSession: Bool
) -> Bool {
    let emptyIdentities = identitiesCount == 0
    let confirmedNoSession = emailConfirmedAt != nil && !hasSession
    let previouslySignedInNoSession = lastSignInAt != nil && !hasSession
    return emptyIdentities || confirmedNoSession || previouslySignedInNoSession
}
