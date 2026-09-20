// The agentic turn loop — the harness contract from
// docs/assistant-tool-contract.md, 1:1 with lib/assistant/use-assistant.ts:
//
//  • ask → run every tool call → append `tool` turns → ask again (≤5 rounds);
//  • FABRICATION GUARD: a reply with no tool calls, no write tool succeeded
//    this turn, and text that CLAIMS an action is hidden and bounced ONCE with
//    the hidden corrective; if the retry's tool ran, its self-correction is
//    stripped (the user never saw the claim);
//  • finish_reason=length on a round that CALLED TOOLS → the hidden "cut off"
//    hint, appended AFTER that round's tool results (never between the
//    tool_calls turn and its results); on a tool-less final reply → no hint;
//  • truncated tool-call JSON → tell the model to split the call;
//  • receipts derived from execution only; NEVER a synthesised "Done." —
//    empty text falls back to the first receipt's label / the honest lines.
//
// Pure with respect to the store: the loop talks to an `AssistantTransport`
// and an `AssistantAppState`, and hands every committed thread back through
// `commit`, so it runs under XCTest against fakes.

import Foundation
import Supabase
import UnstuckCore
import UnstuckSync

// MARK: - transport

struct HarnessReply: Equatable, Sendable {
    var content: String?
    var toolCalls: [ToolCall]
    /// "length" when the upstream cut the reply off. nil = unknown/complete.
    var finishReason: String?

    init(content: String?, toolCalls: [ToolCall] = [], finishReason: String? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.finishReason = finishReason
    }
}

enum HarnessAsk: Sendable {
    case ok(HarnessReply)
    /// "not_configured" | "network" | "timeout" | "upstream" | …
    case err(String)
}

@MainActor
protocol AssistantTransport: AnyObject {
    func ask(messages: [ChatMessage], context: [String: AnyJSON]) async -> HarnessAsk
}

/// The production transport: the `assistant` edge function via UnstuckSync.
@MainActor
final class AssistantClientTransport: AssistantTransport {
    private let client: AssistantClient
    init(_ client: AssistantClient) { self.client = client }

    func ask(messages: [ChatMessage], context: [String: AnyJSON]) async -> HarnessAsk {
        switch await client.ask(messages: messages, context: context) {
        case .ok(let reply):
            // The edge fn's top-level `finish_reason` rides on AssistantReply
            // (UnstuckSync/AssistantClient.swift): "length" ⇒ the loop sends the
            // cut-off hint explicitly instead of inferring it from bad JSON.
            return .ok(HarnessReply(content: reply.content, toolCalls: reply.toolCalls ?? [], finishReason: reply.finishReason))
        case .err(let code):
            return .err(code)
        }
    }
}

// MARK: - the loop

@MainActor
enum AssistantHarness {
    static let maxIterations = 5

