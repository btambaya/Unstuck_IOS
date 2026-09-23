// The AI-consent OK on the wire: read from a real GoTrue user body through
// supabase-swift's own decoder (what the client uses), and the exact
// user_metadata change the app sends — the same keys the web writes.

import XCTest
import Supabase
import UnstuckCore
@testable import UnstuckSync

final class AIConsentMetadataTests: XCTestCase {
    private func user(metadata: String) throws -> User {
        let json = """
        {"id":"6f0c1e0a-3b1d-4a53-9a55-0c1f2d3e4f50","aud":"authenticated","role":"authenticated",
         "email":"maya@example.com","app_metadata":{"provider":"email"},
         "user_metadata":\(metadata),
         "created_at":"2026-09-23T19:30:00.123456Z","updated_at":"2026-09-24T08:00:00.123456Z"}
        """
        return try AuthClient.Configuration.jsonDecoder.decode(User.self, from: Data(json.utf8))
    }

    func testAGrantWrittenByTheWebIsRead() throws {
        let u = try user(metadata: #"{"full_name":"Maya","ai_consent_at":"2026-09-24T08:00:00.000Z","ai_consent_version":"2026-09-24"}"#)
        let r = AuthService.aiConsent(from: u)
        XCTAssertEqual(r, AIConsent.Record(at: "2026-09-24T08:00:00.000Z", version: "2026-09-24"))
        XCTAssertTrue(r.isGranted)
    }

    func testNoKeysIsNoConsent() throws {
        let r = AuthService.aiConsent(from: try user(metadata: #"{"full_name":"Maya"}"#))
        XCTAssertEqual(r, .none)
        XCTAssertFalse(r.isGranted)
        XCTAssertEqual(AuthService.aiConsent(from: nil as User?), .none)
    }

    func testAClearedOrOddlyTypedValueIsNoConsent() throws {
        XCTAssertFalse(AuthService.aiConsent(from: try user(
            metadata: #"{"ai_consent_at":null,"ai_consent_version":"2026-09-24"}"#)).isGranted)
        XCTAssertFalse(AuthService.aiConsent(from: try user(
            metadata: #"{"ai_consent_at":true,"ai_consent_version":"2026-09-24"}"#)).isGranted)
        XCTAssertFalse(AuthService.aiConsent(from: try user(
            metadata: #"{"ai_consent_at":"2026-09-24T08:00:00.000Z","ai_consent_version":"2025-01-01"}"#)).isGranted)
    }

    func testAgreeWritesBothKeys() {
        let r = AIConsent.Record(at: "2026-09-24T08:00:00.000Z", version: AIConsent.version)
        XCTAssertEqual(AuthService.aiConsentData(r), [
            "ai_consent_at": .string("2026-09-24T08:00:00.000Z"),
            "ai_consent_version": .string("2026-09-24"),
        ])
    }

    func testTurningItOffClearsTheTime() {
        XCTAssertEqual(AuthService.aiConsentData(.none), ["ai_consent_at": .null])
        let off = AIConsent.revoked(AIConsent.Record(at: "2026-09-24T08:00:00.000Z", version: AIConsent.version))
        XCTAssertEqual(AuthService.aiConsentData(off), ["ai_consent_at": .null])
    }

    func testTheUpdateBodyCarriesAnExplicitNull() throws {
        // GoTrue deletes a user_metadata key sent as null — it must reach the wire.
        let body = try JSONEncoder().encode(UserAttributes(data: AuthService.aiConsentData(.none)))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(#""ai_consent_at":null"#), text)
    }
}
