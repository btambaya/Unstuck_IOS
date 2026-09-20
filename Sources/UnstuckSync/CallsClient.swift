// CallsClient — "Unstuck calls you" (ios-gateway-plan Part B, C1/C2).
// The client half of the call_requests contract: the owner-RLS table the
// user books calls into (from the assistant's request_call / cancel_call /
// update_call / get_calls, the task editor's "Call me about this", and the
// Settings "Test call now"), plus the `call-outcome` edge fn the CallKit path
// reports every end state to (answered / declined / missed / busy / snoozed /
// done / stale).
//
// Server contract (built concurrently — code against it, don't infer):
//   public.call_requests(id, user_id, task_id?, block_id?, call_at timestamptz,
//     lead_min?, label, notes text[], status, snooze_until, outcome_notes text[],
//     call_id, attempts, kind, retries, created_at, updated_at)
//   status: scheduled|calling|answered|declined|missed|busy|snoozed|stale|cancelled|done
//   kind (migration 072): requested|test|morning|evening|after_block — who booked
//     it (the user / the test button / the proactive dispatcher); the call
//     script opens differently per kind. retries: automatic re-rings after a miss.
//   call-outcome (user JWT): { callId, outcome, snoozeMinutes?, outcomeNotes?[], callKitId? }
//     → { ok, retry } — `retry: true` means the server re-arms the call for one
//     automatic ring-back (a first miss, kind ≠ test), so the phone must NOT
//     post its local "I called about X" notification for that miss.
//
// LOCAL MIRROR (CallRequestsMirror.swift): the rows also live in GRDB
// (`call_requests`), hydrated, mirrored via realtime and caught up by cursor
// like every other synced table, so get_calls / the task editor / the deep
// link read offline and see status changes live.
// `callId` on call-outcome is the id the VoIP push carried (payload.callId),
// passed through verbatim — the server resolves it to the row; `callKitId` is
// the CXCall UUID the phone presented (stored on the row as `call_id`).
//
// Writes that can lose a race (update / cancel) are compare-and-set on the
// row still being LIVE and return the row the server actually wrote — nil
// means zero rows matched (the call was cancelled / rang / finished
// underneath the caller), and callers must say so rather than echo stale state.

import Foundation
import Supabase

/// What the phone reports back after a call attempt (call-outcome `outcome`).
public enum CallOutcome: String, Sendable, Codable, Equatable {
    case answered, declined, missed, busy, snoozed, done, stale
}

/// call-outcome refused a report FOR GOOD: the row is gone (404 / 410), isn't
/// the caller's, or the body is malformed (400 / 422) — a 4xx other than
/// 401 (token refresh), 408 and 429 (try again). Retrying can never succeed,
/// so the outcome reporter drops the item instead of blocking the queue.
/// Transport failures, 5xx and auth refreshes stay plain errors (transient).
public struct CallOutcomeRejected: Error, Equatable, Sendable {
    public let status: Int
    public let message: String?

    public init(status: Int, message: String? = nil) {
        self.status = status
        self.message = message
    }

    /// The 4xx family minus the three that mean "later": 401 / 408 / 429.
    public static func isPermanent(status: Int) -> Bool {
        (400..<500).contains(status) && ![401, 408, 429].contains(status)
    }
}

/// What `call-outcome` answered — `{ ok, status, retry, snoozeUntil? }` on
/// every outcome. `retry` is true ONLY for a missed call the server re-armed
/// for one automatic ring-back 5 min later (migration 072): the phone then
/// skips its local "I called about X" notification — the second miss (or the
/// answer) settles it. `status` is the row's status after the report,
/// `snoozeUntil` the re-ring instant when one was scheduled. A pre-072 server
/// answers no `retry` → false.
public struct CallOutcomeReceipt: Sendable, Equatable, Codable {
    public var ok: Bool
    public var retry: Bool
    public var status: String?
    public var snoozeUntil: String?

    public init(ok: Bool = true, retry: Bool = false, status: String? = nil, snoozeUntil: String? = nil) {
        self.ok = ok
        self.retry = retry
        self.status = status
        self.snoozeUntil = snoozeUntil
    }

    enum CodingKeys: String, CodingKey { case ok, retry, status, snoozeUntil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? true
        retry = (try? c.decodeIfPresent(Bool.self, forKey: .retry)) ?? false
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        snoozeUntil = try? c.decodeIfPresent(String.self, forKey: .snoozeUntil)
    }
}