    /// Hidden user-role bounce after a fabricated claim. NOT from the user, and
    /// the user never saw the claim — so the retry must read like a first
    /// answer. It never asserts "nothing was done" (that invited redoing an
    /// earlier turn's action). Verbatim on every platform — tooling rules §3.
    static let correctiveText = "(from the app, not the user: you described an action, but no tool ran THIS turn. If it is still needed, call the right tool now and then say in a few words what happened; if you were describing something from an earlier turn, answer plainly without claiming it again. Never claim an action without its tool result.)"
    /// Hidden hint when the upstream says the reply was cut off by length.
    static let cutOffHint = "(your previous reply was cut off by the length limit — continue from where it stopped, splitting any large tool call into smaller calls of at most 12 items.)"
    /// Tool result substituted when the call's JSON parsed to {} but wasn't empty.
    static let truncatedArgsResult = "error: your tool call arguments were cut off mid-JSON — retry with fewer items per call (split large lists across several calls)"
    // Honest fallbacks (contract §6) — verbatim from use-assistant.ts.
    static let lostThread = "Hmm, I lost my thread there — nothing was changed. Try me again?"
    /// A staged share (share_task / share_list) with no text: the card IS the reply.
    static let stagedReady = "Ready — check the card below."
    /// A receipt-less, card-less write succeeded (2026-09-20: never "Ready —
    /// check the card below" when there is no card).
    static let wentThrough = "That went through."
    /// A navigation with no text: say what was opened, never "nothing changed".
    static func opened(_ screen: String) -> String { "Opened \(screen)." }
    static let droppedMidReply = "The connection dropped mid-reply — but these went through:"
    static let partwayStaged = "I got partway through — see what's staged below and tell me what's still missing."
    static let partwayWrite = "I got partway through — something went through, but I ran out of steps. Tell me what's still missing."
    static func partwayOpened(_ screen: String) -> String {
        "I opened \(screen) but ran out of steps before finishing — nothing else was changed. Tell me what's still missing."
    }
    static let ranOut = "I ran out of steps without getting that done — nothing was changed. Try again, or break it into smaller asks."
    static func partway(_ n: Int) -> String {
        "I got partway through — \(n) thing\(n == 1 ? "" : "s") went through (receipts below). Tell me what's still missing."
    }

    // MARK: tool-call hygiene

    /// A tool call's `function.arguments` as it is PERSISTED and replayed:
    /// anything that does not parse to a JSON object becomes "{}". DashScope
    /// rejects the WHOLE request (400 InvalidParameter: "function.arguments …
    /// must be in JSON format") when any replayed assistant tool_call carries
    /// an empty string or JSON cut off by finish_reason=length — clients
    /// persisted those turns verbatim, so ONE bad call poisoned every later
    /// turn of the thread (2026-09-06, iOS builds 39/40). A valid object is
    /// returned untouched, so the model-facing history is otherwise identical.
    /// Execution still sees the raw string (the truncated-args hint keys on it).
    nonisolated static func argumentsAsObjectJSON(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let data = s.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              parsed is [String: Any] else { return "{}" }
        return raw
    }

    /// The calls as they go into the thread (see `argumentsAsObjectJSON`).
    nonisolated static func normalisedForHistory(_ calls: [ToolCall]) -> [ToolCall] {
        calls.map { call in
            var c = call
            c.function.arguments = argumentsAsObjectJSON(call.function.arguments)
            return c
        }
    }

    struct Deps {
        let transport: AssistantTransport
        let api: AssistantAppState
        let scratch: TurnScratch
        /// Fresh context per round (the store moves between rounds).
        let context: () -> [String: AnyJSON]
        /// Receipt for one executed call (nil for read-only / errored / unknown).
        let receipt: (_ name: String, _ args: ToolArgs, _ result: String) -> Receipt?
        /// The deterministic style-preference save, run BEFORE the model sees the
        /// message; returns its receipt when something was saved.
        let stylePreference: (_ userText: String) -> Receipt?
        /// Hand the working thread back (persist=false mid-flight, true when committed).
        let commit: (_ working: [AssistantTurn], _ persist: Bool) -> Void
        let now: () -> Double
        let isCancelled: () -> Bool
    }

    enum Outcome: Equatable {
        case reply(String)
        case error(String)
        case cancelled
    }

