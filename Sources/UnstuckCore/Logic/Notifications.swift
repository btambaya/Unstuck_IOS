// Notification moments — pure decision logic (spec 10-notifications.md).
// Port of the Android NotificationLevel (SettingsStore.kt) + the
// ReminderScheduler.sync() selection rules + the Notification Center's
// Upcoming computation and relative-time formatters. Everything here is
// pure so the scheduling decisions are unit-testable; the App layer maps
// PlannedReminders onto UNNotificationRequests.

import Foundation

/// How proactively the app notifies (Settings → Notifications). Calm =
/// only what you can't miss; Balanced = the default helpful set; Coach =
/// maximum prompting. The booleans below are the single source of truth
/// for which moments each level enables — read by ReminderScheduler,
/// PausedCheckinScheduler, and (mirrored to the server) the morning brief.
public enum NotificationLevel: String, CaseIterable, Sendable {
    case calm = "Calm"
    case balanced = "Balanced"
    case coach = "Coach"

    /// Verbatim copy from the Android SettingsStore (spec 10 §3.1).
    public var blurb: String {
        switch self {
        case .calm: return "Only the essentials — pre-task reminders and your session recap."
        case .balanced: return "Reminders, a start-now nudge with Start/Reschedule, paused check-ins, the morning brief, and quiet in-app nudges."
        case .coach: return "Everything in Balanced, plus a nudge if you haven't started on time and more proactive prompts."
        }
    }

    /// A "starts now" notification (Start / Reschedule) at the block's start time.
    public var atStart: Bool { self != .calm }
    /// A follow-up ~10 min after start if the task still hasn't been started.
    public var drifted: Bool { self == .coach }
    /// The paused-too-long check-in.
    public var pausedCheckin: Bool { self != .calm }
    /// The server-sent morning brief.
    public var morningBrief: Bool { self != .calm }
    /// Quiet in-app nudge cards (no push).
    public var nudges: Bool { self != .calm }

    public static func fromLabel(_ label: String) -> NotificationLevel {
        NotificationLevel(rawValue: label) ?? .balanced
    }
}

/// The three on-device exact reminders (Android moment ids A1 / A2 / A4).
public enum ReminderKind: String, CaseIterable, Sendable {
    case lead       // A1 pre-task "Coming up"
    case atstart    // A2 "starts now" + Start / Reschedule
    case drifted    // A4 didn't-start follow-up
}

/// One reminder the scheduler should have armed. `key` mirrors the
/// Android persisted-set scheme ("<tag>:<blockId>") so the prev − now
/// stale-cancellation diff is identical across platforms.
public struct PlannedReminder: Equatable, Sendable {
    public let kind: ReminderKind
    public let blockId: String
    public let taskId: String      // "" for external calendar events
    public let taskName: String
    public let fireAt: EpochMillis
    public let leadMinutes: Int    // LEAD only; 0 for atstart/drifted

    public var key: String { "\(kind.rawValue):\(blockId)" }

    public init(kind: ReminderKind, blockId: String, taskId: String, taskName: String, fireAt: EpochMillis, leadMinutes: Int) {
        self.kind = kind
        self.blockId = blockId
        self.taskId = taskId
        self.taskName = taskName
        self.fireAt = fireAt
        self.leadMinutes = leadMinutes
    }
}

/// Schedule 48h ahead (Android ReminderScheduler.HORIZON_MS).
public let REMINDER_HORIZON_MS: Double = 2 * 86_400_000
/// A4 fires 10 min after start (Android DRIFT_MS).
public let REMINDER_DRIFT_MS: Double = 10 * 60_000

/// A block's start instant in the DEVICE's local zone (epoch ms), from its
/// `date` ("YYYY-MM-DD") + `startTime` ("HH:MM"). Matches Android
/// blockStartMs (ZoneId.systemDefault) — spec 10 gotcha 2.
public func blockStartMillis(_ b: CalBlock) -> EpochMillis? {
    let d = b.date.split(separator: "-").compactMap { Int($0) }
    let t = b.startTime.split(separator: ":").compactMap { Int($0) }
    guard d.count == 3, t.count >= 2 else { return nil }
    var c = DateComponents()
    c.year = d[0]; c.month = d[1]; c.day = d[2]
    c.hour = t[0]; c.minute = t[1]
    guard let date = Calendar.current.date(from: c) else { return nil }
    return date.timeIntervalSince1970 * 1000
}

