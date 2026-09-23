// App-confirm email links: the parser (which URLs are ours, what they carry),
// the verify-error classes (a port of the web's classifyVerifyError) and the
// copy. The contract is shared with the web + Android: the app asks with
// redirect `unstuck://auth-confirm`, the email links to
// https://unstucknow.io/auth/app-confirm/?token_hash=…&type=signup|magiclink.

import XCTest
@testable import UnstuckCore

final class AppConfirmLinkParseTests: XCTestCase {
    private let sample = "pkce_0123456789abcdef0123456789abcdef0123456789abcdef01234567"

    private func parse(_ s: String) -> AppConfirmLink? {
        AppConfirmLink.parse(URL(string: s)!)
    }

    // MARK: the contract's constants

    func testRedirectIsTheExactContractString() {
        XCTAssertEqual(AppConfirmLink.redirectTo, "unstuck://auth-confirm")
        XCTAssertEqual(AppConfirmLink.redirectURL.absoluteString, "unstuck://auth-confirm")
    }

    // MARK: the Universal Link

    func testTrailingSlashPathSignup() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=\(sample)&type=signup"),
                       .verify(tokenHash: sample, kind: .signup))
    }

    func testNoTrailingSlashPathMagicLink() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm?token_hash=\(sample)&type=magiclink"),
                       .verify(tokenHash: sample, kind: .magiclink))
    }

    func testDoubleTrailingSlashStillOurs() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm//?token_hash=\(sample)&type=signup"),
                       .verify(tokenHash: sample, kind: .signup))
    }

    func testEmailTypeAccepted() {
        // The web page accepts `email` too (verifyOtp's generic email type).
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=\(sample)&type=email"),
                       .verify(tokenHash: sample, kind: .email))
    }

    func testWwwHostAndUppercaseHostAccepted() {
        XCTAssertEqual(parse("https://www.unstucknow.io/auth/app-confirm/?token_hash=\(sample)&type=signup"),
                       .verify(tokenHash: sample, kind: .signup))
        XCTAssertEqual(parse("https://UnstuckNow.io/auth/app-confirm/?token_hash=\(sample)&type=signup"),
                       .verify(tokenHash: sample, kind: .signup))
    }

    func testExtraParamsAreIgnored() {
        let url = "https://unstucknow.io/auth/app-confirm/?utm_source=email&token_hash=\(sample)"
            + "&redirect_to=unstuck%3A%2F%2Fauth-confirm&type=signup&next=%2Ftoday"
        XCTAssertEqual(parse(url), .verify(tokenHash: sample, kind: .signup))
    }

    func testParamOrderDoesNotMatter() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?type=magiclink&token_hash=\(sample)"),
                       .verify(tokenHash: sample, kind: .magiclink))
    }

    func testFirstTokenHashWins() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=first&token_hash=second&type=signup"),
                       .verify(tokenHash: "first", kind: .signup))
    }

    func testPercentEncodedHashIsDecodedAndWhitespaceTrimmed() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=%20abc_123%20&type=signup"),
                       .verify(tokenHash: "abc_123", kind: .signup))
    }

    // MARK: ours, but unusable

    func testMissingHashIsInvalid() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?type=signup"), .unusable(.invalid))
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/"), .unusable(.invalid))
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm"), .unusable(.invalid))
    }

    func testEmptyOrBlankHashIsInvalid() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=&type=signup"), .unusable(.invalid))
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=%20%20&type=signup"), .unusable(.invalid))
    }

    func testEmptyFirstHashFallsThroughToALaterOne() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=&token_hash=abc&type=signup"),
                       .verify(tokenHash: "abc", kind: .signup))
    }

    func testOversizedHashIsInvalid() {
        let atCap = String(repeating: "a", count: AppConfirmLink.maxTokenHashLength)
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=\(atCap)&type=signup"),
                       .verify(tokenHash: atCap, kind: .signup))
        let over = atCap + "a"
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=\(over)&type=signup"),
                       .unusable(.invalid))
    }

    func testUnknownTypeIsInvalid() {
        for type in ["recovery", "invite", "email_change", "SIGNUP", "magic_link", ""] {
            XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=\(sample)&type=\(type)"),
                           .unusable(.invalid), "type=\(type)")
        }
    }

    func testMissingTypeIsInvalid() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?token_hash=\(sample)"), .unusable(.invalid))
    }

    func testCodeOnTheWebLinkIsInvalid() {
        // Only Supabase's own redirect (the custom scheme) carries a PKCE code.
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/?code=abc"), .unusable(.invalid))
    }

    func testDeeperPathUnderTheClaimedPrefixIsInvalid() {
        // The AASA claims /auth/app-confirm/* — it opened the app, so it is ours.
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/extra?token_hash=\(sample)&type=signup"),
                       .unusable(.invalid))
    }

    func testErrorRedirectIsUsed() {
        XCTAssertEqual(parse("https://unstucknow.io/auth/app-confirm/#error=access_denied&error_code=otp_expired"
                             + "&error_description=Email+link+is+invalid+or+has+expired"),
                       .unusable(.used))
    }

    // MARK: not ours

    func testOtherPathsAreNotOurs() {
        XCTAssertNil(parse("https://unstucknow.io/auth/confirm/?token_hash=\(sample)&type=signup"))  // the web page
        XCTAssertNil(parse("https://unstucknow.io/auth/app-confirmation?token_hash=\(sample)&type=signup"))
        XCTAssertNil(parse("https://unstucknow.io/circle/join?code=ABCD"))
        XCTAssertNil(parse("https://unstucknow.io/"))
        XCTAssertNil(parse("https://unstucknow.io/AUTH/APP-CONFIRM/?token_hash=\(sample)&type=signup"))
    }

    func testOtherHostsAndSchemesAreNotOurs() {
        XCTAssertNil(parse("https://evil.example/auth/app-confirm/?token_hash=\(sample)&type=signup"))
        XCTAssertNil(parse("https://evilunstucknow.io/auth/app-confirm/?token_hash=\(sample)&type=signup"))
        XCTAssertNil(parse("https://unstucknow.io.evil.example/auth/app-confirm/?token_hash=\(sample)&type=signup"))
        XCTAssertNil(parse("http://unstucknow.io/auth/app-confirm/?token_hash=\(sample)&type=signup"))
        XCTAssertNil(parse("unstuck://auth-callback?code=abc"))       // the old link — its own path
        XCTAssertNil(parse("unstuck://task/t1"))
        XCTAssertNil(parse("unstuck://today"))
    }

    // MARK: the custom scheme (defensive)

    func testCustomSchemeTokenHash() {
        XCTAssertEqual(parse("unstuck://auth-confirm?token_hash=\(sample)&type=signup"),
                       .verify(tokenHash: sample, kind: .signup))
        XCTAssertEqual(parse("unstuck://auth-confirm/?token_hash=\(sample)&type=magiclink"),
                       .verify(tokenHash: sample, kind: .magiclink))
    }

    func testCustomSchemePKCECodeIsExchanged() {
        XCTAssertEqual(parse("unstuck://auth-confirm?code=0b8a-4c2e"), .exchangeCode)
    }

    func testCustomSchemeTokenHashBeatsCode() {
        XCTAssertEqual(parse("unstuck://auth-confirm?code=abc&token_hash=\(sample)&type=signup"),
                       .verify(tokenHash: sample, kind: .signup))
    }

    func testCustomSchemeErrorRedirectIsUsed() {
        XCTAssertEqual(parse("unstuck://auth-confirm#error=access_denied&error_code=otp_expired"
                             + "&error_description=Email+link+is+invalid+or+has+expired"),
                       .unusable(.used))
        XCTAssertEqual(parse("unstuck://auth-confirm?error=server_error&error_description=x"), .unusable(.used))
    }

    func testCustomSchemeBareOrPathIsInvalid() {
        XCTAssertEqual(parse("unstuck://auth-confirm"), .unusable(.invalid))
        XCTAssertEqual(parse("unstuck://auth-confirm/somewhere?token_hash=\(sample)&type=signup"), .unusable(.invalid))
    }

    func testOddFragmentDoesNotTrap() throws {
        // %E0%A4 is a valid escape but not UTF-8 (removingPercentEncoding → nil);
        // `b` has no value. Neither may trap, and neither changes the answer.
        let url = try XCTUnwrap(URL(string: "unstuck://auth-confirm?token_hash=\(sample)&type=signup#a=%E0%A4&b&=x"))
        XCTAssertEqual(AppConfirmLink.parse(url), .verify(tokenHash: sample, kind: .signup))
    }
}

