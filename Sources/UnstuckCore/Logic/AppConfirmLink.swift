// App-confirm email links (owner decision 2026-09-23: "Proper fix in the apps").
//
// The sign-up and magic-link emails the app asks for used to carry Supabase's
// own link, which ends at `unstuck://auth-callback?code=…`. A phone opens that;
// a computer can't, so an app sign-up whose email was read on a laptop hit a
// dead end. The app now asks with redirect `unstuck://auth-confirm`, and the
// templates turn that into
//
//     https://unstucknow.io/auth/app-confirm/?token_hash=<hash>&type=<signup|magiclink>
//
// On a phone with the app, that path is a Universal Link (the AASA claims
// /auth/app-confirm and /auth/app-confirm/* for this app only), so the app opens
// and trades the hash for a session with verifyOTP(tokenHash:type:). On a
// computer the same URL is a web page that confirms the address and says
// "open the app". Same contract as the web and Android.
//
// This file is the pure part: which URLs are ours and what they carry, why a
// verify failed, and the words for it. Mirrors the web's lib/email-link.ts
// (same 1024-character cap, same type spellings, same failure classes).

import Foundation

/// The email-link kinds the app finishes in-app — the verifyOTP type. Same
/// spelling as Supabase's own links. Password reset is NOT here: it keeps
/// `unstuck://auth-callback` and the JWT `amr` recovery probe.
public enum EmailLinkKind: String, Sendable, Equatable, CaseIterable {
    case signup
    case magiclink
    case email
}

/// Why an email link didn't work (the web's EmailLinkFailure).
public enum EmailLinkFailure: String, Sendable, Equatable {
    /// GoTrue says invalid or expired. It gives the same answer for a link
    /// already used and one that timed out, and a used sign-up link DID
    /// confirm the email — so the way on is "sign in".
    case used
    /// The link itself is malformed: no hash, an oversized one, a type the
    /// app doesn't finish.
    case invalid
    /// Network, timeout, rate limit or a server error — the link may well
    /// still be good, so tapping it again is the way on.
    case retry

    /// The sign-in screen's line for this failure.
    public var message: String {
        switch self {
        case .used:
            return "That link has already been used or has expired. If you’ve confirmed your email, just sign in — or send yourself a new link."
        case .invalid:
            return "That link looks incomplete. Sign in below, or send yourself a new link."
        case .retry:
            return "Couldn’t reach the server to check that link. Check your connection, then tap the link again."
        }
    }
}

/// What an app-confirm link asks the app to do.
public enum AppConfirmLink: Sendable, Equatable {
    /// A token-hash link: verify it in-app (verifyOTP(tokenHash:type:)).
    case verify(tokenHash: String, kind: EmailLinkKind)
    /// Supabase's own PKCE redirect to `unstuck://auth-confirm?code=…` — what
    /// a template that still used {{ .ConfirmationURL }} for this redirect
    /// would produce. Exchanged like `unstuck://auth-callback`.
    case exchangeCode
    /// Ours, but it can't be used: malformed, or Supabase's error redirect
    /// (`#error_code=otp_expired`).
    case unusable(EmailLinkFailure)

    /// The redirect the app sends with sign-up and magic-link requests. The
    /// templates key on this exact string; it is on the Supabase allow list.
    public static let redirectTo = "unstuck://auth-confirm"
    /// `redirectTo` as a URL (a literal, so the unwrap cannot fail).
    public static let redirectURL = URL(string: redirectTo)!
    /// The custom-scheme host of `redirectTo`.
    public static let schemeHost = "auth-confirm"
    /// The Universal Link path the AASA claims for the app.
    public static let webPath = "/auth/app-confirm"
    /// The hosts the app's `applinks:` entitlement can deliver.
    public static let webHosts: Set<String> = ["unstucknow.io", "www.unstucknow.io"]
    /// Same cap as the web page: a real hash is ~61 characters ("pkce_" + 56 hex).
    public static let maxTokenHashLength = 1024

