// Unified sharing v1 (docs/unified-sharing-spec.md §2 / §4) — the ONE
// vocabulary and the pure pieces behind the single Share screen:
//
//   • ShareAccess — "Can edit" / "Can view", mapped onto the two backends
//     (tasks: partner / view; collections: editor / viewer). "Assign" is no
//     longer a share level in the UI: it is the task action "Hand over to…".
//   • composeSharePeople — the People section (everyone you are connected
//     to, each annotated with what they already have on this item).
//   • shareResultLine — the honest line under the button ("Shared with Maya
//     — they can edit." vs "Invite sent to x@y — waiting for them to sign
//     up." vs "Link copied — …").
//   • ShareFailure — the server's reason codes → what the user reads.
//   • pendingInviteLabel / composePeopleSections — Settings → People's
//     "Waiting to join" list (§2 "One place for people"): every email invite
//     I sent, whichever screen sent it, each shown once.
//
// Pure + Sendable so the screen model, the assistant's confirm card and the
// unit tests share one source of truth for copy and mapping.

import Foundation

/// The single user-facing access grade. Default is `.edit`.
public enum ShareAccess: String, Codable, Sendable, CaseIterable, Equatable {
    case edit
    case view

    /// The segmented-control / menu label.
    public var label: String {
        switch self {
        case .edit: return "Can edit"
        case .view: return "Can view"
        }
    }

    /// The short verb phrase used in result lines ("they can edit").
    public var verb: String {
        switch self {
        case .edit: return "edit"
        case .view: return "view"
        }
    }

    /// What it means, in one line (the explainer under the control). Task
    /// wording; `blurb(for:)` is the kind-aware one.
    public var blurb: String { blurb(for: .task) }

    /// What the grade means for THIS kind of item. A list is never "started"
    /// or "focused", so the task wording read as nonsense on a list's Share
    /// screen ("They can start, complete and focus on it with you." under
    /// "Lisbon trip").
    public func blurb(for kind: ShareItemKind) -> String {
        switch (kind, self) {
        case (.task, .edit): return "They can start, complete and focus on it with you."
        case (.task, .view): return "They see it and hear when you start and finish."
        case (.collection, .edit): return "They can add, tick off and edit everything on the list."
        case (.collection, .view): return "They can see the list and everything on it."
        }
    }

    /// The task-share capability grade this maps to (`task_share.p_level`).
    public var taskLevel: ShareLevel {
        switch self {
        case .edit: return .partner
        case .view: return .view
        }
    }

    /// The collection role this maps to (`share-collection.role`).
    public var collectionRole: String {
        switch self {
        case .edit: return "editor"
        case .view: return "viewer"
        }
    }

    /// Reverse mapping from a task share level. `assign` is not an access
    /// grade (it is "handed over") → nil.
    public init?(taskLevel: ShareLevel) {
        switch taskLevel {
        case .partner: self = .edit
        case .view: self = .view
        case .assign: return nil
        }
    }

    /// Reverse mapping from a collection role. Anything but "viewer" is edit
    /// (the server itself coerces unknown roles to editor).
    public init(collectionRole: String) {
        self = collectionRole == "viewer" ? .view : .edit
    }
}

/// What is being shared. Drives the vocabulary ("task" / "list") and which
/// backend the screen talks to.
public enum ShareItemKind: String, Sendable, Equatable {
    case task
    case collection

    /// The noun in copy ("this task" / "this list").
    public var noun: String {
        switch self {
        case .task: return "task"
        case .collection: return "list"
        }
    }
}

/// A grant that already exists on the item (a task share / a collection
/// member) — the input the People composition annotates the roster with.
public struct ShareExistingGrant: Equatable, Sendable {
    public let userId: String
    /// A display name when the roster doesn't know this person (a legacy
    /// collection member who never became a connection).
    public let name: String?
    /// Known for collection members (the edge function lists them by email);
    /// nil for task shares.
    public let email: String?
    /// nil ⇒ the grant is `assign` (handed over), see `handedOver`.
    public let access: ShareAccess?
    public let handedOver: Bool
    /// The task share id (for `task_unshare`); nil for collection members.
    public let shareId: String?