/// A `call_requests` row as the client reads it (snake_case ↔ camelCase at
/// this boundary, like DbRowCodec). Tolerant decoding: array columns default
/// to `[]`, so a row written by another platform without notes still loads.
public struct CallRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var userId: String?
    public var taskId: String?
    public var blockId: String?
    /// ISO-8601 timestamptz (absolute; the server re-derives it from the block
    /// when `leadMin` is set and the block moves).
    public var callAt: String
    public var leadMin: Int?
    public var label: String
    public var notes: [String]
    public var status: String
    public var snoozeUntil: String?
    public var outcomeNotes: [String]
    public var callId: String?
    public var attempts: Int?
    /// Who booked it: requested | test | morning | evening | after_block
    /// (migration 072). Rows from before the column default to `requested`.
    public var kind: String
    /// Automatic re-rings after a miss (migration 072); nil before the column.
    public var retries: Int?
    public var createdAt: String?
    public var updatedAt: String?

    /// The `kind` values the server writes (`request_call` / the task editor →
    /// requested, the test button → test, the proactive dispatcher → the rest).
    public static let kinds = ["requested", "test", "morning", "evening", "after_block"]
    public static let defaultKind = "requested"

    /// Web parity (lib/calls/types.ts LIVE_CALL_STATUSES): a call that is
    /// ringing right now still "is coming" — get_calls lists it ("· ringing
    /// now") and it counts as a duplicate anchor.
    public static let liveStatuses = ["scheduled", "snoozed", "calling"]
    /// Rows whose NOTES / LABEL may still change: the live ones plus a call
    /// that has been ANSWERED and is in progress — "add 'bring the contract'
    /// to the notes and call me back in 20" edits the row mid-conversation so
    /// the snoozed call-back reads the new notes. Its TIME may not move (see
    /// `reschedulableStatuses`).
    public static let editableStatuses = ["scheduled", "snoozed", "calling", "answered"]
    /// Rows whose TIME may move. A ringing / answered call is NOT one of them:
    /// re-arming it to `scheduled` would be overwritten by the phone's own
    /// outcome report a moment later (missed / done), silently discarding the
    /// reschedule the tool just confirmed.
    public static let reschedulableStatuses = ["scheduled", "snoozed"]

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case taskId = "task_id"
        case blockId = "block_id"
        case callAt = "call_at"
        case leadMin = "lead_min"
        case label, notes, status
        case snoozeUntil = "snooze_until"
        case outcomeNotes = "outcome_notes"
        case callId = "call_id"
        case attempts, kind, retries
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(id: String, userId: String? = nil, taskId: String? = nil, blockId: String? = nil,
                callAt: String, leadMin: Int? = nil, label: String, notes: [String] = [],
                status: String = "scheduled", snoozeUntil: String? = nil, outcomeNotes: [String] = [],
                callId: String? = nil, attempts: Int? = nil, kind: String = CallRequest.defaultKind,
                retries: Int? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.userId = userId; self.taskId = taskId; self.blockId = blockId
        self.callAt = callAt; self.leadMin = leadMin; self.label = label; self.notes = notes
        self.status = status; self.snoozeUntil = snoozeUntil; self.outcomeNotes = outcomeNotes
        self.callId = callId; self.attempts = attempts; self.kind = kind; self.retries = retries
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        blockId = try c.decodeIfPresent(String.self, forKey: .blockId)
        callAt = try c.decode(String.self, forKey: .callAt)
        leadMin = try c.decodeIfPresent(Int.self, forKey: .leadMin)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "scheduled"
        snoozeUntil = try c.decodeIfPresent(String.self, forKey: .snoozeUntil)
        outcomeNotes = try c.decodeIfPresent([String].self, forKey: .outcomeNotes) ?? []
        callId = try c.decodeIfPresent(String.self, forKey: .callId)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts)
        let k = (try c.decodeIfPresent(String.self, forKey: .kind) ?? "").trimmingCharacters(in: .whitespaces)
        kind = k.isEmpty ? Self.defaultKind : k
        retries = try c.decodeIfPresent(Int.self, forKey: .retries)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// `callAt` as a Date (nil if the server sent something unparseable).
    public var callAtDate: Date? { CallsClient.parseISO(callAt) }
    /// The effective next ring time: `snoozeUntil` when snoozed, else `callAt`.
    public var effectiveAtDate: Date? {
        if status == "snoozed", let s = snoozeUntil, let d = CallsClient.parseISO(s) { return d }
        return callAtDate
    }
    public var isLive: Bool { Self.liveStatuses.contains(status) }
    /// Notes / label may still change (live, or answered and in progress).
    public var isEditable: Bool { Self.editableStatuses.contains(status) }
    /// The call is ringing or in progress right now: notes/label edits land,
    /// a time change is refused.
    public var isInProgress: Bool { status == "calling" || status == "answered" }
}

