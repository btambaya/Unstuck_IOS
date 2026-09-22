// CircleClient — the iOS port of the web sharing transport
// (lib/use-circle.ts + lib/use-task-shares.ts). All writes go through the
// SECURITY DEFINER RPCs (migrations 036 / 037 / 040 / 044) that enforce
// ownership + circle membership server-side; recipients read shared tasks via
// the tasks_shared_with_me() projection, never the tasks table (RLS).
//
// Mirrors CollectionShareClient's conventions: a Sendable struct over the shared
// SupabaseClient, Encodable param structs with snake_case `p_` names, and the
// same error tolerance — reads return [] on any failure; best-effort writes are
// fire-and-forget; only the meaningfully-failable writes (share / setDone) throw.

import Foundation
import Supabase
import UnstuckCore

/// Result of a `circle_redeem` — the RPC returns jsonb {ok, error?, owner_name?,
/// granted?: {task_id?, collection_id?}, already_connected?} (unified sharing
/// v1: a link can carry an item, granted in the same step).
public struct CircleRedeemResult: Decodable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var ownerName: String?
    /// The item the link carried and the server granted (migration 065).
    public var grantedTaskId: String?
    public var grantedCollectionId: String?
    /// The connection already existed; only the item (if any) was new.
    public var alreadyConnected: Bool?
    enum CodingKeys: String, CodingKey {
        case ok, error, ownerName = "owner_name", granted, alreadyConnected = "already_connected"
    }
    private enum GrantedKeys: String, CodingKey { case taskId = "task_id", collectionId = "collection_id" }

    public init(ok: Bool, error: String? = nil, ownerName: String? = nil,
                grantedTaskId: String? = nil, grantedCollectionId: String? = nil, alreadyConnected: Bool? = nil) {
        self.ok = ok
        self.error = error
        self.ownerName = ownerName
        self.grantedTaskId = grantedTaskId
        self.grantedCollectionId = grantedCollectionId
        self.alreadyConnected = alreadyConnected
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName)
        alreadyConnected = (try? c.decodeIfPresent(Bool.self, forKey: .alreadyConnected)) ?? nil
        if let g = try? c.nestedContainer(keyedBy: GrantedKeys.self, forKey: .granted) {
            grantedTaskId = (try? g.decodeIfPresent(String.self, forKey: .taskId)) ?? nil
            grantedCollectionId = (try? g.decodeIfPresent(String.self, forKey: .collectionId)) ?? nil
        }
    }

    /// True when the link carried an item that is now mine to see.
    public var grantedItem: Bool { grantedTaskId != nil || grantedCollectionId != nil }
}

/// Outcome of a `circle-invite` edge-fn call: existing user → added; new
/// person → emailed + link; blank email → link only. (The shapes differ, so
/// the answer does reveal an existing account — the old "uniform" claim was
/// false; audit 2026-09-22, C10.) `error` carries a server code (e.g.
/// "circle_full", or "blocked" when I blocked that person) on a non-2xx.
public struct CircleInviteResult: Decodable, Sendable, Equatable {
    public var ok: Bool?
    public var added: Bool?
    public var emailed: Bool?
    public var link: String?
    public var error: String?

    public init(ok: Bool? = nil, added: Bool? = nil, emailed: Bool? = nil, link: String? = nil, error: String? = nil) {
        self.ok = ok
        self.added = added
        self.emailed = emailed
        self.link = link
        self.error = error
    }
}

/// Outcome of a `log_shared_focus` ledger write — surfaced (never swallowed)
/// so the app layer can queue a durable retry or apply the owner fallback.
public enum SharedFocusLogResult: Sendable, Equatable {
    /// Landed (or no-op'd server-side — the ledger is idempotent per session).
    case ok
    /// The server rejected the caller (`not_allowed`): no share admits them
    /// anymore (revoked mid-session). Retrying can never succeed.
    case notAllowed
    /// Transport / transient failure — retry later (idempotent per sessionId).
    case failure
}

public struct CircleClient: Sendable {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    // ── Trusted circle (roster) ─────────────────────────────────────────────