    /// nil = not an app-confirm link (route it elsewhere). Otherwise what to do
    /// with it. Accepts `https://unstucknow.io/auth/app-confirm[/]?…` and,
    /// defensively, `unstuck://auth-confirm?…`. Unknown extra parameters
    /// (redirect_to, utm_*) are ignored.
    public static func parse(_ url: URL) -> AppConfirmLink? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased() else { return nil }
        let host = comps.host?.lowercased() ?? ""
        let isCustomScheme: Bool
        switch scheme {
        case "https":
            guard webHosts.contains(host) else { return nil }
            let path = trimmingTrailingSlashes(comps.path)
            if path == webPath {
                isCustomScheme = false
            } else if path.hasPrefix(webPath + "/") {
                // Under the claimed prefix, but not the page: it opened the app,
                // so say so rather than dropping it on the floor.
                return .unusable(.invalid)
            } else {
                return nil
            }
        case "unstuck":
            guard host == schemeHost else { return nil }
            let path = trimmingTrailingSlashes(comps.path)
            guard path.isEmpty || path == "/" else { return .unusable(.invalid) }
            isCustomScheme = true
        default:
            return nil
        }

        let params = parameters(comps)
        // Supabase's verify endpoint redirects failures with the reason in the
        // fragment (#error=access_denied&error_code=otp_expired&…).
        if params["error"] != nil || params["error_code"] != nil || params["error_description"] != nil {
            return .unusable(.used)
        }
        let hash = params["token_hash"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if hash.isEmpty {
            // Only Supabase's own redirect (custom scheme) carries a `code`.
            if isCustomScheme, let code = params["code"], !code.isEmpty { return .exchangeCode }
            return .unusable(.invalid)
        }
        guard hash.count <= maxTokenHashLength,
              let kind = params["type"].flatMap(EmailLinkKind.init(rawValue:)) else {
            return .unusable(.invalid)
        }
        return .verify(tokenHash: hash, kind: kind)
    }

    /// Query items, then fragment pairs that aren't already set; the first
    /// occurrence of a name with a value wins (a link with two `token_hash`es
    /// uses the first).
    private static func parameters(_ comps: URLComponents) -> [String: String] {
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] where out[item.name] == nil {
            if let value = item.value, !value.isEmpty { out[item.name] = value }
        }
        // Split by hand: handing the fragment to a URLComponents setter would
        // trap on a badly percent-encoded string.
        for pair in (comps.percentEncodedFragment ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, !kv[1].isEmpty, let name = String(kv[0]).removingPercentEncoding,
                  !name.isEmpty, out[name] == nil else { continue }
            out[name] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }
        return out
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// Classify a failed verifyOTP(tokenHash:) — port of the web's
/// classifyVerifyError. `otp_expired`, or a 403 that says expired/invalid, is a
/// used link; a malformed request is invalid; anything else (network, timeout,
/// 429, 5xx) may still be a good link.
public func classifyEmailLinkVerifyError(_ err: AuthErrorInfo) -> EmailLinkFailure {
    let code = err.code ?? ""
    let message = (err.message ?? "").lowercased()
    if code == "otp_expired" { return .used }
    if err.status == 403, message.contains("expired") || message.contains("invalid") { return .used }
    if code == "validation_failed" || code == "bad_json" { return .invalid }
    return .retry
}

/// The line when the link confirmed the email but no session came back.
public let emailLinkConfirmedSignInMessage = "Your email is confirmed. Sign in to continue."

/// The notice when an app-confirm link arrives while an account is already
/// signed in here. The app does NOT use the link (that would swap accounts
/// silently); it stays good for after a sign-out.
public func emailLinkAlreadySignedInMessage(email: String?) -> String {
    let who = email.flatMap { $0.isEmpty ? nil : " as \($0)" } ?? ""
    return "You’re already signed in\(who). If that link was for a different account, sign out first (Settings), then tap the link again."
}
