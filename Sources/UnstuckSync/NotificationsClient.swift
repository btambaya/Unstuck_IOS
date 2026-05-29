// Calls the notification Edge Functions: session-recap (on session end)
// and paused-checkin (cap coordination for the local paused-too-long
// notif). Best-effort — failures are swallowed by callers.

import Foundation
import Supabase

public struct NotificationsClient: Sendable {
    let client: SupabaseClient
    public init(_ client: SupabaseClient) { self.client = client }

    public func sessionRecap(taskName: String, away: Bool) async throws {
        struct Body: Encodable { let taskName: String; let away: Bool }
        try await client.functions.invoke(
            "send-session-recap",
            options: FunctionInvokeOptions(method: .post, body: Body(taskName: taskName, away: away)))
    }

    /// Returns whether a paused-checkin notification is allowed (cap +
    /// preference). Defaults to true if the server can't be reached.
    public func pausedCheckin() async throws -> Bool {
        struct Empty: Encodable {}
        struct Response: Decodable { let allowed: Bool? }
        let response: Response = try await client.functions.invoke(
            "send-paused-checkin",
            options: FunctionInvokeOptions(method: .post, body: Empty()))
        return response.allowed ?? false
    }
}

public struct PreferencesClient: Sendable {
    let client: SupabaseClient
    public init(_ client: SupabaseClient) { self.client = client }

    /// Persist onboarding struggle selections to user_preferences (PK'd on
    /// user_id, so a dedicated upsert path rather than the generic gateway).
    public func setAdhdStruggles(userId: String, struggles: [String]) async throws {
        struct Row: Encodable { let user_id: String; let adhd_struggles: [String] }
        _ = try await client.from("user_preferences")
            .upsert(Row(user_id: userId, adhd_struggles: struggles), onConflict: "user_id")
            .execute()
    }
}