    /// Your circle roster — active members (resolved names) + pending invites
    /// (with their code). RPC: circle_list(). Tolerant → [] on any failure.
    public func listCircle() async -> [CircleMember] {
        do {
            let rows: [CircleMemberRow] = try await client.rpc("circle_list").execute().value
            return rows.map { $0.model() }
        } catch { return [] }
    }

    /// Redeem an invite code → join that owner's circle. RPC: circle_redeem(p_code).
    public func redeem(code: String) async -> CircleRedeemResult {
        do {
            return try await client.rpc("circle_redeem",
                params: RedeemParams(p_code: code.trimmingCharacters(in: .whitespacesAndNewlines)))
                .execute().value
        } catch {
            return CircleRedeemResult(ok: false, error: "network")
        }
    }

    /// Remove someone from your circle. Server-side this also drops the task
    /// shares AND the list memberships between the two of you, in both
    /// directions, releasing the promotions they held (migration 075 — 066
    /// left every shared list shared; audit 2026-09-22, C11). A pending roster
    /// row is just cancelled. RPC: circle_remove(p_id). Best-effort.
    public func removeMember(id: String) async {
        _ = try? await client.rpc("circle_remove", params: IdParams(p_id: id)).execute()
    }

    /// Invite by email (we reach them ourselves) or blank for a shareable link.
    /// Edge fn: circle-invite. Body omits `email` when blank (→ link-only), 1:1
    /// with the web's `email: … || undefined`.
    public func invite(email: String?) async -> CircleInviteResult {
        let trimmed = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = InviteBody(email: trimmed.isEmpty ? nil : trimmed)
        do {
            return try await client.functions.invoke(
                "circle-invite", options: FunctionInvokeOptions(method: .post, body: body))
        } catch {
            // Surface a server error code (e.g. 409 { error: 'circle_full' }) from
            // the non-2xx body when present, mirroring the web hook.
            if case let FunctionsError.httpError(_, data) = error,
               let decoded = try? JSONDecoder().decode(CircleInviteResult.self, from: data) {
                return CircleInviteResult(ok: false, error: decoded.error ?? "invite_failed")
            }
            return CircleInviteResult(ok: false, error: "invite_failed")
        }
    }

    // ── Per-task sharing ────────────────────────────────────────────────────

    /// Share a task I own with a circle member at a level. RPC: task_share.
    /// Throws on a server error (bad_level / not_your_task / not_in_circle) so
    /// the UI can react — parity with the web hook's `throw new Error(...)`.
    public func shareTask(taskId: String, user: String, level: ShareLevel) async throws {
        _ = try await client.rpc("task_share",
            params: TaskShareParams(p_task_id: taskId, p_user: user, p_level: level.rawValue)).execute()
    }

    /// Revoke a share. RPC: task_unshare(p_id). Returns whether the server
    /// accepted the revoke — the assistant's `unshare_task` must not report
    /// "stopped sharing" over a failed RPC (the share sheet stays best-effort
    /// and refetches).
    @discardableResult
    public func unshareTask(shareId: String) async -> Bool {
        do {
            _ = try await client.rpc("task_unshare", params: IdParams(p_id: shareId)).execute()
            return true
        } catch { return false }
    }

    /// The shares on a single task I own — drives the share sheet.
    /// RPC: task_shares_for_task(p_task_id). Tolerant → [].
    public func sharesForTask(taskId: String) async -> [ShareForTask] {
        do {
            let rows: [ShareForTaskRow] = try await client.rpc(
                "task_shares_for_task", params: TaskIdParams(p_task_id: taskId)).execute().value
            return rows.map { $0.model() }
        } catch { return [] }
    }

    /// Tasks other people have shared WITH me. RPC: tasks_shared_with_me().
    /// Tolerant → []. (Recipients cannot read the raw task rows — this
    /// projection is the ONLY read path.)
    public func tasksSharedWithMe() async -> [SharedWithMe] {
        do {
            let rows: [SharedWithMeRow] = try await client.rpc("tasks_shared_with_me").execute().value
            return rows.map { $0.model() }
        } catch { return [] }
    }

