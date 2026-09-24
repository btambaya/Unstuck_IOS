// Share-at-creation (New task → "Share with…" one row + the pre-create Share
// screen): the local selection, its submit mapping, the row's summary text
// and the pre-create result lines.

import XCTest
@testable import UnstuckCore

final class ShareDraftTests: XCTestCase {
    private func person(_ id: String, _ name: String, _ level: ShareLevel = .partner) -> ShareDraftPick {
        ShareDraftPick(recipient: .user(id: id), name: name, level: level)
    }

    // MARK: THE SHARED CASES — the summary rule, verbatim on iOS / Android / web

    /// One row per case: the picks as (name, level) — "e" Can edit (partner),
    /// "v" Can view (view), "h" Hand over (assign) — and the row's text at the
    /// default budget of 28 characters. Android (ShareWithSummaryTest) and web
    /// (pre-create-share.test) carry the same table.
    static let sharedCases: [(picks: [(String, String)], text: String)] = [
        ([], "Only you"),
        // 1 → "<Name> · can edit|can view|handed over"
        ([("James Wilson", "e")], "James · can edit"),
        ([("James Wilson", "v")], "James · can view"),
        ([("James Wilson", "h")], "James · handed over"),
        // 2, same grade → "<A>, <B> · <grade>"
        ([("James Wilson", "e"), ("Anna Berg", "e")], "James, Anna · can edit"),
        ([("James Wilson", "v"), ("Anna Berg", "v")], "James, Anna · can view"),
        ([("James Wilson", "h"), ("Anna Berg", "h")], "James, Anna · handed over"),
        // 2, mixed → "<A> · edit, <B> · view"
        ([("James Wilson", "e"), ("Anna Berg", "v")], "James · edit, Anna · view"),
        ([("Anna Berg", "v"), ("James Wilson", "e")], "Anna · view, James · edit"),
        // 3+ → "<First> + N more", " · <grade>" ONLY when everyone has the same one
        ([("James Wilson", "e"), ("Anna Berg", "e"), ("Sam O'Brien", "e")], "James + 2 more · can edit"),
        ([("James Wilson", "v"), ("Anna Berg", "v"), ("Sam", "v"), ("Maya Chen", "v"), ("Kai", "v")],
         "James + 4 more · can view"),
        ([("James Wilson", "h"), ("Anna Berg", "h"), ("Sam", "h")], "James + 2 more · handed over"),
        ([("James Wilson", "e"), ("Anna Berg", "v"), ("Sam O'Brien", "e")], "James + 2 more"),
        ([("Ivy Park", "e"), ("Sam O'Brien", "e"), ("Kai Lee", "e")], "Ivy + 2 more · can edit"),
        // addresses: the part before the @
        ([("maya@example.com", "v")], "maya · can view"),
        ([("James Wilson", "e"), ("maya@example.com", "v")], "James · edit, maya · view"),
        // blank → "Someone"
        ([("", "e")], "Someone · can edit"),
        // long names are cut with "…" BEFORE the grade — the grade always shows
        ([("Bartholomew-Alexander", "e")], "Bartholomew-Alex… · can edit"),
        ([("Wolfeschlegelsteinhausenbergerdorff", "v")], "Wolfeschlegelste… · can view"),
        ([("Bartholomew-Alexander", "h")], "Bartholomew-A… · handed over"),
        ([("Bartholomew-Alexander", "e"), ("Anna Berg", "e")], "Bartholome…, Anna · can edit"),
        ([("Bartholomew-Alexander", "e"), ("Wolfeschlegelsteinhausen", "e")], "Bartho…, Wolfes… · can edit"),
        ([("Bartholomew-Alexander", "e"), ("Anna Berg", "v")], "Barthol… · edit, Anna · view"),
        ([("James Wilson", "e"), ("Anna Berg", "h")], "J… · edit, A… · handed over"),
        ([("Bartholomew-Alexander", "e"), ("Anna", "e"), ("Sam", "e")], "Barthol… + 2 more · can edit"),
        ([("Bartholomew-Alexander", "e"), ("Anna", "v"), ("Sam", "e")], "Bartholomew-Alexan… + 2 more"),
    ]

    private static func level(_ code: String) -> ShareLevel {
        switch code {
        case "v": return .view
        case "h": return .assign
        default: return .partner
        }
    }