public struct CallsClient: Sendable {
    let client: SupabaseClient
    public init(_ client: SupabaseClient) { self.client = client }

    // MARK: - outcome (the CallKit path → call-outcome edge fn)

    /// Report how a call ended. `callId` is the id the push carried, verbatim.
    /// `snoozeMinutes` only with `.snoozed`; `outcomeNotes` are free-text lines
    /// the conversation produced (what got ticked off / added).
    ///
    /// Throws `CallOutcomeRejected` for a PERMANENT refusal (404 not_found /
    /// 410 / 400 / 422 …) so the reporter can drop the item; every other
    /// failure (transport, 5xx, 401 refresh, 429) is rethrown as-is → retry.
    /// Returns the server's `{ ok, retry }` (an empty / older body decodes as
    /// `retry: false`).
    @discardableResult
    public func outcome(callId: String, outcome: CallOutcome,
                        snoozeMinutes: Int? = nil, outcomeNotes: [String]? = nil,
                        callKitId: String? = nil) async throws -> CallOutcomeReceipt {
        struct Body: Encodable {
            let callId: String
            let outcome: String
            let snoozeMinutes: Int?
            let outcomeNotes: [String]?
            let callKitId: String?
        }
        do {
            let data: Data = try await client.functions.invoke(
                "call-outcome",
                options: FunctionInvokeOptions(method: .post, body: Body(
                    callId: callId, outcome: outcome.rawValue,
                    snoozeMinutes: snoozeMinutes, outcomeNotes: outcomeNotes,
                    callKitId: callKitId))) { data, _ in data }
            return Self.decodeReceipt(data)
        } catch let FunctionsError.httpError(code, data) where CallOutcomeRejected.isPermanent(status: code) {
            throw CallOutcomeRejected(status: code, message: String(data: data, encoding: .utf8))
        }
    }

    /// `{ ok, retry }` from the response body; anything unparseable (an
    /// empty 2xx from a pre-072 server) is "no retry" — the notification posts.
    public static func decodeReceipt(_ data: Data) -> CallOutcomeReceipt {
        guard !data.isEmpty, let r = try? JSONDecoder().decode(CallOutcomeReceipt.self, from: data) else {
            return CallOutcomeReceipt()
        }
        return r
    }

    // MARK: - reads

    /// The user's calls. `upcoming` (default) = status in scheduled/snoozed,
    /// soonest first; otherwise the 50 most recent rows of any status.
    public func list(upcoming: Bool = true) async throws -> [CallRequest] {
        if upcoming {
            return try await client.from("call_requests")
                .select()
                .in("status", values: CallRequest.liveStatuses)
                .order("call_at", ascending: true)
                .execute().value
        }
        return try await client.from("call_requests")
            .select()
            .order("call_at", ascending: false)
            .limit(50)
            .execute().value
    }

    public func get(id: String) async throws -> CallRequest? {
        let rows: [CallRequest] = try await client.from("call_requests")
            .select().eq("id", value: id).limit(1).execute().value
        return rows.first
    }

    /// The live (scheduled/snoozed) call anchored to a task, if any — "one
    /// call per anchor" is enforced on the write side with this read.
    public func forTask(taskId: String) async throws -> CallRequest? {
        let rows: [CallRequest] = try await client.from("call_requests")
            .select()
            .eq("task_id", value: taskId)
            .in("status", values: CallRequest.liveStatuses)
            .order("call_at", ascending: true)
            .limit(1)
            .execute().value
        return rows.first
    }

    // MARK: - writes

    /// Book a call (upsert on id). Returns the row as stored. `kind` is
    /// `requested` for everything a user books; the Settings test button
    /// passes `test` (the script's test-call opening; never auto-retried).
    @discardableResult
    public func create(id: String = UUID().uuidString.lowercased(), userId: String,
                       taskId: String? = nil, blockId: String? = nil,
                       callAt: Date, leadMin: Int? = nil, label: String, notes: [String],
                       kind: String = CallRequest.defaultKind) async throws -> CallRequest {
        struct Row: Encodable {
            let id: String
            let user_id: String
            let task_id: String?
            let block_id: String?
            let call_at: String
            let lead_min: Int?
            let label: String
            let notes: [String]
            let status: String
            let kind: String
            let updated_at: String
        }
        let now = Self.iso(Date())
        let rows: [CallRequest] = try await client.from("call_requests")
            .upsert(Row(id: id, user_id: userId, task_id: taskId, block_id: blockId,
                        call_at: Self.iso(callAt), lead_min: leadMin, label: label, notes: notes,
                        status: "scheduled", kind: kind, updated_at: now), onConflict: "id")
            .select()
            .execute().value
        return rows.first ?? CallRequest(id: id, userId: userId, taskId: taskId, blockId: blockId,
                                         callAt: Self.iso(callAt), leadMin: leadMin, label: label, notes: notes,
                                         kind: kind, updatedAt: now)
    }

