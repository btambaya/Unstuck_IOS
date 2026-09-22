// CalendarClient — invokes the existing `calendar-sync` Edge Function
// (NO new Google OAuth client). The ASWebAuthenticationSession consent
// flow lives in the UI layer; this client provides the server calls:
// authorize (server-built consent URL + signed state) → connect (server
// exchanges the code for a refresh token) → list/pull/insert/patch/delete.
// The connect redirect MUST be an HTTPS Universal Link (Google blocks
// custom schemes for web OAuth clients), reusing the web client creds.

import Foundation
import Supabase
import UnstuckCore

public struct CalendarClient: Sendable {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    private struct Empty: Encodable {}

    // MARK: connect flow

    public struct AuthorizeResponse: Decodable, Sendable {
        public let url: String
        public let state: String
    }
    public struct GoogleCalendar: Decodable, Sendable {
        public let id: String
        public let summary: String
        public let primary: Bool?
    }
    public struct ConnectResponse: Decodable, Sendable {
        public let id: String
        public let accountEmail: String
        public let calendars: [GoogleCalendar]
        public let colorSlot: Int?

        /// The local calendar_connections row this connect implies, shaped like
        /// the server's insert (handleConnect: every returned calendar, else
        /// "primary"; iOS sends no displayName, so it stores the email). A
        /// successful connect used to write nothing locally, so the bar stayed
        /// "Connect" and googleConnection(for:) found nothing until relaunch; this
        /// stands in until the next /connections read replaces it with the
        /// stored row (audit 2026-09-22, C18).
        public func localConnection(connectedAt: String) -> CalendarConnection {
            CalendarConnection(id: id, provider: .google, accountEmail: accountEmail, displayName: accountEmail,
                               selectedCalendarIds: calendars.isEmpty ? ["primary"] : calendars.map(\.id),
                               colorSlot: colorSlot ?? 0, lastSyncCursor: nil, connectedAt: connectedAt)
        }
    }

    /// Step 1: ask the server for the Google consent URL + signed state.
    public func authorize(redirectUri: String) async throws -> AuthorizeResponse {
        struct Body: Encodable { let provider = "google"; let redirectUri: String }
        return try await client.functions.invoke(
            "calendar-sync/authorize",
            options: FunctionInvokeOptions(method: .post, body: Body(redirectUri: redirectUri)))
    }

    /// Step 2 (after consent): exchange the code server-side + store creds.
    public func connectGoogle(code: String, redirectUri: String, state: String) async throws -> ConnectResponse {
        struct Body: Encodable { let provider = "google"; let code: String; let redirectUri: String; let state: String }
        return try await client.functions.invoke(
            "calendar-sync/connect",
            options: FunctionInvokeOptions(method: .post, body: Body(code: code, redirectUri: redirectUri, state: state)))
    }

    public func disconnect(connectionId: String) async throws {
        struct Body: Encodable { let connectionId: String }
        try await client.functions.invoke(
            "calendar-sync/disconnect",
            options: FunctionInvokeOptions(method: .post, body: Body(connectionId: connectionId)))
    }

    // MARK: connections + events

    /// A connection row plus the server's health flags (migration 056:
    /// `needs_reauth` is set on a 401 / `invalid_grant` refresh, `last_error`
    /// keeps the reason). `needsReauth` ⇒ the UI offers "Reconnect Google".
    public struct ConnectionStatus: Sendable, Equatable {
        public let connection: CalendarConnection
        public let needsReauth: Bool
        public let lastError: String?
        public init(connection: CalendarConnection, needsReauth: Bool, lastError: String?) {
            self.connection = connection; self.needsReauth = needsReauth; self.lastError = lastError
        }
    }

