// A small persistent log of notifications the app has shown, so the
// in-app Notification Center can list them after they're swiped from the
// system tray (spec 10 §1.10; Android NotificationLog). Process-wide
// singleton backed by UserDefaults (client-only, capped at 60, never
// synced) + an @Observable the UI reads. `lastSeenMs` drives the unread
// badge. Reminders that haven't fired yet are NOT stored here — the
// center computes those live from the scheduled blocks.
//
// iOS divergence from Android: local/remote notifications can't run app
// code at display time, so entries are appended from willPresent
// (foreground delivery), didReceive (taps), and a delivered-notification
// sweep on each foreground — de-duped by request identifier + fire date.

import Foundation
import Observation
import UnstuckCore
import UserNotifications

/// The Sendable projection of a shown UNNotification — extracted in the
/// delegate's nonisolated context (UNNotification itself isn't Sendable,
/// so it can't hop to the MainActor log).
struct PostedNotification: Sendable {
    let kind: String?
    let title: String
    let body: String
    let deepLink: String?
    let at: Double          // epoch ms
    let dedupeKey: String

    init(_ notification: UNNotification) {
        let content = notification.request.content
        let info = content.userInfo
        kind = info["kind"] as? String
        title = content.title
        body = content.body
        deepLink = info["deepLink"] as? String
        at = notification.date.timeIntervalSince1970 * 1000
        dedupeKey = "\(notification.request.identifier)|\(Int(notification.date.timeIntervalSince1970))"
    }
}

@MainActor
@Observable
final class NotificationLog {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let kind: String
        let title: String
        let body: String
        let deepLink: String?
        let at: Double            // epoch ms
    }

    static let shared = NotificationLog()

    private static let logKey = "unstuck.notiflog.log"
    private static let seenKey = "unstuck.notiflog.lastSeen"
    private static let dedupeKey = "unstuck.notiflog.loggedKeys"
    private static let cap = 60
    private static let dedupeCap = 200

    private(set) var items: [Entry] = []
    private(set) var lastSeenMs: Double = 0
    /// Delivered-notification keys already logged (newest first, capped).
    private var loggedKeys: [String] = []

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.logKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            items = decoded
        }
        lastSeenMs = d.double(forKey: Self.seenKey)
        loggedKeys = d.stringArray(forKey: Self.dedupeKey) ?? []
    }

    /// True when an entry newer than the last center-open exists.
    var hasUnread: Bool { (items.first?.at ?? 0) > lastSeenMs }

    /// Record a shown notification (newest first), capped. `dedupeKey`
    /// (request identifier + fire date) keeps the willPresent / didReceive /
    /// delivered-sweep paths from triple-logging one notification.
    func add(kind: String?, title: String, body: String, deepLink: String?,
             at: Double = Date().timeIntervalSince1970 * 1000, dedupeKey: String? = nil) {
        if let dedupeKey {
            guard !loggedKeys.contains(dedupeKey) else { return }
            loggedKeys = Array(([dedupeKey] + loggedKeys).prefix(Self.dedupeCap))
        }
        let entry = Entry(id: newUUID(), kind: kind ?? "note", title: title, body: body,
                          deepLink: deepLink, at: at)
        items = Array(([entry] + items).prefix(Self.cap))
        persist()
    }

    /// Append a (foreground-presented / tapped / delivered-swept) system
    /// notification, parsed into its Sendable projection.
    func add(_ posted: PostedNotification) {
        add(kind: posted.kind, title: posted.title, body: posted.body,
            deepLink: posted.deepLink, at: posted.at, dedupeKey: posted.dedupeKey)
    }

    /// Catch up on notifications that fired while the app was away (local
    /// reminders / pushes delivered straight by the system). Called on
    /// launch + every foreground.
    func sweepDelivered() {
        Task { @MainActor in
            for posted in await Self.fetchDelivered() { add(posted) }
        }
    }

    /// Read + project the delivered notifications off the main actor
    /// (UNNotification isn't Sendable; only the projection crosses back).
    private nonisolated static func fetchDelivered() async -> [PostedNotification] {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return delivered.sorted { $0.date < $1.date }.map(PostedNotification.init)
    }

    /// Mark everything currently logged as seen (clears the unread badge).
    func markAllSeen() {
        lastSeenMs = Date().timeIntervalSince1970 * 1000
        UserDefaults.standard.set(lastSeenMs, forKey: Self.seenKey)
    }

    /// Wipe the log + unread marker. Called on sign-out so a different
    /// account on this device never sees the previous user's history.
    func clear() {
        items = []
        lastSeenMs = 0
        loggedKeys = []
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.logKey)
        d.removeObject(forKey: Self.seenKey)
        d.removeObject(forKey: Self.dedupeKey)
    }

    private func persist() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(items) { d.set(data, forKey: Self.logKey) }
        d.set(loggedKeys, forKey: Self.dedupeKey)
    }
}
