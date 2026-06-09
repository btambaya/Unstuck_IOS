// FeedbackClient — one-way in-app beta feedback to the `feedback` table
// (migration 027), 1:1 with sync/FeedbackClient.kt. Online-only; returns a
// Bool so the composer can surface a "couldn't send" retry. The submitter's
// context (app version, platform, device, screen, email) is attached so a
// one-line report is still actionable in the dashboard. Owner RLS keys on
// user_id; `email` is denormalized for triage convenience.

import Foundation
import Supabase

public struct FeedbackClient: Sendable {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    // Every field is set explicitly — Supabase omits nil from JSON payloads,
    // so a column the server stores would silently never sync if absent.
    private struct Row: Encodable, Sendable {
        let id: String
        let body: String
        let category: String?
        let user_id: String
        let email: String?
        let app_version: String?
        let platform: String
        let device: String?
        let screen: String?
    }

    /// Insert a feedback row. Returns true on success, false on any failure
    /// (offline / auth / server) so the caller can show a retry message.
    public func submit(
        id: String,
        body: String,
        category: String?,
        email: String?,
        appVersion: String?,
        platform: String,
        device: String?,
        screen: String?
    ) async -> Bool {
        // Lowercased like AuthService.currentUserId — server uuids are lowercase.
        guard let userId = client.auth.currentSession?.user.id.uuidString.lowercased() else { return false }
        do {
            _ = try await client.from("feedback").insert(
                Row(id: id, body: body, category: category, user_id: userId, email: email,
                    app_version: appVersion, platform: platform, device: device, screen: screen)
            ).execute()
            return true
        } catch {
            return false
        }
    }
}
