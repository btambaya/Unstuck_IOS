// PushClient — registers the device's APNs token with the
// register-push-token Edge Function. The app's notification-permission +
// UIApplicationDelegate APNs registration calls this once it has a token.

import Foundation
import Supabase

public struct PushClient: Sendable {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    public func register(
        deviceId: String,
        apnsToken: String?,
        liveActivityPushToStartToken: String? = nil,
        timezone: String = TimeZone.current.identifier,
        apnsEnvironment: String = "production"
    ) async throws {
        struct Body: Encodable {
            let deviceId: String
            let apnsToken: String?
            let liveActivityPushToStartToken: String?
            let timezone: String
            let apnsEnvironment: String
        }
        try await client.functions.invoke(
            "register-push-token",
            options: FunctionInvokeOptions(method: .post, body: Body(
                deviceId: deviceId, apnsToken: apnsToken,
                liveActivityPushToStartToken: liveActivityPushToStartToken,
                timezone: timezone, apnsEnvironment: apnsEnvironment)))
    }

    /// Register a running Live Activity's per-update push token (the APNs
    /// backstop for when the app is suspended/killed). Writes directly to
    /// live_activity_tokens (RLS scopes to the user).
    public func registerLiveActivityToken(
        userId: String, deviceId: String, activityId: String, pushToken: String, sessionId: String?
    ) async throws {
        struct Row: Encodable {
            let user_id: String
            let device_id: String
            let activity_id: String
            let push_token: String
            let session_id: String?
        }
        _ = try await client.from("live_activity_tokens")
            .upsert(Row(user_id: userId, device_id: deviceId, activity_id: activityId,
                        push_token: pushToken, session_id: sessionId), onConflict: "user_id,activity_id")
            .execute()
    }
}
