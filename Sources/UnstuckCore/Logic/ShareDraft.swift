// Share-at-creation (New task → "Share with…", Ahmad 2026-09-24: "One row +
// picker"). The New task sheet shows ONE row — "Share with…" + a one-line
// summary + chevron — and the row opens the SAME Share screen used for an
// existing task, in pre-create mode. The task does not exist yet, so every
// pick is held HERE, locally; the sheet fires the real share RPCs on submit,
// after the task row lands (a failed share never blocks creation).
//
//   • ShareDraft           — the local picks: connections (task_share by id)
//                            and typed addresses (share-task add by email),
//                            each at a level, in pick order.
//   • shareDraftSummary    — the row's trailing text ("Only you",
//                            "James · can edit", "James · edit, Anna · view",
//                            "James + 3 more · can edit") + its spoken form;
//                            connections first, then held addresses.
//   • shareDraftResultLine — the Share screen's confirmation line in
//                            pre-create mode ("Maya can edit once you add the
//                            task."), never "Shared with…" for a task that
//                            isn't there.
//
// ONE behaviour on iOS, Android and web (decided 2026-09-24 after the three
// were compared side by side): the grades are Can edit / Can view / Hand over
// (the same `partner` / `view` / `assign` levels the others send), a typed
// address is held until the task is added, and the summary follows the rule
// on `shareDraftSummary` verbatim — ShareDraftTests carries the shared cases.
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
    /// The `task_share.p_level` submit sends: `partner` (Can edit), `view`
    /// (Can view) or `assign` (Hand over — connections only).
    public var level: ShareLevel

    public init(recipient: Recipient, name: String, level: ShareLevel) {
        self.recipient = recipient
        self.name = name
        // A hand-over is never an email grade (the server has no one to hand
        // it to until they sign up) — held as Can edit, as on web.
        if case .email = recipient, level == .assign { self.level = .partner } else { self.level = level }
    }

    public init(recipient: Recipient, name: String, access: ShareAccess) {
        self.init(recipient: recipient, name: name, level: access.taskLevel)
    }

    /// Can edit / Can view; nil when handed over.
    public var access: ShareAccess? { ShareAccess(taskLevel: level) }
    public var handedOver: Bool { level == .assign }

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

