// CollectionShareClient — the iOS port of the web shared-collections plumbing
// (use-collections.ts share/unshare/leave/listMembers + the atomic item RPCs),
// 1:1 with sync/CollectionShareClient.kt.
//
//  • Membership is managed by the `share-collection` edge function (owner-only
//    add/remove; self leave; list members + pending invites). The function
//    resolves email → user id server-side and, when no account exists, stores a
//    pending invite + emails them (claimed on signup) → ShareOutcome.invited.
//  • Item edits on a SHARED collection go through the atomic JSONB RPCs (one
//    server-side statement, RLS-gated) so two people editing the same list don't
//    clobber each other. Own/unshared lists keep the whole-row outbox path.

import Foundation
import Supabase

/// Result of a `share` attempt — mirrors Android's ShareOutcome enum.
public enum ShareOutcome: Sendable, Equatable {
    case ok          // shared with an existing account
    case invited     // no account yet → pending invite + email sent
    case notFound    // email/collection invalid
    case selfError   // tried to share with my own email
    case error       // unrecoverable
}

/// A member (joined) or pending invite of a shared collection, for the share sheet.
public struct CollectionMemberInfo: Codable, Equatable, Sendable, Identifiable {
    public let userId: String     // "" for a pending invite
    public let email: String
    public let role: String       // "editor" | "viewer"
    public let pending: Bool

    public var id: String { pending ? "pending:\(email)" : userId }

    public init(userId: String, email: String, role: String, pending: Bool) {
        self.userId = userId
        self.email = email
        self.role = role
        self.pending = pending
    }
}

public struct CollectionShareClient: Sendable {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    // ── share-collection edge function ─────────────────────────────────────
    private struct ShareBody: Encodable {
        let action: String
        let collectionId: String
        var email: String? = nil
        var userId: String? = nil
        var role: String? = nil
    }

    private struct ShareResponse: Decodable {
        var ok: Bool? = nil
        var invited: Bool? = nil
        var userId: String? = nil
        var role: String? = nil
        var email: String? = nil
        var error: String? = nil
    }

    private struct MemberRow: Decodable {
        var userId: String = ""
        var email: String = ""
        var role: String? = nil
        enum CodingKeys: String, CodingKey { case userId = "user_id", email, role }
    }

    private struct PendingRow: Decodable {
        var email: String = ""
        var role: String? = nil
    }

    private struct ListResponse: Decodable {
        var ok: Bool? = nil
        var members: [MemberRow] = []
        var pending: [PendingRow] = []
        var isOwner: Bool? = nil
        // The share-collection edge fn returns camelCase `isOwner` (matches Android).
        enum CodingKeys: String, CodingKey { case ok, members, pending, isOwner }
    }

    private func call(_ body: ShareBody) async throws -> ShareResponse {
        try await client.functions.invoke(
            "share-collection",
            options: FunctionInvokeOptions(method: .post, body: body))
    }

    /// A share attempt's outcome plus what the server now knows about the
    /// membership: `memberUserIds` is the joined-member list when the
    /// function returned it (`members` rows, the owner sees them via RLS),
    /// else just the newly-added user — enough for the owner's client to mark
    /// the list SHARED immediately instead of after the next full hydrate.
    public struct ShareResult: Sendable, Equatable {
        public let outcome: ShareOutcome
        public let memberUserIds: [String]
        public init(outcome: ShareOutcome, memberUserIds: [String]) {
            self.outcome = outcome; self.memberUserIds = memberUserIds
        }
    }

    private struct ShareAddResponse: Decodable {
        var ok: Bool? = nil
        var invited: Bool? = nil
        var userId: String? = nil
        var role: String? = nil
        var email: String? = nil
        var error: String? = nil
        var members: [MemberRow]? = nil
    }

    /// Share with an email. Existing account → member; otherwise pending invite + email.
    public func share(collectionId: String, email: String, role: String) async -> ShareOutcome {
        await shareDetailed(collectionId: collectionId, email: email, role: role).outcome
    }

    public func shareDetailed(collectionId: String, email: String, role: String) async -> ShareResult {
        do {
            let r: ShareAddResponse = try await client.functions.invoke(
                "share-collection",
                options: FunctionInvokeOptions(method: .post,
                    body: ShareBody(action: "add", collectionId: collectionId, email: email, role: role)))
            let members = (r.members ?? []).map(\.userId).filter { !$0.isEmpty }
            switch true {
            case r.error == "not_found": return ShareResult(outcome: .notFound, memberUserIds: members)
            case r.error == "self": return ShareResult(outcome: .selfError, memberUserIds: members)
            case r.invited == true: return ShareResult(outcome: .invited, memberUserIds: members)
            case r.ok == true && r.userId != nil:
                let added = r.userId ?? ""
                return ShareResult(outcome: .ok,
                                   memberUserIds: members.isEmpty ? [added] : members)
            default: return ShareResult(outcome: .error, memberUserIds: members)
            }
        } catch { return ShareResult(outcome: .error, memberUserIds: []) }
    }

