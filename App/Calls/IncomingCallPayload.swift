// The VoIP-push payload for a requested call (server `send-call`), and the
// CallSession the CallKit path + the voice launcher share.
//
// Contract (send-call, APNs VoIP push, topic io.unstucknow.app.voip):
//   { kind:'call', callId, label, notes:[String], taskId?, blockId?, taskName?,
//     startTime?, firstAction?, captures:[String], name?,
//     callKind?: requested|test|morning|evening|after_block, endTime?: "HH:MM" }
// The same shape rides the fallback time-sensitive ALERT push (custom keys at
// the top level next to `aps`, or under `data`) when no VoIP token is
// registered — `init?(dictionary:)` accepts both.
//
// WHICH CALL THIS IS (calls build-out, migration 072): the row's `kind`
// travels as `callKind`; a server that instead overwrites the push's own
// `kind` discriminator with the row's kind is accepted too (`kind` ∈ the five
// call kinds ⇒ a call push of that kind — `isCallPush`). Unknown / absent ⇒
// `requested`, the only kind there was before. `endTime` (after_block) is
// the block's end, "HH:MM" local, for "<task> was on till <time>".

import Foundation

/// Who booked the call — the script opens differently per kind.
enum CallKind: String, Codable, Equatable, Sendable, CaseIterable {
    case requested, test, morning, evening, afterBlock = "after_block"

    /// Tolerant: nil / blank / unknown → `.requested`.
    init(raw: String?) {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = CallKind(rawValue: t) ?? .requested
    }
}

struct IncomingCallPayload: Codable, Equatable, Sendable {
    /// The push discriminator (`'call'`), or — from a server that reuses the
    /// key — the call kind itself. `isCallPush` accepts both.
    var kind: String?
    /// The `call_requests.kind` this ring is for (nil ⇒ requested).
    var callKind: String?
    /// after_block: the block's end, "HH:MM" local (or ISO / "YYYY-MM-DD HH:MM").
    var endTime: String?
    var callId: String
    var label: String
    var notes: [String]
    var taskId: String?
    var blockId: String?
    var taskName: String?
    /// The anchored block's start — ISO-8601, or "HH:MM" (today) / "YYYY-MM-DD HH:MM" (local).
    var startTime: String?
    var firstAction: String?
    var captures: [String]
    /// The user's preferred name (what the call opens with).
    var name: String?

    init(kind: String? = "call", callId: String, label: String, notes: [String] = [],
         taskId: String? = nil, blockId: String? = nil, taskName: String? = nil,
         startTime: String? = nil, firstAction: String? = nil, captures: [String] = [], name: String? = nil,
         callKind: String? = nil, endTime: String? = nil) {
        self.kind = kind; self.callId = callId; self.label = label; self.notes = notes
        self.taskId = taskId; self.blockId = blockId; self.taskName = taskName
        self.startTime = startTime; self.firstAction = firstAction; self.captures = captures; self.name = name
        self.callKind = callKind; self.endTime = endTime
    }

    /// The resolved kind: `callKind` when given, else `kind` when the server
    /// put the row's kind there, else requested.
    var resolvedKind: CallKind {
        if let k = callKind, CallKind(rawValue: k.lowercased()) != nil { return CallKind(raw: k) }
        if let k = kind, CallKind(rawValue: k.lowercased()) != nil { return CallKind(raw: k) }
        return .requested
    }

    /// A push's `kind` names a call: the `'call'` discriminator, or one of the
    /// five call kinds (a server that writes the row's kind into `kind`).
    static func isCallPush(kind: String?) -> Bool {
        guard let k = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !k.isEmpty else { return false }
        return k == "call" || CallKind(rawValue: k) != nil
    }

