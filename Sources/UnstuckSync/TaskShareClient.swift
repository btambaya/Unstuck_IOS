// TaskShareClient — the `share-task` edge function (unified sharing v1,
// docs/unified-sharing-spec.md §3.3). Mirrors CollectionShareClient's shape:
// a Sendable struct over the shared SupabaseClient, camelCase edge-fn bodies,
// tolerant reads, and outcomes that report what the SERVER said.
//
//   add    { taskId, email, level }  → { ok, status: 'shared'|'invited', userId?, displayName? }
//                                     | { ok:false, reason: 'self'|'blocked'|… }
//   remove { taskId, userId? | inviteId? } → { ok }
//   list   { taskId }               → { members:[{userId,displayName,level}], pending:[{id,email,level}] }
//   link   { taskId, level }        → { ok, url }
//
// `status` is decoded HONESTLY: "shared" means the person had an account and
// got the task right now; "invited" means an invite was stored + emailed and
// is claimed when they sign up. The decoders are pure (`decodeAdd` & co.) so
// the contract is unit-tested without a network.

import Foundation
import Supabase
import UnstuckCore

/// What `share-task add` did.
public enum TaskShareOutcome: Sendable, Equatable {
    /// An existing account — the task is theirs to see now.
    case shared(userId: String, displayName: String)
    /// No account for that address yet — invite stored, email sent.
    case invited
    /// The server refused / could not be reached; `reason` is its code
    /// ("self", "blocked", "rate_limited", "forbidden", …) or "network".
    case failed(reason: String)
}

/// A join link the item rides on (`share-task link` / `share-collection link`).
public enum ShareLinkOutcome: Sendable, Equatable {
    case ok(url: String)
    case failed(reason: String)
}

/// A joined recipient of a task (from `share-task list`).
public struct TaskShareMember: Sendable, Equatable, Identifiable {
    public let userId: String
    public let displayName: String
    public let level: ShareLevel
    public var id: String { userId }
    public init(userId: String, displayName: String, level: ShareLevel) {
        self.userId = userId
        self.displayName = displayName
        self.level = level
    }
}

/// A pending email invite on a task (`task_invites`).
public struct TaskSharePendingInvite: Sendable, Equatable, Identifiable {
    public let id: String
    public let email: String
    public let level: ShareLevel
    public init(id: String, email: String, level: ShareLevel) {
        self.id = id
        self.email = email
        self.level = level
    }
}

/// The roster `share-task list` returns.
public struct TaskShareRoster: Sendable, Equatable {
    public var members: [TaskShareMember]
    public var pending: [TaskSharePendingInvite]
    public init(members: [TaskShareMember] = [], pending: [TaskSharePendingInvite] = []) {
        self.members = members
        self.pending = pending
    }
    public static let empty = TaskShareRoster()
}

public struct TaskShareClient: Sendable {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    // ── wire shapes (internal → unit-tested via @testable) ─────────────────

    struct Body: Encodable {
        let action: String
        let taskId: String
        var email: String? = nil
        var level: String? = nil
        var userId: String? = nil
        var inviteId: String? = nil
    }

    struct AddResponse: Decodable {
        var ok: Bool? = nil
        var status: String? = nil
        var userId: String? = nil
        var displayName: String? = nil
        var reason: String? = nil
        var error: String? = nil
    }

    struct MemberRow: Decodable {
        var userId: String? = nil
        var displayName: String? = nil
        var level: String? = nil
    }

    struct PendingRow: Decodable {
        var id: String? = nil
        var email: String? = nil
        var level: String? = nil
    }

    struct ListResponse: Decodable {
        var members: [MemberRow]? = nil
        var pending: [PendingRow]? = nil
        var error: String? = nil
    }

    struct LinkResponse: Decodable {
        var ok: Bool? = nil
        var url: String? = nil
        var reason: String? = nil
        var error: String? = nil
    }

    struct OkResponse: Decodable {
        var ok: Bool? = nil
        var error: String? = nil
        var reason: String? = nil
    }

    // ── calls ───────────────────────────────────────────────────────────────

    /// Share a task I own with an email. Existing account → shared at once
    /// (+ the server pushes them); no account → invite by email.
    public func add(taskId: String, email: String, level: ShareLevel) async -> TaskShareOutcome {
        let body = Body(action: "add", taskId: taskId, email: normalizedShareEmail(email), level: level.rawValue)
        do {
            let data = try await raw(body)
            return Self.decodeAdd(data)
        } catch {
            return .failed(reason: Self.failureReason(from: error))
        }
    }

    /// Revoke a joined recipient. TRUE only when the server confirmed.
    public func remove(taskId: String, userId: String) async -> Bool {
        await confirmed(Body(action: "remove", taskId: taskId, userId: userId))
    }

