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

    /// The account's onboarding struggles as the server has them (any
    /// platform's vocabulary — callers canonicalise). Empty when the row or
    /// column is absent; throws only on transport failure.
    public func adhdStruggles(userId: String) async throws -> [String] {
        struct Row: Decodable { let adhd_struggles: [String]? }
        let rows: [Row] = try await client.from("user_preferences")
            .select("adhd_struggles").eq("user_id", value: userId).limit(1)
            .execute().value
        return rows.first?.adhd_struggles ?? []
    }

    /// Mirror the device NotificationLevel to notification_preferences
    /// (owner-self RLS) so the server-driven morning brief + paused-checkin
    /// cap honour it (spec 10 §1.12). Only the level-derived toggles are
    /// sent — plus, when given, the level itself (`notification_level`, the
    /// column the web reads back; lowercase per the migration-030 check);
    /// other columns keep their values (Android PreferencesClient).
    public func setNotificationLevel(userId: String, morningBrief: Bool, pausedCheckin: Bool,
                                     level: String? = nil) async throws {
        struct Row: Encodable {
            let user_id: String
            let morning_brief_enabled: Bool
            let paused_checkin_enabled: Bool
            let notification_level: String?
        }
        _ = try await client.from("notification_preferences")
            .upsert(Row(user_id: userId, morning_brief_enabled: morningBrief,
                        paused_checkin_enabled: pausedCheckin, notification_level: level?.lowercased()),
                    onConflict: "user_id")
            .execute()
    }

    /// Mirror the global reminder lead (`reminder_lead_min`, 0 = off) — the
    /// same upsert the web's `setReminderLead` makes, so a lead chosen through
    /// the assistant reads back identically on every platform. iOS reminders
    /// still fire locally (the server cron only targets web devices).
    public func setReminderLead(userId: String, minutes: Int) async throws {
        struct Row: Encodable { let user_id: String; let reminder_lead_min: Int }
        _ = try await client.from("notification_preferences")
            .upsert(Row(user_id: userId, reminder_lead_min: minutes), onConflict: "user_id")
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

    // MARK: interview flag (migration 052)

    /// Mirror "the get-to-know-you interview is done" to the ACCOUNT —
    /// `user_preferences.assistant_interview_done_at` — so no other device
    /// re-asks (the web writes the same column). Upsert on user_id like the
    /// other prefs writers (a bare UPDATE on a missing row is a silent no-op).
    /// Throws while the column doesn't exist yet (PGRST204) — callers are
    /// best-effort and the next sign-in hydrate re-pushes.
    public func setInterviewDone(userId: String, at date: Date = Date()) async throws {
        struct Row: Encodable { let user_id: String; let assistant_interview_done_at: String }
        _ = try await client.from("user_preferences")
            .upsert(Row(user_id: userId, assistant_interview_done_at: CallsClient.iso(date)), onConflict: "user_id")
            .execute()
    }

    /// When the account finished the interview (on any platform), or nil when
    /// it hasn't / the row is absent. Throws on transport failure AND while
    /// the column doesn't exist yet (42703) — callers treat both as "unknown,
    /// retry later", never as "not done".
    public func interviewDoneAt(userId: String) async throws -> Date? {
        struct Row: Decodable { let assistant_interview_done_at: String? }
        let rows: [Row] = try await client.from("user_preferences")
            .select("assistant_interview_done_at").eq("user_id", value: userId).limit(1)
            .execute().value
        return rows.first?.assistant_interview_done_at.flatMap(Self.parseTimestamp)
    }

    /// A Postgres `timestamptz` as PostgREST emits it — `+00:00` offset and
    /// up to SIX fractional digits (`now()` keeps microseconds), which
    /// ISO8601DateFormatter refuses: normalise the fraction to milliseconds
    /// and retry. Nil for empty / unparseable.
    public static func parseTimestamp(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let d = CallsClient.parseISO(t) { return d }
        guard let dot = t.firstIndex(of: ".") else { return nil }
        let afterDot = t[t.index(after: dot)...]
        let digits = afterDot.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = afterDot.dropFirst(digits.count)
        let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return CallsClient.parseISO(String(t[..<dot]) + "." + millis + String(rest))
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