    /// Tolerant decode: `callId` + a non-empty `label` are REQUIRED (a push
    /// without them is "invalid" — the coordinator still reports a CallKit
    /// call, then ends it as failed); every array defaults to `[]`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        let id = (try c.decodeIfPresent(String.self, forKey: .callId) ?? "").trimmingCharacters(in: .whitespaces)
        let lbl = (try c.decodeIfPresent(String.self, forKey: .label) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !lbl.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "callId + label required"))
        }
        callId = id
        label = lbl
        notes = Self.cleanLines(try c.decodeIfPresent([String].self, forKey: .notes) ?? [])
        taskId = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .taskId))
        blockId = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .blockId))
        taskName = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .taskName))
        startTime = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .startTime))
        firstAction = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .firstAction))
        captures = Self.cleanLines(try c.decodeIfPresent([String].self, forKey: .captures) ?? [])
        name = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .name))
        callKind = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .callKind))
        endTime = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .endTime))
    }

    /// Decode from a PushKit `dictionaryPayload` / a UNNotification `userInfo`.
    /// Looks at the top level first, then under `data` (the alert-push
    /// fallback nests the custom keys there). nil ⇒ invalid payload.
    init?(dictionary raw: [AnyHashable: Any]) {
        let top = Self.stringKeyed(raw)
        let candidates: [[String: Any]] = [top, (top["data"] as? [AnyHashable: Any]).map(Self.stringKeyed) ?? [:]]
        for dict in candidates where dict["callId"] != nil {
            guard JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let decoded = try? JSONDecoder().decode(IncomingCallPayload.self, from: data) else { continue }
            self = decoded
            return
        }
        return nil
    }

    private static func stringKeyed(_ d: [AnyHashable: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in d { if let ks = k as? String { out[ks] = v } }
        return out
    }
    private static func blankToNil(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
    private static func cleanLines(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// One presented call: the payload + what the script and the launcher derive
/// from it. Value type so the coordinator, the script and the tests can hold
/// it without CallKit.
struct CallSession: Equatable, Sendable {
    /// The CallKit call UUID. The server mints `callId` as a UUID per ring
    /// attempt; a non-UUID id falls back to a random UUID (CallKit needs one
    /// per call) while `callId` stays what the server sent for call-outcome.
    let uuid: UUID
    let payload: IncomingCallPayload
    let receivedAt: Date

    init(payload: IncomingCallPayload, receivedAt: Date = Date()) {
        self.payload = payload
        self.receivedAt = receivedAt
        self.uuid = UUID(uuidString: payload.callId) ?? UUID()
    }

    var callId: String { payload.callId }
    var label: String { payload.label }
    var notes: [String] { payload.notes }
    var taskId: String? { payload.taskId }
    var blockId: String? { payload.blockId }
    var taskName: String? { payload.taskName }
    var firstAction: String? { payload.firstAction }
    var captures: [String] { payload.captures }
    /// Who booked it — what the script opens with.
    var kind: CallKind { payload.resolvedKind }
    /// after_block: the block's end as a Date (same forms as `startTime`).
    var endDate: Date? { CallSession.parseStart(payload.endTime, relativeTo: receivedAt) }
    /// after_block: "till 11:30am" — the end the way people say it; nil when
    /// the push carried none.
    var spokenEnd: String? {
        guard let raw = payload.endTime?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if CallSettings.minutesOfDay(raw) != nil { return CallSettings.spokenTime(raw) }
        guard let d = endDate else { return nil }
        return CallSettings.spokenTime(CallSettings.hhmm(d))
    }
    /// The name the call opens with — the server's preferred name, first
    /// token only (a full "Ahmad Tambaya" reads wrong on a phone call).
    var preferredName: String? {
        guard let n = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        return n.split(whereSeparator: { $0 == " " }).first.map(String.init)
    }

    /// The anchored block's start as a Date (see `IncomingCallPayload.startTime`).
    var startDate: Date? { CallSession.parseStart(payload.startTime, relativeTo: receivedAt) }

    /// Whole minutes from `now` until the block starts (negative once it has
    /// started); nil when the call isn't anchored to a timed block.
    func minutesUntilStart(now: Date) -> Int? {
        guard let s = startDate else { return nil }
        return Int((s.timeIntervalSince(now) / 60).rounded())
    }

    // Configured once, never mutated → thread-safe (see the note in CallsClient).
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// ISO-8601 → absolute; "YYYY-MM-DD HH:MM" / "YYYY-MM-DDTHH:MM" → local;
    /// "HH:MM" → that time on the day the push arrived (local).
    static func parseStart(_ raw: String?, relativeTo anchor: Date, calendar: Calendar = .current) -> Date? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = isoFractional.date(from: s) ?? isoPlain.date(from: s) { return d }
        let parts = s.replacingOccurrences(of: "T", with: " ").split(separator: " ", omittingEmptySubsequences: true)
        var comps = calendar.dateComponents([.year, .month, .day], from: anchor)
        var timePart: Substring? = parts.first
        if parts.count >= 2 {
            let ymd = parts[0].split(separator: "-").compactMap { Int($0) }
            guard ymd.count == 3 else { return nil }
            comps.year = ymd[0]; comps.month = ymd[1]; comps.day = ymd[2]
            timePart = parts[1]
        }
        guard let t = timePart else { return nil }
        let hm = t.split(separator: ":").compactMap { Int($0) }
        guard hm.count >= 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]) else { return nil }
        comps.hour = hm[0]; comps.minute = hm[1]; comps.second = 0
        return calendar.date(from: comps)
    }
}
