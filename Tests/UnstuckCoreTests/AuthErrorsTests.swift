// Ported from lib/auth-helpers.test.ts (the pure helpers).

import XCTest
@testable import UnstuckCore

final class NextSafePathTests: XCTestCase {
    func testFallbackOnNilOrEmpty() {
        XCTAssertEqual(nextSafePath(nil), "/dashboard")
        XCTAssertEqual(nextSafePath(""), "/dashboard")
    }
    func testAcceptsSameOriginPath() {
        XCTAssertEqual(nextSafePath("/tasks"), "/tasks")
        XCTAssertEqual(nextSafePath("/calendar/week"), "/calendar/week")
    }
    func testPreservesQueryStrings() {
        XCTAssertEqual(nextSafePath("/tasks?new=1"), "/tasks?new=1")
    }
    func testRejectsDoubleSlash() {
        XCTAssertEqual(nextSafePath("//evil.com"), "/dashboard")
        XCTAssertEqual(nextSafePath("//evil.com/path"), "/dashboard")
    }
    func testRejectsAbsoluteURLs() {
        XCTAssertEqual(nextSafePath("https://evil.com"), "/dashboard")
        XCTAssertEqual(nextSafePath("http://example.com/foo"), "/dashboard")
        XCTAssertEqual(nextSafePath("javascript:alert(1)"), "/dashboard")
    }
    func testRejectsRelativeNotStartingWithSlash() {
        XCTAssertEqual(nextSafePath("tasks"), "/dashboard")
        XCTAssertEqual(nextSafePath("../tasks"), "/dashboard")
    }
    func testDecodesEncodedPaths() {
        XCTAssertEqual(nextSafePath("%2Ftasks"), "/tasks")
        XCTAssertEqual(nextSafePath("%2Ftasks%3Fnew%3D1"), "/tasks?new=1")
    }
    func testFallbackWhenDecodingThrows() {
        XCTAssertEqual(nextSafePath("%E0%A4%A"), "/dashboard")
    }
    func testHonoursCustomFallback() {
        XCTAssertEqual(nextSafePath(nil, fallback: "/onboarding"), "/onboarding")
        XCTAssertEqual(nextSafePath("//evil", fallback: "/onboarding"), "/onboarding")
    }
}

final class HumanizeAuthErrorTests: XCTestCase {
    func testEmptyError() {
        XCTAssertTrue(humanizeAuthError(nil).lowercased().contains("something went wrong"))
    }
    func testRateLimitByCodeAndMessage() {
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(code: "over_email_send_rate_limit", message: "whatever"))
            .lowercased().contains("few sign-up emails per hour"))
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(message: "Email rate limit exceeded"))
            .lowercased().contains("few sign-up emails per hour"))
    }
    func testInvalidCredentials() {
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(code: "invalid_credentials")).lowercased().contains("email and password don't match"))
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(message: "Invalid login credentials")).lowercased().contains("email and password don't match"))
    }
    func testUserAlreadyExists() {
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(code: "user_already_exists")).lowercased().contains("account with that email already exists"))
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(message: "User already registered")).lowercased().contains("account with that email already exists"))
    }
    func testEmailNotConfirmed() {
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(code: "email_not_confirmed")).lowercased().contains("email isn't confirmed"))
    }
    func testWeakPassword() {
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(code: "weak_password")).lowercased().contains("at least 8 characters"))
    }
    func testStatus429() {
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(message: "too many requests", status: 429)).lowercased().contains("rate limit"))
    }
    func testNetworkFailures() {
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(message: "Failed to fetch")).lowercased().contains("couldn't reach the server"))
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(message: "Operation timed out")).lowercased().contains("couldn't reach the server"))
    }
    func testInvalidEmail() {
        XCTAssertTrue(humanizeAuthError(AuthErrorInfo(message: "Invalid email")).lowercased().contains("email address looks off"))
    }
    func testFallbackCapitalises() {
        XCTAssertEqual(humanizeAuthError(AuthErrorInfo(message: "something weird happened")), "Something weird happened")
    }
}

final class DetectSignupAlreadyExistsTests: XCTestCase {
    func testEmptyIdentitiesMeansExists() {
        XCTAssertTrue(detectSignupAlreadyExists(identitiesCount: 0, emailConfirmedAt: nil, lastSignInAt: nil, hasSession: false))
    }
    func testNonEmptyIdentitiesIsGenuineNewUser() {
        XCTAssertFalse(detectSignupAlreadyExists(identitiesCount: 1, emailConfirmedAt: nil, lastSignInAt: nil, hasSession: false))
    }
    func testNilIdentitiesIsNotExists() {
        XCTAssertFalse(detectSignupAlreadyExists(identitiesCount: nil, emailConfirmedAt: nil, lastSignInAt: nil, hasSession: false))
    }
    func testConfirmedWithoutSessionMeansExists() {
        XCTAssertTrue(detectSignupAlreadyExists(identitiesCount: 1, emailConfirmedAt: "2026-01-01T00:00:00Z", lastSignInAt: nil, hasSession: false))
    }
    func testConfirmedWithSessionIsNewlyVerified() {
        XCTAssertFalse(detectSignupAlreadyExists(identitiesCount: 1, emailConfirmedAt: "2026-01-01T00:00:00Z", lastSignInAt: nil, hasSession: true))
    }
}
