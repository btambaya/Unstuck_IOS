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
//     call_id, attempts, created_at, updated_at)
//   status: scheduled|calling|answered|declined|missed|busy|snoozed|stale|cancelled|done
//   call-outcome (user JWT): { callId, outcome, snoozeMinutes?, outcomeNotes?[], callKitId? }
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
    public var createdAt: String?
    public var updatedAt: String?

    /// Web parity (lib/calls/types.ts LIVE_CALL_STATUSES): a call that is
    /// ringing right now still "is coming" — get_calls lists it ("· ringing
    /// now") and it counts as a duplicate anchor.
    public static let liveStatuses = ["scheduled", "snoozed", "calling"]

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
        case attempts
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(id: String, userId: String? = nil, taskId: String? = nil, blockId: String? = nil,
                callAt: String, leadMin: Int? = nil, label: String, notes: [String] = [],
                status: String = "scheduled", snoozeUntil: String? = nil, outcomeNotes: [String] = [],
                callId: String? = nil, attempts: Int? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.userId = userId; self.taskId = taskId; self.blockId = blockId
        self.callAt = callAt; self.leadMin = leadMin; self.label = label; self.notes = notes
        self.status = status; self.snoozeUntil = snoozeUntil; self.outcomeNotes = outcomeNotes
        self.callId = callId; self.attempts = attempts; self.createdAt = createdAt; self.updatedAt = updatedAt
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
}

public struct CallsClient: Sendable {
    let client: SupabaseClient
    public init(_ client: SupabaseClient) { self.client = client }

    // MARK: - outcome (the CallKit path → call-outcome edge fn)

    /// Report how a call ended. `callId` is the id the push carried, verbatim.
    /// `snoozeMinutes` only with `.snoozed`; `outcomeNotes` are free-text lines
    /// the conversation produced (what got ticked off / added).
    public func outcome(callId: String, outcome: CallOutcome,
                        snoozeMinutes: Int? = nil, outcomeNotes: [String]? = nil,
                        callKitId: String? = nil) async throws {
        struct Body: Encodable {
            let callId: String
            let outcome: String
            let snoozeMinutes: Int?
            let outcomeNotes: [String]?
            let callKitId: String?
        }
        try await client.functions.invoke(
            "call-outcome",
            options: FunctionInvokeOptions(method: .post, body: Body(
                callId: callId, outcome: outcome.rawValue,
                snoozeMinutes: snoozeMinutes, outcomeNotes: outcomeNotes,
                callKitId: callKitId)))
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

    /// Book a call (upsert on id). Returns the row as stored.
    @discardableResult
    public func create(id: String = UUID().uuidString.lowercased(), userId: String,
                       taskId: String? = nil, blockId: String? = nil,
                       callAt: Date, leadMin: Int? = nil, label: String, notes: [String]) async throws -> CallRequest {
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
            let updated_at: String
        }
        let now = Self.iso(Date())
        let rows: [CallRequest] = try await client.from("call_requests")
            .upsert(Row(id: id, user_id: userId, task_id: taskId, block_id: blockId,
                        call_at: Self.iso(callAt), lead_min: leadMin, label: label, notes: notes,
                        status: "scheduled", updated_at: now), onConflict: "id")
            .select()
            .execute().value
        return rows.first ?? CallRequest(id: id, userId: userId, taskId: taskId, blockId: blockId,
                                         callAt: Self.iso(callAt), leadMin: leadMin, label: label, notes: notes)
    }

    /// Patch a booked call — only the given fields change. Re-arms a snoozed
    /// row back to `scheduled` when its time is moved. Compare-and-set on the
    /// row still being live: nil ⇒ nothing was written (it changed underneath).
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
            .in("status", values: CallRequest.liveStatuses)
            .select()
            .execute().value
        return rows.first
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