    /// Remove a joined member (owner-only).
    public func unshare(collectionId: String, userId: String) async {
        _ = try? await call(ShareBody(action: "remove", collectionId: collectionId, userId: userId))
    }

    /// Cancel a pending email invite (owner-only).
    public func cancelInvite(collectionId: String, email: String) async {
        _ = try? await call(ShareBody(action: "remove", collectionId: collectionId, email: email))
    }

    /// Leave a collection shared WITH me.
    public func leave(collectionId: String) async {
        _ = try? await call(ShareBody(action: "leave", collectionId: collectionId))
    }

    /// Joined members + pending invites for the share sheet.
    public func listMembers(collectionId: String) async -> [CollectionMemberInfo] {
        do {
            let r: ListResponse = try await client.functions.invoke(
                "share-collection",
                options: FunctionInvokeOptions(method: .post, body: ShareBody(action: "list", collectionId: collectionId)))
            let members = r.members.map {
                CollectionMemberInfo(userId: $0.userId, email: $0.email,
                                     role: $0.role == "viewer" ? "viewer" : "editor", pending: false)
            }
            let pending = r.pending.map {
                CollectionMemberInfo(userId: "", email: $0.email,
                                     role: $0.role == "viewer" ? "viewer" : "editor", pending: true)
            }
            return members + pending
        } catch { return [] }
    }

    // ── Atomic item RPCs (shared collections only) ─────────────────────────
    // Built as `CollectionRPC` descriptors and queued through the OUTBOX
    // (`WriteThrough.applyCollectionRPC` → `OutboxKind.rpc`) so they retry
    // offline and a refusal rolls the optimistic row back — never fired and
    // forgotten. Every RPC is idempotent by item id (a replay is a no-op).
    // The direct (awaited, best-effort) forms below remain for callers that
    // are not row mutations of a local collection (tests / tools).

    public func addItem(collectionId: String, id: String, body: String, at: String) async {
        await call(CollectionRPC.addItem(collectionId: collectionId, id: id, body: body, at: at))
    }

    public func updateItem(collectionId: String, itemId: String, body: String) async {
        await call(CollectionRPC.updateItem(collectionId: collectionId, itemId: itemId, body: body))
    }

    public func removeItem(collectionId: String, itemId: String) async {
        await call(CollectionRPC.removeItem(collectionId: collectionId, itemId: itemId))
    }

    public func setItemFlag(collectionId: String, itemId: String, flag: String, value: Bool) async {
        await call(CollectionRPC.setItemFlag(collectionId: collectionId, itemId: itemId, flag: flag, value: value))
    }

    /// Mark a SHARED item as promoted (assignee + optional pending/done + by-time).
    public func setItemPromotion(collectionId: String, itemId: String, assignee: String, done: Bool?, dueAt: String?) async {
        await call(CollectionRPC.setItemPromotion(collectionId: collectionId, itemId: itemId,
                                                  assignee: assignee, done: done, dueAt: dueAt))
    }

    /// Fire one descriptor directly (best-effort, no retry) — the outbox path
    /// (`SyncGateway.rpc`) is what the app's mutations use.
    private func call(_ rpc: CollectionRPC) async {
        guard let params = try? JSONDecoder().decode([String: AnyJSON].self, from: Data(rpc.paramsJSON.utf8)) else { return }
        _ = try? await client.rpc(rpc.fn, params: params).execute()
    }

    private struct CollectionMetaUpdate: Encodable {
        let name: String
        let color: String
        let subtitle: String
        let archived: Bool
    }

    /// Sync member ids the share sheet just LISTED onto the local row, so
    /// `isShared` / the SHARED badge don't wait for the next full hydrate.
    public static func joinedUserIds(_ members: [CollectionMemberInfo]) -> [String] {
        members.filter { !$0.pending && !$0.userId.isEmpty }.map(\.userId)
    }

    /// Update ONLY a shared collection's metadata columns (a PostgREST UPDATE, not
    /// a whole-row upsert) so the `items` JSONB isn't shipped + can't clobber a
    /// member's concurrent item edit. RLS gates it to owner/editor.
    public func updateCollectionFields(id: String, name: String, color: String, subtitle: String, archived: Bool) async {
        _ = try? await client.from("collections")
            .update(CollectionMetaUpdate(name: name, color: color, subtitle: subtitle, archived: archived))
            .eq("id", value: id)
            .execute()
    }

