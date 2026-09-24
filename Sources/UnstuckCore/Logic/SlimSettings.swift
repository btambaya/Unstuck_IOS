// Slim Settings (PLAN.md, approved 2026-09-24) — the pure half.
//
// Settings holds only what you set once: Account, Notifications & calls,
// Assistant & privacy, People and Appearance, plus two one-tap actions (Send
// feedback, Replay the tour) and a footer (Terms · Privacy · version). Things
// that change one screen live on that screen now (focus options on the Focus
// screen, background noise on its speaker button, hold-to-talk on Talk, areas
// and tags on Tasks).
//
// Everything a link, the tour or the assistant can name is resolved here, so
// the aliases (old section names included) are unit-tested once and every
// entry point agrees.

import Foundation

/// Where a Settings link lands. The raw values are the section ids the web
/// uses (`?section=`), so a link means the same thing on every platform.
public enum SettingsDestination: String, CaseIterable, Sendable {
    /// The hub itself (the bare `unstuck://settings`, or a name we don't know).
    case hub = "Hub"
    case account = "Account"
    /// "Notifications & calls" — the id stays `Notifications` so every old
    /// link keeps working.
    case notifications = "Notifications"
    /// "Assistant & privacy".
    case assistant = "Assistant"
    case people = "People"
    case appearance = "Appearance"
    /// The feedback sheet (a hub action, not a screen).
    case feedback = "Feedback"
    /// Focus options live on the Focus screen now: a live session opens it,
    /// otherwise the hub.
    case focus = "Focus"
    /// Areas & tags live on Tasks now: the Tasks tab + its Areas & tags sheet.
    case areas = "Areas"

    /// The screens Settings pushes (the rest are handled elsewhere).
    public var isSettingsScreen: Bool {
        switch self {
        case .account, .notifications, .assistant, .people, .appearance: return true
        case .hub, .feedback, .focus, .areas: return false
        }
    }

    /// Resolve a `section=` value (or a tour step's section) — case-
    /// insensitive, with every old name as an alias. nil / empty / unknown →
    /// the hub (a link never dead-ends).
    public static func from(section raw: String?) -> SettingsDestination {
        guard let raw else { return .hub }
        // Same folding as the web's normalizeSection (lib/settings-sections.ts):
        // trimmed, lower-cased, runs of spaces collapsed.
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !key.isEmpty else { return .hub }
        // Every web alias is here too (so a link means the same everywhere),
        // except `sound`, which the plan sends to the Focus screen on iOS.
        switch key {
        case "notifications", "notification", "calls", "call", "reminders", "reminder",
             "calls from unstuck", "notifications & calls", "notifications and calls",
             "notifications-and-calls", "notifications-calls":
            return .notifications
        case "assistant", "ai", "ai assistant", "ai data sharing", "memory", "knows", "remembers", "privacy",
             "assistant & privacy", "assistant and privacy", "assistant-and-privacy", "assistant-privacy",
             "what unstuck knows", "what-unstuck-knows", "what unstuck remembers":
            return .assistant
        case "interface", "appearance", "accessibility", "a11y", "theme", "text size", "text-size", "display":
            return .appearance
        case "people", "connections", "circle", "sharing", "people you share with",
             "trusted circle", "trusted-circle":
            return .people
        case "account", "backup", "export", "sync", "profile", "password", "delete":
            return .account
        case "feedback", "send feedback":
            return .feedback
        case "focus", "sound", "sounds":
            return .focus
        case "areas", "tags", "areas & tags", "areas and tags", "areas-and-tags", "areas-tags", "areas+tags",
             "area", "tag":
            return .areas
        default:
            return .hub
        }
    }

    /// The `section=` of an `unstuck://settings?section=…` link.
    public static func from(link: String) -> SettingsDestination {
        guard let comps = URLComponents(string: link),
              let raw = comps.queryItems?.first(where: { $0.name == "section" })?.value
        else { return .hub }
        return from(section: raw)
    }
}