    /// Patch a booked call — only the given fields change. Re-arms a snoozed
    /// row back to `scheduled` when its time is moved. Compare-and-set on the
    /// row's status: a notes/label-only edit lands on any EDITABLE row (live,
    /// or answered and in progress — mid-call "change the notes for later");
    /// a TIME change (callAt / block / lead) lands only on a `scheduled` /
    /// `snoozed` row — never on one that is ringing or answered, whose status
    /// the phone's outcome report is about to settle (re-arming it to
    /// `scheduled` from here would silently lose that reschedule when the
    /// `missed` / `done` report overwrote it). nil ⇒ nothing was written (it
    /// changed underneath, or the time change was refused).
    @discardableResult
    public func update(id: String, callAt: Date? = nil, blockId: String?? = nil, leadMin: Int?? = nil,
                       label: String? = nil, notes: [String]? = nil) async throws -> CallRequest? {
        var patch: [String: AnyJSON] = ["updated_at": .string(Self.iso(Date()))]
        if let callAt {
            patch["call_at"] = .string(Self.iso(callAt))
            patch["status"] = .string("scheduled")
            patch["snooze_until"] = .null
        }
        if let blockId { patch["block_id"] = blockId.map { .string($0) } ?? .null }
        if let leadMin { patch["lead_min"] = leadMin.map { .integer($0) } ?? .null }
        if let label { patch["label"] = .string(label) }
        if let notes { patch["notes"] = .array(notes.map { .string($0) }) }
        let rows: [CallRequest] = try await client.from("call_requests")
            .update(patch)
            .eq("id", value: id)
            .in("status", values: Self.statusesAccepting(timeChange: callAt != nil || blockId != nil || leadMin != nil))
            .select()
            .execute().value
        return rows.first
    }

    /// The compare-and-set status list for an `update`: the reschedulable
    /// rows when the patch moves the call, the editable rows otherwise.
    public static func statusesAccepting(timeChange: Bool) -> [String] {
        timeChange ? CallRequest.reschedulableStatuses : CallRequest.editableStatuses
    }

    /// Cancel a booked call (status → cancelled; the row stays for history).
    /// Compare-and-set on the row still being live: the cancelled row, or nil
    /// when zero rows matched (already cancelled / rang / done elsewhere).
    @discardableResult
    public func cancel(id: String) async throws -> CallRequest? {
        let patch: [String: AnyJSON] = [
            "status": .string("cancelled"),
            "updated_at": .string(Self.iso(Date())),
        ]
        let rows: [CallRequest] = try await client.from("call_requests")
            .update(patch)
            .eq("id", value: id)
            .in("status", values: CallRequest.liveStatuses)
            .select()
            .execute().value
        return rows.first
    }

    // MARK: - time helpers

    // THREAD SAFETY of the shared formatters (here and in the app's
    // IncomingCallPayload): ISO8601DateFormatter is documented thread-safe —
    // like DateFormatter since iOS 7 — once configured. Both instances are
    // configured exactly once inside their static initializer and never
    // mutated afterwards, so `nonisolated(unsafe)` only opts them out of the
    // Swift 6 global-actor check; there is no data race to guard.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO-8601 with fractional seconds, UTC — the form every other writer uses.
    public static func iso(_ date: Date) -> String { isoFractional.string(from: date) }

    /// Parse a server timestamptz. PostgREST emits `2026-09-02T14:45:00+00:00`
    /// (no fractional seconds, `+00:00` offset) — both formatter variants
    /// accept that; the fractional form covers rows we wrote ourselves.
    public static func parseISO(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        // PostgREST sometimes emits fractional seconds with a +00:00 offset,
        // which ISO8601DateFormatter handles; a bare "YYYY-MM-DD HH:MM:SS+00"
        // (psql style) doesn't come through PostgREST, so no further fallback.
        return nil
    }
}