    /// Decodes the connection's own shape PLUS the flags, whether the function
    /// camelCases them or passes the columns through.
    struct ConnectionWire: Decodable, Sendable {
        let status: ConnectionStatus
        init(from decoder: Decoder) throws {
            // The function returns the raw `select('*')` rows (snake_case). The
            // synthesized camelCase decode threw keyNotFound(accountEmail) on
            // every one and pullCalendar's `try?` swallowed it, so nothing was
            // ever imported. Read the hydrate's own snake_case DTO first; keep
            // camelCase as the fallback, like web's normalizeConnection
            // (audit 2026-09-22, C18).
            let connection = try (try? CalendarConnectionRow(from: decoder))?.model()
                ?? CalendarConnection(from: decoder)
            let c = try decoder.container(keyedBy: DynamicKey.self)
            let needs = Self.bool(c, "needsReauth") ?? Self.bool(c, "needs_reauth") ?? false
            let err = Self.string(c, "lastError") ?? Self.string(c, "last_error")
            status = ConnectionStatus(connection: connection, needsReauth: needs, lastError: err)
        }
        private static func bool(_ c: KeyedDecodingContainer<DynamicKey>, _ k: String) -> Bool? {
            guard let key = DynamicKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil
        }
        private static func string(_ c: KeyedDecodingContainer<DynamicKey>, _ k: String) -> String? {
            guard let key = DynamicKey(stringValue: k) else { return nil }
            return (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
    }

    struct ConnectionsWire: Decodable, Sendable { let connections: [ConnectionWire] }

    public func listConnectionStatuses() async throws -> [ConnectionStatus] {
        // Body-less: `body: Empty()` put "{}" in httpBody, and URLSession refuses
        // a GET that carries a body (-1103), so the call never left the phone
        // (audit 2026-09-22, C18).
        let r: ConnectionsWire = try await client.functions.invoke(
            "calendar-sync/connections",
            options: FunctionInvokeOptions(method: .get))
        return r.connections.map(\.status)
    }

    public func listConnections() async throws -> [CalendarConnection] {
        try await listConnectionStatuses().map(\.connection)
    }

    /// One connection / calendar the server could NOT read on this pull
    /// (`/events` → `{ events, failures }`). A client must not treat the
    /// absence of that connection's events as "deleted in Google".
    public struct PullFailure: Decodable, Sendable, Equatable {
        public let connectionId: String
        public let calendarId: String?
        public let status: Int?
        public let reason: String?
        public init(connectionId: String, calendarId: String? = nil, status: Int? = nil, reason: String? = nil) {
            self.connectionId = connectionId; self.calendarId = calendarId; self.status = status; self.reason = reason
        }
        /// 401 / a dead refresh token: the connection needs a fresh consent.
        public var needsReauth: Bool {
            status == 401 || reason == "invalid_grant" || reason == "needs_reauth" || reason == "unauthorized"
        }
        public var rateLimited: Bool { status == 429 }
    }

    /// The reconciled shape of one `/events` pull.
    public struct CalendarPull: Sendable, Equatable {
        public let events: [ExternalEvent]
        /// Events the provider gave as date-only (`allDay: true` from the server,
        /// which keeps the bare date as `start`). Filtered out of the time grid.
        public let allDayEventIds: Set<String>
        public let failures: [PullFailure]
        public init(events: [ExternalEvent], allDayEventIds: Set<String>, failures: [PullFailure]) {
            self.events = events; self.allDayEventIds = allDayEventIds; self.failures = failures
        }

        /// True when Google answered for NONE of `connections`: each failed
        /// whole (token mint / unreachable — calendarId "*") or on every
        /// selected calendar, and not only for a dead token (the bar already
        /// offers "Reconnect Google" for that). calendar-sync reports Google's
        /// 429 / 5xx / 403 inside a 200's `failures`, never as an HTTP error,
        /// so this is how "Sync now" learns it read nothing. One calendar
        /// failing next to a readable one is not "nothing" (audit 2026-09-22,
        /// C18).
        public func readNothing(from connections: [CalendarConnection]) -> Bool {
            guard !connections.isEmpty, !failures.isEmpty, !failures.allSatisfy(\.needsReauth) else { return false }
            return connections.allSatisfy { conn in
                let own = failures.filter { $0.connectionId == conn.id }
                if own.contains(where: { ($0.calendarId ?? "*") == "*" }) { return true }
                let failedCalendars = Set(own.compactMap(\.calendarId))
                return !own.isEmpty && conn.selectedCalendarIds.allSatisfy(failedCalendars.contains)
            }
        }
    }

    /// An event plus the server's explicit `allDay` flag (the model has no slot
    /// for it; the reconcile takes the ids separately).
    struct EventWire: Decodable, Sendable {
        let event: ExternalEvent
        let allDay: Bool
        init(from decoder: Decoder) throws {
            event = try ExternalEvent(from: decoder)
            let c = try decoder.container(keyedBy: DynamicKey.self)
            var flag = false
            if let k = DynamicKey(stringValue: "allDay"), let v = (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil { flag = v }
            else if let k = DynamicKey(stringValue: "all_day"), let v = (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil { flag = v }
            allDay = flag
        }
    }

    struct EventsWire: Decodable, Sendable {
        let events: [EventWire]
        let failures: [PullFailure]?
    }

    /// Pull external events in [from, to] (ISO), optionally one connection.
    /// Throws on transport failure or a non-2xx (a 429 maps to
    /// `CalendarSyncError.rateLimited`); per-connection failures ride inside.
    public func pullEvents(from: String, to: String, connectionId: String? = nil) async throws -> CalendarPull {
        var query = [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)]
        if let connectionId { query.append(URLQueryItem(name: "connectionId", value: connectionId)) }
        do {
            // Body-less GET, as for /connections (audit 2026-09-22, C18).
            let r: EventsWire = try await client.functions.invoke(
                "calendar-sync/events",
                options: FunctionInvokeOptions(method: .get, query: query))
            return CalendarPull(events: r.events.map(\.event),
                                allDayEventIds: Set(r.events.filter(\.allDay).map(\.event.id)),
                                failures: r.failures ?? [])
        } catch {
            throw Self.classify(error) ?? error
        }
    }

    public struct InsertResponse: Decodable, Sendable { public let id: String }
    public func insertEvent(connectionId: String, calendarId: String, summary: String, start: String, end: String) async throws -> String {
        struct Body: Encodable { let connectionId, calendarId, summary, start, end: String }
        do {
            let r: InsertResponse = try await client.functions.invoke(
                "calendar-sync/events",
                options: FunctionInvokeOptions(method: .post, body: Body(connectionId: connectionId, calendarId: calendarId, summary: summary, start: start, end: end)))
            return r.id
        } catch {
            throw Self.classify(error) ?? error
        }
    }

    /// Throws `CalendarSyncError.eventGone` when the server answers 404
    /// `event_gone` (deleted in Google) — the caller clears the stale id and
    /// falls through to INSERT.
    public func patchEvent(eventId: String, connectionId: String, calendarId: String, summary: String?, start: String?, end: String?) async throws {
        struct Body: Encodable { let connectionId, calendarId: String; let summary, start, end: String? }
        let path = "calendar-sync/events/\(eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId)"
        do {
            try await client.functions.invoke(
                path,
                options: FunctionInvokeOptions(method: .patch, body: Body(connectionId: connectionId, calendarId: calendarId, summary: summary, start: start, end: end)))
        } catch {
            throw Self.classify(error) ?? error
        }
    }

    public func deleteEvent(eventId: String, connectionId: String, calendarId: String) async throws {
        let path = "calendar-sync/events/\(eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId)"
        do {
            try await client.functions.invoke(
                path,
                options: FunctionInvokeOptions(method: .delete,
                    query: [URLQueryItem(name: "connectionId", value: connectionId), URLQueryItem(name: "calendarId", value: calendarId)],
                    body: Empty()))
        } catch {
            throw Self.classify(error) ?? error
        }
    }

    // MARK: error classification

    /// Map an edge-function HTTP failure onto the sync-relevant verdicts.
    /// nil = something else (transport / 5xx / unknown) — rethrown as-is.
    public static func classify(_ error: Error) -> CalendarSyncError? {
        guard case let FunctionsError.httpError(code, data) = error else { return nil }
        return classify(status: code, body: String(data: data, encoding: .utf8) ?? "")
    }

    /// Pure: status + body → verdict. 404 `event_gone` (the PATCH/DELETE target
    /// no longer exists in Google), 429 (back off), 401 / `invalid_grant` /
    /// `needs_reauth` (the refresh token is dead — reconnect).
    public static func classify(status: Int, body: String) -> CalendarSyncError? {
        let lower = body.lowercased()
        if status == 404, lower.contains("event_gone") { return .eventGone }
        if status == 429 { return .rateLimited }
        if status == 401 || lower.contains("invalid_grant") || lower.contains("needs_reauth") { return .needsReauth }
        return nil
    }
}

/// Sync-relevant calendar-sync failures (see `CalendarClient.classify`).
public enum CalendarSyncError: Error, Equatable, Sendable {
    case eventGone
    case rateLimited
    case needsReauth
}

/// A CodingKey over an arbitrary string, for reading optional extra fields
/// next to a model's own decoder.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
