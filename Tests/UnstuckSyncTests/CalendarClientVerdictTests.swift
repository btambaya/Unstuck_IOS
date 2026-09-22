// The calendar-sync failure verdicts the pull + push paths key on
// (CalendarClient.classify), the per-connection `failures[]` flags, the
// /connections row shape and the body-less GETs (a URLProtocol stub, no
// network, no keychain), and the wake-window sample the first foreground of a
// local day records.

import XCTest
import Supabase
import Auth
import UnstuckCore
@testable import UnstuckSync

final class CalendarClientVerdictTests: XCTestCase {

    // MARK: - classify(status:body:)

    func testEventGoneIsA404WithTheServersMarker() {
        XCTAssertEqual(CalendarClient.classify(status: 404, body: #"{"error":"event_gone"}"#), .eventGone)
        XCTAssertNil(CalendarClient.classify(status: 404, body: #"{"error":"not_found"}"#),
                     "a plain 404 (unknown route / connection) is not 'the event was deleted in Google'")
    }

    func testRateLimitBacksOff() {
        XCTAssertEqual(CalendarClient.classify(status: 429, body: ""), .rateLimited)
    }

    func testDeadRefreshTokenNeedsReauth() {
        XCTAssertEqual(CalendarClient.classify(status: 401, body: ""), .needsReauth)
        XCTAssertEqual(CalendarClient.classify(status: 400, body: #"{"error":"invalid_grant"}"#), .needsReauth)
        XCTAssertEqual(CalendarClient.classify(status: 409, body: #"{"error":"needs_reauth"}"#), .needsReauth)
    }

    func testTransientAndUnknownFailuresAreNotAVerdict() {
        XCTAssertNil(CalendarClient.classify(status: 500, body: "boom"))
        XCTAssertNil(CalendarClient.classify(status: 503, body: ""))
        XCTAssertNil(CalendarClient.classify(status: 400, body: #"{"error":"bad_request"}"#))
    }

    // MARK: - failures[] flags

    func testPullFailureFlags() {
        XCTAssertTrue(CalendarClient.PullFailure(connectionId: "c", status: 401).needsReauth)
        XCTAssertTrue(CalendarClient.PullFailure(connectionId: "c", status: 400, reason: "invalid_grant").needsReauth)
        XCTAssertTrue(CalendarClient.PullFailure(connectionId: "c", status: 429).rateLimited)
        let flaky = CalendarClient.PullFailure(connectionId: "c", status: 503, reason: "upstream")
        XCTAssertFalse(flaky.needsReauth)
        XCTAssertFalse(flaky.rateLimited)
    }

    func testEventsWireDecodesAllDayAndFailures() throws {
        let json = #"""
        {"events":[
          {"id":"e1","connectionId":"c1","calendarId":"primary","summary":"Standup",
           "start":"2026-06-10T09:00:00.000Z","end":"2026-06-10T09:30:00.000Z"},
          {"id":"hol","connectionId":"c1","calendarId":"primary","summary":"Holiday",
           "start":"2026-06-11","end":"2026-06-12","allDay":true}
        ],
         "failures":[{"connectionId":"c2","calendarId":"primary","status":401,"reason":"invalid_grant"}]}
        """#
        let wire = try JSONDecoder().decode(CalendarClient.EventsWire.self, from: Data(json.utf8))
        XCTAssertEqual(wire.events.map(\.event.id), ["e1", "hol"])
        XCTAssertEqual(wire.events.filter(\.allDay).map(\.event.id), ["hol"])
        XCTAssertEqual(wire.failures?.first?.connectionId, "c2")
        XCTAssertEqual(wire.failures?.first?.needsReauth, true)
    }

    func testEventsWireToleratesTheLegacyShape() throws {
        // The pre-056 function: no `failures`, no `allDay`.
        let json = #"{"events":[{"id":"e1","connectionId":"c1","calendarId":"primary","summary":"S","start":"2026-06-10T09:00:00Z","end":"2026-06-10T09:30:00Z"}]}"#
        let wire = try JSONDecoder().decode(CalendarClient.EventsWire.self, from: Data(json.utf8))
        XCTAssertEqual(wire.events.count, 1)
        XCTAssertFalse(wire.events[0].allDay)
        XCTAssertNil(wire.failures)
    }

    func testConnectionsWireReadsNeedsReauthInEitherCase() throws {
        // c1 is the function's REAL row (snake_case `select('*')` minus
        // credentials); c2 keeps the camelCase fallback. The old fixture was
        // camelCase only, a shape the server never sends — it hid the bug
        // (audit 2026-09-22, C18).
        let json = #"""
        {"connections":[
          {"id":"c1","user_id":"u1","provider":"google","account_email":"a@b.c","display_name":"A",
           "selected_calendar_ids":["primary"],"color_slot":0,"last_sync_cursor":null,
           "connected_at":"2026-06-01T00:00:00Z","needs_reauth":true,"last_error":"invalid_grant"},
          {"id":"c2","provider":"google","accountEmail":"d@e.f","displayName":"D","selectedCalendarIds":["primary"],
           "colorSlot":1,"connectedAt":"2026-06-01T00:00:00Z","needsReauth":false}
        ]}
        """#
        let wire = try JSONDecoder().decode(CalendarClient.ConnectionsWire.self, from: Data(json.utf8))
        let statuses = wire.connections.map(\.status)
        XCTAssertEqual(statuses.map(\.needsReauth), [true, false])
        XCTAssertEqual(statuses[0].lastError, "invalid_grant")
        XCTAssertEqual(statuses.map(\.connection.id), ["c1", "c2"])
        XCTAssertEqual(statuses[0].connection.accountEmail, "a@b.c")
        XCTAssertEqual(statuses[1].connection.colorSlot, 1)
    }

    /// Exactly what handleListConnections returns. Before the fix this threw
    /// keyNotFound(accountEmail) and pullCalendar gave up in silence.
    static let serverConnectionsJSON = #"""
    {"connections":[{"id":"c1","user_id":"u1","provider":"google","account_email":"a@b.c","display_name":"a@b.c",
      "selected_calendar_ids":["primary","team@group.calendar.google.com"],"color_slot":2,"last_sync_cursor":null,
      "connected_at":"2026-09-20T10:00:00.123456+00:00","needs_reauth":false,"last_error":null}]}
    """#

    static let serverConnection = CalendarConnection(
        id: "c1", provider: .google, accountEmail: "a@b.c", displayName: "a@b.c",
        selectedCalendarIds: ["primary", "team@group.calendar.google.com"], colorSlot: 2,
        lastSyncCursor: nil, connectedAt: "2026-09-20T10:00:00.123456+00:00")

    func testConnectionsWireDecodesTheFunctionsRealRows() throws {
        let wire = try JSONDecoder().decode(CalendarClient.ConnectionsWire.self,
                                            from: Data(Self.serverConnectionsJSON.utf8))
        let statuses = wire.connections.map(\.status)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[0].connection, Self.serverConnection)
        XCTAssertFalse(statuses[0].needsReauth)
        XCTAssertNil(statuses[0].lastError)
    }

    // MARK: - connect → local row

    func testConnectResponseSeedsTheLocalRowLikeTheServerInsert() throws {
        let body = #"""
        {"id":"c1","accountEmail":"a@b.c","calendars":[{"id":"primary","summary":"a@b.c","primary":true},
          {"id":"team@x","summary":"Team"}],"colorSlot":1,"reconnected":false}
        """#
        let r = try JSONDecoder().decode(CalendarClient.ConnectResponse.self, from: Data(body.utf8))
        XCTAssertEqual(r.localConnection(connectedAt: "T"),
                       CalendarConnection(id: "c1", provider: .google, accountEmail: "a@b.c", displayName: "a@b.c",
                                          selectedCalendarIds: ["primary", "team@x"], colorSlot: 1,
                                          lastSyncCursor: nil, connectedAt: "T"))
        // No calendars listed and no slot: the server's insert defaults.
        let bare = try JSONDecoder().decode(CalendarClient.ConnectResponse.self,
                                            from: Data(#"{"id":"c2","accountEmail":"d@e.f","calendars":[]}"#.utf8))
        let seeded = bare.localConnection(connectedAt: "T")
        XCTAssertEqual(seeded.selectedCalendarIds, ["primary"])
        XCTAssertEqual(seeded.colorSlot, 0)
        XCTAssertEqual(seeded.displayName, "d@e.f")
    }

    // MARK: - the GETs carry no body

    func testConnectionsAndEventsAreBodylessGETs() async throws {
        CalendarStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarStubProtocol.self]
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://stub.invalid")!, supabaseKey: "anon",
            options: .init(auth: .init(storage: StubAuthStorage(), autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
        let calendar = CalendarClient(client)

        let statuses = try await calendar.listConnectionStatuses()
        XCTAssertEqual(statuses.map(\.connection), [Self.serverConnection],
                       "decoded end to end through the SDK's functions decoder")
        let pull = try await calendar.pullEvents(from: "2026-09-15T00:00:00Z", to: "2026-10-23T00:00:00Z")
        XCTAssertTrue(pull.events.isEmpty)

        let requests = CalendarStubProtocol.recorded()
        XCTAssertEqual(requests.count, 2)
        for r in requests {
            XCTAssertEqual(r.httpMethod, "GET")
            // Inside a URLProtocol a body shows up as a stream, so check both.
            XCTAssertNil(r.httpBody, "URLSession refuses a GET that carries a body (-1103)")
            XCTAssertNil(r.httpBodyStream)
            XCTAssertNil(r.value(forHTTPHeaderField: "Content-Type"))
        }
        XCTAssertEqual(requests.first?.url?.path, "/functions/v1/calendar-sync/connections")
        let events = try XCTUnwrap(requests.last?.url)
        XCTAssertEqual(events.path, "/functions/v1/calendar-sync/events")
        let items = URLComponents(url: events, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "from" }?.value, "2026-09-15T00:00:00Z")
        XCTAssertEqual(items.first { $0.name == "to" }?.value, "2026-10-23T00:00:00Z")
    }

    // MARK: - wake-window sample

    func testWakeWindowSampleUsesTheLocalDayAndServerWeekdayConvention() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        // 2026-06-07 is a Sunday. 05:10 UTC = 06:10 BST.
        let now = ISO8601DateFormatter().date(from: "2026-06-07T05:10:00Z")!
        let s = WakeWindowSample(now: now, calendar: cal)
        XCTAssertEqual(s.localDate, "2026-06-07")
        XCTAssertEqual(s.firstInputLocal, "06:10")
        XCTAssertEqual(s.weekday, 0, "0 = Sunday, like calibrate_wake_windows")
        // Late Saturday night in Los Angeles is still Saturday there.
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let la = WakeWindowSample(now: now, calendar: cal)
        XCTAssertEqual(la.localDate, "2026-06-06")
        XCTAssertEqual(la.firstInputLocal, "22:10")
        XCTAssertEqual(la.weekday, 6)
    }
}

/// Answers the calendar-sync GETs from fixtures and records every request.
private final class CalendarStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset() { lock.withLock { requests = [] } }
    static func recorded() -> [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        let path = request.url?.path ?? ""
        let body = path.hasSuffix("/calendar-sync/connections")
            ? CalendarClientVerdictTests.serverConnectionsJSON
            : #"{"events":[],"failures":[]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Session storage that lives and dies with the test — NOT the keychain.
private final class StubAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
