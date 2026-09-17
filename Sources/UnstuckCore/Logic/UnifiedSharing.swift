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
