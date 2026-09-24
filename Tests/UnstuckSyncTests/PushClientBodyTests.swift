// register-push-token's body (2026-09-24): it carries the phone's 12/24-hour
// clock as `clock` ("12h" / "24h") so the server writes reminder times the way
// the app shows them ("Starts in 10 min — 15:00." on a 24-hour iPhone). The
// JSON is encoded with a plain JSONEncoder — what supabase-swift's
// FunctionInvokeOptions uses — so the keys here are the keys on the wire.

import XCTest
import UnstuckCore
@testable import UnstuckSync

final class PushClientBodyTests: XCTestCase {
    private func json(_ body: PushClient.RegisterBody) throws -> [String: Any] {
        let data = try JSONEncoder().encode(body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func body(apns: String? = "abc", voip: String? = nil,
                      clock: ClockFormat.Cycle) -> PushClient.RegisterBody {
        PushClient.registerBody(
            deviceId: "dev-1", apnsToken: apns, voipToken: voip,
            liveActivityPushToStartToken: nil, timezone: "Europe/London",
            apnsEnvironment: "production", clock: clock)
    }

    func testTwentyFourHourPhoneSendsTwentyFourH() throws {
        let j = try json(body(clock: .h24))
        XCTAssertEqual(j["clock"] as? String, "24h")
        XCTAssertEqual(j["deviceId"] as? String, "dev-1")
        XCTAssertEqual(j["apnsToken"] as? String, "abc")
        XCTAssertEqual(j["platform"] as? String, "ios")
        XCTAssertEqual(j["timezone"] as? String, "Europe/London")
        XCTAssertEqual(j["apnsEnvironment"] as? String, "production")
    }

    func testTwelveHourPhoneSendsTwelveH() throws {
        XCTAssertEqual(try json(body(clock: .h12))["clock"] as? String, "12h")
    }

    func testClockFieldMatchesTheContract() {
        XCTAssertEqual(PushClient.clockField(.h12), "12h")
        XCTAssertEqual(PushClient.clockField(.h24), "24h")
    }

    /// Unchanged behaviour: an empty/absent token is OMITTED (the server keeps
    /// what it has) — and a VoIP-only registration still carries the clock.
    func testEmptyTokensAreOmittedAndClockStillSent() throws {
        let j = try json(body(apns: "", voip: "", clock: .h24))
        XCTAssertNil(j["apnsToken"])
        XCTAssertNil(j["voipToken"])
        XCTAssertNil(j["liveActivityPushToStartToken"])
        XCTAssertEqual(j["clock"] as? String, "24h")

        let voipOnly = try json(body(apns: nil, voip: "beef", clock: .h12))
        XCTAssertNil(voipOnly["apnsToken"])
        XCTAssertEqual(voipOnly["voipToken"] as? String, "beef")
        XCTAssertEqual(voipOnly["clock"] as? String, "12h")
    }
}