    func testTheSharedCases() {
        for c in Self.sharedCases {
            let picks = c.picks.enumerated().map { i, p in
                p.0.contains("@") ? ShareDraftPick(recipient: .email(p.0), name: p.0, level: Self.level(p.1))
                                  : person("u\(i)", p.0, Self.level(p.1))
            }
            let text = shareDraftSummary(picks).text
            XCTAssertEqual(text, c.text, "\(c.picks)")
            XCTAssertLessThanOrEqual(text.count, shareDraftSummaryMaxLength, "“\(text)” is over the budget")
        }
    }

    // MARK: summary — the rule's edges

    func testNothingPickedIsOnlyYou() {
        XCTAssertEqual(shareDraftSummary([]), ShareDraftSummary(text: "Only you", spoken: "Only you"))
    }

    func testTheFormGoesByCountNeverByLength() {
        // Three short names would fit in full — the rule still says "+ N more".
        XCTAssertEqual(shareDraftSummary([person("u1", "Al"), person("u2", "Bo"), person("u3", "Cy")]).text,
                       "Al + 2 more · can edit")
        // Two long names never collapse to "+ 1 more": they are cut instead.
        let two = shareDraftSummary([person("u1", "Bartholomew-Alexander"), person("u2", "Anna Berg", .view)]).text
        XCTAssertTrue(two.hasSuffix("· edit, Anna · view"), two)
        XCTAssertFalse(two.contains("more"))
    }

    func testTheGradeAlwaysShowsAtEveryBudget() {
        let sets: [[ShareDraftPick]] = [
            [person("u1", "Bartholomew-Alexander")],
            [person("u1", "Bartholomew-Alexander", .assign)],
            [person("u1", "Bartholomew-Alexander"), person("u2", "Wolfeschlegelsteinhausen")],
            [person("u1", "Bartholomew-Alexander", .view), person("u2", "Anna"), person("u3", "Sam", .view)],
            (0..<6).map { person("u\($0)", "Priya Raghunathan-Okafor", .view) },
        ]
        for picks in sets {
            for budget in [28, 24, 20, 16, 12] {
                let text = shareDraftSummary(picks, maxLength: budget).text
                let levels = Set(picks.map(\.level))
                if picks.count <= 2 || levels.count == 1 {
                    for level in levels {
                        let grade = picks.count == 2 && levels.count > 1 ? shareDraftGradeWord(level) : shareDraftGradePhrase(level)
                        XCTAssertTrue(text.contains(grade), "budget \(budget): “\(text)” lost “\(grade)”")
                    }
                }
                if picks.count >= 3 { XCTAssertTrue(text.contains("+ \(picks.count - 1) more"), text) }
                XCTAssertFalse(text.contains("\n"))
            }
        }
    }

    func testANameIsNeverCutBelowOneLetter() {
        let text = shareDraftSummary([person("u1", "Bartholomew-Alexander"), person("u2", "Anna", .assign)],
                                     maxLength: 12).text
        XCTAssertEqual(text, "B… · edit, A… · handed over", "past the floor the view truncates, never the rule")
    }

    func testSpokenFormsAreNeverTruncated() {
        XCTAssertEqual(shareDraftSummary([person("u1", "James Wilson")]).spoken, "James can edit")
        XCTAssertEqual(shareDraftSummary([person("u1", "James Wilson"), person("u2", "Anna Berg")]).spoken,
                       "James and Anna can edit")
        XCTAssertEqual(shareDraftSummary([person("u1", "James Wilson"), person("u2", "Anna Berg", .view)]).spoken,
                       "James can edit, Anna can view")
        XCTAssertEqual(shareDraftSummary([person("u1", "James Wilson", .assign)]).spoken, "handed over to James")
        XCTAssertEqual(shareDraftSummary([person("u1", "James", .view), person("u2", "Anna", .assign)]).spoken,
                       "James can view, handed over to Anna")
        let many = [person("u1", "James Wilson"), person("u2", "Anna Berg"), person("u3", "Sam O'Brien"),
                    person("u4", "Bartholomew-Alexander")]
        XCTAssertEqual(shareDraftSummary(many).spoken, "James, Anna, Sam and Bartholomew-Alexander can edit")
    }

