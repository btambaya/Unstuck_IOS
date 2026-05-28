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

    public struct ConnectionsResponse: Decodable, Sendable {
        public let connections: [CalendarConnection]
    }
    public func listConnections() async throws -> [CalendarConnection] {
        let r: ConnectionsResponse = try await client.functions.invoke(
            "calendar-sync/connections",
            options: FunctionInvokeOptions(method: .get, body: Empty()))
        return r.connections
    }

    public struct EventsResponse: Decodable, Sendable {
        public let events: [ExternalEvent]
    }
    /// Pull external events in [from, to] (ISO), optionally one connection.
    public func pullEvents(from: String, to: String, connectionId: String? = nil) async throws -> [ExternalEvent] {
        var query = [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)]
        if let connectionId { query.append(URLQueryItem(name: "connectionId", value: connectionId)) }
        let r: EventsResponse = try await client.functions.invoke(
            "calendar-sync/events",
            options: FunctionInvokeOptions(method: .get, query: query, body: Empty()))
        return r.events
    }

    public struct InsertResponse: Decodable, Sendable { public let id: String }
    public func insertEvent(connectionId: String, calendarId: String, summary: String, start: String, end: String) async throws -> String {
        struct Body: Encodable { let connectionId, calendarId, summary, start, end: String }
        let r: InsertResponse = try await client.functions.invoke(
            "calendar-sync/events",
            options: FunctionInvokeOptions(method: .post, body: Body(connectionId: connectionId, calendarId: calendarId, summary: summary, start: start, end: end)))
        return r.id
    }

    public func patchEvent(eventId: String, connectionId: String, calendarId: String, summary: String?, start: String?, end: String?) async throws {
        struct Body: Encodable { let connectionId, calendarId: String; let summary, start, end: String? }
        let path = "calendar-sync/events/\(eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId)"
        try await client.functions.invoke(
            path,
            options: FunctionInvokeOptions(method: .patch, body: Body(connectionId: connectionId, calendarId: calendarId, summary: summary, start: start, end: end)))
    }

    public func deleteEvent(eventId: String, connectionId: String, calendarId: String) async throws {
        let path = "calendar-sync/events/\(eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId)"
        try await client.functions.invoke(
            path,
            options: FunctionInvokeOptions(method: .delete,
                query: [URLQueryItem(name: "connectionId", value: connectionId), URLQueryItem(name: "calendarId", value: calendarId)],
                body: Empty()))
    }
}
