// Single source of truth for "what kind of block is this?". Port of
// lib/cal-block-kind.ts. Calendar surfaces and the "usable time" math
// all route through here so they agree on the rules.

import Foundation

public func blockKind(_ b: CalBlock) -> CalBlockKind {
    // Prefer the server-stored kind once migration 006 has populated it.
    // Falls back to the string-prefix heuristic for legacy rows + the
    // signed-out mock seed.
    if let k = b.kind { return k }
    if let ext = b.externalEventId, !ext.isEmpty { return .external }
    let id = b.taskId ?? ""
    if id == "placeholder" { return .placeholder }
    if id.hasPrefix("cal-") { return .external }
    return .task
}

/// True for blocks that represent real task work. Block-time events
/// (migration 009) carry taskId=nil and kind=external — never a task
/// block.
public func isTaskBlock(_ b: CalBlock) -> Bool {
    blockKind(b) == .task && !(b.taskId ?? "").isEmpty
}

public func isPlaceholderBlock(_ b: CalBlock) -> Bool { blockKind(b) == .placeholder }
public func isExternalBlock(_ b: CalBlock) -> Bool { blockKind(b) == .external }
