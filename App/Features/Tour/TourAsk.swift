// "Ask a question" — the REAL assistant, tour-framed. Port of web tour-ask.ts.
//
// One stateless round-trip through the SAME `assistant` edge function the
// app's agent uses (AssistantModel.tourAsk → AssistantClient), with
// context.tour = {step, title} flagging PRODUCT-TOUR Q&A MODE server-side
// (the edge fn appends its stricter tour addendum and withholds the tool
// schemas — the guardrail lives on the SERVER). Any tool_calls in the reply
// are IGNORED — the tour only ever speaks; a tool-calls-only reply, an
// error, a timeout, or offline all fall back to the canned TOUR_QA answer
// instantly (unlabelled — it just answers).

import Foundation
import Observation
import UnstuckSync

// MARK: - pure wire building (unit-tested)

struct TourAskMessage: Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: String
}

struct TourAskResult: Equatable, Sendable {
    let text: String
    let fromAssistant: Bool
}

/// Wire cap: last 2 complete Q/A pairs + the current question.
let MAX_TOUR_HISTORY = 4
let TOUR_ASK_TIMEOUT_MS: UInt64 = 20_000

/// Marker the preamble carries so buildAskWire can tell whether the capped
/// history still contains the tour framing.
let TOUR_CONTEXT_MARK = "I'm taking the Unstuck product tour"

/// The tour framing + the question, as ONE user message (no server change,
/// the scope guardrail stays intact — this is an Unstuck question). Pure.
func buildTourPrompt(stepTitle: String, stepBody: String, question: String) -> String {
    let body = stepBody.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = body.count > 220 ? "\(String(body.prefix(217)).trimmingCharacters(in: .whitespaces))…" : body
    return "(\(TOUR_CONTEXT_MARK), currently on the step \"\(stepTitle)\" — \(summary) "
        + "Please answer this question about Unstuck briefly, in 2–3 calm sentences, without using any tools.)\n\n"
        + "Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines))"
}

/// Build the wire messages for one ask: capped history (always starting at a
/// user turn) + the current question — re-embedding the tour framing whenever
/// the cap dropped the original preambled turn. Pure.
func buildAskWire(stepTitle: String, stepBody: String,
                  thread: [TourAskMessage], question: String) -> [TourAskMessage] {
    var kept = Array(thread.suffix(MAX_TOUR_HISTORY))
    while let first = kept.first, first.role != .user { kept.removeFirst() }
    let framed = kept.contains { $0.role == .user && $0.content.contains(TOUR_CONTEXT_MARK) }
    let content = framed
        ? question.trimmingCharacters(in: .whitespacesAndNewlines)
        : buildTourPrompt(stepTitle: stepTitle, stepBody: stepBody, question: question)
    return kept + [TourAskMessage(role: .user, content: content)]
}

/// Fallback logic, pure: a real text reply passes through; anything else
/// (error, timeout/nil, tool-calls-only ⇒ empty content) answers canned.
func resolveAskReply(_ content: String?, question: String) -> TourAskResult {
    if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return TourAskResult(text: content.trimmingCharacters(in: .whitespacesAndNewlines), fromAssistant: true)
    }
    return TourAskResult(text: tourAnswer(for: question), fromAssistant: false)
}

// MARK: - transport (the app's existing assistant client)

/// The timeout race outcome: a (possibly failed → nil-content) reply, or the
/// 20s deadline firing first. Either non-reply path answers canned.
private enum TourAskRace: Sendable {
    case reply(String?)
    case timeout
}

/// One bounded round-trip to the production assistant. Never throws; 20s
/// timeout → canned answer. tool_calls in the reply are ignored (content only).
func sendTourAsk(assistant: AssistantModel?, wire: [TourAskMessage],
                 question: String, step: TourStep) async -> TourAskResult {
    guard let assistant else { return resolveAskReply(nil, question: question) }
    let messages = wire.map { ChatMessage(role: $0.role.rawValue, content: $0.content) }
    let stepId = step.id
    let stepTitle = step.title
    let outcome = await withTaskGroup(of: TourAskRace.self) { group -> TourAskRace in
        group.addTask {
            // tourAsk is @MainActor — the await hops there; the child itself
            // stays nonisolated (keeps the region checker happy).
            switch await assistant.tourAsk(messages: messages, stepId: stepId, stepTitle: stepTitle) {
            case .ok(let reply): return .reply(reply.content)
            case .err: return .reply(nil)
            }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: TOUR_ASK_TIMEOUT_MS * 1_000_000)
            return .timeout
        }
        let first = await group.next() ?? .timeout
        group.cancelAll()
        return first
    }
    switch outcome {
    case .reply(let content): return resolveAskReply(content, question: question)
    case .timeout: return resolveAskReply(nil, question: question)
    }
}

// MARK: - per-step ask thread

/// The panel's per-step Q/A thread: visible bubbles + the wire history the
/// next follow-up sends (so the assistant sees the prior exchange). Reset on
/// every step change; a reply landing after the user moved on is dropped.
@MainActor
@Observable
final class TourAskModel {
    struct Bubble: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id: Int
        let role: Role
        let text: String
    }

    private(set) var bubbles: [Bubble] = []
    private(set) var busy = false
    /// The ask input row is open (web `asking` toggle).
    var asking = false

    private var wire: [TourAskMessage] = []
    private var seq = 0
    private var stepKey = ""

    func reset(step: String) {
        stepKey = step
        bubbles = []
        wire = []
        busy = false
        asking = false
    }

    func submit(_ question: String, step: TourStep, assistant: AssistantModel?) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        let key = stepKey
        busy = true
        seq += 1
        bubbles.append(Bubble(id: seq, role: .user, text: q))
        let outgoing = buildAskWire(stepTitle: step.title, stepBody: step.body, thread: wire, question: q)
        Task { [weak self] in
            let res = await sendTourAsk(assistant: assistant, wire: outgoing, question: q, step: step)
            guard let self, self.stepKey == key else { return }
            self.wire = outgoing + [TourAskMessage(role: .assistant, content: res.text)]
            self.seq += 1
            self.bubbles.append(Bubble(id: self.seq, role: .assistant, text: res.text))
            self.busy = false
        }
    }
}
