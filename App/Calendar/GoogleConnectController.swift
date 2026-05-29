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

@MainActor
final class GoogleConnectController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let calendar: CalendarClient
    /// HTTPS Universal Link registered on the web Google client; bounces to
    /// unstuck://calendar-callback.
    private let redirectUri = "https://unstuck-602.pages.dev/calendar/ios-callback"
    private var session: ASWebAuthenticationSession?

    init(_ calendar: CalendarClient) { self.calendar = calendar }

    func connect() async -> Result<CalendarClient.ConnectResponse, Error> {
        do {
            let auth = try await calendar.authorize(redirectUri: redirectUri)
            guard let url = URL(string: auth.url) else { return .failure(ConnectError.badURL) }
            let callback = try await presentConsent(url: url)
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

    enum ConnectError: Error { case badURL, noCode, cancelled }
}
