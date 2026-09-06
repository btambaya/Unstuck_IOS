// The calendar-sync failure verdicts the pull + push paths key on
// (CalendarClient.classify), the per-connection `failures[]` flags, and the
// wake-window sample the first foreground of a local day records.

import XCTest
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
        let json = #"""
        {"connections":[
          {"id":"c1","provider":"google","accountEmail":"a@b.c","displayName":"A","selectedCalendarIds":["primary"],
           "colorSlot":0,"connectedAt":"2026-06-01T00:00:00Z","needs_reauth":true,"last_error":"invalid_grant"},
          {"id":"c2","provider":"google","accountEmail":"d@e.f","displayName":"D","selectedCalendarIds":["primary"],
           "colorSlot":1,"connectedAt":"2026-06-01T00:00:00Z","needsReauth":false}
        ]}
        """#
        let wire = try JSONDecoder().decode(CalendarClient.ConnectionsWire.self, from: Data(json.utf8))
        let statuses = wire.connections.map(\.status)
        XCTAssertEqual(statuses.map(\.needsReauth), [true, false])
        XCTAssertEqual(statuses[0].lastError, "invalid_grant")
        XCTAssertEqual(statuses.map(\.connection.id), ["c1", "c2"])
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
