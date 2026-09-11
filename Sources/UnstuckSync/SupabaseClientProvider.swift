// Builds + holds the shared SupabaseClient. PKCE flow (required for the
// OAuth / magic-link deep-link callback) + a custom `unstuck://`
// auth-redirect. The app injects the real URL + publishable key via
// SyncConfig (kept out of source — see .xcconfig / Secrets).

import Foundation
import os
import Supabase

#if DEBUG
/// DEBUG only: pipes the SDK's own log lines into os_log. Without it the Auth
/// client swallows its storage failures — a keychain read that fails (an
/// unsigned dev build has no `application-identifier`, so every SecItem call
/// returns errSecMissingEntitlement −34018) just makes `currentSession` nil,
/// which reads as "signed out" with no explanation anywhere. Never compiled
/// into Release: these lines include request URLs.
struct OSLogSupabaseLogger: SupabaseLogger {
    static let log = Logger(subsystem: "io.unstucknow.app", category: "supabase")
    func log(message: SupabaseLogMessage) {
        Self.log.debug("\(message.description, privacy: .public)")
    }
}
#endif

public struct SyncConfig: Sendable {
    public let url: URL
    public let anonKey: String
    /// Deep-link the Supabase auth callback returns to (Info.plist scheme).
    public let authRedirectURL: URL

    public init(url: URL, anonKey: String, authRedirectURL: URL) {
        self.url = url
        self.anonKey = anonKey
        self.authRedirectURL = authRedirectURL
    }
}

public struct SupabaseClientProvider: Sendable {
    public let client: SupabaseClient

    public init(_ config: SyncConfig) {
        client = SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.anonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    redirectToURL: config.authRedirectURL,
                    flowType: .pkce,
                    autoRefreshToken: true,
                    // Emit the locally-stored session as the initial session so an
                    // OFFLINE launch with an expired access token stays signed in.
                    // The SDK's legacy default (false) runs `try? await session` at
                    // launch, which auto-refreshes the expired token and yields nil
                    // when offline → `.initialSession(nil)` → the app wrongly logged
                    // the user out (and scrubbed device-local data). With true, the
                    // stored session is emitted immediately and the refresh retries
                    // in the background once connectivity returns.
                    emitLocalSessionAsInitialSession: true),
                global: SupabaseClientOptions.GlobalOptions(logger: Self.debugLogger)))
    }

    /// DEBUG builds get the SDK's own diagnostics (see OSLogSupabaseLogger); a
    /// Release build gets none.
    private static var debugLogger: (any SupabaseLogger)? {
        #if DEBUG
        return OSLogSupabaseLogger()
        #else
        return nil
        #endif
    }
}
