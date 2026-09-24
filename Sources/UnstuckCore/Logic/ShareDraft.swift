// Share-at-creation (New task → "Share with…", Ahmad 2026-09-24: "One row +
// picker"). The New task sheet shows ONE row — "Share with…" + a one-line
// summary + chevron — and the row opens the SAME Share screen used for an
// existing task, in pre-create mode. The task does not exist yet, so every
// pick is held HERE, locally; the sheet fires the real share RPCs on submit,
// after the task row lands (a failed share never blocks creation).
//
//   • ShareDraft           — the local picks: connections (task_share by id)
//                            and typed addresses (share-task add by email),
//                            each at a grade, in pick order.
//   • shareDraftSummary    — the row's trailing text ("Only you",
//                            "James · can edit", "James · edit, Anna · view",
//                            "James + 3 more") + its spoken form.
//   • shareDraftResultLine — the Share screen's honest line in pre-create
//                            mode ("Maya will get it when you add the task…"),
//                            never "Shared with…" for a task that isn't there.
//
// Pure + Sendable, unit-tested in ShareDraftTests.

import Foundation

/// One pick on a task that doesn't exist yet.
public struct ShareDraftPick: Equatable, Sendable, Identifiable {
    public enum Recipient: Equatable, Sendable {
        /// A connection — shared with `task_share(p_user)` on submit.
        case user(id: String)
        /// A typed address — shared with `share-task add {email}` on submit
        /// (an existing account gets it at once, anyone else an invite).
        case email(String)
    }

    public let recipient: Recipient
    /// The display name (a connection's name; the address for an email).
    public var name: String
    public var access: ShareAccess

    public init(recipient: Recipient, name: String, access: ShareAccess) {
        self.recipient = recipient
        self.name = name
        self.access = access
    }

    /// Stable across grade changes: "user:<id>" / "email:<address>".
    public var id: String {
        switch recipient {
        case .user(let id): return Self.id(forUser: id)
        case .email(let e): return "email:\(e)"
        }
    }

    /// The `id` a connection's pick has.
    public static func id(forUser userId: String) -> String { "user:\(userId)" }
}

/// A `task_share(p_task_id, p_user, p_level)` call to make on submit.
public struct ShareDraftUserShare: Equatable, Sendable {
    public let userId: String
    public let level: ShareLevel
    public init(userId: String, level: ShareLevel) {
        self.userId = userId
        self.level = level
    }
}

/// A `share-task add {taskId, email, level}` call to make on submit.
public struct ShareDraftEmailShare: Equatable, Sendable {
    public let email: String
    public let level: ShareLevel
    public init(email: String, level: ShareLevel) {
        self.email = email
        self.level = level
    }
}

/// The New task sheet's local share selection. Grades are the Share screen's
/// two — Can edit / Can view (the inline section offered Off / Can edit /
/// Can view; "Hand over to…" stays a post-creation action).
public struct ShareDraft: Equatable, Sendable {
    /// Pick order (the summary names people in the order they were picked).
    public private(set) var picks: [ShareDraftPick]

    public init(picks: [ShareDraftPick] = []) { self.picks = picks }

    public var isEmpty: Bool { picks.isEmpty }

    /// Connections picked, pick order.
    public var people: [ShareDraftPick] {
        picks.filter { if case .user = $0.recipient { return true } else { return false } }
    }

    /// Typed addresses picked, pick order.
    public var emails: [ShareDraftPick] {
        picks.filter { if case .email = $0.recipient { return true } else { return false } }
    }

    /// Pick a connection at a grade, or change the grade of one already
    /// picked (their place in the order is kept). A blank id is ignored. A
    /// connection with no display name is "Someone" — what the Share screen's
    /// row calls them — never a blank (the row would read "them · can edit"
    /// beside an empty monogram).
    public mutating func pick(userId: String, name: String, access: ShareAccess) {
        guard !userId.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pick = ShareDraftPick(recipient: .user(id: userId), name: trimmed.isEmpty ? shareDraftUnnamed : trimmed,
                                  access: access)
        if let i = picks.firstIndex(where: { $0.id == pick.id }) {
            picks[i].access = access
            if !trimmed.isEmpty { picks[i].name = trimmed }
        } else {
            picks.append(pick)
        }
    }

    /// Add a typed address at a grade (normalised as the server does: trimmed,
    /// lower-cased). Re-adding the same address changes its grade. Returns
    /// false — and changes nothing — when it doesn't look like an address.
    @discardableResult
    public mutating func addEmail(_ raw: String, access: ShareAccess) -> Bool {
        let email = normalizedShareEmail(raw)
        guard isEmailLike(email) else { return false }
        let pick = ShareDraftPick(recipient: .email(email), name: email, access: access)
        if let i = picks.firstIndex(where: { $0.id == pick.id }) {
            picks[i].access = access
        } else {
            picks.append(pick)
        }
        return true
    }

    /// Change a pick's grade by its `id`. Unknown ids are ignored.
    public mutating func setAccess(id: String, _ access: ShareAccess) {
        guard let i = picks.firstIndex(where: { $0.id == id }) else { return }
        picks[i].access = access
    }

