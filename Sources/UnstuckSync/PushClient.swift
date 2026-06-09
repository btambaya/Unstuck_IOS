// PushClient — registers the device's APNs token with the
// register-push-token Edge Function. The app's notification-permission +
// UIApplicationDelegate APNs registration calls this once it has a token.

import Foundation
import Supabase

public struct PushClient: Sendable {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    /// Debug (Xcode) installs carry SANDBOX APNs tokens — registering them
    /// as "production" makes every server push to a dev device silently
    /// fail. TestFlight/App Store builds compile Release → production.
    public static var defaultApnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    public func register(
        deviceId: String,
        apnsToken: String?,
        liveActivityPushToStartToken: String? = nil,
        timezone: String = TimeZone.current.identifier,
        apnsEnvironment: String = PushClient.defaultApnsEnvironment
    ) async throws {
        struct Body: Encodable {
            let deviceId: String
            let apnsToken: String?
            let liveActivityPushToStartToken: String?
            // Always sent explicitly and non-optionally (spec 10 §1.8 gotcha 1):
            // the edge fn happens to fall through to its 'ios' branch when
            // platform is absent, but that implicit coupling must not be
            // relied on.
            let platform: String
            let timezone: String
            let apnsEnvironment: String
        }
        try await client.functions.invoke(
            "register-push-token",
            options: FunctionInvokeOptions(method: .post, body: Body(
                deviceId: deviceId, apnsToken: apnsToken,
                liveActivityPushToStartToken: liveActivityPushToStartToken,
                platform: "ios",
                timezone: timezone, apnsEnvironment: apnsEnvironment)))
    }

    /// Delete this device's token rows on sign-out so the previous user's
    /// morning brief / recaps / pushes are never delivered to whoever signs
    /// in next on this device. MUST run while the signing-out user's JWT is
    /// still valid (RLS: user_id = auth.uid()) — spec 10 §1.8 gotcha 10.
    public func unregister(deviceId: String) async throws {
        _ = try await client.from("device_tokens")
            .delete().eq("device_id", value: deviceId).execute()
        _ = try? await client.from("live_activity_tokens")
            .delete().eq("device_id", value: deviceId).execute()
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
