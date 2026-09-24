// Small value objects embedded inside tasks/collections (stored as
// JSONB columns server-side). Mirror lib/types.ts.

import Foundation

public struct Objective: Codable, Equatable, Sendable {
    public var text: String
    public var done: Bool?
    public var minutes: Int?

    public init(text: String, done: Bool? = nil, minutes: Int? = nil) {
        self.text = text
        self.done = done
        self.minutes = minutes
    }
}

public struct Comment: Codable, Equatable, Sendable {
    public var text: String
    public var at: String?

    public init(text: String, at: String? = nil) {
        self.text = text
        self.at = at
    }
}

/// Recurring schedule on a task. `nil` (the optional) = does not repeat.
/// `daysOfWeek` uses 0=Sun … 6=Sat to match `Date.getDay()` so the
/// client needs no translation layer. `until` (YYYY-MM-DD) is inclusive.
/// Encodes/decodes the tagged-union JSON shape used by the web:
///   { "kind": "daily", "until": null }
///   { "kind": "weekly", "daysOfWeek": [1,3,5], "until": "2026-09-01" }
///   { "kind": "monthly" }
///   { "kind": "everyNWeeks", "interval": 2, "daysOfWeek": [4], "anchor": "2026-09-21" }
///
/// `everyNWeeks` (every-n-weeks spec, owner-approved 2026-09-24, Zubair's
/// "every two weeks on Thursdays"): week one is the ISO (Monday) week holding
/// `anchor`, then every `interval`-th week before and after it. Writers store
/// the anchor as a Monday, `interval` 2…8 (1 is written as plain weekly) and
/// distinct, sorted days in 0…6; readers accept any integral interval ≥ 1 and
/// ignore out-of-range days. A malformed one decodes to the unknown sentinel.
public enum Recurrence: Codable, Equatable, Sendable {
    case daily(until: String?)
    case weekly(daysOfWeek: [Int], until: String?)
    case monthly(until: String?)
    case everyNWeeks(interval: Int, daysOfWeek: [Int], anchor: String, until: String?)

    private enum CodingKeys: String, CodingKey {
        case kind, interval, daysOfWeek, anchor, until
    }

    /// `until` sentinel for an unrecognised recurrence kind (see `init(from:)`).
    /// A date far enough in the past that the until-guard in
    /// `materializeOccurrences` trips before any occurrence is materialised, so
    /// the task repeats zero times on this build. `isUnknown` detects it.
    public static let UNKNOWN_UNTIL = "0001-01-01"

    /// True for the `init(from:)` degrade-sentinel — a daily whose until is in
    /// the distant past. Callers (recurrenceLabel) treat it as "no recurrence".
    public static func isUnknown(_ r: Recurrence?) -> Bool {
        if case .daily(let until) = r, until == UNKNOWN_UNTIL { return true }
        return false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let until = try c.decodeIfPresent(String.self, forKey: .until)
        switch kind {
        case "daily":
            self = .daily(until: until)
        case "weekly":
            let days = try c.decodeIfPresent([Int].self, forKey: .daysOfWeek) ?? []
            self = .weekly(daysOfWeek: days, until: until)
        case "monthly":
            self = .monthly(until: until)
        case "everyNWeeks":
            // Strict (spec §2): anything that isn't a valid rule is the same
            // inert sentinel an unknown kind gets — never a throw (the whole
            // TaskRow would vanish), never a guess (a string "2", a boolean, a
            // fractional interval, an anchor like "soon" or 2026-02-31).
            self = Self.decodeEveryNWeeks(c, until: until) ?? .daily(until: Self.UNKNOWN_UNTIL)
        default:
            // Forward-compat: an UNKNOWN kind (a newer web/iOS release added a
            // recurrence type this build can't model). A bare throw would abort
            // the WHOLE TaskRow decode, so the task would VANISH from the list.
            // Degrade to a no-op daily that already ENDED (UNKNOWN_UNTIL): zero
            // occurrences materialise and recurrenceLabel renders nothing, so
            // the task stays usable (it just doesn't repeat here) instead of
            // disappearing. Mirrors the Android RecurrenceSerializer fix.
            self = .daily(until: Self.UNKNOWN_UNTIL)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .daily(let until):
            try c.encode("daily", forKey: .kind)
            try c.encodeIfPresent(until, forKey: .until)
        case .weekly(let days, let until):
            try c.encode("weekly", forKey: .kind)
            try c.encode(days, forKey: .daysOfWeek)
            try c.encodeIfPresent(until, forKey: .until)
        case .monthly(let until):
            try c.encode("monthly", forKey: .kind)
            try c.encodeIfPresent(until, forKey: .until)
        case .everyNWeeks(let interval, let days, let anchor, let until):
            try c.encode("everyNWeeks", forKey: .kind)
            try c.encode(interval, forKey: .interval)
            try c.encode(days, forKey: .daysOfWeek)
            try c.encode(anchor, forKey: .anchor)
            try c.encodeIfPresent(until, forKey: .until)
        }
    }

