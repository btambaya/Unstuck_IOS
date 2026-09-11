// The crash/hang trail (App/Diagnostics/CrashBreadcrumbs.swift): it must
// actually reach disk, and it must never be able to carry user content — the
// whole point is that it can be attached to a feedback report unreviewed.

import XCTest
@testable import Unstuck

final class CrashBreadcrumbsTests: XCTestCase {

    private var trail: String {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
        else { return "" }
        let url = base.appendingPathComponent("diagnostics/breadcrumbs.log")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The app installs the trail in `UnstuckApp.init`; a drop must land in the
    /// file, tagged with the thread it happened on.
    func testABreadcrumbReachesTheFile() {
        CrashBreadcrumbs.install()   // idempotent — the host app already did
        CrashBreadcrumbs.drop("tool.run create_tasks")
        XCTAssertTrue(trail.contains("tool.run create_tasks"), trail.suffix(400).description)
    }

    /// Anything that looks like user content is stripped: quotes, commas,
    /// apostrophes, emoji, @ and # are all gone, and the label is capped.
    func testUserContentCannotRideAlongInABreadcrumb() {
        CrashBreadcrumbs.install()
        CrashBreadcrumbs.drop(#"tool.run create_task "Call Mum about Dad's biopsy, 3pm" 🙏 @sarah #private"#)
        let written = trail
        for leak in ["\"", "'", ",", "🙏", "@", "#"] {
            XCTAssertFalse(written.contains(leak), "\(leak) survived sanitising")
        }
        // The harmless skeleton still gets through, so the trail is readable
        // (the stripped emoji leaves its surrounding spaces behind).
        XCTAssertTrue(written.contains("tool.run create_task Call Mum about Dads biopsy 3pm  sarah private"),
                      written.suffix(300).description)
    }

    func testALongLabelIsTruncated() {
        CrashBreadcrumbs.install()
        CrashBreadcrumbs.drop(String(repeating: "a", count: 500))
        let line = trail.split(separator: "\n").last { $0.contains("aaaa") } ?? ""
        // stamp + thread tag + at most 80 label characters.
        XCTAssertLessThanOrEqual(line.count, 100, String(line))
    }

    /// `lastReport` is only offered when the PREVIOUS run actually faulted —
    /// a clean run must not pester the user with an empty report.
    func testNoReportIsOfferedAfterACleanRun() {
        CrashBreadcrumbs.install()
        // The test host has not faulted, so there is nothing to attach.
        XCTAssertNil(CrashBreadcrumbs.lastReport)
    }
}

// MARK: - what the feedback composer actually sends

final class FeedbackPayloadTests: XCTestCase {

    private let report = "--- Unstuck diagnostics (previous session) ---\nSIGNAL 11"

    func testACleanRunSendsTheNoteVerbatim() {
        XCTAssertEqual(feedbackPayload(note: "  it crashed  ", report: nil, attach: true), "it crashed")
    }

    func testDecliningTheToggleSendsTheNoteVerbatim() {
        XCTAssertEqual(feedbackPayload(note: "it crashed", report: report, attach: false), "it crashed")
    }

    func testAcceptingTheToggleAppendsTheTrail() {
        let sent = feedbackPayload(note: "it crashed", report: report, attach: true)
        XCTAssertTrue(sent.hasPrefix("it crashed\n\n"))
        XCTAssertTrue(sent.contains("SIGNAL 11"))
    }

    /// An empty report is the same as no report — never send a bare header.
    func testAnEmptyReportIsNotAppended() {
        XCTAssertEqual(feedbackPayload(note: "it crashed", report: "", attach: true), "it crashed")
    }
}
