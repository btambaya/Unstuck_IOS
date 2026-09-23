// Sign-up with an email that is ALREADY registered (owner 2026-09-23: "we need
// to notify the user the email has been used or an account has been created").
// GoTrue answers with 200, no session, no email sent, and an obfuscated user
// whose "identities" is [] (sanitizeUser). The web's supabase-js 2.106 dropped
// that user, so the web showed a dead-end "check your email". These tests run
// the real bodies through supabase-swift's own decoder (the one the client
// uses) and then AuthService's decision, so a future SDK that decoded the body
// differently would fail here rather than on a user's phone.

import XCTest
import Supabase
import UnstuckCore
@testable import UnstuckSync

final class SignUpResponseTests: XCTestCase {
    private func decode(_ json: String) throws -> AuthResponse {
        try AuthClient.Configuration.jsonDecoder.decode(AuthResponse.self, from: Data(json.utf8))
    }

    /// GoTrue's sanitized user for an existing, confirmed address.
    private let alreadyRegistered = """
    {"id":"6f0c1e0a-3b1d-4a53-9a55-0c1f2d3e4f50","aud":"authenticated","role":"",
     "email":"maya@example.com","phone":"",
     "confirmation_sent_at":"2026-09-23T19:30:00.123456Z",
     "app_metadata":{"provider":"email","providers":["email"]},
     "user_metadata":{"full_name":"Maya","display_name":"Maya"},
     "identities":[],
     "created_at":"2026-09-23T19:30:00.123456Z","updated_at":"2026-09-23T19:30:00.123456Z",
     "is_anonymous":false}
    """

    /// A genuine new sign-up waiting on its confirmation email.
    private let newSignUp = """
    {"id":"1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d","aud":"authenticated","role":"authenticated",
     "email":"new@example.com","phone":"",
     "confirmation_sent_at":"2026-09-23T19:30:00.123456Z",
     "app_metadata":{"provider":"email","providers":["email"]},
     "user_metadata":{"email":"new@example.com","email_verified":false,"phone_verified":false,
                      "sub":"1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d"},
     "identities":[{"identity_id":"9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d",
                    "id":"1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                    "user_id":"1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                    "identity_data":{"email":"new@example.com","email_verified":false,
                                     "phone_verified":false,"sub":"1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d"},
                    "provider":"email","last_sign_in_at":"2026-09-23T19:30:00.12345Z",
                    "created_at":"2026-09-23T19:30:00.12345Z","updated_at":"2026-09-23T19:30:00.12345Z",
                    "email":"new@example.com"}],
     "created_at":"2026-09-23T19:30:00.123456Z","updated_at":"2026-09-23T19:30:00.123456Z",
     "is_anonymous":false}
    """

    func testAlreadyRegisteredDecodesAsAUserWithNoIdentities() throws {
        let response = try decode(alreadyRegistered)
        XCTAssertNil(response.session)
        XCTAssertEqual(response.user.identities?.count, 0)
    }

    func testAlreadyRegisteredIsAlreadyExists() throws {
        let response = try decode(alreadyRegistered)
        XCTAssertEqual(AuthService.signUpOutcome(user: response.user, hasSession: false), .alreadyExists)
    }

    func testGenuineNewSignUpNeedsConfirmation() throws {
        let response = try decode(newSignUp)
        XCTAssertNil(response.session)
        XCTAssertEqual(response.user.identities?.count, 1)
        XCTAssertEqual(AuthService.signUpOutcome(user: response.user, hasSession: false), .needsConfirmation)
    }

    func testMissingIdentitiesKeyIsNotTakenAsExisting() throws {
        // No "identities" key at all decodes to nil — that is NOT the
        // anti-enumeration tell, so it stays the ordinary "check your email".
        let json = alreadyRegistered.replacingOccurrences(of: "\"identities\":[],", with: "")
        let response = try decode(json)
        XCTAssertNil(response.user.identities)
        XCTAssertEqual(AuthService.signUpOutcome(user: response.user, hasSession: false), .needsConfirmation)
    }

    func testInstantConfirmWithASessionIsOk() throws {
        let response = try decode(newSignUp)
        XCTAssertEqual(AuthService.signUpOutcome(user: response.user, hasSession: true), .ok)
    }
}