    func testTwoPeopleWithTheSameFirstNameReadAsTheRuleSays() {
        // No special case (web and Android have none): first names, as written.
        XCTAssertEqual(shareDraftSummary([person("u1", "Maya Chen"), person("u2", "Maya Lopez")]).text,
                       "Maya, Maya · can edit")
    }

    // MARK: the local selection

    func testPickAppendsInOrderAndRepickChangesGradeInPlace() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "James Wilson", access: .edit)
        d.pick(userId: "u2", name: "Anna Berg", access: .edit)
        d.pick(userId: "u1", name: "James Wilson", access: .view)
        XCTAssertEqual(d.picks.map(\.id), ["user:u1", "user:u2"])
        XCTAssertEqual(d.pick(forUser: "u1")?.access, .view)
        d.pick(userId: "", name: "Nobody", access: .edit)
        XCTAssertEqual(d.picks.count, 2, "a blank id is never picked")
    }

    func testHandOverIsAPickLevelOfItsOwn() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "James Wilson", access: .edit)
        d.pick(userId: "u1", name: "James Wilson", level: .assign)
        XCTAssertEqual(d.picks.count, 1, "a hand-over re-grades the pick in place")
        XCTAssertTrue(d.pick(forUser: "u1")?.handedOver == true)
        XCTAssertNil(d.pick(forUser: "u1")?.access, "handed over is neither Can edit nor Can view")
        XCTAssertEqual(shareDraftSummary(d.picks).text, "James · handed over")
        d.setAccess(id: "user:u1", .view)
        XCTAssertEqual(d.pick(forUser: "u1")?.level, .view, "and back to a grade from the same menu")
        // No one-hand-over limit (the server has none; neither do web / Android).
        d.pick(userId: "u1", name: "James", level: .assign)
        d.pick(userId: "u2", name: "Anna", level: .assign)
        XCTAssertEqual(d.userShares.map(\.level), [.assign, .assign])
    }

    func testAnAddressIsNeverHandedOver() {
        var d = ShareDraft()
        d.addEmail("maya@example.com", access: .view)
        d.setLevel(id: "email:maya@example.com", .assign)
        XCTAssertEqual(d.emails.first?.level, .partner, "held as Can edit, as on web")
        XCTAssertEqual(ShareDraftPick(recipient: .email("x@y.com"), name: "x@y.com", level: .assign).level, .partner)
        XCTAssertEqual(d.emailShares, [ShareDraftEmailShare(email: "maya@example.com", level: .partner)])
    }

    func testRepickWithABlankNameKeepsTheKnownName() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "James Wilson", access: .edit)
        d.pick(userId: "u1", name: "  ", access: .view)
        XCTAssertEqual(d.pick(forUser: "u1")?.name, "James Wilson")
    }

    func testAConnectionWithNoNameIsSomeoneNeverBlank() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "", access: .edit)
        XCTAssertEqual(d.pick(forUser: "u1")?.name, "Someone", "the Share screen's row name for them")
        XCTAssertEqual(shareDraftSummary(d.picks).text, "Someone · can edit")
        d.pick(userId: "u2", name: " Anna Berg ", access: .view)
        XCTAssertEqual(d.pick(forUser: "u2")?.name, "Anna Berg", "names are trimmed")
        XCTAssertEqual(shareDraftSummary(d.picks).text, "Someone · edit, Anna · view")
        // A pick built directly with no name still never reads "them".
        XCTAssertEqual(shareDraftSummary([person("u9", "  ", .view)]).text, "Someone · can view")
        d.pick(userId: "u1", name: "Maya Chen", access: .edit)
        XCTAssertEqual(d.pick(forUser: "u1")?.name, "Maya Chen", "a later known name replaces the fallback")
    }

    func testSetAccessAndRemoveById() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "James", access: .edit)
        d.addEmail("maya@example.com", access: .edit)
        d.setAccess(id: "email:maya@example.com", .view)
        XCTAssertEqual(d.emails.first?.access, .view)
        d.setAccess(id: "user:nope", .view)   // ignored
        XCTAssertTrue(d.remove(id: ShareDraftPick.id(forUser: "u1")))
        XCTAssertFalse(d.remove(id: "user:u1"), "already gone")
        XCTAssertEqual(d.picks.map(\.id), ["email:maya@example.com"])
    }

    func testAddEmailNormalisesDedupesAndRefusesJunk() {
        var d = ShareDraft()
        XCTAssertTrue(d.addEmail("  Maya@Example.COM ", access: .edit))
        XCTAssertTrue(d.addEmail("maya@example.com", access: .view))
        XCTAssertEqual(d.emails.count, 1)
        XCTAssertEqual(d.emails.first?.name, "maya@example.com")
        XCTAssertEqual(d.emails.first?.access, .view)
        XCTAssertFalse(d.addEmail("not an email", access: .edit))
        XCTAssertFalse(d.addEmail("", access: .edit))
        XCTAssertEqual(d.picks.count, 1)
    }

    func testAHeldAddressCountsInTheSummaryByItsLocalPart() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "James Wilson", access: .edit)
        d.addEmail("Maya.Chen@Example.com", access: .edit)
        XCTAssertEqual(shareDraftSummary(d.picks).text, "James, maya.chen · can edit")
    }

    func testPeopleAndEmailsSplitKeepsPickOrder() {
        var d = ShareDraft()
        d.addEmail("a@x.com", access: .edit)
        d.pick(userId: "u1", name: "James", access: .view)
        d.addEmail("b@x.com", access: .view)
        XCTAssertEqual(d.people.map(\.id), ["user:u1"])
        XCTAssertEqual(d.emails.map(\.id), ["email:a@x.com", "email:b@x.com"])
        XCTAssertFalse(d.isEmpty)
        XCTAssertTrue(ShareDraft().isEmpty)
    }

    // MARK: selection → submit

    func testSubmitMappingSendsTheLevelsWebAndAndroidSend() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "James", access: .edit)
        d.pick(userId: "u2", name: "Anna", access: .view)
        d.pick(userId: "u3", name: "Sam", level: .assign)
        d.addEmail("maya@example.com", access: .view)
        d.addEmail("sam@example.com", access: .edit)
        XCTAssertEqual(d.userShares, [ShareDraftUserShare(userId: "u1", level: .partner),
                                      ShareDraftUserShare(userId: "u2", level: .view),
                                      ShareDraftUserShare(userId: "u3", level: .assign)])
        XCTAssertEqual(d.emailShares, [ShareDraftEmailShare(email: "maya@example.com", level: .view),
                                       ShareDraftEmailShare(email: "sam@example.com", level: .partner)])
    }

    func testRemovedPicksAreNotSubmitted() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "James", access: .edit)
        d.pick(userId: "u2", name: "Anna", access: .edit)
        d.remove(id: "user:u1")
        XCTAssertEqual(d.userShares, [ShareDraftUserShare(userId: "u2", level: .partner)])
        XCTAssertTrue(d.emailShares.isEmpty)
        XCTAssertTrue(ShareDraft().userShares.isEmpty && ShareDraft().emailShares.isEmpty)
    }

    // MARK: pre-create lines

    func testPreCreateLinesSayWhatWillHappen() {
        XCTAssertEqual(shareDraftResultLine(.shared(name: "Maya Chen", access: .edit)),
                       "Maya will get it when you add the task — they can edit.")
        XCTAssertEqual(shareDraftResultLine(.invited(email: "x@y.com")), "x@y.com will get it when you add the task.")
        XCTAssertEqual(shareDraftResultLine(.accessChanged(name: "Maya Chen", access: .view)), "Maya will be able to view.")
        XCTAssertEqual(shareDraftResultLine(.handedOver(name: "Maya Chen")),
                       "Maya will get it as their task when you add it — you keep view.")
        XCTAssertEqual(shareDraftResultLine(.removed(name: "Maya Chen")), "Maya won't get it.")
        XCTAssertEqual(shareDraftResultLine(.inviteCancelled(email: "x@y.com")), "x@y.com won't get it.")
        XCTAssertTrue(shareDraftResultLine(.linkCopied(kind: .task)).hasPrefix("Invite link copied"))
        for r: ShareResult in [.shared(name: "Maya", access: .edit), .invited(email: "x@y.com"),
                               .accessChanged(name: "Maya", access: .edit), .handedOver(name: "Maya")] {
            XCTAssertFalse(shareDraftResultLine(r).hasPrefix("Shared with"), "nothing is shared before the task exists")
            XCTAssertFalse(shareDraftResultLine(r).hasPrefix("Handed over to"), "nothing is handed over yet either")
            XCTAssertFalse(shareDraftResultLine(r).contains("Invite sent"))
        }
    }
}
