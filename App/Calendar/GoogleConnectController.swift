// Google Calendar connect via the existing server flow (no new OAuth
// client). authorize → consent in ASWebAuthenticationSession → capture the
// redirect's ?code= → connectGoogle (server exchanges the code).
//
// Google blocks custom schemes for WEB OAuth clients, so the registered
// redirect is an HTTPS Universal Link; that page must bounce to
// `unstuck://calendar-callback?code=…&state=…` so ASWebAuthenticationSession
// (callbackURLScheme: "unstuck") can capture it. Register the redirect on
// the existing web client + ship the AASA (see handover manual step 6).

import Foundation
import AuthenticationServices
import UIKit
import UnstuckSync

/// What connecting Google Calendar does, said before Google's consent opens
/// (CalendarSyncBar). Unstuck pulls the user's Google events AND writes every
/// scheduled task block to their PRIMARY calendar with the task's name as the
/// event title (AppModel.mirrorBlockToGoogle) — the connect pill used to go
/// straight to consent without a word about the writing. Web's words
/// (sync-flow.tsx, W14), as on Android (A19) (web/Android audit 2026-09-23,
/// W14/A19).
enum GoogleConnectCopy {
    static let disclosure =
        "Unstuck shows your Google events here, so your plans fit around them.\n\n"
        + "Each task you schedule becomes an event on your main Google Calendar, and moves or disappears "
        + "when you change it here. Anyone who can see that calendar sees the task’s name."

    /// The disclosure's title for a first connect or a reconnect.
    static func title(reconnect: Bool) -> String {
        reconnect ? "Reconnect Google Calendar?" : "Connect Google Calendar?"
    }
}

@MainActor
final class GoogleConnectController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let calendar: CalendarClient
    /// HTTPS redirect registered on the web Google client; the
    /// /calendar-callback page bounces to unstuck://calendar-callback, which
    /// ASWebAuthenticationSession (callbackURLScheme "unstuck") captures.
    private let redirectUri = "https://unstuck-602.pages.dev/calendar-callback"
    private var session: ASWebAuthenticationSession?

    init(_ calendar: CalendarClient) { self.calendar = calendar }

    func connect() async -> Result<CalendarClient.ConnectResponse, Error> {
        do {
            let auth = try await calendar.authorize(redirectUri: redirectUri)
            guard let url = URL(string: auth.url) else { return .failure(ConnectError.badURL) }
            let callback = try await presentConsent(url: url)
            // RFC 6749 §10.12: the state echoed back in the redirect must
            // equal the one minted for THIS consent — otherwise an
            // attacker-substituted callback could have its code exchanged
            // under our valid signed state (Android completeGoogleConnect
            // applies the same guard).
            guard queryItem(callback, "state") == auth.state else {
                return .failure(ConnectError.stateMismatch)
            }
            guard let code = queryItem(callback, "code") else { return .failure(ConnectError.noCode) }
            let conn = try await calendar.connectGoogle(code: code, redirectUri: redirectUri, state: auth.state)
            return .success(conn)
        } catch {
            return .failure(error)
        }
    }

    private func presentConsent(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let webSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "unstuck") { callbackURL, error in
                if let callbackURL { continuation.resume(returning: callbackURL) }
                else { continuation.resume(throwing: error ?? ConnectError.cancelled) }
            }
            webSession.presentationContextProvider = self
            webSession.prefersEphemeralWebBrowserSession = false
            session = webSession
            webSession.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    private func queryItem(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    enum ConnectError: Error { case badURL, noCode, stateMismatch, cancelled }
}
