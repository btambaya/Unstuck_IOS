// AI data-sharing consent (App Store guideline 5.1.2(i)): before anything the
// user types or says reaches a third-party AI, the app says so plainly and
// asks. Until now only small print in the assistant's memory screens
// mentioned "our AI provider".
//
// The contract is shared with the web, word for word:
//
//   • the OK lives in Supabase auth user_metadata
//       { ai_consent_at: <ISO timestamp>, ai_consent_version: "2026-09-24" }
//     (auth.updateUser({ data })), so it follows the account to every device.
//     Each device keeps a copy so the gate answers offline and a ringing call
//     can be judged before the app is up;
//   • it counts only while ai_consent_version == `version` — a new AI
//     provider bumps it and every surface asks again;
//   • it is asked for once: before the FIRST assistant use of any kind (a
//     message, Talk) and before Calls are switched on — and on app open when
//     Calls are already on without it, where "Not now" turns Calls off;
//   • "Not now" blocks nothing else: that one action doesn't happen and a
//     short line says why;
//   • Settings shows it and can turn it off (clears ai_consent_at and turns
//     Calls off) or back on (the same sheet).
//
// No server-side enforcement yet — older builds must keep working.
//
// This file is the pure part: the copy, which records count, what "Not now"
// does, when app open asks, and how the device copy follows the account. The
// app wires it through AppModel (the one gate), AssistantSheet.swift (the
// sheet) and the call path (a call without consent never connects).

import Foundation

public enum AIConsent {
    /// Bump when the provider (or what is sent) changes: every OK given under
    /// an older version stops counting and the sheet shows again.
    public static let version = "2026-09-24"
    /// The user_metadata keys.
    public static let atKey = "ai_consent_at"
    public static let versionKey = "ai_consent_version"

    // MARK: copy — exactly what the web shows

    public static let title = "Your assistant uses OpenAI"
    public static let body = "To answer you, Unstuck sends what you type or say to the assistant — including your voice in Talk and calls — with the tasks, calendar and notes it needs, to OpenAI, our AI provider. OpenAI uses it to reply and doesn't train its models on it. You can turn this off any time in Settings."
    public static let privacyLinkLabel = "Privacy policy"
    /// Section 9 of the published policy, "The AI Assistant".
    public static let privacyURL = URL(string: "https://unstucknow.io/privacy#s9")!
    public static let agreeLabel = "Agree and continue"
    public static let declineLabel = "Not now"

    // MARK: the record

    /// The OK as user_metadata carries it. Both nil = never given (or
    /// turned off, which clears `at`).
    public struct Record: Codable, Equatable, Sendable {
        public var at: String?
        public var version: String?

        public init(at: String? = nil, version: String? = nil) {
            self.at = at
            self.version = version
        }

        public static let none = Record()

        public var isGranted: Bool { AIConsent.isGranted(at: at, version: version) }
    }

    /// An OK counts when it has a time and was given for THIS version.
    public static func isGranted(at: String?, version: String?) -> Bool {
        guard let at, !at.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return version == Self.version
    }

    /// What "Agree and continue" writes: now, in the web's toISOString shape.
    public static func grant(at now: Date) -> Record {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Record(at: f.string(from: now), version: version)
    }

    /// What turning it off leaves: `at` cleared (the server deletes the key);
    /// the version stays, and on its own it means nothing.
    public static func revoked(_ record: Record) -> Record {
        Record(at: nil, version: record.version)
    }

    // MARK: the gate

    /// What the user was doing when the gate stopped them.
    public enum Action: String, Sendable, Equatable, CaseIterable {
        /// A typed or dictated message, a suggestion chip.
        case chat
        /// Starting Talk (realtime voice).
        case talk
        /// Switching Calls or a proactive call on, booking a call, a test call.
        case callsOn
        /// App open with Calls already on and no OK.
        case callsOnOpen
        /// Settings → AI data sharing → on.
        case settings
    }

    /// What "Not now" does: the action never happens, and this line says why.
    public struct Decline: Equatable, Sendable {
        public let turnCallsOff: Bool
        public let note: String
    }

    public static func decline(_ action: Action) -> Decline {
        switch action {
        case .chat, .talk:
            return Decline(turnCallsOff: false,
                           note: "Nothing was sent. The assistant needs your OK before it can answer.")
        case .callsOn:
            return Decline(turnCallsOff: false,
                           note: "Calls use the assistant, so they stay off until you agree.")
        case .callsOnOpen:
            return Decline(turnCallsOff: true, note: callsTurnedOffNote)
        case .settings:
            return Decline(turnCallsOff: false,
                           note: "Still off. The assistant will ask before it's used.")
        }
    }

    /// App open, "Not now": Calls were on, and now they're off.
    public static let callsTurnedOffTitle = "Calls are off"
    public static let callsTurnedOffNote = "Calls use the assistant, so they're off for now. You can switch them back on in Settings › Calls."

    /// Settings → AI data sharing → off. Calls go off with it.
    public static let revokedNote = "Calls are off too. The assistant will ask again before it's used."

    /// Calls count as ON for this account when this phone takes them and
    /// something can ring: a proactive call switched on, or a call booked.
    /// The phone's switch alone is on by default, so it isn't enough.
    public static func callsAreOn(deviceSwitch: Bool, proactiveOn: Bool, hasLiveCall: Bool) -> Bool {
        deviceSwitch && (proactiveOn || hasLiveCall)
    }

    /// App open: ask once per launch, only when Calls are on without an OK.
    public static func asksOnOpen(granted: Bool, callsOn: Bool, askedThisLaunch: Bool) -> Bool {
        !granted && callsOn && !askedThisLaunch
    }

    // MARK: the device copy

    /// This device's copy of the account's OK. `pending` = a change made here
    /// that hasn't reached user_metadata yet: it is sent again on the next
    /// open instead of letting the account's older answer win.
    public struct Cache: Codable, Equatable, Sendable {
        public var userId: String
        public var record: Record
        public var pending: Bool

        public init(userId: String, record: Record, pending: Bool) {
            self.userId = userId
            self.record = record
            self.pending = pending
        }
    }

    /// Where the account's answer came from.
    public enum Source: Sendable, Equatable {
        /// Straight from the server: a /user read, a sign-in, a token
        /// refresh, our own update.
        case fresh
        /// The session saved on this device at launch — it can predate a
        /// change made on the web since.
        case stored
    }

    /// The device copy after the account's answer lands. A change made here
    /// that is still on its way wins; so does the copy we have over a saved
    /// session's older view of the same account. Anything else follows the
    /// account.
    public static func merge(cache: Cache?, server: Record, userId: String, source: Source) -> Cache {
        if let cache, cache.userId == userId {
            if cache.pending || source == .stored { return cache }
        }
        return Cache(userId: userId, record: server, pending: false)
    }

    /// Does the device copy say yes for this account? `userId` nil = not known
    /// yet (a call ringing before the app is up) — then the copy is trusted;
    /// sign-out wipes it, so it can only be the last account's.
    public static func isGranted(_ cache: Cache?, userId: String?) -> Bool {
        guard let cache else { return false }
        if let userId, cache.userId != userId { return false }
        return cache.record.isGranted
    }

    public static func encode(_ cache: Cache) -> Data? { try? JSONEncoder().encode(cache) }

    public static func decode(_ data: Data?) -> Cache? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }
}