    /// A JSON number with an integral value (`2` and `2.0` alike — jsonb keeps
    /// `2.0` as written); anything else (a string, a boolean, null, `2.5`, a
    /// number past Int's range) is `.other`. Decoded through Codable, never
    /// JSONSerialization, where `1` and `true` are the same NSNumber.
    private enum IntegralNumber: Decodable {
        case integral(Int)
        case other

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) {
                self = .integral(i)
            } else if let d = try? c.decode(Double.self), let i = Int(exactly: d) {
                self = .integral(i)
            } else {
                self = .other
            }
        }

        var value: Int? {
            if case .integral(let i) = self { return i }
            return nil
        }
    }

    /// A valid `everyNWeeks` (spec §2), or nil: `interval` an integral number
    /// ≥ 1, `anchor` exactly YYYY-MM-DD and a real date (it must round-trip),
    /// `daysOfWeek` an array of integral numbers only (out-of-range values are
    /// kept as stored and ignored by readers).
    private static func decodeEveryNWeeks(_ c: KeyedDecodingContainer<CodingKeys>, until: String?) -> Recurrence? {
        guard let interval = (try? c.decode(IntegralNumber.self, forKey: .interval))?.value, interval >= 1,
              let anchor = try? c.decode(String.self, forKey: .anchor), strictEpochDay(anchor) != nil,
              let raw = try? c.decode([IntegralNumber].self, forKey: .daysOfWeek) else { return nil }
        var days: [Int] = []
        for d in raw {
            guard let v = d.value else { return nil }
            days.append(v)
        }
        return .everyNWeeks(interval: interval, daysOfWeek: days, anchor: anchor, until: until)
    }
}

/// User-owned life area (Work / Personal / …). Tasks reference areas by
/// name via `lifeArea`; this row is the canonical editable vocabulary +
/// its color token.
public struct LifeArea: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var color: String
    public var sortOrder: Int

    public init(id: String, name: String, color: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
    }
}

/// Curated tag (migration 010). Tasks reference tag names via their
/// `tags: [String]` array — this row is the canonical user-owned
/// vocabulary edited in Settings → Tags.
public struct TagRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var color: String?
    public var sortOrder: Int

    public init(id: String, name: String, color: String? = nil, sortOrder: Int) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
    }
}

/// One entry inside a collection. NOT a task — no scheduling/focus.
public struct CollectionItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var body: String
    /// Pinned items rise to the top of the detail list.
    public var pinned: Bool?
    /// Soft, optional tick — a calm "handled", not a task completion.
    public var done: Bool?
    /// ISO timestamp the item was added.
    public var at: String
    // Move-to-task / accountability (migration 025). Stored in the items JSONB; the
    // collection_set_item_promotion RPC writes these exact camelCase keys.
    /// Promoted to a real task (struck-through + status chip).
    public var promoted: Bool?
    /// Display name of whoever is on it (keep-everyone-in-the-loop).
    public var assignee: String?
    /// True once the assignee's linked task is completed ("done by <name> ✓").
    public var promotedDone: Bool?
    /// ISO "by" time for the loop promotion.
    public var dueAt: String?

    public init(id: String, body: String, pinned: Bool? = nil, done: Bool? = nil, at: String,
                promoted: Bool? = nil, assignee: String? = nil, promotedDone: Bool? = nil, dueAt: String? = nil) {
        self.id = id
        self.body = body
        self.pinned = pinned
        self.done = done
        self.at = at
        self.promoted = promoted
        self.assignee = assignee
        self.promotedDone = promotedDone
        self.dueAt = dueAt
    }
}

/// Collection (migration 012) — a calm "memory container".
/// (Web name: `Collection`; renamed here to avoid shadowing the Swift
/// standard-library `Collection` protocol within the module.)
public struct ItemCollection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Color token from the area palette (indigo, coral, green, …).
    public var color: String
    /// Optional serif-italic framing line shown under the name.
    public var subtitle: String?
    public var items: [CollectionItem]
    public var sortOrder: Int
    // Shared-collection fields (migration 020/022/026). Client-only — populated by the
    // Hydrator from collections.user_id + collection_members; never written back to the
    // DB row (the CollectionRow codec drops them). Optional so a row that omits them decodes.
    /// Owner's user id (the collection's user_id). Nil for local/demo rows.
    public var ownerId: String?
    /// Shared-with user ids (excludes the owner). Nil/empty = not shared.
    public var members: [String]?
    /// Current user's role: "owner" | "editor" | "viewer". Nil = local/own.
    public var myRole: String?
    /// Archived (migration 026) — hidden from the main overview; restorable.
    public var archived: Bool?

    public init(id: String, name: String, color: String, subtitle: String? = nil, items: [CollectionItem], sortOrder: Int,
                ownerId: String? = nil, members: [String]? = nil, myRole: String? = nil, archived: Bool? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.subtitle = subtitle
        self.items = items
        self.sortOrder = sortOrder
        self.ownerId = ownerId
        self.members = members
        self.myRole = myRole
        self.archived = archived
    }
}