    /// Cancel a pending email invite. TRUE only when the server confirmed.
    public func cancelInvite(taskId: String, inviteId: String) async -> Bool {
        await confirmed(Body(action: "remove", taskId: taskId, inviteId: inviteId))
    }

    /// Joined recipients + pending invites. Tolerant → `.empty` on any failure
    /// (incl. a server where `share-task` isn't deployed yet).
    public func list(taskId: String) async -> TaskShareRoster {
        do {
            return Self.decodeList(try await raw(Body(action: "list", taskId: taskId)))
        } catch { return .empty }
    }

    /// A one-shot join link that grants THIS task at `level` on redeem.
    public func link(taskId: String, level: ShareLevel) async -> ShareLinkOutcome {
        do {
            return Self.decodeLink(try await raw(Body(action: "link", taskId: taskId, level: level.rawValue)))
        } catch {
            return .failed(reason: Self.failureReason(from: error))
        }
    }

    private func raw(_ body: Body) async throws -> Data {
        try await client.functions.invoke(
            "share-task",
            options: FunctionInvokeOptions(method: .post, body: body)) { data, _ in data }
    }

    private func confirmed(_ body: Body) async -> Bool {
        do {
            let r = try JSONDecoder().decode(OkResponse.self, from: try await raw(body))
            return r.ok == true && (r.error ?? "").isEmpty && (r.reason ?? "").isEmpty
        } catch {
            print("[share-task] \(body.action) failed: \(Self.failureReason(from: error))")
            return false
        }
    }

    // ── pure decoders ───────────────────────────────────────────────────────

    /// `add` → outcome. `status` wins ("shared" / "invited"); a refusal is
    /// `{ok:false, reason}` (or a legacy `{error}`); anything unreadable is a
    /// failure — never a fabricated "invited".
    static func decodeAdd(_ data: Data) -> TaskShareOutcome {
        guard let r = try? JSONDecoder().decode(AddResponse.self, from: data) else {
            return .failed(reason: "bad_response")
        }
        if let reason = r.reason ?? r.error, !reason.isEmpty, r.ok != true {
            return .failed(reason: reason)
        }
        switch (r.status ?? "").lowercased() {
        case "shared":
            return .shared(userId: r.userId ?? "", displayName: r.displayName ?? "")
        case "invited":
            return .invited
        default:
            // A 2xx with `ok` but no status: honest fallback on what's present.
            if r.ok == true, let uid = r.userId, !uid.isEmpty {
                return .shared(userId: uid, displayName: r.displayName ?? "")
            }
            return .failed(reason: r.reason ?? r.error ?? "bad_response")
        }
    }

    /// `list` → roster. Unknown levels degrade to `.view` (least privilege);
    /// rows missing their key are dropped rather than failing the whole list.
    static func decodeList(_ data: Data) -> TaskShareRoster {
        guard let r = try? JSONDecoder().decode(ListResponse.self, from: data) else { return .empty }
        let members = (r.members ?? []).compactMap { m -> TaskShareMember? in
            guard let uid = m.userId, !uid.isEmpty else { return nil }
            return TaskShareMember(userId: uid, displayName: m.displayName ?? "",
                                   level: ShareLevel(rawValue: m.level ?? "") ?? .view)
        }
        let pending = (r.pending ?? []).compactMap { p -> TaskSharePendingInvite? in
            guard let id = p.id, !id.isEmpty, let email = p.email, !email.isEmpty else { return nil }
            return TaskSharePendingInvite(id: id, email: email,
                                          level: ShareLevel(rawValue: p.level ?? "") ?? .partner)
        }
        return TaskShareRoster(members: members, pending: pending)
    }

    /// `link` → the URL, or the server's reason.
    static func decodeLink(_ data: Data) -> ShareLinkOutcome {
        guard let r = try? JSONDecoder().decode(LinkResponse.self, from: data) else {
            return .failed(reason: "bad_response")
        }
        if let url = r.url, !url.isEmpty, r.ok != false { return .ok(url: url) }
        return .failed(reason: r.reason ?? r.error ?? "bad_response")
    }

    /// A thrown invoke → the server's code when the non-2xx body carries one
    /// (`{error:'rate_limited'}` / `{ok:false, reason:'self'}`), else "network".
    static func failureReason(from error: Error) -> String {
        if case let FunctionsError.httpError(_, data) = error {
            return failureReason(fromBody: data)
        }
        return "network"
    }

    static func failureReason(fromBody data: Data) -> String {
        if let r = try? JSONDecoder().decode(AddResponse.self, from: data),
           let code = r.reason ?? r.error, !code.isEmpty {
            return code
        }
        return "network"
    }
}