final class EmailLinkVerifyErrorTests: XCTestCase {
    func testOtpExpiredIsUsed() {
        XCTAssertEqual(classifyEmailLinkVerifyError(AuthErrorInfo(code: "otp_expired", message: "whatever", status: 403)), .used)
        XCTAssertEqual(classifyEmailLinkVerifyError(AuthErrorInfo(code: "otp_expired")), .used)
    }

    func testForbiddenExpiredOrInvalidMessageIsUsed() {
        XCTAssertEqual(classifyEmailLinkVerifyError(
            AuthErrorInfo(code: "unknown", message: "Email link is invalid or has expired", status: 403)), .used)
        XCTAssertEqual(classifyEmailLinkVerifyError(
            AuthErrorInfo(message: "Token has expired or is invalid", status: 403)), .used)
    }

    func testForbiddenWithOtherMessageIsRetry() {
        XCTAssertEqual(classifyEmailLinkVerifyError(AuthErrorInfo(message: "forbidden", status: 403)), .retry)
    }

    func testValidationIsInvalid() {
        XCTAssertEqual(classifyEmailLinkVerifyError(AuthErrorInfo(code: "validation_failed", status: 400)), .invalid)
        XCTAssertEqual(classifyEmailLinkVerifyError(AuthErrorInfo(code: "bad_json", status: 400)), .invalid)
    }

