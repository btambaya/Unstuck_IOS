// Unit tests for GreetingName.firstName — the pure first-name derivation
// behind the Today greeting — and GreetingName.line, the ONE-line
// "Good evening Maya." it renders (no line break since 2026-09-17). Mirrors the web
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

    // MARK: the one-line greeting

    func testGreetingIsOneLineWithTheFirstName() {
        XCTAssertEqual(GreetingName.line(greeting: "Good evening", firstName: "Maya"), "Good evening Maya.")
        XCTAssertEqual(GreetingName.line(greeting: "Good morning", firstName: GreetingName.firstName("Zubair Kazaure")),
                       "Good morning Zubair.")
        XCTAssertFalse(GreetingName.line(greeting: "Still up", firstName: "Maya").contains("\n"),
                       "the name no longer stacks on a second line")
    }

    func testGreetingFallsBackToTheBrandLineWithoutAName() {
        XCTAssertEqual(GreetingName.line(greeting: "Good afternoon", firstName: nil), "Good afternoon Unstuck.")
        XCTAssertEqual(GreetingName.line(greeting: "Good afternoon", firstName: GreetingName.firstName("")),
                       "Good afternoon Unstuck.")
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