    public init(userId: String, name: String? = nil, email: String? = nil,
                access: ShareAccess?, handedOver: Bool = false, shareId: String? = nil) {
        self.userId = userId
        self.name = name
        self.email = email
        self.access = access
        self.handedOver = handedOver
        self.shareId = shareId
    }
}

/// One row of the People section.
public struct SharePersonRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let userId: String
    public let name: String
    /// The relationship label ("Coach") when set.
    public let subtitle: String?
    /// Known only when the grant carried it (collection members).
    public let email: String?
    /// What they have on this item now; nil = not shared with them yet.
    public var access: ShareAccess?
    /// The task was handed over to them (level `assign`).
    public var handedOver: Bool
    /// The task share id, when shared (drives revoke).
    public var shareId: String?

    public init(id: String, userId: String, name: String, subtitle: String? = nil, email: String? = nil,
                access: ShareAccess? = nil, handedOver: Bool = false, shareId: String? = nil) {
        self.id = id
        self.userId = userId
        self.name = name
        self.subtitle = subtitle
        self.email = email
        self.access = access
        self.handedOver = handedOver
        self.shareId = shareId
    }

    /// True when they hold anything on the item (a grade or a hand-over).
    public var isShared: Bool { access != nil || handedOver }

    /// The trailing status text: "Can edit" / "Can view" / "Handed over".
    public var statusLabel: String? {
        if handedOver { return "Handed over" }
        return access?.label
    }
}

/// One pending (email) invite on the item — shown under "Someone new".
public struct SharePendingRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let access: ShareAccess

    public init(id: String, email: String, access: ShareAccess) {
        self.id = id
        self.email = email
        self.access = access
    }
}

/// The People section: every ACTIVE connection (roster order), annotated with
/// the grant they already hold on this item, followed by anyone who holds a
/// grant but is not (yet) a connection — a legacy collection member — so an
/// existing share is never invisible. Pending circle invites are NOT people
/// (they show under Settings → People with their email).
public func composeSharePeople(circle: [CircleMember], grants: [ShareExistingGrant]) -> [SharePersonRow] {
    var byUser: [String: ShareExistingGrant] = [:]
    for g in grants where !g.userId.isEmpty { byUser[g.userId] = g }
    var rows: [SharePersonRow] = []
    var seen = Set<String>()
    for m in circle where m.status == "active" {
        guard let uid = m.memberUserId, !uid.isEmpty, !seen.contains(uid) else { continue }
        seen.insert(uid)
        let g = byUser[uid]
        let name = firstNonEmptyName([m.memberName, g?.name, g?.email])
        let handedOver: Bool = g?.handedOver ?? false
        rows.append(SharePersonRow(id: m.id, userId: uid, name: name, subtitle: m.relationshipLabel,
                                   email: g?.email, access: g?.access, handedOver: handedOver,
                                   shareId: g?.shareId))
    }
    for g in grants where !g.userId.isEmpty && !seen.contains(g.userId) {
        seen.insert(g.userId)
        let name = firstNonEmptyName([g.name, g.email])
        rows.append(SharePersonRow(id: "grant:\(g.userId)", userId: g.userId, name: name, subtitle: nil,
                                   email: g.email, access: g.access, handedOver: g.handedOver, shareId: g.shareId))
    }
    return rows
}

/// The first non-blank candidate, trimmed; "Someone" when there is none.
/// (A plain loop — the chained compactMap/first form made the type checker
/// crawl inside the composition above.)
private func firstNonEmptyName(_ candidates: [String?]) -> String {
    for c in candidates {
        guard let c else { continue }
        let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
    }
    return "Someone"
}

// MARK: - People section · collapse + order (the Share screen's card)

/// Rows shown before "Show N more" hides the rest. Mirrored by the Android
/// and web Share screens — change all three together or they collapse
/// differently.
public let sharePeopleCollapsedCap = 3
/// From this many people up, the EXPANDED list gets a Find field.
public let sharePeopleSearchThreshold = 10

