// App-layer unit tests for AppModel.isRecoverySession — the static, dependency-
// free JWT `amr` (authentication-methods-reference) probe used to classify a
// PKCE password-recovery session (the recovery deep link carries no
// type=recovery, so the only reliable signal is the exchanged JWT). Best-effort
// base64url decode of the unsigned middle segment. Mirrors the Android probe.

import XCTest
@testable import Unstuck

final class IsRecoverySessionTests: XCTestCase {
    /// Build a JWT-shaped string ("header.payload.sig") whose payload is the
    /// base64url-encoded JSON of `claims`. Header + signature are arbitrary —
    /// the probe only reads segment[1] and never verifies the signature.
    private func jwt(claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        var b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        // base64url has no padding.
        b64 = b64.replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(b64).sig"
    }

    func testStringAmrEntryDetectsRecovery() {
        let token = jwt(claims: ["amr": ["recovery"], "sub": "u1"])
        XCTAssertTrue(AppModel.isRecoverySession(token))
    }

    func testObjectAmrEntryDetectsRecovery() {
        // Supabase emits amr as [{ method, timestamp }] objects.
        let token = jwt(claims: ["amr": [["method": "recovery", "timestamp": 1_700_000_000]]])
        XCTAssertTrue(AppModel.isRecoverySession(token))
    }

    func testMixedAmrWithRecoveryDetected() {
        let token = jwt(claims: ["amr": [["method": "password"], ["method": "recovery"]]])
        XCTAssertTrue(AppModel.isRecoverySession(token))
    }

    func testPasswordOnlyIsNotRecovery() {
        let token = jwt(claims: ["amr": [["method": "password"]]])
        XCTAssertFalse(AppModel.isRecoverySession(token))
    }

    func testStringPasswordAmrIsNotRecovery() {
        let token = jwt(claims: ["amr": ["password", "otp"]])
        XCTAssertFalse(AppModel.isRecoverySession(token))
    }

    func testMissingAmrClaimIsNotRecovery() {
        let token = jwt(claims: ["sub": "u1", "role": "authenticated"])
        XCTAssertFalse(AppModel.isRecoverySession(token))
    }

    func testEmptyAmrIsNotRecovery() {
        let token = jwt(claims: ["amr": [Any]()])
        XCTAssertFalse(AppModel.isRecoverySession(token))
    }

    func testMalformedTokenTooFewSegmentsIsNotRecovery() {
        XCTAssertFalse(AppModel.isRecoverySession("only-one-segment"))
        XCTAssertFalse(AppModel.isRecoverySession(""))
    }

    func testNonBase64PayloadIsNotRecovery() {
        XCTAssertFalse(AppModel.isRecoverySession("header.@@not-base64@@.sig"))
    }

    func testBase64urlPaddingIsTolerated() {
        // Payload length that requires '=' padding to be re-added before decode —
        // the probe pads to a multiple of 4. Use a claim set that recovers true.
        let token = jwt(claims: ["amr": ["recovery"], "iss": "supabase", "aud": "x"])
        XCTAssertTrue(AppModel.isRecoverySession(token))
    }
}