    /// Every block (any share level) of every task shared with me, dated within
    /// [from, to] inclusive ('YYYY-MM-DD') — the recipient calendar's read-only
    /// layer. RPC: shared_task_blocks(p_from, p_to) (migration 052). The server
    /// caps the window at 62 days (`range_too_wide`) and never projects external
    /// blocks. Tolerant → [] on any failure (incl. a pre-052 server where the
    /// function doesn't exist yet).
    public func sharedTaskBlocks(from: String, to: String) async -> [SharedBlock] {
        do {
            let rows: [SharedBlockRow] = try await client.rpc(
                "shared_task_blocks", params: SharedBlocksParams(p_from: from, p_to: to)).execute().value
            return rows.map { $0.model() }
        } catch { return [] }
    }

    /// Complete/uncomplete a task shared with me (partner or assign only; the RPC
    /// rejects view). RPC: shared_task_set_done(p_task_id, p_done). Throws on the
    /// server's `not_allowed`, matching the web hook.
    public func setSharedTaskDone(taskId: String, done: Bool) async throws {
        _ = try await client.rpc("shared_task_set_done",
            params: SetDoneParams(p_task_id: taskId, p_done: done)).execute()
    }

    /// The read-only detail of a task shared WITH me, at ANY level (the recipient
    /// can't read the raw `tasks` row — RLS — so this SECURITY DEFINER window is
    /// the only path). RPC: shared_task_detail(p_task_id) → a single-row table.
    /// Tolerant → nil on any failure / no matching share.
    public func sharedTaskDetail(taskId: String) async -> SharedTaskDetail? {
        do {
            let rows: [SharedTaskDetailRow] = try await client.rpc(
                "shared_task_detail", params: TaskIdParams(p_task_id: taskId)).execute().value
            return rows.first?.model()
        } catch { return nil }
    }

    /// Accrue focus seconds onto the shared task's ledger (Option B / one true
    /// shared session — owner included since migration 047).
    /// RPC: log_shared_focus(p_task_id, p_actual_sec, p_session_id) (migration
    /// 046). The server raises `not_allowed` when no share admits the caller
    /// (revoked mid-session); no-ops for actualSec ≤ 0. IDEMPOTENT per
    /// `sessionId` — a re-fire with the same live-session id no-ops server-side,
    /// so a retry / double finalize can never double-count.
    ///
    /// SURFACES the outcome (not fire-and-forget): the app layer queues a
    /// durable retry on `.failure` (offline finish must not lose the accrual)
    /// and falls back to the owner's direct totalFocused bump on `.notAllowed`.
    @discardableResult
    public func logSharedFocus(taskId: String, actualSec: Int, sessionId: String) async -> SharedFocusLogResult {
        guard actualSec > 0 else { return .ok }
        do {
            _ = try await client.rpc("log_shared_focus",
                params: LogSharedFocusParams(p_task_id: taskId, p_actual_sec: actualSec,
                                             p_session_id: sessionId)).execute()
            return .ok
        } catch {
            if let pg = error as? PostgrestError {
                return pg.message.contains("not_allowed") ? .notAllowed : .failure
            }
            return .failure
        }
    }

    /// All of my outgoing shares, for the task-row badges. RPC:
    /// my_task_share_badges(). Tolerant → []. Flat list; group with
    /// `shareBadgesByTask(_:)` for the per-row map the web builds.
    public func shareBadges() async -> [ShareBadge] {
        do {
            let rows: [ShareBadgeRow] = try await client.rpc("my_task_share_badges").execute().value
            return rows.map { $0.model() }
        } catch { return [] }
    }

    /// The server's reason behind a thrown RPC / edge-fn call, for the shared
    /// `ShareFailure` copy: a SECURITY DEFINER function's `raise exception
    /// 'not_in_circle'` arrives as a PostgrestError whose message carries the
    /// code; a non-2xx edge-fn body carries `{error}` / `{reason}`; anything
    /// else (offline, timeout) is "network".
    public static func rpcFailureReason(_ error: Error) -> String {
        if let pg = error as? PostgrestError {
            let m = pg.message.lowercased()
            for code in ["not_in_circle", "not_your_task", "bad_level", "not_allowed", "unauthorized", "not_found", "self", "blocked"]
            where m.contains(code) { return code }
            return m.isEmpty ? "network" : m
        }
        if case let FunctionsError.httpError(_, data) = error {
            return TaskShareClient.failureReason(fromBody: data)
        }
        return "network"
    }

