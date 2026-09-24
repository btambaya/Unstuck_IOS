// Share-at-creation (New task → "Share with…" one row + the pre-create Share
// screen): the local selection, its submit mapping, the row's summary text
// and the pre-create result lines.

import XCTest
@testable import UnstuckCore

final class ShareDraftTests: XCTestCase {
    private func person(_ id: String, _ name: String, _ access: ShareAccess = .edit) -> ShareDraftPick {
        ShareDraftPick(recipient: .user(id: id), name: name, access: access)
    }
    private func address(_ email: String, _ access: ShareAccess = .edit) -> ShareDraftPick {
        ShareDraftPick(recipient: .email(email), name: email, access: access)
    }

    // MARK: summary — 0 / 1 / 2 / many

    func testNothingPickedIsOnlyYou() {
        XCTAssertEqual(shareDraftSummary([]), ShareDraftSummary(text: "Only you", spoken: "Only you"))
    }

    func testOnePersonShowsFirstNameAndGrade() {
        let s = shareDraftSummary([person("u1", "James Wilson")])
        XCTAssertEqual(s.text, "James · can edit")
        XCTAssertEqual(s.spoken, "James can edit")
        XCTAssertEqual(shareDraftSummary([person("u1", "James Wilson", .view)]).text, "James · can view")
    }

    func testTwoPeopleSameGradeShareOneGrade() {
        let s = shareDraftSummary([person("u1", "James Wilson"), person("u2", "Anna Berg")])
        XCTAssertEqual(s.text, "James, Anna · can edit")
        XCTAssertEqual(s.spoken, "James and Anna can edit")
    }

    func testMixedGradesNameEachGrade() {
        let s = shareDraftSummary([person("u1", "James Wilson", .edit), person("u2", "Anna Berg", .view)])
        XCTAssertEqual(s.text, "James · edit, Anna · view")
        XCTAssertEqual(s.spoken, "James can edit, Anna can view")
    }

    func testThreeShortNamesStillFitInFull() {
        let s = shareDraftSummary([person("u1", "Ivy Park"), person("u2", "Sam O'Brien"), person("u3", "Kai Lee")])
        XCTAssertEqual(s.text, "Ivy, Sam, Kai · can edit")
        XCTAssertEqual(s.spoken, "Ivy, Sam and Kai can edit")
    }

    func testManyPeopleCollapseToFirstPlusMore() {
        let picks = [person("u1", "James Wilson"), person("u2", "Anna Berg"),
                     person("u3", "Sam O'Brien"), person("u4", "Maya Chen")]
        let s = shareDraftSummary(picks)
        XCTAssertEqual(s.text, "James + 3 more")
        // VoiceOver still hears everyone.
        XCTAssertEqual(s.spoken, "James, Anna, Sam and Maya can edit")
    }

    func testMixedGradesThatDoNotFitCollapseToo() {
        let picks = [person("u1", "James Wilson", .edit), person("u2", "Anna Berg", .view), person("u3", "Sam O'Brien", .edit)]
        XCTAssertEqual(shareDraftSummary(picks).text, "James + 2 more")
    }

    func testSummaryNeverExceedsTheBudget() {
        let names = ["James Wilson", "Anastasia Konstantinopoulou", "Bartholomew-Maximilian", "Priya Raghunathan-Okafor",
                     "Zoë Müller", "Sam", "maximiliana.alexandra.longaddress@example.com"]
        for n in 1...names.count {
            for grades in [[ShareAccess.edit], [.view], [.edit, .view]] {
                let picks = names.prefix(n).enumerated().map { i, name in
                    person("u\(i)", name, grades[i % grades.count])
                }
                let text = shareDraftSummary(picks).text
                XCTAssertLessThanOrEqual(text.count, shareDraftSummaryMaxLength, "\(n) picks → “\(text)”")
                XCTAssertFalse(text.contains("\n"))
            }
        }
    }

    // MARK: summary — long names, addresses, collisions

    func testOneLongNameIsCutWithAnEllipsis() {
        let s = shareDraftSummary([person("u1", "Bartholomew-Maximilian")])
        XCTAssertEqual(s.text, "Bartholomew-Maxi… · can edit")
        XCTAssertEqual(s.text.count, shareDraftSummaryMaxLength)
        XCTAssertEqual(s.spoken, "Bartholomew-Maximilian can edit")
    }

    func testLongFirstNameIsCutBeforePlusMore() {
        let s = shareDraftSummary([person("u1", "Bartholomew-Maximilian"), person("u2", "Anna Berg"), person("u3", "Sam")])
        XCTAssertEqual(s.text, "Bartholomew-Maximi… + 2 more")
        XCTAssertLessThanOrEqual(s.text.count, shareDraftSummaryMaxLength)
    }

    func testAnAddressShowsItsLocalPart() {
        XCTAssertEqual(shareDraftSummary([address("maya@example.com", .view)]).text, "maya · can view")
    }

    func testTwoPicksThatWouldReadTheSameKeepFullNames() {
        let s = shareDraftSummary([person("u1", "Maya Chen"), person("u2", "Maya Lopez")])
        // "Maya, Maya" never happens — full names, which then collapse.
        XCTAssertEqual(s.spoken, "Maya Chen and Maya Lopez can edit")
        XCTAssertEqual(s.text, "Maya Chen + 1 more")
    }

    func testShortCustomBudget() {
        XCTAssertEqual(shareDraftSummary([person("u1", "James"), person("u2", "Anna")], maxLength: 14).text, "James + 1 more")
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

    func testRepickWithABlankNameKeepsTheKnownName() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "James Wilson", access: .edit)
        d.pick(userId: "u1", name: "  ", access: .view)
        XCTAssertEqual(d.pick(forUser: "u1")?.name, "James Wilson")
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

    func testSubmitMappingUsesTheShareScreensGradeMapping() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "James", access: .edit)
        d.pick(userId: "u2", name: "Anna", access: .view)
        d.addEmail("maya@example.com", access: .view)
        d.addEmail("sam@example.com", access: .edit)
        XCTAssertEqual(d.userShares, [ShareDraftUserShare(userId: "u1", level: .partner),
                                      ShareDraftUserShare(userId: "u2", level: .view)])
        XCTAssertEqual(d.emailShares, [ShareDraftEmailShare(email: "maya@example.com", level: .view),
                                       ShareDraftEmailShare(email: "sam@example.com", level: .partner)])
    }

    func testSubmitNeverHandsOver() {
        var d = ShareDraft()
        d.pick(userId: "u1", name: "James", access: .edit)
        d.addEmail("maya@example.com", access: .edit)
        XCTAssertFalse(d.userShares.contains { $0.level == .assign })
        XCTAssertFalse(d.emailShares.contains { $0.level == .assign })
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
        XCTAssertEqual(shareDraftResultLine(.removed(name: "Maya Chen")), "Maya won't get it.")
        XCTAssertEqual(shareDraftResultLine(.inviteCancelled(email: "x@y.com")), "x@y.com won't get it.")
        XCTAssertTrue(shareDraftResultLine(.linkCopied(kind: .task)).hasPrefix("Invite link copied"))
        for r: ShareResult in [.shared(name: "Maya", access: .edit), .invited(email: "x@y.com"),
                               .accessChanged(name: "Maya", access: .edit)] {
            XCTAssertFalse(shareDraftResultLine(r).hasPrefix("Shared with"), "nothing is shared before the task exists")
            XCTAssertFalse(shareDraftResultLine(r).contains("Invite sent"))
        }
    }
}