/// Settings → Appearance → Text size (phones only). Merges the old Density
/// and Larger type: compact → Smaller, regular → Default, comfy or Larger
/// type → Larger. Applied as DynamicTypeSize steps on top of the phone's own
/// text size (every app font is `Font.custom(_:size:)`, which scales).
public enum TextSizePref: String, CaseIterable, Sendable {
    case smaller, standard = "default", larger

    public var label: String {
        switch self {
        case .smaller: return "Smaller"
        case .standard: return "Default"
        case .larger: return "Larger"
        }
    }

    /// DynamicTypeSize steps relative to the system size.
    public var typeStepShift: Int {
        switch self {
        case .smaller: return -1
        case .standard: return 0
        case .larger: return 2
        }
    }

    /// The first read on a device that set the old controls: Larger type won
    /// (it was the bigger of the two), then Density. Neither stored → Default.
    /// The old keys are never wiped — they're just not read once a Text size
    /// has been chosen.
    public static func migrated(density: String?, largerType: Bool) -> TextSizePref {
        if largerType { return .larger }
        switch density {
        case "compact": return .smaller
        case "comfy": return .larger
        default: return .standard
        }
    }
}

public extension NotificationLevel {
    /// One plain line under each level in Notifications & calls. Coach's extra
    /// nudge is a phone reminder, so the web must not promise it (PLAN.md risk 6).
    var plainLine: String {
        switch self {
        case .calm: return "Only the reminders you set, and a recap."
        case .balanced: return "Also a nudge when a task should start, a check-in if you've paused a while, and a morning summary."
        case .coach: return "Also a second nudge if you haven't started 10 minutes in."
        }
    }

    /// The line under the picker: the level also paces the spoken focus coach.
    static let coachPaceNote = "This also sets how often the focus coach talks during a session."
}

public extension ProfileFactCategory {
    /// Plain names for What Unstuck remembers (never the internal ids).
    var plainLabel: String {
        switch self {
        case .person: return "About me"
        case .rhythm: return "Routine"
        case .constraint: return "Limits"
        case .preference: return "Likes"
        case .context: return "Other"
        }
    }
}

/// The routines' names on the web assistant panel (slim-settings plan): the
/// morning one is not the morning summary notification nor the morning call.
public func routineName(_ key: RitualKey) -> String {
    switch key {
    case .morning: return "Morning plan"
    case .evening: return "Evening wind-down"
    case .friday: return "Friday look-back"
    case .sunday: return "Sunday plan-ahead"
    }
}

/// Background noise (the Focus screen's speaker button). Stored as the old
/// Ambient raw value so older builds read it: "brown" and "pink" both mean ON
/// (pink was the same loop), anything else is off.
public func backgroundNoiseIsOn(storedAmbient raw: String?) -> Bool {
    raw == "brown" || raw == "pink"
}

/// What the Calls block in Notifications & calls shows.
public enum CallsBlockState: Equatable, Sendable {
    /// The Assistant or AI data sharing is off: calls can't connect, so the
    /// whole block is one line ("Calls need the Assistant and AI data
    /// sharing · Turn on").
    case needsAssistant
    /// This phone's switch is off: just the switch.
    case off
    /// The switch and everything under it.
    case on

    public static func resolve(assistantOn: Bool, aiSharingOn: Bool, phoneSwitchOn: Bool) -> CallsBlockState {
        guard assistantOn, aiSharingOn else { return .needsAssistant }
        return phoneSwitchOn ? .on : .off
    }

    /// The one line shown for `.needsAssistant`, naming only what's missing.
    public static func needsLine(assistantOn: Bool, aiSharingOn: Bool) -> String {
        switch (assistantOn, aiSharingOn) {
        case (false, false): return "Calls need the Assistant and AI data sharing."
        case (false, true): return "Calls need the Assistant, which is off."
        default: return "Calls need AI data sharing, which is off."
        }
    }
}