    /// Drop a pick by its `id`. Returns whether anything was removed.
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = picks.count
        picks.removeAll { $0.id == id }
        return picks.count != before
    }

    /// The pick for a connection, if they are picked.
    public func pick(forUser userId: String) -> ShareDraftPick? {
        picks.first { $0.recipient == .user(id: userId) }
    }

    // MARK: submit mapping

    /// The `task_share` calls submit makes, pick order — the grade maps
    /// exactly as the Share screen's (Can edit → partner, Can view → view).
    public var userShares: [ShareDraftUserShare] {
        picks.compactMap { p in
            guard case .user(let id) = p.recipient else { return nil }
            return ShareDraftUserShare(userId: id, level: p.access.taskLevel)
        }
    }

    /// The `share-task add` calls submit makes, pick order.
    public var emailShares: [ShareDraftEmailShare] {
        picks.compactMap { p in
            guard case .email(let e) = p.recipient else { return nil }
            return ShareDraftEmailShare(email: e, level: p.access.taskLevel)
        }
    }
}

// MARK: - the row's summary

/// What the "Share with…" row shows (`text`, one line) and what VoiceOver
/// reads as the row's value (`spoken`, never truncated).
public struct ShareDraftSummary: Equatable, Sendable {
    public let text: String
    public let spoken: String
    public init(text: String, spoken: String) {
        self.text = text
        self.spoken = spoken
    }
}

/// The row's budget in characters: what fits beside "Share with…" and the
/// chevron on the narrowest supported phone at the default text size. The
/// view still truncates as a last resort, so this only decides the FORM.
public let shareDraftSummaryMaxLength = 28

/// THE SUMMARY RULE.
///  • nothing picked       → "Only you"
///  • one grade for all    → "James · can edit", "James, Anna · can edit"
///  • grades differ        → "James · edit, Anna · view"
///  • longer than `maxLength` → "James + 3 more" (the first pick named)
///  • one pick whose name alone is too long → the name is cut with "…"
/// Names are first names ("James" from "James Wilson"; the local part of an
/// address); two picks that would read the same keep their full names.
public func shareDraftSummary(_ picks: [ShareDraftPick],
                              maxLength: Int = shareDraftSummaryMaxLength) -> ShareDraftSummary {
    guard !picks.isEmpty else { return ShareDraftSummary(text: "Only you", spoken: "Only you") }
    let names = shareDraftNames(picks)
    let grades = picks.map(\.access)
    let uniform = Set(grades).count == 1

    let full: String
    if uniform {
        full = "\(names.joined(separator: ", ")) · can \(grades[0].verb)"
    } else {
        full = zip(names, grades).map { "\($0) · \($1.verb)" }.joined(separator: ", ")
    }

    let text: String
    if full.count <= maxLength {
        text = full
    } else if picks.count == 1 {
        let suffix = " · can \(grades[0].verb)"
        text = shareDraftTruncate(names[0], to: maxLength - suffix.count) + suffix
    } else {
        let suffix = " + \(picks.count - 1) more"
        text = shareDraftTruncate(names[0], to: maxLength - suffix.count) + suffix
    }

    let spoken: String
    if uniform {
        spoken = "\(shareDraftList(names)) can \(grades[0].verb)"
    } else {
        spoken = zip(names, grades).map { "\($0) can \($1.verb)" }.joined(separator: ", ")
    }
    return ShareDraftSummary(text: text, spoken: spoken)
}

/// The name of a pick that has none (the Share screen's own fallback).
public let shareDraftUnnamed = "Someone"

/// First names, except where two picks would read the same — those keep
/// their full name so "Maya, Maya" never happens. A blank name reads
/// "Someone", never `shareShortName`'s "them".
private func shareDraftNames(_ picks: [ShareDraftPick]) -> [String] {
    let short = picks.map { p in
        p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? shareDraftUnnamed : shareShortName(p.name)
    }
    var counts: [String: Int] = [:]
    for s in short { counts[s.lowercased(), default: 0] += 1 }
    return zip(picks, short).map { p, s in
        guard counts[s.lowercased(), default: 0] > 1 else { return s }
        let full = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? s : full
    }
}

/// "Maya", "Maya and Zubair", "Maya, Zubair and Sam".
private func shareDraftList(_ names: [String]) -> String {
    guard names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
}

/// Cut to `limit` characters (grapheme clusters), ending in "…". Never below
/// one character + the ellipsis.
private func shareDraftTruncate(_ s: String, to limit: Int) -> String {
    guard s.count > limit else { return s }
    let keep = max(1, limit - 1)
    return String(s.prefix(keep)).trimmingCharacters(in: .whitespaces) + "…"
}

// MARK: - the Share screen's line in pre-create mode

/// The honest line under the Share screen's controls when the task does not
/// exist yet: nothing has been shared, so it says what WILL happen on "Add
/// task". Outcomes that don't arise before creation fall back to
/// `shareResultLine`.
public func shareDraftResultLine(_ r: ShareResult) -> String {
    switch r {
    case .shared(let name, let access):
        return "\(shareShortName(name)) will get it when you add the task — they can \(access.verb)."
    case .invited(let email), .accepted(let email):
        return "\(email) will get it when you add the task."
    case .accessChanged(let name, let access):
        return "\(shareShortName(name)) will be able to \(access.verb)."
    case .removed(let name):
        return "\(shareShortName(name)) won't get it."
    case .inviteCancelled(let email):
        return "\(email) won't get it."
    case .linkCopied:
        return "Invite link copied — whoever opens it is connected to you, then you can pick them here."
    case .handedOver, .blocked:
        return shareResultLine(r)
    }
}
