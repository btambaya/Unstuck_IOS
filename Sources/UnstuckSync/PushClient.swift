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
}