/// What the People card renders for one (people, pinned, expanded, query).
public struct SharePeopleLayout: Equatable, Sendable {
    public var rows: [SharePersonRow]
    /// 0 when expanded, searching, or nothing is hidden.
    public var hiddenCount: Int
    /// expanded && count ≥ `sharePeopleSearchThreshold`.
    public var showsSearch: Bool
    /// Whether the "Show N more / Show less" row exists at all.
    public var canCollapse: Bool

    public init(rows: [SharePersonRow], hiddenCount: Int, showsSearch: Bool, canCollapse: Bool) {
        self.rows = rows
        self.hiddenCount = hiddenCount
        self.showsSearch = showsSearch
        self.canCollapse = canCollapse
    }
}

/// Shared-first, roster order preserved inside each half. `pinned` = the ids
/// that already held the item when the screen OPENED, so a row never moves
/// under the finger after a tap.
public func sharePeopleOrdered(_ people: [SharePersonRow], pinned: Set<String>) -> [SharePersonRow] {
    people.filter { pinned.contains($0.id) } + people.filter { !pinned.contains($0.id) }
}

/// Diacritic- and case-insensitive prefix-of-word over name, relationship and
/// email. Every query term must prefix some word.
public func sharePersonMatches(_ row: SharePersonRow, query: String) -> Bool {
    let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let terms = query.folding(options: opts, locale: .current).split(whereSeparator: \.isWhitespace)
    guard !terms.isEmpty else { return true }
    let words = [row.name, row.subtitle ?? "", row.email ?? ""].joined(separator: " ")
        .folding(options: opts, locale: .current)
        .split(whereSeparator: { $0.isWhitespace || $0 == "@" || $0 == "." })
    return terms.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
}

/// THE COLLAPSE RULE.
///  • order = pinned first, roster order inside each half
///  • cap  = max(sharePeopleCollapsedCap, pinned.count) — a person who already
///           holds the item is NEVER hidden (that is the section's promise)
///  • hide only when it hides ≥ 2 rows: a "Show 1 more" is worse than the row
///  • searching lifts the cap entirely and hides the disclosure
public func sharePeopleLayout(_ people: [SharePersonRow], pinned: Set<String>,
                              expanded: Bool, query: String) -> SharePeopleLayout {
    let ordered = sharePeopleOrdered(people, pinned: pinned)
    let showsSearch = expanded && ordered.count >= sharePeopleSearchThreshold
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    if showsSearch, !trimmed.isEmpty {
        return .init(rows: ordered.filter { sharePersonMatches($0, query: trimmed) },
                     hiddenCount: 0, showsSearch: true, canCollapse: false)
    }
    let cap = max(sharePeopleCollapsedCap, pinned.intersection(Set(ordered.map(\.id))).count)
    let canCollapse = ordered.count > cap + 1
    guard canCollapse, !expanded else {
        return .init(rows: ordered, hiddenCount: 0, showsSearch: showsSearch, canCollapse: canCollapse)
    }
    return .init(rows: Array(ordered.prefix(cap)), hiddenCount: ordered.count - cap,
                 showsSearch: false, canCollapse: true)
}

/// "Show 4 more" / "Show less". No "· N already shared" suffix exists, because
/// with the max() cap a hidden row can never be a shared one.
public func sharePeopleDisclosureTitle(hiddenCount: Int, expanded: Bool) -> String {
    expanded ? "Show less" : "Show \(hiddenCount) more"
}

/// A successful outcome, in the vocabulary of §2 — rendered by `shareResultLine`.
public enum ShareResult: Equatable, Sendable {
    /// An existing account got the item right away.
    case shared(name: String, access: ShareAccess)
    /// No account for that email yet — invite stored, email sent.
    case invited(email: String)
    /// The server took the share but does not say whether the address had an
    /// account (`share-collection add` deliberately answers the same for
    /// both) — the line stays neutral rather than guessing.
    case accepted(email: String)
    /// A join link was copied / handed to the system share sheet.
    case linkCopied(kind: ShareItemKind)
    /// The task was handed over (level `assign`).
    case handedOver(name: String)
    /// Their grade changed.
    case accessChanged(name: String, access: ShareAccess)
    /// They no longer have the item.
    case removed(name: String)
    /// A pending email invite was cancelled.
    case inviteCancelled(email: String)
}

