// Daily check-in — a grounded one-liner the assistant "says" on the first
// open of each day, built ENTIRELY client-side from real data (zero tokens).
// Injected as a local display message (never sent to the model).
//
// Port of lib/assistant/checkin.ts.

import Foundation

private func greetingWord(_ hour: Int) -> String {
    if hour < 12 { return "Morning" }
    if hour < 18 { return "Afternoon" }
    return "Evening"
}

public func buildCheckin(
    firstName: String?,
    openTodayCount: Int,
    usableLabel: String?,
    /// Local hour 0-23 — drives Morning/Afternoon/Evening.
    hour: Int
) -> String {
    let word = greetingWord(hour)
    let hi = firstName.map { "\(word), \($0)." } ?? "\(word)."
    let n = openTodayCount
    if n == 0 {
        return "\(hi) Nothing scheduled yet — want me to help plan today?"
    }
    let things = "\(n) thing\(n == 1 ? "" : "s") on today"
    let time = usableLabel.map { ", \($0) usable" } ?? ""
    return "\(hi) \(things)\(time). Want me to sequence them, or take something off the list?"
}
