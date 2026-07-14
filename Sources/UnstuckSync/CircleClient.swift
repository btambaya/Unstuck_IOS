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

/// Result of a `circle_redeem` — the RPC returns jsonb {ok, error?, owner_name?}.
public struct CircleRedeemResult: Decodable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var ownerName: String?
    enum CodingKeys: String, CodingKey { case ok, error, ownerName = "owner_name" }

    public init(ok: Bool, error: String? = nil, ownerName: String? = nil) {
        self.ok = ok
        self.error = error
        self.ownerName = ownerName
    }
}

/// Outcome of a `circle-invite` edge-fn call. Uniform shape (never reveals
/// whether the email has an account): existing user → added; new person →
/// emailed + link; blank email → link only. `error` carries a server code
/// (e.g. "circle_full") on a non-2xx.
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

    /// Remove someone from your circle (also drops their task shares, server-side).
    /// RPC: circle_remove(p_id). Best-effort.
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

    /// Revoke a share. RPC: task_unshare(p_id). Best-effort.
    public func unshareTask(shareId: String) async {
        _ = try? await client.rpc("task_unshare", params: IdParams(p_id: shareId)).execute()
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

    /// Accrue a recipient's focus seconds onto the OWNER's shared task
    /// (Option B — the recipient's minutes reflect onto the one shared task).
    /// RPC: log_shared_focus(p_task_id, p_actual_sec, p_session_id) (migration
    /// 046). Allowed only for a partner/assign share (the server raises
    /// `not_allowed` for view) and no-ops for actualSec ≤ 0. IDEMPOTENT per
    /// `sessionId` — a re-fire with the same live-session id no-ops server-side,
    /// so a retry / double finalize can never double-count. Best-effort — the
    /// local recap stands regardless.
    public func logSharedFocus(taskId: String, actualSec: Int, sessionId: String) async {
        guard actualSec > 0 else { return }
        _ = try? await client.rpc("log_shared_focus",
            params: LogSharedFocusParams(p_task_id: taskId, p_actual_sec: actualSec,
                                         p_session_id: sessionId)).execute()
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
}

// MARK: - Wire shapes (internal → unit-tested via @testable)

// RPC params: snake_case `p_` names, exactly matching the migration signatures.
struct RedeemParams: Encodable { let p_code: String }
struct IdParams: Encodable { let p_id: String }
struct TaskIdParams: Encodable { let p_task_id: String }
struct TaskShareParams: Encodable { let p_task_id: String; let p_user: String; let p_level: String }
struct SetDoneParams: Encodable { let p_task_id: String; let p_done: Bool }
struct LogSharedFocusParams: Encodable { let p_task_id: String; let p_actual_sec: Int; let p_session_id: String }

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

    func model() -> CircleMember {
        CircleMember(id: id, relationshipLabel: relationship_label, level: level, status: status,
                     inviteCode: invite_code, memberUserId: member_user_id,
                     memberName: member_name, createdAt: created_at)
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

    func model() -> SharedWithMe {
        SharedWithMe(shareId: share_id, taskId: task_id, ownerName: owner_name,
                     level: ShareLevel(rawValue: level) ?? .view, title: title, done: done == true)
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
            createdAt: created_at)
    }
}