    /// Group a flat badge list by task id — the taskId → [badges] map the web's
    /// `useShareBadges` exposes for the row badges + delegation/co-focus.
    public static func shareBadgesByTask(_ badges: [ShareBadge]) -> [String: [ShareBadge]] {
        var map: [String: [ShareBadge]] = [:]
        for b in badges { map[b.taskId, default: []].append(b) }
        return map
    }

    // ── share-notify edge fn (best-effort) ──────────────────────────────────

    /// Notify a sharing event (in-app + push, pref-gated, server-revalidated).
    /// kind ∈ { task_share, task_done, session_start, session_end }; recipientId
    /// is required only for `task_share`. Fire-and-forget, like the web.
    public func shareNotify(kind: String, taskId: String, recipientId: String? = nil) async {
        try? await client.functions.invoke(
            "share-notify",
            options: FunctionInvokeOptions(method: .post,
                body: ShareNotifyBody(kind: kind, taskId: taskId, recipientId: recipientId)))
    }

    // ── Pending invites — Settings → People "Waiting to join" ───────────────
    // (unified sharing v1, spec §2 "One place for people")

    /// Every invite I sent that is still waiting: task_invites (`kind: task`),
    /// collection_invites (`collection`) and my own email circle invites
    /// (`circle`), newest first. RPC: my_pending_invites() → setof jsonb, each
    /// `{kind, id, itemId, itemName, email, access, createdAt}`. Tolerant → []
    /// on any failure — including a server where the RPC is not deployed yet
    /// (PostgREST 404) — so the People screen simply shows its roster then.
    public func myPendingInvites() async -> [PendingInvite] {
        do {
            let resp = try await client.rpc("my_pending_invites").execute()
            return Self.decodePendingInvites(resp.data)
        } catch { return [] }
    }

    /// Cancel one pending invite I sent. RPC: cancel_pending_invite(p_kind,
    /// p_id) → boolean. TRUE only when the server says a row was deleted — a
    /// missing RPC, a foreign row or a refusal all read as false so the UI
    /// never pretends.
    @discardableResult
    public func cancelPendingInvite(kind: PendingInviteKind, id: String) async -> Bool {
        do {
            let resp = try await client.rpc(
                "cancel_pending_invite",
                params: CancelPendingInviteParams(p_kind: kind.rawValue, p_id: id)).execute()
            return Self.decodeCancelPendingInvite(resp.data)
        } catch { return false }
    }

    // ── Blocks + recipient-side removal (migration 075) ──────────────────────
    // A block used to be a device-local email set that nothing on the server
    // read, and a recipient had no way to drop a task shared with them (audit
    // 2026-09-22, C10). These are the server-backed RPCs; every write is TRUE
    // only when the server says so (the scalar boolean is read by the same
    // parser as `cancel_pending_invite`), and a throw — offline, or a server
    // without 075 — is false, so the UI never claims a block that didn't land.

    /// Block someone by user id: the server cuts the connection, the task
    /// shares and list memberships both ways, and their pending invites to
    /// me, and refuses anything they share with me from then on.
    /// RPC: block_user(p_user) → boolean.
    @discardableResult
    public func blockUser(userId: String) async -> Bool {
        await booleanRPC("block_user", UserParams(p_user: userId))
    }

    /// Block the OWNER of a task shared with me — the recipient only knows the
    /// share id. RPC: block_task_sharer(p_share_id) → boolean.
    @discardableResult
    public func blockTaskSharer(shareId: String) async -> Bool {
        await booleanRPC("block_task_sharer", ShareIdParams(p_share_id: shareId))
    }

