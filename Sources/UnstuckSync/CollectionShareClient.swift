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
        enum CodingKeys: String, CodingKey { case ok, members, pending; case isOwner = "is_owner" }
    }

    private func call(_ body: ShareBody) async throws -> ShareResponse {
        try await client.functions.invoke(
            "share-collection",
            options: FunctionInvokeOptions(method: .post, body: body))
    }

    /// Share with an email. Existing account → member; otherwise pending invite + email.
    public func share(collectionId: String, email: String, role: String) async -> ShareOutcome {
        do {
            let r = try await call(ShareBody(action: "add", collectionId: collectionId, email: email, role: role))
            switch true {
            case r.error == "not_found": return .notFound
            case r.error == "self": return .selfError
            case r.invited == true: return .invited
            case r.ok == true && r.userId != nil: return .ok
            default: return .error
            }
        } catch { return .error }
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
    private struct AddItemParams: Encodable {
        let p_collection_id: String
        let p_id: String
        let p_body: String
        let p_at: String
    }
    private struct UpdateItemParams: Encodable {
        let p_collection_id: String
        let p_item_id: String
        let p_body: String
    }
    private struct ItemRefParams: Encodable {
        let p_collection_id: String
        let p_item_id: String
    }
    private struct FlagParams: Encodable {
        let p_collection_id: String
        let p_item_id: String
        let p_flag: String
        let p_value: Bool
    }

    public func addItem(collectionId: String, id: String, body: String, at: String) async {
        _ = try? await client.rpc("collection_add_item",
            params: AddItemParams(p_collection_id: collectionId, p_id: id, p_body: body, p_at: at)).execute()
    }

    public func updateItem(collectionId: String, itemId: String, body: String) async {
        _ = try? await client.rpc("collection_update_item",
            params: UpdateItemParams(p_collection_id: collectionId, p_item_id: itemId, p_body: body)).execute()
    }

    public func removeItem(collectionId: String, itemId: String) async {
        _ = try? await client.rpc("collection_remove_item",
            params: ItemRefParams(p_collection_id: collectionId, p_item_id: itemId)).execute()
    }

    public func setItemFlag(collectionId: String, itemId: String, flag: String, value: Bool) async {
        _ = try? await client.rpc("collection_set_item_flag",
            params: FlagParams(p_collection_id: collectionId, p_item_id: itemId, p_flag: flag, p_value: value)).execute()
    }

    // ── Move-to-task accountability ────────────────────────────────────────
    private struct PromotionParams: Encodable {
        let p_collection_id: String
        let p_item_id: String
        let p_assignee: String
        let p_done: Bool?
        let p_due_at: String?
    }

    /// Mark a SHARED item as promoted (assignee + optional pending/done + by-time).
    public func setItemPromotion(collectionId: String, itemId: String, assignee: String, done: Bool?, dueAt: String?) async {
        _ = try? await client.rpc("collection_set_item_promotion",
            params: PromotionParams(p_collection_id: collectionId, p_item_id: itemId,
                                    p_assignee: assignee, p_done: done, p_due_at: dueAt)).execute()
    }

    private struct CollectionMetaUpdate: Encodable {
        let name: String
        let color: String
        let subtitle: String
        let archived: Bool
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

    private struct TaskDoneBody: Encodable {
        let collectionId: String
        let itemId: String
        let taskName: String
        let by: String
    }

    /// The assignee completed a promoted task → flip the shared item to done +
    /// notify the other members (server-side; best-effort).
    public func taskDone(collectionId: String, itemId: String, taskName: String, by: String) async {
        try? await client.functions.invoke(
            "collection-task-done",
            options: FunctionInvokeOptions(method: .post,
                body: TaskDoneBody(collectionId: collectionId, itemId: itemId, taskName: taskName, by: by)))
    }
}
