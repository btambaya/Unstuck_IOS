// Unit tests for GreetingName.firstName — the pure first-name derivation
// behind the Today greeting ("Good evening,\nMaya."). Mirrors the web
// firstName() in components/dashboard/greeting-header.tsx: first token split
// on whitespace / "." / "_" / "-"; nil/empty/separator-only → nil so the
// greeting falls back to the brand "Unstuck." line.

import XCTest
@testable import Unstuck

final class GreetingNameTests: XCTestCase {
    func testFullNameUsesFirstWord() {
        XCTAssertEqual(GreetingName.firstName("Maya Chen"), "Maya")
        XCTAssertEqual(GreetingName.firstName("Zubair Kazaure"), "Zubair")
    }

    func testSingleWordNamePassesThrough() {
        XCTAssertEqual(GreetingName.firstName("Maya"), "Maya")
    }

    func testEmailLocalPartSplitsLikeWeb() {
        // AuthService.displayName falls back to the email local-part when no
        // full_name/display_name metadata is set — the web splits those on
        // . _ - too, so "maya.chen" greets as "maya".
        XCTAssertEqual(GreetingName.firstName("maya.chen"), "maya")
        XCTAssertEqual(GreetingName.firstName("maya_chen"), "maya")
        XCTAssertEqual(GreetingName.firstName("maya-chen"), "maya")
    }

    func testWhitespacePaddingIsIgnored() {
        XCTAssertEqual(GreetingName.firstName("  Maya Chen  "), "Maya")
        XCTAssertEqual(GreetingName.firstName("Maya\n"), "Maya")
    }

    func testConsecutiveSeparatorsCollapse() {
        XCTAssertEqual(GreetingName.firstName("maya..chen"), "maya")
        XCTAssertEqual(GreetingName.firstName(" . Maya"), "Maya")
    }

    func testNoNameFallsBackToNil() {
        // nil / empty / separator-only → nil, so the greeting renders the
        // brand "Unstuck." line exactly as before.
        XCTAssertNil(GreetingName.firstName(nil))
        XCTAssertNil(GreetingName.firstName(""))
        XCTAssertNil(GreetingName.firstName("   "))
        XCTAssertNil(GreetingName.firstName("._-"))
    }
}