/// The honest line under the button (§2 "Feedback that is true").
public func shareResultLine(_ r: ShareResult) -> String {
    switch r {
    case .shared(let name, let access):
        return "Shared with \(shareShortName(name)) — they can \(access.verb)."
    case .invited(let email):
        return "Invite sent to \(email) — waiting for them to sign up."
    case .accepted(let email):
        return "Shared with \(email) — they'll see it as soon as they're in."
    case .linkCopied(let kind):
        return "Link copied — whoever opens it gets this \(kind.noun)."
    case .handedOver(let name):
        return "Handed over to \(shareShortName(name)) — it's their task now; you keep view."
    case .accessChanged(let name, let access):
        return "\(shareShortName(name)) can now \(access.verb)."
    case .removed(let name):
        return "\(shareShortName(name)) no longer has this."
    case .inviteCancelled(let email):
        return "Invite to \(email) cancelled."
    }
}

/// Why a share did not happen — the server's reason codes and the local
/// guards, mapped to what the user reads.
public enum ShareFailure: Equatable, Sendable {
    /// The email is the caller's own.
    case selfShare
    /// A device-local block, or the server's `blocked`.
    case blocked
    /// The limiter refused (`rate_limited`).
    case rateLimited
    /// The item is gone / unknown.
    case notFound
    /// Not the owner / no permission.
    case notAllowed
    /// The address didn't parse (locally or `invalid_email` / `bad_request`).
    case invalidEmail
    /// No signed-in transport (demo boot / signed out).
    case notSignedIn
    /// `task_share` still needs an active connection (`not_in_circle`).
    case notConnected
    /// Sharing a LIST with a connection by name: the collection function
    /// resolves emails only and the roster has none (contract gap).
    case listNeedsEmail
    /// Offline / a non-2xx with no readable reason.
    case network
    /// Any other server code, kept for the log.
    case server(String)

    /// Map a server reason / error code (share-task `reason`, share-collection
    /// `error`, circle-invite `error`) to a failure. nil / "network" → network.
    public init(reason: String?) {
        switch (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "self": self = .selfShare
        case "blocked": self = .blocked
        case "rate_limited", "rate_limit", "too_many_requests", "circle_full": self = .rateLimited
        case "not_found": self = .notFound
        case "forbidden", "not_owner", "not_your_task", "unauthorized", "not_allowed": self = .notAllowed
        case "invalid_email", "bad_request", "bad_email": self = .invalidEmail
        case "not_configured", "signed_out": self = .notSignedIn
        case "not_in_circle": self = .notConnected
        case "", "network", "invite_failed", "server_error": self = .network
        case let other: self = .server(other)
        }
    }

    /// The line the user reads.
    public var message: String {
        switch self {
        case .selfShare: return "That's you."
        case .blocked: return "You've blocked that person."
        case .rateLimited: return "Too many invites right now — try again in a few minutes."
        case .notFound: return "Couldn't find that — it may have been deleted."
        case .notAllowed: return "Only the owner can share this."
        case .invalidEmail: return "That doesn't look like an email address."
        case .notSignedIn: return "Sign in to share."
        case .notConnected: return "You're not connected yet — share by email or a link below."
        case .listNeedsEmail: return "Lists can't be shared by name yet — enter their email below."
        case .network, .server: return "Couldn't share — try again."
        }
    }
}

/// A loose "is this an email address?" — enough to route the assistant's
/// `person` argument and to guard the Someone-new field before a round trip.
public func isEmailLike(_ raw: String) -> Bool {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let at = s.firstIndex(of: "@"), at != s.startIndex else { return false }
    let domain = s[s.index(after: at)...]
    guard !domain.isEmpty, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
    return !s.contains(where: { $0.isWhitespace }) && s.filter({ $0 == "@" }).count == 1
}

