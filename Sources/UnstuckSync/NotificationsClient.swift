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

    /// Mirror the device NotificationLevel to notification_preferences
    /// (owner-self RLS) so the server-driven morning brief + paused-checkin
    /// cap honour it (spec 10 §1.12). Only the level-derived toggles are
    /// sent; other columns keep their values (Android PreferencesClient).
    public func setNotificationLevel(userId: String, morningBrief: Bool, pausedCheckin: Bool) async throws {
        struct Row: Encodable {
            let user_id: String
            let morning_brief_enabled: Bool
            let paused_checkin_enabled: Bool
        }
        _ = try await client.from("notification_preferences")
            .upsert(Row(user_id: userId, morning_brief_enabled: morningBrief,
                        paused_checkin_enabled: pausedCheckin), onConflict: "user_id")
            .execute()
    }

    /// Mirror the usable-minutes budget (Settings / the assistant's
    /// `set_usable_minutes`) to user_preferences — upsert on user_id, like the
    /// web `setUsableMinutes`. A nil value is NOT sent (synthesised Encodable
    /// omits nil optionals), so that column keeps what it had — PostgREST
    /// updates only the columns present. Columns: usable_minutes_per_day /
    /// usable_minutes_weekend (migration 007; check 1…1440 — callers validate).
    public func setUsableMinutes(userId: String, perDay: Int?, weekend: Int?) async throws {
        struct Row: Encodable {
            let user_id: String
            let usable_minutes_per_day: Int?
            let usable_minutes_weekend: Int?
        }
        _ = try await client.from("user_preferences")
            .upsert(Row(user_id: userId, usable_minutes_per_day: perDay, usable_minutes_weekend: weekend),
                    onConflict: "user_id")
            .execute()
    }

    /// Same, for the signed-in user (resolved from the current session —
    /// lowercase uuid, matching AuthService.currentUserId). Throws
    /// `PreferencesClientError.notSignedIn` when there's no session.
    public func setUsableMinutes(perDay: Int?, weekend: Int?) async throws {
        guard let uid = client.auth.currentSession?.user.id.uuidString.lowercased() else {
            throw PreferencesClientError.notSignedIn
        }
        try await setUsableMinutes(userId: uid, perDay: perDay, weekend: weekend)
    }
}

public enum PreferencesClientError: Error, Sendable, Equatable {
    case notSignedIn
}

/// Records a sign-in for usage analytics via the `track-login` Edge Function
/// (platform + device; the server derives country/city from the request IP, no
/// raw IP stored). Best-effort: usage analytics must never affect sign-in, so
/// failures are swallowed. Throttling is the caller's job. Mirrors the Android
/// LoginTrackerClient.
public struct LoginTrackerClient: Sendable {
    let client: SupabaseClient
    public init(_ client: SupabaseClient) { self.client = client }

    public func track(device: String) async {
        struct Body: Encodable { let platform = "ios"; let device: String }
        // Returns nothing; ignore decode + swallow any error.
        try? await client.functions.invoke(
            "track-login",
            options: FunctionInvokeOptions(method: .post, body: Body(device: device)))
    }
}
