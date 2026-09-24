// Unit tests for GreetingName.firstName — the pure first-name derivation
// behind the Today greeting — and GreetingName.line, the ONE-line
// "Good evening Maya." it renders (no line break since 2026-09-17). Mirrors the web
// firstName() in components/dashboard/greeting-header.tsx: first token split
// on whitespace / "." / "_" / "-"; nil/empty/separator-only → nil so the
// greeting falls back to the brand "Unstuck." line.

import XCTest
import UnstuckCore
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

/// The Today date eyebrow — "THURSDAY · 2:02 PM" on a 24-hour phone was the
/// bug (Ahmad, 2026-09-24). The weekday stays English; the time follows the
/// phone's 12/24-hour clock through ClockFormat.
final class TodayEyebrowClockTests: XCTestCase {
    private func thursday(_ h: Int, _ m: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 24; c.hour = h; c.minute = m
        return Time.calendar.date(from: c)!
    }

    func testEyebrowOnATwentyFourHourPhone() {
        XCTAssertEqual(TodayFmt.eyebrow(thursday(14, 2), clock: .h24), "Thursday · 14:02")
        XCTAssertEqual(TodayFmt.eyebrow(thursday(9, 5), clock: .h24), "Thursday · 09:05")
    }

    func testEyebrowOnATwelveHourPhone() {
        XCTAssertEqual(TodayFmt.eyebrow(thursday(14, 2), clock: .h12), "Thursday · 2:02 PM")
        XCTAssertEqual(TodayFmt.eyebrow(thursday(0, 30), clock: .h12), "Thursday · 12:30 AM")
    }

    func testEyebrowDefaultsToThePhonesClock() {
        let d = thursday(14, 2)
        XCTAssertEqual(TodayFmt.eyebrow(d), TodayFmt.eyebrow(d, clock: ClockFormat.device))
        XCTAssertTrue(TodayFmt.eyebrow(d).hasSuffix(ClockFormat.device.time(hour: 14, minute: 2)))
    }
}
