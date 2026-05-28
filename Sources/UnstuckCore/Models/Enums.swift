// Domain enums. Mirror lib/types.ts in the web app (which in turn
// mirrors the normalized Supabase schema in
// supabase/migrations/001_initial.sql). Raw values match the strings
// stored server-side so Codable round-trips against PostgREST JSON.

import Foundation

public enum Priority: String, Codable, Sendable, CaseIterable {
    case urgent, high, medium, low
}

public enum Tier: String, Codable, Sendable {
    case free, beta, pro, team
}

public enum ThemePref: String, Codable, Sendable {
    case system, light, dark
}

public enum Density: String, Codable, Sendable {
    case compact, regular, comfy
}

public enum AccentPalette: String, Codable, Sendable {
    case indigoCoral = "indigo-coral"
    case periwinkleRose = "periwinkle-rose"
    case forestAmber = "forest-amber"
}

public enum FocusTreatment: String, Codable, Sendable {
    case ambient, cockpit, monk
}

public enum FocusState: String, Codable, Sendable {
    case idle, starting, running, overrun, pause, done, resume
}

public enum CalMode: String, Codable, Sendable {
    case day, week, month
}

public enum TaskView: String, Codable, Sendable {
    case list, board, priority
}

public enum ReasonAction: String, Codable, Sendable {
    case pause, `switch`
}

public enum SyncStatus: String, Codable, Sendable {
    case saving, saved, error
}

public enum CalendarProvider: String, Codable, Sendable {
    case google, apple, microsoft
}

/// What kind of calendar block this is. Backed by migration 006; falls
/// back to a derived kind (see `blockKind`) for legacy rows + the
/// signed-out mock seed.
public enum CalBlockKind: String, Codable, Sendable {
    case task, placeholder, external
}

public enum CaptureTag: String, Codable, Sendable {
    case followUp = "follow-up"
    case idea
    case edit
    case question
    case distraction
}
