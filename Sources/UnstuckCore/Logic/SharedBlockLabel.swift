// The text of a shared block on a calendar surface — ONE rule on every
// platform (web `sharedBlockLabel`, Android `sharedBlockLabel`): the TASK
// leads, the sharer follows.
//
// Every calendar chip renders one tail-truncated line, and a Week column is
// ~45pt wide — so whatever comes FIRST is all that survives. Leading with the
// sharer ("anna odu · London weekend") left a recipient reading "anna odu · L…"
// with no idea WHAT was planned; the dashed outline already says it is someone
// else's. Task first means truncation drops the sharer, never the task.

import Foundation

/// "London weekend · anna" — the task name, then the sharer as a suffix.
/// `compact` drops the sharer entirely (a block too short for two lines, a
/// column too narrow for a suffix): the Week grid shows the sharer on its own
/// second line when the block is tall enough, and nothing when it isn't.
///
/// The sharer is the raw owner name from the projection — an email loses its
/// domain (`name.split('@')[0]`, as everywhere else); a blank one adds no
/// suffix. A blank task name reads "Shared task" so a chip is never empty.
public func sharedBlockLabel(taskName: String, sharer: String?, compact: Bool = false) -> String {
    let task = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
    let primary = task.isEmpty ? "Shared task" : task
    guard !compact, let who = sharerDisplayName(sharer) else { return primary }
    return "\(primary) · \(who)"
}

/// The sharer's display name: an email address loses its domain; nil when
/// blank (so a caller can omit the suffix / the "shared by" clause).
public func sharerDisplayName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let local = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
    let trimmed = local.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