/// The New task sheet's local share selection. A picked person's grade is
/// Can edit / Can view / Hand over (the menu on their row); a typed address
/// is Can edit / Can view. No limit on hand-overs — the server has none, and
/// neither do web and Android.
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

    /// Pick a connection at a level, or change the level of one already
    /// picked (their place in the order is kept). A blank id is ignored. A
    /// connection with no display name is "Someone" — what the Share screen's
    /// row calls them — never a blank (the row would read "them · can edit"
    /// beside an empty monogram).
    public mutating func pick(userId: String, name: String, level: ShareLevel) {
        guard !userId.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pick = ShareDraftPick(recipient: .user(id: userId), name: trimmed.isEmpty ? shareDraftUnnamed : trimmed,
                                  level: level)
        if let i = picks.firstIndex(where: { $0.id == pick.id }) {
            picks[i].level = level
            if !trimmed.isEmpty { picks[i].name = trimmed }
        } else {
            picks.append(pick)
        }
    }

    public mutating func pick(userId: String, name: String, access: ShareAccess) {
        pick(userId: userId, name: name, level: access.taskLevel)
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
            picks[i].level = pick.level
        } else {
            picks.append(pick)
        }
        return true
    }

    /// Change a pick's level by its `id` (an address can't be handed over —
    /// it stays Can edit). Unknown ids are ignored.
    public mutating func setLevel(id: String, _ level: ShareLevel) {
        guard let i = picks.firstIndex(where: { $0.id == id }) else { return }
        picks[i] = ShareDraftPick(recipient: picks[i].recipient, name: picks[i].name, level: level)
    }

    public mutating func setAccess(id: String, _ access: ShareAccess) { setLevel(id: id, access.taskLevel) }

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

    /// The `task_share` calls submit makes, pick order — Can edit → partner,
    /// Can view → view, Hand over → assign (what web and Android send).
    public var userShares: [ShareDraftUserShare] {
        picks.compactMap { p in
            guard case .user(let id) = p.recipient else { return nil }
            return ShareDraftUserShare(userId: id, level: p.level)
        }
    }

    /// The `share-task add` calls submit makes, pick order (never `assign`).
    public var emailShares: [ShareDraftEmailShare] {
        picks.compactMap { p in
            guard case .email(let e) = p.recipient else { return nil }
            return ShareDraftEmailShare(email: e, level: p.level == .assign ? .partner : p.level)
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

/// The row's budget in characters — the same 28 on iOS, Android and web. The
/// row tries this first and only asks for a tighter budget when the line
/// really doesn't fit (the grade still shows: names are what gets cut).
public let shareDraftSummaryMaxLength = 28

/// THE SUMMARY RULE (one rule on all three apps; the FORM is decided by the
/// number of picks, never by the length). ORDER: connections first, in pick
/// order, then held addresses, in pick order (`shareDraftSummaryOrder`):
///  • 0         → "Only you"
///  • 1         → "James · can edit" | "· can view" | "· handed over"
///  • 2, same   → "James, Anna · can edit"
///  • 2, mixed  → "James · edit, Anna · view" (or "· handed over")
///  • 3+        → "James + 2 more", plus " · can edit" / " · can view" /
///                " · handed over" ONLY when everyone has the same grade
///  • longer than `maxLength` → the NAMES are cut with "…" (never the grade):
///    each name is capped at the largest length that fits, so a short name
///    stays whole and a long one gives way; never below one letter + "…".
/// Names are first names ("James" from "James Wilson"; the part of an address
/// before the @); a blank name is "Someone". Two or more names that must be
/// cut share ONE common cap (not a half split each). The spoken form follows
/// the same order.
public func shareDraftSummary(_ picked: [ShareDraftPick],
                              maxLength: Int = shareDraftSummaryMaxLength) -> ShareDraftSummary {
    let picks = shareDraftSummaryOrder(picked)
    guard let first = picks.first else { return ShareDraftSummary(text: "Only you", spoken: "Only you") }
    let names = picks.map { shareDraftName($0.name) }
    let uniform = picks.allSatisfy { $0.level == first.level }

    let text: String
    switch picks.count {
    case 1:
        text = shareDraftFit(names, maxLength) { "\($0[0]) · \(shareDraftGradePhrase(first.level))" }
    case 2 where uniform:
        text = shareDraftFit(names, maxLength) { "\($0[0]), \($0[1]) · \(shareDraftGradePhrase(first.level))" }
    case 2:
        text = shareDraftFit(names, maxLength) {
            "\($0[0]) · \(shareDraftGradeWord(picks[0].level)), \($0[1]) · \(shareDraftGradeWord(picks[1].level))"
        }
    default:
        let tail = " + \(picks.count - 1) more" + (uniform ? " · \(shareDraftGradePhrase(first.level))" : "")
        text = shareDraftFit([names[0]], maxLength) { $0[0] + tail }
    }

    let spoken: String
    if uniform {
        spoken = first.level == .assign ? "handed over to \(shareDraftList(names))"
                                        : "\(shareDraftList(names)) can \(first.access?.verb ?? "edit")"
    } else {
        spoken = zip(names, picks).map { name, p in
            p.level == .assign ? "handed over to \(name)" : "\(name) can \(p.access?.verb ?? "edit")"
        }.joined(separator: ", ")
    }
    return ShareDraftSummary(text: text, spoken: spoken)
}

/// The order the summary (and the row's monograms) name picks in:
/// connections first, in pick order, then held addresses, in pick order — on
/// iOS, Android and web alike. Stable: already-ordered input is unchanged.
public func shareDraftSummaryOrder(_ picks: [ShareDraftPick]) -> [ShareDraftPick] {
    func isAddress(_ p: ShareDraftPick) -> Bool { if case .email = p.recipient { return true } else { return false } }
    return picks.filter { !isAddress($0) } + picks.filter(isAddress)
}

/// "can edit" / "can view" / "handed over" — the one grade everyone has.
func shareDraftGradePhrase(_ level: ShareLevel) -> String {
    switch level {
    case .partner: return "can edit"
    case .view: return "can view"
    case .assign: return "handed over"
    }
}

/// "edit" / "view" / "handed over" — each person's grade when they differ.
func shareDraftGradeWord(_ level: ShareLevel) -> String {
    switch level {
    case .partner: return "edit"
    case .view: return "view"
    case .assign: return "handed over"
    }
}

/// The name of a pick that has none (the Share screen's own fallback).
public let shareDraftUnnamed = "Someone"

/// A pick's name in the summary: the first name, the part of an address
/// before the @, "Someone" when blank (never `shareShortName`'s "them").
private func shareDraftName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? shareDraftUnnamed : shareShortName(raw)
}

/// `render(names)` when it fits in `budget`; otherwise the names are capped
/// (water-filling: the largest cap whose total fits the room the fixed text
/// leaves) and cut with "…" — the fixed text, the grade included, is never cut.
private func shareDraftFit(_ names: [String], _ budget: Int, _ render: ([String]) -> String) -> String {
    let full = render(names)
    guard full.count > budget else { return full }
    let room = budget - render(names.map { _ in "" }).count
    let floor = 2   // one letter + "…"
    var cap = names.map(\.count).max() ?? floor
    while cap > floor, names.reduce(0, { $0 + min($1.count, cap) }) > room { cap -= 1 }
    return render(names.map { shareDraftTruncate($0, to: cap) })
}

/// "Maya", "Maya and Zubair", "Maya, Zubair and Sam".
private func shareDraftList(_ names: [String]) -> String {
    guard names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
}

/// Cut to `limit` characters (grapheme clusters) including the closing "…".
/// Never below one character + the ellipsis.
private func shareDraftTruncate(_ s: String, to limit: Int) -> String {
    guard s.count > limit else { return s }
    let keep = max(1, limit - 1)
    return String(s.prefix(keep)).trimmingCharacters(in: .whitespaces) + "…"
}

// MARK: - the Share screen's line in pre-create mode

/// The confirmation line under the Share screen's controls when the task does
/// not exist yet: nothing has been shared, so it says what WILL happen on
/// "Add task". The SAME strings on iOS, Android and web (decided 2026-09-24):
///  • pick / grade change → "<Name> can edit once you add the task."
///                          "<Name> can view once you add the task."
///  • hand over           → "<Name> gets it as their task once you add it — you keep view."
///  • add an address      → "<address> gets it once you add the task."
///  • remove              → "<Name> won't get this task."
/// <Name> is the short name (the first name; for an address, the part before
/// the @). Outcomes that don't arise before creation fall back to
/// `shareResultLine`.
public func shareDraftResultLine(_ r: ShareResult) -> String {
    switch r {
    case .shared(let name, let access), .accessChanged(let name, let access):
        return "\(shareShortName(name)) can \(access.verb) once you add the task."
    case .invited(let email), .accepted(let email):
        return "\(email) gets it once you add the task."
    case .handedOver(let name):
        return "\(shareShortName(name)) gets it as their task once you add it — you keep view."
    case .removed(let name):
        return "\(shareShortName(name)) won't get this task."
    case .inviteCancelled(let email):
        return "\(shareShortName(email)) won't get this task."
    case .linkCopied:
        return "Invite link copied — whoever opens it is connected to you, then you can pick them here."
    case .blocked:
        return shareResultLine(r)
    }
}