    /// Lift a block. Restores nothing that the block removed.
    /// RPC: unblock_user(p_user) → boolean.
    @discardableResult
    public func unblockUser(userId: String) async -> Bool {
        await booleanRPC("unblock_user", UserParams(p_user: userId))
    }

    /// Remove a task shared WITH me from my list (deletes MY recipient row;
    /// the owner isn't told). RPC: task_share_leave(p_share_id) → boolean.
    @discardableResult
    public func leaveSharedTask(shareId: String) async -> Bool {
        await booleanRPC("task_share_leave", ShareIdParams(p_share_id: shareId))
    }

    /// Everyone I blocked, newest first (display names only, never an email).
    /// RPC: my_blocked_users() → table(user_id, name, created_at). Tolerant →
    /// [] on any failure, including a server without 075.
    public func blockedUsers() async -> [BlockedUser] {
        do {
            let rows: [BlockedUserRow] = try await client.rpc("my_blocked_users").execute().value
            return rows.map { $0.model() }
        } catch { return [] }
    }

    private func booleanRPC(_ fn: String, _ params: some Encodable) async -> Bool {
        do {
            let resp = try await client.rpc(fn, params: params).execute()
            return Self.decodeCancelPendingInvite(resp.data)
        } catch { return false }
    }

    /// `my_pending_invites` body → models. Defensive by design (the RPC lands
    /// separately): the body must be a JSON array; an element that is not an
    /// object, has an unknown `kind`, or has no `id` is dropped WITHOUT taking
    /// the rest down; every other field is optional. Accepts the contract's
    /// camelCase keys and their snake_case twins. Order is preserved.
    static func decodePendingInvites(_ data: Data) -> [PendingInvite] {
        guard let rows = try? JSONDecoder().decode([Lenient<PendingInviteRow>].self, from: data) else { return [] }
        return rows.compactMap { $0.value?.model() }
    }

    /// `cancel_pending_invite` body → did a row go? PostgREST renders a scalar
    /// `boolean` as `true` / `false`; `[true]` and `{"ok":true}` are read too in
    /// case the function is ever reshaped. Anything else is false.
    static func decodeCancelPendingInvite(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "true" { return true }
        if let b = try? JSONDecoder().decode(Bool.self, from: data) { return b }
        if let arr = try? JSONDecoder().decode([Bool].self, from: data) { return arr.first == true }
        if let obj = try? JSONDecoder().decode([String: Lenient<Bool>].self, from: data) {
            return obj["ok"]?.value == true || obj["cancel_pending_invite"]?.value == true
        }
        return false
    }
}

// MARK: - Wire shapes (internal → unit-tested via @testable)

// RPC params: snake_case `p_` names, exactly matching the migration signatures.
struct RedeemParams: Encodable { let p_code: String }
struct IdParams: Encodable { let p_id: String }
struct TaskIdParams: Encodable { let p_task_id: String }
struct TaskShareParams: Encodable { let p_task_id: String; let p_user: String; let p_level: String }
struct SetDoneParams: Encodable { let p_task_id: String; let p_done: Bool }
struct LogSharedFocusParams: Encodable { let p_task_id: String; let p_actual_sec: Int; let p_session_id: String }
struct SharedBlocksParams: Encodable { let p_from: String; let p_to: String }
struct CancelPendingInviteParams: Encodable { let p_kind: String; let p_id: String }
/// block_user / unblock_user (migration 075).
struct UserParams: Encodable { let p_user: String }
/// block_task_sharer / task_share_leave (migration 075).
struct ShareIdParams: Encodable { let p_share_id: String }

/// One `my_blocked_users()` row (migration 075). `name` is the server's
/// `_display_name`; a null one reads "Someone" rather than failing the row.
struct BlockedUserRow: Decodable {
    let user_id: String
    let name: String?
    let created_at: String?

    func model() -> BlockedUser {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return BlockedUser(userId: user_id, name: n.isEmpty ? "Someone" : n, createdAt: created_at)
    }
}