    func testNetworkRateLimitAndServerErrorsAreRetry() {
        XCTAssertEqual(classifyEmailLinkVerifyError(AuthErrorInfo(message: "The Internet connection appears to be offline.")), .retry)
        XCTAssertEqual(classifyEmailLinkVerifyError(AuthErrorInfo(code: "over_request_rate_limit", status: 429)), .retry)
        XCTAssertEqual(classifyEmailLinkVerifyError(AuthErrorInfo(code: "unexpected_failure", status: 500)), .retry)
        XCTAssertEqual(classifyEmailLinkVerifyError(AuthErrorInfo()), .retry)
    }
}

final class EmailLinkCopyTests: XCTestCase {
    func testUsedTellsThemToSignIn() {
        XCTAssertTrue(EmailLinkFailure.used.message.contains("already been used"))
        XCTAssertTrue(EmailLinkFailure.used.message.contains("sign in"))
    }

    func testEveryFailureHasALine() {
        for f in [EmailLinkFailure.used, .invalid, .retry] {
            XCTAssertFalse(f.message.isEmpty)
        }
        XCTAssertTrue(EmailLinkFailure.retry.message.contains("tap the link again"))
    }

    func testAlreadySignedInNamesTheAccountWhenKnown() {
        XCTAssertTrue(emailLinkAlreadySignedInMessage(email: "maya@example.com")
            .hasPrefix("You’re already signed in as maya@example.com."))
        XCTAssertTrue(emailLinkAlreadySignedInMessage(email: nil).hasPrefix("You’re already signed in."))
        XCTAssertTrue(emailLinkAlreadySignedInMessage(email: "").hasPrefix("You’re already signed in."))
        XCTAssertTrue(emailLinkAlreadySignedInMessage(email: nil).contains("sign out first"))
    }
}
