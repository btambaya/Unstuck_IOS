// Calls the notification Edge Functions: session-recap (on session end)
// and paused-checkin (cap coordination for the local paused-too-long
// notif). Best-effort — failures are swallowed by callers.

import Foundation
import Supabase
import UnstuckCore

public struct NotificationsClient: Sendable {
    let client: SupabaseClient
    public init(_ client: SupabaseClient) { self.client = client }

    public func sessionRecap(taskName: String, away: Bool) async throws {
        struct Body: Encodable { let taskName: String; let away: Bool }
        try await client.functions.invoke(
            "send-session-recap",
            options: FunctionInvokeOptions(method: .post, body: Body(taskName: taskName, away: away)))
    }

    /// How `send-paused-checkin` treats the shared daily push budget.
    /// `.peek` asks "would a paused check-in be allowed right now?" (mute /
    /// preference / remaining cap) WITHOUT claiming a slot — used at pause
    /// time, when the local ~14-min nag is merely scheduled; `.consume` claims
    /// the slot (`try_consume_push_budget`) — used once the nag has actually
    /// fired, so a quick pause/resume never burns the cap (web/Android claim
    /// at fire time too). `.consume` is the function's legacy default shape.
    public enum PausedCheckinMode: String, Sendable { case peek, consume }

    /// Whether a paused-checkin notification is allowed (cap + preference).
    /// Throws on transport failure AND on a malformed 2xx body (no `allowed`)
    /// so the caller's offline default is a deliberate choice, not a decode
    /// accident — see AppModel.peekPausedCheckinAllowed.
    public func pausedCheckin(mode: PausedCheckinMode = .consume) async throws -> Bool {
        struct Body: Encodable { let mode: String }
        struct Response: Decodable { let allowed: Bool?; let error: String? }
        let response: Response = try await client.functions.invoke(
            "send-paused-checkin",
            options: FunctionInvokeOptions(method: .post, body: Body(mode: mode.rawValue)))
        guard let allowed = response.allowed else {
            throw PausedCheckinResponseError(reason: response.error ?? "missing `allowed`")
        }
        return allowed
    }

    /// A 2xx `send-paused-checkin` reply without a usable verdict.
    public struct PausedCheckinResponseError: Error, Sendable { public let reason: String }

    // MARK: wake-window calibration (migration 015 `wake_window_history`)

    /// Record the day's FIRST app input (foreground) for `calibrate_wake_windows`
    /// — one row per (user, local date); a repeat for the same day is IGNORED
    /// (the earliest input is the wake signal). Until every client wrote this,
    /// the auto wake-window mode medianed an empty table and pinned everyone's
    /// morning brief to the 08:00 fallback.
    public func recordWakeWindow(userId: String, sample: WakeWindowSample) async throws {
        struct Row: Encodable {
            let user_id: String
            let local_date: String
            let first_input_local: String
            let weekday: Int
        }
        _ = try await client.from("wake_window_history")
            .upsert(Row(user_id: userId, local_date: sample.localDate,
                        first_input_local: sample.firstInputLocal, weekday: sample.weekday),
                    onConflict: "user_id,local_date", ignoreDuplicates: true)
            .execute()
    }
}

/// One wake-window observation: the local date, the local HH:MM of the first
/// input, and the weekday (0 = Sunday … 6 = Saturday — the server's
/// `calibrate_wake_windows` convention). Pure — built from a `Date` + calendar.
public struct WakeWindowSample: Equatable, Sendable {
    public let localDate: String
    public let firstInputLocal: String
    public let weekday: Int

    public init(localDate: String, firstInputLocal: String, weekday: Int) {
        self.localDate = localDate
        self.firstInputLocal = firstInputLocal
        self.weekday = weekday
    }

    public init(now: Date, calendar: Foundation.Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        localDate = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        firstInputLocal = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        weekday = max(0, (c.weekday ?? 1) - 1)   // Foundation: 1 = Sunday
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

    /// The account's notification level + reminder lead as the server has
    /// them (`notification_preferences.notification_level` /
    /// `reminder_lead_min`) — the cross-device source of truth the phone reads
    /// back on every sign-in hydrate. Nil fields when the row / column is
    /// absent or null (the caller keeps its local value); throws only on
    /// transport failure.
    public func notificationPrefs(userId: String) async throws -> NotificationPrefsRow {
        struct Row: Decodable { let notification_level: String?; let reminder_lead_min: Int? }
        let rows: [Row] = try await client.from("notification_preferences")
            .select("notification_level, reminder_lead_min").eq("user_id", value: userId).limit(1)
            .execute().value
        return NotificationPrefsRow(level: rows.first?.notification_level, reminderLeadMin: rows.first?.reminder_lead_min)
    }

    // MARK: PA rituals (migration 053: `user_preferences.pa_rituals jsonb`)

    /// Which recurring PA moments run, server-backed so a toggle made on one
    /// device holds everywhere. Nil when the row is absent or the column is
    /// null (never set on any device yet — the caller keeps its local cache).
    /// Moment DISMISSALS stay device-local by design (a "not now" on the
    /// phone shouldn't hide the card on the laptop).
    public func paRituals(userId: String) async throws -> RitualPrefs? {
        struct Row: Decodable { let pa_rituals: RitualPrefs? }
        let rows: [Row] = try await client.from("user_preferences")
            .select("pa_rituals").eq("user_id", value: userId).limit(1)
            .execute().value
        return rows.first?.pa_rituals
    }

    /// Persist the ritual toggles (`{"morning":bool,"evening":bool,"friday":bool,"sunday":bool}`).
    public func setPaRituals(userId: String, prefs: RitualPrefs) async throws {
        struct Row: Encodable { let user_id: String; let pa_rituals: RitualPrefs }
        _ = try await client.from("user_preferences")
            .upsert(Row(user_id: userId, pa_rituals: prefs), onConflict: "user_id")
            .execute()
    }

    /// Record this device's IANA timezone on the account — RPC
    /// `set_timezone(p_tz)` (migration 053), which writes
    /// `notification_preferences.timezone`. Everything the SERVER schedules or
    /// projects in the user's local day reads that column (reminders, the
    /// morning brief, and the owner-local slot a recipient's shared tasks are
    /// bucketed by), so a phone-only account must not be left on the UTC
    /// fallback. Returns false when the server rejects the zone (nothing
    /// written); throws only on transport failure.
    @discardableResult
    public func setTimezone(_ tz: String) async throws -> Bool {
        struct Params: Encodable { let p_tz: String }
        return try await client.rpc("set_timezone", params: Params(p_tz: tz)).execute().value
    }

    /// The usable-minutes budget as the server has it (nil fields = unset).
    public func usableMinutes(userId: String) async throws -> (perDay: Int?, weekend: Int?) {
        struct Row: Decodable { let usable_minutes_per_day: Int?; let usable_minutes_weekend: Int? }
        let rows: [Row] = try await client.from("user_preferences")
            .select("usable_minutes_per_day, usable_minutes_weekend").eq("user_id", value: userId).limit(1)
            .execute().value
        return (rows.first?.usable_minutes_per_day, rows.first?.usable_minutes_weekend)
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

/// `notification_preferences` as read back from the server — nil = unset there.
public struct NotificationPrefsRow: Sendable, Equatable {
    public let level: String?
    public let reminderLeadMin: Int?
    public init(level: String?, reminderLeadMin: Int?) {
        self.level = level
        self.reminderLeadMin = reminderLeadMin
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
