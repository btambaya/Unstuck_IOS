// AI data-sharing consent (guideline 5.1.2(i)): the shared contract with the
// web — the keys, the version rule, the exact copy — plus the rules the app
// gates on: what "Not now" does, when app open asks, and how the device copy
// follows the account's user_metadata.

import XCTest
@testable import UnstuckCore

final class AIConsentTests: XCTestCase {

    // MARK: the contract

    func testTheContractConstants() {
        XCTAssertEqual(AIConsent.version, "2026-09-24")
        XCTAssertEqual(AIConsent.atKey, "ai_consent_at")
        XCTAssertEqual(AIConsent.versionKey, "ai_consent_version")
        XCTAssertEqual(AIConsent.privacyURL.absoluteString, "https://unstucknow.io/privacy#s9")
    }

    func testTheCopyIsWordForWord() {
        XCTAssertEqual(AIConsent.title, "Your assistant uses OpenAI")
        XCTAssertEqual(AIConsent.body, "To answer you, Unstuck sends what you type or say to the assistant — including your voice in Talk and calls — with the tasks, calendar and notes it needs, to OpenAI, our AI provider. OpenAI uses it to reply and doesn't train its models on it. You can turn this off any time in Settings.")
        XCTAssertEqual(AIConsent.privacyLinkLabel, "Privacy policy")
        XCTAssertEqual(AIConsent.agreeLabel, "Agree and continue")
        XCTAssertEqual(AIConsent.declineLabel, "Not now")
    }

    // MARK: which records count

    func testAMatchingVersionWithATimeCounts() {
        XCTAssertTrue(AIConsent.isGranted(at: "2026-09-24T10:00:00.000Z", version: "2026-09-24"))
        XCTAssertTrue(AIConsent.Record(at: "2026-09-24T10:00:00.000Z", version: AIConsent.version).isGranted)
    }

    func testMissingOrBlankTimeAsks() {
        XCTAssertFalse(AIConsent.isGranted(at: nil, version: AIConsent.version))
        XCTAssertFalse(AIConsent.isGranted(at: "", version: AIConsent.version))
        XCTAssertFalse(AIConsent.isGranted(at: "  ", version: AIConsent.version))
        XCTAssertFalse(AIConsent.Record.none.isGranted)
    }

    func testAStaleOrMissingVersionAsks() {
        // A future provider change bumps the version: yesterday's OK stops counting.
        XCTAssertFalse(AIConsent.isGranted(at: "2026-01-01T00:00:00.000Z", version: "2026-01-01"))
        XCTAssertFalse(AIConsent.isGranted(at: "2026-09-24T10:00:00.000Z", version: nil))
        XCTAssertFalse(AIConsent.isGranted(at: "2026-09-24T10:00:00.000Z", version: "2026-09-25"))
    }

    func testGrantWritesNowInTheWebsIsoShapeAndTheCurrentVersion() {
        let r = AIConsent.grant(at: Date(timeIntervalSince1970: 1_790_000_000.25))
        XCTAssertEqual(r.at, "2026-09-21T14:13:20.250Z")
        XCTAssertEqual(r.version, AIConsent.version)
        XCTAssertTrue(r.isGranted)
    }

    func testTurningItOffClearsTheTimeOnly() {
        let granted = AIConsent.grant(at: Date(timeIntervalSince1970: 1_790_000_000))
        let off = AIConsent.revoked(granted)
        XCTAssertNil(off.at)
        XCTAssertEqual(off.version, AIConsent.version)
        XCTAssertFalse(off.isGranted)
    }

    // MARK: "Not now"

    func testNotNowOnTheAssistantSendsNothingAndLeavesCallsAlone() {
        for action in [AIConsent.Action.chat, .talk] {
            let d = AIConsent.decline(action)
            XCTAssertFalse(d.turnCallsOff, "\(action)")
            XCTAssertTrue(d.note.contains("Nothing was sent"), "\(action)")
            XCTAssertTrue(d.note.contains("needs your OK"), "\(action)")
        }
    }

    func testNotNowWhenSwitchingCallsOnKeepsThemOff() {
        let d = AIConsent.decline(.callsOn)
        XCTAssertFalse(d.turnCallsOff, "nothing to turn off — the switch just doesn't move")
        XCTAssertTrue(d.note.contains("stay off"))
    }

    func testNotNowOnAppOpenWithCallsOnTurnsThemOffAndSaysSo() {
        let d = AIConsent.decline(.callsOnOpen)
        XCTAssertTrue(d.turnCallsOff)
        XCTAssertEqual(d.note, AIConsent.callsTurnedOffNote)
        XCTAssertTrue(d.note.contains("Settings › Calls"))
    }

    func testEveryActionHasAShortLine() {
        for action in AIConsent.Action.allCases {
            let note = AIConsent.decline(action).note
            XCTAssertFalse(note.isEmpty, "\(action)")
            XCTAssertLessThan(note.count, 120, "\(action): keep it short")
        }
    }

