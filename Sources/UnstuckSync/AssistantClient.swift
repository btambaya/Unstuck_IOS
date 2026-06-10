// AssistantClient — transport for the in-app agent. Calls the stateless
// `assistant` edge function (a qwen proxy that owns the system prompt + tool
// schemas) and returns the assistant message (text and/or tool_calls). The
// CLIENT (AssistantModel) holds the conversation, executes the tool_calls
// through its own offline-first methods, appends the results, and re-invokes
// until the assistant returns a plain text reply. Messages use the OpenAI chat
// shape. 1:1 with the Android sync/AssistantClient.kt.

import Foundation
import Supabase

/// One message in the OpenAI-style conversation (user | assistant | tool).
public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?
    public var name: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    public init(role: String, content: String? = nil, toolCalls: [ToolCall]? = nil,
                toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }
}

/// A tool call the model wants run. `id`/`type` always round-trip back to qwen
/// on the next turn (no defaults — they must always be present in the history).
public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var function: ToolFunction

    public init(id: String, type: String, function: ToolFunction) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct ToolFunction: Codable, Equatable, Sendable {
    public var name: String
    public var arguments: String   // JSON-encoded args object

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

/// The assistant turn returned by the edge function.
public struct AssistantReply: Codable, Equatable, Sendable {
    public var content: String?
    public var toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
    }

    public init(content: String? = nil, toolCalls: [ToolCall]? = nil) {
        self.content = content
        self.toolCalls = toolCalls
    }
}

/// Outcome of one round-trip: the assistant turn, or an error code for the UI.
public enum AssistantResult: Sendable {
    case ok(AssistantReply)
    /// "not_configured" | "upstream" | "network" | "unauthorized" | "timeout" | "empty" | …
    case err(String)
}

public struct AssistantClient: Sendable {
    let client: SupabaseClient

    public init(_ client: SupabaseClient) { self.client = client }

    private struct Request: Encodable {
        let messages: [ChatMessage]
        let context: [String: AnyJSON]
    }

    private struct Response: Decodable {
        var assistant: AssistantReply?
        var error: String?
    }

    /// One round-trip to the edge function. One retry on a thrown error
    /// (transient network / cold-start timeout), 800ms backoff. The edge fn
    /// returns its own error codes in the body (e.g. "not_configured",
    /// "upstream", "unauthorized") which we surface verbatim.
    public func ask(messages: [ChatMessage], context: [String: AnyJSON]) async -> AssistantResult {
        var lastWasTimeout = false
        for attempt in 0..<2 {
            do {
                let resp: Response = try await client.functions.invoke(
                    "assistant",
                    options: FunctionInvokeOptions(method: .post, body: Request(messages: messages, context: context)))
                if let error = resp.error { return .err(error) }
                if let assistant = resp.assistant { return .ok(assistant) }
                return .err("empty")
            } catch {
                lastWasTimeout = (error as? URLError)?.code == .timedOut
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
        }
        return .err(lastWasTimeout ? "timeout" : "network")
    }
}