/// One `my_pending_invites()` element — the contract's camelCase jsonb
/// (`itemId`, `itemName`, `createdAt`) with snake_case twins accepted, every
/// field optional, `id` read as a string OR a number. `model()` is nil when
/// the kind is unknown or the id is missing (the row can't be cancelled).
struct PendingInviteRow: Decodable {
    var kind: String?
    var id: String?
    var itemId: String?
    var itemName: String?
    var email: String?
    var access: String?
    var createdAt: String?

    private enum Keys: String, CodingKey {
        case kind, id, email, access
        case itemId, item_id, itemName, item_name, createdAt, created_at
        case inviteeEmail = "invitee_email", level, role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = Self.string(c, .kind)
        id = Self.string(c, .id)
        itemId = Self.string(c, .itemId) ?? Self.string(c, .item_id)
        itemName = Self.string(c, .itemName) ?? Self.string(c, .item_name)
        email = Self.string(c, .email) ?? Self.string(c, .inviteeEmail)
        access = Self.string(c, .access) ?? Self.string(c, .level) ?? Self.string(c, .role)
        createdAt = Self.string(c, .createdAt) ?? Self.string(c, .created_at)
    }

    /// A string, or a number rendered as one; nil for null / absent / other.
    private static func string(_ c: KeyedDecodingContainer<Keys>, _ key: Keys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    func model() -> PendingInvite? {
        guard let k = PendingInviteKind(rawValue: (kind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
              let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return PendingInvite(kind: k, inviteId: id,
                             itemId: itemId.flatMap { $0.isEmpty ? nil : $0 },
                             itemName: itemName.flatMap { $0.isEmpty ? nil : $0 },
                             email: (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                             access: access.flatMap { $0.isEmpty ? nil : $0 },
                             createdAt: createdAt.flatMap { $0.isEmpty ? nil : $0 })
    }
}

// Edge-fn bodies: camelCase, matching what the web sends + the functions read.
struct InviteBody: Encodable { let email: String? }
struct ShareNotifyBody: Encodable { let kind: String; let taskId: String; let recipientId: String? }

// RPC result rows: snake_case columns → camelCase models (mirrors the web map()).
struct CircleMemberRow: Decodable {
    let id: String
    let relationship_label: String?
    let level: String
    let status: String
    let invite_code: String?
    let member_user_id: String?
    let member_name: String?
    let created_at: String
    /// Unified sharing v1 (migration 065): the pending invite's address, so
    /// People can show WHO was invited. Optional — absent entirely on a
    /// pre-065 projection, null for link-only / active rows.
    let invitee_email: String?

    func model() -> CircleMember {
        CircleMember(id: id, relationshipLabel: relationship_label, level: level, status: status,
                     inviteCode: invite_code, memberUserId: member_user_id,
                     memberName: member_name, createdAt: created_at,
                     inviteeEmail: invitee_email.flatMap { $0.isEmpty ? nil : $0 })
    }
}

struct ShareForTaskRow: Decodable {
    let share_id: String
    let recipient_user_id: String
    let recipient_name: String
    let level: String

    func model() -> ShareForTask {
        ShareForTask(shareId: share_id, recipientUserId: recipient_user_id,
                     recipientName: recipient_name, level: ShareLevel(rawValue: level) ?? .view)
    }
}

struct SharedWithMeRow: Decodable {
    let share_id: String
    let task_id: String
    let owner_name: String
    let level: String
    let title: String
    let done: Bool?
    /// Migration 049. Optional (decodeIfPresent) so an un-migrated projection —
    /// which omits the column entirely — still decodes.
    let completed_at: String?
    /// Migration 052 — the owner's estimate/area + NEXT block. All optional for
    /// the same reason (a pre-052 projection omits every one of them), and the
    /// `next_*` set is null whenever nothing is scheduled.
    let estimate_min: Int?
    let life_area: String?
    let next_block_id: String?
    let next_date: String?
    let next_start_time: String?
    let next_duration_minutes: Int?
    let next_done: Bool?
    /// Migration 053 — the next block's start as an INSTANT (the owner's local
    /// date + start_time through the owner's notification timezone), the
    /// owner's `later` flag and `recurrence`. All optional (a pre-053
    /// projection omits them); a malformed recurrence blob decodes to nil
    /// instead of failing the row.
    let next_start_at: String?
    let later: Bool?
    let recurrence: Lenient<Recurrence>?

    func model() -> SharedWithMe {
        SharedWithMe(shareId: share_id, taskId: task_id, ownerName: owner_name,
                     level: ShareLevel(rawValue: level) ?? .view, title: title,
                     done: done == true, completedAt: completed_at,
                     estimateMin: estimate_min, lifeArea: life_area,
                     nextBlockId: next_block_id, nextDate: next_date, nextStartTime: next_start_time,
                     nextDurationMinutes: next_duration_minutes, nextDone: next_done,
                     nextStartAt: next_start_at, later: later, recurrence: recurrence?.value)
    }
}

/// A value that decodes to nil instead of throwing when the wire shape is not
/// what we expect — for optional jsonb projections (`recurrence`) that must
/// never take a whole row down with them.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}

/// One row of shared_task_blocks (migration 052 / 053). `date` is a Postgres
/// date → 'YYYY-MM-DD'; `start_time` the 'HH:MM' text cal_blocks stores;
/// `start_at` (053) the same slot as a timestamptz instant; the booleans are
/// nullable → coalesced false.
struct SharedBlockRow: Decodable {
    let block_id: String
    let task_id: String
    let share_id: String
    let level: String
    let owner_name: String?
    let title: String?
    let date: String
    let start_time: String
    let duration_minutes: Int?
    let done: Bool?
    let skipped: Bool?
    let kind: String?
    let start_at: String?

    func model() -> SharedBlock {
        SharedBlock(blockId: block_id, taskId: task_id, shareId: share_id,
                    level: ShareLevel(rawValue: level) ?? .view,
                    ownerName: owner_name ?? "Someone", title: title ?? "Untitled task",
                    date: date, startTime: start_time, durationMinutes: duration_minutes ?? 25,
                    done: done == true, skipped: skipped == true, kind: kind ?? "task",
                    startAt: start_at)
    }
}

struct ShareBadgeRow: Decodable {
    let task_id: String
    let level: String
    let recipient_name: String

    func model() -> ShareBadge {
        ShareBadge(taskId: task_id, level: ShareLevel(rawValue: level) ?? .view, recipientName: recipient_name)
    }
}

/// One row of shared_task_detail (migration 045). Top-level columns are
/// snake_case; `objectives` is a jsonb blob whose keys stay camelCase (like the
/// tasks TaskRow), and `tags` is a Postgres text[] → JSON array of strings.
/// timestamptz columns arrive as ISO strings. All nullable → tolerant defaults.
struct SharedTaskDetailRow: Decodable {
    let task_id: String
    let owner_name: String?
    let level: String
    let name: String?
    let done: Bool?
    let estimate_min: Int?
    let total_focused: Int?
    let life_area: String?
    let priority: String?
    let tags: [String]?
    let objectives: [Objective]?
    let due_at: String?
    let created_at: String?
    /// Migration 052 — the owner's NEXT block (nil pre-052 / unscheduled).
    let next_block_id: String?
    let next_date: String?
    let next_start_time: String?
    let next_duration_minutes: Int?
    let next_done: Bool?
    /// Migration 053 (nil pre-053).
    let next_start_at: String?
    let later: Bool?

    func model() -> SharedTaskDetail {
        SharedTaskDetail(
            taskId: task_id,
            ownerName: owner_name ?? "Someone",
            level: ShareLevel(rawValue: level) ?? .view,
            name: name ?? "Untitled task",
            done: done == true,
            estimateMin: estimate_min ?? 25,
            totalFocused: total_focused ?? 0,
            lifeArea: life_area,
            priority: priority.flatMap { Priority(rawValue: $0) },
            tags: tags ?? [],
            objectives: objectives ?? [],
            dueAt: due_at,
            createdAt: created_at,
            nextBlockId: next_block_id,
            nextDate: next_date,
            nextStartTime: next_start_time,
            nextDurationMinutes: next_duration_minutes,
            nextDone: next_done,
            nextStartAt: next_start_at,
            later: later)
    }
}