    // MARK: app open

    func testCallsAreOnOnlyWhenThisPhoneTakesThemAndSomethingCanRing() {
        XCTAssertTrue(AIConsent.callsAreOn(deviceSwitch: true, proactiveOn: true, hasLiveCall: false))
        XCTAssertTrue(AIConsent.callsAreOn(deviceSwitch: true, proactiveOn: false, hasLiveCall: true))
        // The switch is on by default — alone it rings nothing.
        XCTAssertFalse(AIConsent.callsAreOn(deviceSwitch: true, proactiveOn: false, hasLiveCall: false))
        // Off here: every call is declined anyway.
        XCTAssertFalse(AIConsent.callsAreOn(deviceSwitch: false, proactiveOn: true, hasLiveCall: true))
    }

    func testAppOpenAsksOnceWhenCallsAreOnWithoutConsent() {
        XCTAssertTrue(AIConsent.asksOnOpen(granted: false, callsOn: true, askedThisLaunch: false))
        XCTAssertFalse(AIConsent.asksOnOpen(granted: false, callsOn: true, askedThisLaunch: true), "once")
        XCTAssertFalse(AIConsent.asksOnOpen(granted: true, callsOn: true, askedThisLaunch: false))
        XCTAssertFalse(AIConsent.asksOnOpen(granted: false, callsOn: false, askedThisLaunch: false),
                       "nothing can ring — the first real use asks instead")
    }

    // MARK: the device copy

    private let granted = AIConsent.Record(at: "2026-09-24T10:00:00.000Z", version: AIConsent.version)

    func testTheAccountsAnswerFillsAnEmptyCopy() {
        let c = AIConsent.merge(cache: nil, server: granted, userId: "u1", source: .stored)
        XCTAssertEqual(c, AIConsent.Cache(userId: "u1", record: granted, pending: false))
        let fresh = AIConsent.merge(cache: nil, server: .none, userId: "u1", source: .fresh)
        XCTAssertFalse(fresh.record.isGranted)
    }

    func testAFreshAnswerReplacesTheCopy() {
        // Turned off on the web: the next /user read turns it off here too.
        let mine = AIConsent.Cache(userId: "u1", record: granted, pending: false)
        let c = AIConsent.merge(cache: mine, server: AIConsent.revoked(granted), userId: "u1", source: .fresh)
        XCTAssertFalse(c.record.isGranted)
        XCTAssertFalse(c.pending)
    }

    func testASavedSessionNeverOverridesTheCopy() {
        // The session saved at launch predates an OK read fresh last time.
        let mine = AIConsent.Cache(userId: "u1", record: granted, pending: false)
        XCTAssertEqual(AIConsent.merge(cache: mine, server: .none, userId: "u1", source: .stored), mine)
    }

    func testAChangeStillOnItsWayWins() {
        // Agreed offline: the account's older "no" must not undo it.
        let mine = AIConsent.Cache(userId: "u1", record: granted, pending: true)
        XCTAssertEqual(AIConsent.merge(cache: mine, server: .none, userId: "u1", source: .fresh), mine)
        // …and turned off offline: an older "yes" must not bring it back.
        let off = AIConsent.Cache(userId: "u1", record: AIConsent.revoked(granted), pending: true)
        XCTAssertEqual(AIConsent.merge(cache: off, server: granted, userId: "u1", source: .fresh), off)
    }

    func testAnotherAccountsCopyIsReplaced() {
        let theirs = AIConsent.Cache(userId: "u0", record: granted, pending: true)
        let c = AIConsent.merge(cache: theirs, server: .none, userId: "u1", source: .stored)
        XCTAssertEqual(c, AIConsent.Cache(userId: "u1", record: .none, pending: false))
    }

    func testTheCopyAnswersOnlyForItsAccount() {
        let mine = AIConsent.Cache(userId: "u1", record: granted, pending: false)
        XCTAssertTrue(AIConsent.isGranted(mine, userId: "u1"))
        XCTAssertFalse(AIConsent.isGranted(mine, userId: "u2"))
        XCTAssertTrue(AIConsent.isGranted(mine, userId: nil), "a call ringing before the app is up trusts it")
        XCTAssertFalse(AIConsent.isGranted(nil, userId: "u1"))
        XCTAssertFalse(AIConsent.isGranted(nil, userId: nil))
        let stale = AIConsent.Cache(userId: "u1", record: .init(at: "2026-01-01T00:00:00Z", version: "2026-01-01"), pending: false)
        XCTAssertFalse(AIConsent.isGranted(stale, userId: "u1"))
    }

    func testTheCopyRoundTrips() {
        let c = AIConsent.Cache(userId: "u1", record: granted, pending: true)
        XCTAssertEqual(AIConsent.decode(AIConsent.encode(c)), c)
        XCTAssertNil(AIConsent.decode(nil))
        XCTAssertNil(AIConsent.decode(Data("nope".utf8)))
    }
}
