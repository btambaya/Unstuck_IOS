// App-layer unit tests for AppModel.isRecoverySession — the static, dependency-
// free JWT `amr` (authentication-methods-reference) probe used to classify a
// PKCE password-recovery session (the recovery deep link carries no
// type=recovery, so the only reliable signal is the exchanged JWT). Best-effort
// base64url decode of the unsigned middle segment. Mirrors the Android probe.

import XCTest
import UnstuckCore
import UnstuckSync
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

// App-confirm email links (owner decision 2026-09-23): the routing AppModel
// applies once AppConfirmLink (UnstuckCore, parser tested there) has said a
// URL is ours. Kept beside the recovery probe — both are "an email link lands
// in the app" rules, and the password-reset link must stay on auth-callback.
final class AppConfirmRoutingTests: XCTestCase {
    private let link = AppConfirmLink.verify(tokenHash: "pkce_abc", kind: .signup)

    func testColdLaunchStashesUntilTheCoordinatorExists() {
        XCTAssertEqual(AppModel.appConfirmAction(link, coordinatorReady: false, signedInUserId: nil), .stash)
        // Even with a session stored: the replay at the end of start() decides.
        XCTAssertEqual(AppModel.appConfirmAction(link, coordinatorReady: false, signedInUserId: "u1"), .stash)
    }

    func testSignedOutVerifiesTheHash() {
        XCTAssertEqual(AppModel.appConfirmAction(link, coordinatorReady: true, signedInUserId: nil),
                       .verify(tokenHash: "pkce_abc", kind: .signup))
        XCTAssertEqual(AppModel.appConfirmAction(link, coordinatorReady: true, signedInUserId: ""),
                       .verify(tokenHash: "pkce_abc", kind: .signup))
    }

    func testSignedOutExchangesSupabasesOwnRedirect() {
        XCTAssertEqual(AppModel.appConfirmAction(.exchangeCode, coordinatorReady: true, signedInUserId: nil), .exchange)
    }

    func testSignedOutShowsAnUnusableLinksReason() {
        XCTAssertEqual(AppModel.appConfirmAction(.unusable(.used), coordinatorReady: true, signedInUserId: nil),
                       .showFailure(.used))
        XCTAssertEqual(AppModel.appConfirmAction(.unusable(.invalid), coordinatorReady: true, signedInUserId: nil),
                       .showFailure(.invalid))
    }

    func testSignedInNeverUsesTheLink() {
        // Verifying would replace this session with whichever account the link
        // belongs to — a silent swap. Every kind of link gets the notice instead.
        for l in [link, .exchangeCode, .unusable(.used), .unusable(.invalid)] {
            XCTAssertEqual(AppModel.appConfirmAction(l, coordinatorReady: true, signedInUserId: "u1"), .alreadySignedIn)
        }
    }

    func testCircleAndAppConfirmLinksDoNotClaimEachOther() {
        let confirm = URL(string: "https://unstucknow.io/auth/app-confirm/?token_hash=abc&type=signup")!
        let circle = URL(string: "https://unstucknow.io/circle/join?code=ABCD")!
        XCTAssertNil(AppModel.circleJoinCode(from: confirm))
        XCTAssertNil(AppConfirmLink.parse(circle))
        XCTAssertEqual(AppModel.circleJoinCode(from: circle), "ABCD")
    }

    func testPasswordResetLinkIsNotAnAppConfirmLink() {
        // Reset keeps unstuck://auth-callback + the amr probe.
        XCTAssertNil(AppConfirmLink.parse(URL(string: "unstuck://auth-callback?code=abc")!))
        XCTAssertNil(AppConfirmLink.parse(URL(string: "unstuck://auth-callback#type=recovery")!))
    }

    @MainActor
    func testOutcomesReachTheSignInScreen() {
        let model = AppModel()
        model.applyEmailLinkOutcome(.failed(.used))
        XCTAssertEqual(model.authLinkStatus?.message, EmailLinkFailure.used.message)
        XCTAssertEqual(model.authLinkStatus?.isError, true)

        model.applyEmailLinkOutcome(.failed(.retry))
        XCTAssertEqual(model.authLinkStatus?.message, EmailLinkFailure.retry.message)

        model.applyEmailLinkOutcome(.confirmedNoSession)
        XCTAssertEqual(model.authLinkStatus?.message, emailLinkConfirmedSignInMessage)
        XCTAssertEqual(model.authLinkStatus?.isError, false)

        model.applyEmailLinkOutcome(.signedIn)
        XCTAssertNil(model.authLinkStatus)
    }

    @MainActor
    func testALateFailureAfterSigningInIsDropped() {
        // Two taps of one link: the first signed in, the second comes back
        // "used" — nothing may wait to greet the next sign-out.
        let model = AppModel()
        model.signedIn = true
        model.applyEmailLinkOutcome(.failed(.used))
        XCTAssertNil(model.authLinkStatus)
    }

    @MainActor
    func testSameMessageTwiceIsStillAChange() {
        let a = AppModel.AuthLinkStatus(message: "x", isError: true)
        let b = AppModel.AuthLinkStatus(message: "x", isError: true)
        XCTAssertNotEqual(a, b)
    }

    @MainActor
    func testALinkBeforeStartIsHeldQuietly() {
        // No coordinator yet (cold launch): nothing shown, nothing routed as a
        // circle invite — the URL waits for start() to replay it.
        let model = AppModel()
        model.handleDeepLink(URL(string: "https://unstucknow.io/auth/app-confirm/?token_hash=abc&type=signup")!)
        XCTAssertNil(model.authLinkStatus)
        XCTAssertNil(model.signedInLinkNotice)
        XCTAssertNil(model.circleInvitePrompt)
    }
}