    /// Run one turn. `base` already ends with the user's turn.
    static func runTurn(text: String, base: [AssistantTurn], deps: Deps) async -> Outcome {
        var working = base
        var receipts: [Receipt] = []
        // Style requests ("don't use my name", "call me X") are saved by the
        // APP, deterministically — the model kept promising and not saving.
        if let r = deps.stylePreference(text) { receipts.append(r) }
        // Fabrication guard state — at most one corrective bounce per turn.
        var corrected = false
        // A WRITE tool succeeded this turn (even receipt-less ones like
        // share_task): a name outside the registry's read-only + navigation
        // sets whose result starts with "ok:" (tooling rules §3). Read-only
        // successes, navigations and errored tools don't count.
        var writeToolSucceeded = false
        // A staged share (share_task / share_list) — the card is the reply.
        var stagedShare = false
        // The last screen a navigation opened — its own kind of empty reply.
        var navigatedTo: String?

        for i in 0..<maxIterations {
            if deps.isCancelled() { return .cancelled }
            // Crash trail: round markers + tool names only, never any content
            // (App/Diagnostics/CrashBreadcrumbs.swift).
            CrashBreadcrumbs.drop("assistant round \(i + 1)")
            let ask = await deps.transport.ask(messages: AssistantModel.modelWindow(working), context: deps.context())
            if deps.isCancelled() { return .cancelled }
            switch ask {
            case .err(let code):
                // A failed FIRST round keeps the user's turn (the panel shows
                // the error inline); a later round keeps the partial exchange
                // — and if tools already ran, says so WITH their receipts.
                if i > 0 {
                    if !receipts.isEmpty {
                        working.append(AssistantTurn(ChatMessage(role: "assistant", content: droppedMidReply),
                                                     at: deps.now(), local: true, receipts: receipts))
                    }
                    deps.commit(working, true)
                } else {
                    deps.commit(working, false)
                }
                return .error(code)

            case .ok(let reply):
                let content = reply.content ?? ""
                // FABRICATION GUARD (a stable qwen failure mode, 2026-08-29).
                if reply.toolCalls.isEmpty && !corrected && !writeToolSucceeded && looksLikeActionClaim(content) {
                    corrected = true
                    working.append(AssistantTurn(ChatMessage(role: "assistant", content: content), hidden: true))
                    working.append(AssistantTurn(ChatMessage(role: "user", content: correctiveText), hidden: true))
                    continue
                }

                // The REAL assistant turn — the receipts, the empty-text
                // fallback and stripSelfCorrection all attach to THIS index,
                // never to whatever happens to be last in `working`. The
                // hidden cut-off hint used to be pushed here, so a cut-off
                // FINAL reply hung its text and its receipts (and their Undo)
                // on a turn the panel never draws. `replyIndex` is
                // use-assistant.ts's `replyTurn`, captured BEFORE anything
                // else is pushed.
                //
                // The thread (persisted + replayed) carries NORMALISED tool
                // calls — a non-object `arguments` string would 400 every
                // later request (see argumentsAsObjectJSON); execution below
                // still runs on the raw reply so the truncated-args hint fires.
                let replyIndex = working.count
                working.append(AssistantTurn(
                    ChatMessage(role: "assistant", content: reply.content,
                                toolCalls: reply.toolCalls.isEmpty ? nil : normalisedForHistory(reply.toolCalls)),
                    at: deps.now()))

                if reply.toolCalls.isEmpty {
                    // Final reply — attach the turn's deterministic receipts.
                    // NEVER synthesize "Done." (harness audit, 2026-09-01).
                    // A length cut-off HERE gets no hidden hint at all:
                    // nothing follows it this turn, and a dangling hidden
                    // user turn made the model resume the abandoned plan on
                    // the NEXT message (lib/assistant/use-assistant.ts).
                    let last = replyIndex
                    var closing = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if corrected && writeToolSucceeded { closing = stripSelfCorrection(closing) }
                    // Deterministic register polish ("Done —", "Let me know…",
                    // raw 2026-09-05 / 14:00) on the model's FINAL text only —
                    // AFTER the fabrication guard saw the raw claim, never on
                    // the hidden bounce, never on voice (naturalness, 2026-09-06).
                    if !closing.isEmpty { closing = polishReply(closing) }
                    // The web's five-branch ladder (use-assistant.ts): a
                    // receipt-less write is still a success — never assert
                    // "nothing changed" over one, and never promise a card
                    // that isn't there (2026-09-20).
                    if closing.isEmpty {
                        if !receipts.isEmpty {
                            closing = "\(receipts[0].label)\(receipts.count > 1 ? " — and \(receipts.count - 1) more below" : "")."
                        } else if stagedShare {
                            closing = stagedReady
                        } else if writeToolSucceeded {
                            closing = wentThrough
                        } else if let navigatedTo {
                            closing = opened(navigatedTo)
                        } else {
                            closing = lostThread
                        }
                    }
                    working[last].message.content = closing
                    if !receipts.isEmpty { working[last].receipts = receipts }
                    deps.commit(working, true)
                    return .reply(closing)
                }

                // Execute each tool call, append its result for the next round.
                CrashBreadcrumbs.drop("assistant tools \(reply.toolCalls.count)")
                for call in reply.toolCalls {
                    let args = ToolArgs(json: call.function.arguments)
                    CrashBreadcrumbs.drop("tool.run \(call.function.name)")
                    var result = await runAssistantTool(name: call.function.name, args: args, api: deps.api, scratch: deps.scratch)
                    CrashBreadcrumbs.drop("tool.done \(call.function.name) \(result.hasPrefix("error") ? "err" : "ok")")
                    if result.hasPrefix("ok:") {
                        if NAVIGATION_TOOLS.contains(call.function.name) {
                            let screen = result.dropFirst("ok:".count).trimmingCharacters(in: .whitespaces)
                                .replacingOccurrences(of: "opened ", with: "", options: .anchored)
                            navigatedTo = screen.isEmpty ? "that screen" : screen
                        } else if !READ_ONLY_TOOLS.contains(call.function.name) {
                            writeToolSucceeded = true
                            if STAGED_TOOLS.contains(call.function.name) { stagedShare = true }
                        }
                    }
                    // Truncated tool-call JSON (completion cap) parses to {} —
                    // tell the model WHY so it splits the call instead of flailing.
                    if result.hasPrefix("error") && args.isEmpty && call.function.arguments.count > 2 {
                        result = truncatedArgsResult
                    }
                    if let receipt = deps.receipt(call.function.name, args, result) { receipts.append(receipt) }
                    working.append(AssistantTurn(ChatMessage(role: "tool", content: result, toolCallId: call.id, name: call.function.name)))
                }
                // The upstream said the reply was CUT OFF by length: later
                // tool calls (or the tail of the text) never arrived. Say so
                // explicitly instead of inferring it from a parse failure —
                // and only AFTER the tool results, so every `tool` message
                // stays adjacent to its `tool_calls` parent. Pushed before
                // them it produced assistant(tool_calls) → user → tool, the
                // orphaned-tool shape the upstream 400s on — which is exactly
                // what a big create_tasks brain dump hits.
                if reply.finishReason == "length" {
                    working.append(AssistantTurn(ChatMessage(role: "user", content: cutOffHint), hidden: true))
                }
                deps.commit(working, false)
            }
        }

        // Ran out of iterations — close out HONESTLY (the plan may be half-executed).
        let closing: String
        if !receipts.isEmpty { closing = partway(receipts.count) }
        else if stagedShare { closing = partwayStaged }
        else if writeToolSucceeded { closing = partwayWrite }
        else if let navigatedTo { closing = partwayOpened(navigatedTo) }
        else { closing = ranOut }
        working.append(AssistantTurn(ChatMessage(role: "assistant", content: closing), at: deps.now(),
                                     receipts: receipts.isEmpty ? nil : receipts))
        deps.commit(working, true)
        return .reply(closing)
    }
}

// MARK: - receipts for every tool

/// Receipt for one executed call — UnstuckCore's `deriveReceipt` (every tool
/// in the contract), phrased with the tone the profile facts ask for. `tasks`
/// should include this turn's scratch rows so an in-flight completion resolves
/// its undo target.
func assistantReceipt(name: String, args: ToolArgs, result: String, tasks: [TaskItem], facts: [ProfileFact]) -> Receipt? {
    deriveReceipt(name: name, args: args.receiptArgs, result: result, tasks: tasks, tone: toneFromFacts(facts))
}