/// Normalise an address the way the server does (trim + lower-case).
public func normalizedShareEmail(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// "Maya" from "Maya Chen" / "maya@x.com" — the first name used in result lines.
public func shareShortName(_ raw: String) -> String {
    let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if n.isEmpty { return "them" }
    if n.contains("@") { return n.split(separator: "@").first.map(String.init) ?? n }
    return n.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? n
}

/// The one-line explainer on the Hand-over picker (§2).
public let handOverExplainer = "It becomes their task to do — you keep view and hear when it's done."

// MARK: - Settings → People · "Waiting to join" (§2 "One place for people")

/// What a pending invite is for, in the ONE vocabulary — the subtitle of a
/// Waiting-to-join row: "Draft the deck · can edit", "Groceries · can view",
/// "your people". A missing item name degrades to "a task" / "a list"; an
/// unknown grade drops the suffix rather than inventing one.
public func pendingInviteLabel(_ p: PendingInvite) -> String {
    switch p.kind {
    case .circle:
        return "your people"
    case .task:
        let name = nonBlank(p.itemName) ?? "a task"
        let grade: String?
        switch (p.access ?? "").lowercased() {
        case "partner": grade = "can edit"
        case "view": grade = "can view"
        case "assign": grade = "handed over"
        default: grade = nil
        }
        return grade.map { "\(name) · \($0)" } ?? name
    case .collection:
        let name = nonBlank(p.itemName) ?? "a list"
        let grade: String?
        switch (p.access ?? "").lowercased() {
        case "editor": grade = "can edit"
        case "viewer": grade = "can view"
        default: grade = nil
        }
        return grade.map { "\(name) · \($0)" } ?? name
    }
}

/// The two lists Settings → People renders from one `circle_list()` and one
/// `my_pending_invites()`.
public struct PeopleSections: Equatable, Sendable {
    /// Active connections + the pending roster rows the RPC did NOT report
    /// (link-only invites, or every pending row on a server without the RPC).
    public var roster: [CircleMember]
    /// Every outstanding invite, RPC order (createdAt desc), each listed once.
    public var waiting: [PendingInvite]
    public init(roster: [CircleMember], waiting: [PendingInvite]) {
        self.roster = roster
        self.waiting = waiting
    }
}

/// Compose the People screen. A circle invite the RPC reports (kind `circle`)
/// REPLACES its roster pending row — matched by `trusted_circle.id`, or, as a
/// belt-and-braces second key, by the invited address — so the same invite is
/// never shown twice; the roster row's `invite_code` is carried onto the
/// waiting row so "Copy link" still works. Anything the RPC does not know
/// stays in the roster exactly as before, which is what keeps the screen
/// whole on a server where `my_pending_invites` does not exist yet (the
/// transport answers `[]`). Duplicate RPC rows collapse to the first.
public func composePeopleSections(circle: [CircleMember], pending: [PendingInvite]) -> PeopleSections {
    // Waiting: RPC order, deduped by `kind:inviteId`, circle rows enriched
    // with the roster's join code.
    let pendingCircleById: [String: CircleMember] = Dictionary(
        circle.filter { $0.status == "invited" }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let pendingCircleByEmail: [String: CircleMember] = Dictionary(
        circle.filter { $0.status == "invited" }.compactMap { m in
            nonBlank(m.inviteeEmail).map { ($0.lowercased(), m) }
        }, uniquingKeysWith: { a, _ in a })
    var seen = Set<String>()
    var waiting: [PendingInvite] = []
    var replacedRosterIds = Set<String>()
    for var p in pending {
        guard !seen.contains(p.id) else { continue }
        seen.insert(p.id)
        if p.kind == .circle {
            let match = pendingCircleById[p.inviteId]
                ?? nonBlank(p.email).flatMap { pendingCircleByEmail[$0.lowercased()] }
            if let match {
                replacedRosterIds.insert(match.id)
                if p.inviteCode == nil { p.inviteCode = match.inviteCode }
                if p.email.isEmpty, let e = nonBlank(match.inviteeEmail) { p.email = e }
            }
        }
        waiting.append(p)
    }
    let roster = circle.filter { !($0.status == "invited" && replacedRosterIds.contains($0.id)) }
    return PeopleSections(roster: roster, waiting: waiting)
}

/// Trimmed, or nil when blank / absent.
private func nonBlank(_ s: String?) -> String? {
    guard let s else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}
