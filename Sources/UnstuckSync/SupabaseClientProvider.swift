// Builds + holds the shared SupabaseClient. PKCE flow (required for the
// OAuth / magic-link deep-link callback) + a custom `unstuck://`
// auth-redirect. The app injects the real URL + publishable key via
// SyncConfig (kept out of source — see .xcconfig / Secrets).

import Foundation
import Supabase

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
                    autoRefreshToken: true)))
    }
}