    /// Which way `collection-task-done` flips the shared item. `.done` is the
    /// function's legacy default (an omitted `action` still means done), so an
    /// older deployment keeps working; `.reopen` un-ticks it.
    public enum TaskDoneAction: String, Sendable { case done, reopen }

    private struct TaskDoneBody: Encodable {
        let collectionId: String
        let itemId: String
        let taskName: String
        let by: String
        let action: String
    }

    /// Flip the shared item behind a promoted task and notify the other members
    /// (server-side; best-effort).
    ///
    /// `.done` — the assignee completed it. `.reopen` — the assignee un-completed
    /// it, or deleted the task outright; without this the collection row stays
    /// ticked forever while no task exists behind it. RLS: `done` is
    /// assignee-or-owner; `reopen` is assignee/owner, OR any editor once no user
    /// holds a linked task for the item (so delete-then-reopen works in either
    /// order).
    public func taskDone(collectionId: String, itemId: String, taskName: String, by: String,
                         action: TaskDoneAction = .done) async {
        try? await client.functions.invoke(
            "collection-task-done",
            options: FunctionInvokeOptions(method: .post,
                body: TaskDoneBody(collectionId: collectionId, itemId: itemId, taskName: taskName,
                                   by: by, action: action.rawValue)))
    }
}

// MARK: - CollectionRPC (the outbox `rpc` op descriptor)

/// One atomic shared-collection item mutation, as the server function name
/// plus its parameters serialised as a JSON object — the payload of an
/// `OutboxKind.rpc` op (`OutboxRPCPayload`). Pure + Codable so the queueing
/// layer and its tests never touch the transport.
///
/// Every function is IDEMPOTENT by item id (migration 056):
///  • `collection_add_item(p_collection_id, p_item jsonb)` UPSERTS by
///    `p_item.id` — the client id — so an outbox replay after a lost response
///    never appends a duplicate;
///  • update / remove / set_flag / set_promotion are keyed on the item id and
///    a repeat converges on the same state.
public struct CollectionRPC: Codable, Equatable, Sendable {
    public let fn: String
    public let paramsJSON: String

    public init(fn: String, paramsJSON: String) {
        self.fn = fn
        self.paramsJSON = paramsJSON
    }

    private static func encode(_ params: [String: AnyJSON]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(data: (try? enc.encode(params)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    /// Upsert-by-id: `p_item` carries the CLIENT id, so a replay is a no-op.
    public static func addItem(collectionId: String, id: String, body: String, at: String) -> CollectionRPC {
        CollectionRPC(fn: "collection_add_item", paramsJSON: encode([
            "p_collection_id": .string(collectionId),
            "p_item": .object(["id": .string(id), "body": .string(body), "at": .string(at)]),
        ]))
    }

    public static func updateItem(collectionId: String, itemId: String, body: String) -> CollectionRPC {
        CollectionRPC(fn: "collection_update_item", paramsJSON: encode([
            "p_collection_id": .string(collectionId), "p_item_id": .string(itemId), "p_body": .string(body),
        ]))
    }

    public static func removeItem(collectionId: String, itemId: String) -> CollectionRPC {
        CollectionRPC(fn: "collection_remove_item", paramsJSON: encode([
            "p_collection_id": .string(collectionId), "p_item_id": .string(itemId),
        ]))
    }

    public static func setItemFlag(collectionId: String, itemId: String, flag: String, value: Bool) -> CollectionRPC {
        CollectionRPC(fn: "collection_set_item_flag", paramsJSON: encode([
            "p_collection_id": .string(collectionId), "p_item_id": .string(itemId),
            "p_flag": .string(flag), "p_value": .bool(value),
        ]))
    }

    public static func setItemPromotion(collectionId: String, itemId: String, assignee: String,
                                        done: Bool?, dueAt: String?) -> CollectionRPC {
        CollectionRPC(fn: "collection_set_item_promotion", paramsJSON: encode([
            "p_collection_id": .string(collectionId), "p_item_id": .string(itemId),
            "p_assignee": .string(assignee),
            "p_done": done.map { .bool($0) } ?? .null,
            "p_due_at": dueAt.map { .string($0) } ?? .null,
        ]))
    }

    /// The decoded parameter object (what `SyncGateway.rpc` sends).
    public var params: [String: AnyJSON] {
        (try? JSONDecoder().decode([String: AnyJSON].self, from: Data(paramsJSON.utf8))) ?? [:]
    }
}