/// The ReminderScheduler decision: which LEAD / ATSTART / DRIFTED alarms
/// should exist right now. Pure port of Android ReminderScheduler.sync():
///  - task blocks + EXTERNAL calendar events are eligible; placeholders skipped
///  - done tasks schedule nothing
///  - externals use the global lead; tasks the per-task override (else global)
///  - LEAD only when lead > 0; ATSTART gated Balanced+; DRIFTED gated Coach
///  - only fire times in (now, now + 48h] are armed
///  - ATSTART/DRIFTED are suppressed for the currently-focused task — the
///    iOS inversion of Android's fire-time re-check (spec 10 gotcha 8):
///    local notifications can't run code before display, so the pending
///    request is cancelled the moment the live session starts.
public func planReminders(
    blocks: [CalBlock],
    tasks: [TaskItem],
    level: NotificationLevel,
    globalLeadMin: Int,
    overrides: [String: Int] = [:],
    liveTaskId: String? = nil,
    now: EpochMillis
) -> [PlannedReminder] {
    var out: [PlannedReminder] = []

    func arm(_ b: CalBlock, _ kind: ReminderKind, fireAt: EpochMillis, lead: Int) {
        guard fireAt > now, fireAt <= now + REMINDER_HORIZON_MS else { return }
        out.append(PlannedReminder(kind: kind, blockId: b.id, taskId: b.taskId ?? "",
                                   taskName: b.taskName, fireAt: fireAt, leadMinutes: lead))
    }

    for b in blocks {
        let isExternal = isExternalBlock(b)
        let isTask = isTaskBlock(b)
        if !isTask && !isExternal { continue }
        guard let startMs = blockStartMillis(b) else { continue }
        let taskId = b.taskId ?? ""
        if isTask, tasks.first(where: { $0.id == taskId })?.done == true { continue }

        // A1 pre-task — every level. External events use the global lead;
        // tasks the per-task override.
        let lead = isExternal ? globalLeadMin : (taskId.isEmpty ? globalLeadMin : (overrides[taskId] ?? globalLeadMin))
        if lead > 0 { arm(b, .lead, fireAt: startMs - Double(lead) * 60_000, lead: lead) }

        // The "no nudge for a handled task" guarantee: skip A2/A4 for the
        // task that is actively being focused.
        let focused = liveTaskId != nil && taskId == liveTaskId
        // A2 starts-now (Start / Reschedule) — task blocks, Balanced+.
        if isTask && level.atStart && !focused { arm(b, .atstart, fireAt: startMs, lead: 0) }
        // A4 didn't-start follow-up — task blocks, Coach.
        if isTask && level.drifted && !focused { arm(b, .drifted, fireAt: startMs + REMINDER_DRIFT_MS, lead: 0) }
    }
    return out
}

// MARK: - notification copy (Android ReminderReceiver / NotificationRenderer)

/// LEAD body — "<name> — in <lead> minutes." (lead == 0 is never armed).
public func reminderLeadBody(taskName: String, leadMin: Int) -> String {
    let name = taskName.isEmpty ? "your task" : taskName
    return leadMin > 0 ? "\(name) — in \(leadMin) minutes." : "\(name) is starting."
}

public func taskStartingTitle(drifted: Bool) -> String {
    drifted ? "Didn't get to it?" : "Time to start"
}

public func taskStartingBody(taskName: String, drifted: Bool) -> String {
    let name = taskName.isEmpty ? "your task" : taskName
    return drifted
        ? "\u{201C}\(name)\u{201D} was set for a little while ago — want to start now?"
        : "\u{201C}\(name)\u{201D} starts now."
}

/// Deep link for a reminder tap: the task if it has one, else Today.
public func reminderDeepLink(taskId: String) -> String {
    taskId.isEmpty ? "unstuck://today" : "unstuck://task/\(taskId)"
}

// MARK: - Notification Center "Upcoming" (computed live, never logged)

public struct UpcomingReminder: Equatable, Sendable, Identifiable {
    public let taskId: String
    public let name: String
    public let at: EpochMillis
    public var id: String { "up:\(taskId):\(at)" }

    public init(taskId: String, name: String, at: EpochMillis) {
        self.taskId = taskId
        self.name = name
        self.at = at
    }
}

/// Scheduled task reminders in the next 2 days, computed live from the
/// blocks (Android NotificationCenterScreen): task blocks whose start is
/// within [now, now+48h] and whose task isn't done, de-duped by
/// (taskId, at), sorted ascending, capped at 20.
public func upcomingReminders(blocks: [CalBlock], tasks: [TaskItem], now: EpochMillis) -> [UpcomingReminder] {
    var seen = Set<String>()
    var out: [UpcomingReminder] = []
    for b in blocks where isTaskBlock(b) {
        guard let ms = blockStartMillis(b), ms >= now, ms <= now + REMINDER_HORIZON_MS else { continue }
        let taskId = b.taskId ?? ""
        if tasks.first(where: { $0.id == taskId })?.done == true { continue }
        let key = "\(taskId):\(ms)"
        if seen.insert(key).inserted {
            out.append(UpcomingReminder(taskId: taskId, name: b.taskName, at: ms))
        }
    }
    return Array(out.sorted { $0.at < $1.at }.prefix(20))
}

// MARK: - relative-time labels (verbatim Android strings)

public func relFuture(_ deltaMs: EpochMillis) -> String {
    let m = max(0, Int(deltaMs / 60_000))
    if m < 60 { return "in \(m)m" }
    if m < 1440 { return "in \(m / 60)h" }
    return "in \(m / 1440)d"
}

public func relPast(_ deltaMs: EpochMillis) -> String {
    let m = max(0, Int(deltaMs / 60_000))
    if m < 1 { return "just now" }
    if m < 60 { return "\(m)m ago" }
    if m < 1440 { return "\(m / 60)h ago" }
    return "\(m / 1440)d ago"
}

// MARK: - accent-by-kind (Android accentFor; colors resolved by the UI)

public enum NotificationAccent: Sendable {
    case amber, green, primaryDeep, coral
}

public func notificationAccent(kind: String) -> NotificationAccent {
    switch kind {
    case "paused_checkin", "atstart", "drifted": return .amber
    case "session_recap": return .green
    case "morning_brief", "evening_preview", "daily_nudge": return .primaryDeep
    default: return .coral
    }
}
