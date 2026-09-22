// The voice tool schemas are ~75 % of what a realtime reply re-reads every
// time, and that prefix is what fills the account's tokens-per-minute bucket —
// so it decides how many replies a conversation gets before the assistant goes
// quiet (beta audit 2026-09-21). Compaction shortens the PROSE and nothing
// else: every tool, parameter, type, enum and required flag must survive, or
// the model loses the ability to call something.

import XCTest
@testable import Unstuck

final class VoiceToolCompactionTests: XCTestCase {

    // MARK: the contract — nothing that matters is lost

    func testEveryToolParameterEnumAndRequiredFlagSurvives() {
        let before = ToolRegistry.voice
        let after = VoiceToolCompaction.compact(before)
        XCTAssertEqual(after.count, before.count, "no tool is dropped")
        XCTAssertEqual(after.compactMap { $0["name"] as? String },
                       before.compactMap { $0["name"] as? String },
                       "same tools, same order")
        for (b, a) in zip(before, after) {
            let name = b["name"] as? String ?? "?"
            XCTAssertEqual(a["type"] as? String, b["type"] as? String, name)
            let bp = b["parameters"] as? [String: Any] ?? [:]
            let ap = a["parameters"] as? [String: Any] ?? [:]
            XCTAssertEqual((ap["required"] as? [String])?.sorted(), (bp["required"] as? [String])?.sorted(), "\(name): required")
            let bProps = bp["properties"] as? [String: Any] ?? [:]
            let aProps = ap["properties"] as? [String: Any] ?? [:]
            XCTAssertEqual(Set(aProps.keys), Set(bProps.keys), "\(name): same parameters")
            for (k, rawB) in bProps {
                guard let pB = rawB as? [String: Any], let pA = aProps[k] as? [String: Any] else {
                    return XCTFail("\(name).\(k) is not an object")
                }
                XCTAssertEqual(pA["type"] as? String, pB["type"] as? String, "\(name).\(k): type")
                XCTAssertEqual((pA["enum"] as? [String])?.sorted(), (pB["enum"] as? [String])?.sorted(), "\(name).\(k): enum values")
                XCTAssertEqual((pA["items"] as? [String: Any])?["type"] as? String,
                               (pB["items"] as? [String: Any])?["type"] as? String, "\(name).\(k): array item type")
            }
            // Never leave a tool undescribed: an unlabelled tool is harder to
            // choose than a blunt one.
            let d = a["description"] as? String ?? ""
            XCTAssertFalse(d.isEmpty, "\(name): still described")
            XCTAssertLessThanOrEqual(d.count, VoiceToolCompaction.toolDescriptionCap + 1, "\(name): \(d)")
        }
    }

    func testItActuallySavesAMeaningfulShareOfThePrefix() {
        let before = VoiceToolCompaction.jsonBytes(ToolRegistry.voice)
        let after = VoiceToolCompaction.jsonBytes(VoiceToolCompaction.compact(ToolRegistry.voice))
        let saved = Double(before - after) / Double(before)
        // Measured at ~36 % when written. The floor guards against someone
        // re-lengthening the descriptions without noticing what it costs.
        XCTAssertGreaterThan(saved, 0.30, "compaction saved only \(Int(saved * 100))% (\(before) → \(after) bytes)")
        print("voice tool schemas: \(before) → \(after) bytes (\(Int(saved * 100))% smaller)")
    }

    // MARK: shortening rules

    func testKeepsTheFirstSentenceAndCapsIt() {
        let long = "Move today's unfinished scheduled tasks to tomorrow — all of them, or only taskIds. The result says which were moved and which could not be: repeat that faithfully."
        let s = VoiceToolCompaction.shorten(long, cap: VoiceToolCompaction.toolDescriptionCap)
        XCTAssertTrue(s.hasPrefix("Move today's unfinished scheduled tasks to tomorrow"), s)
        XCTAssertFalse(s.contains("repeat that faithfully"), "the elaboration goes")
        XCTAssertLessThanOrEqual(s.count, VoiceToolCompaction.toolDescriptionCap + 1)
    }

    func testDoesNotSplitOnAnAbbreviation() {
        let s = VoiceToolCompaction.shorten("Pick a day, e.g. Monday, for the slot. Then confirm it.", cap: 200)
        XCTAssertEqual(s, "Pick a day, e.g. Monday, for the slot.", "e.g. is not the end of a sentence")
    }

    func testShortTextAndEdgeCasesAreLeftAlone() {
        XCTAssertEqual(VoiceToolCompaction.shorten("Pause the running focus session.", cap: 140), "Pause the running focus session.")
        XCTAssertEqual(VoiceToolCompaction.shorten("", cap: 140), "")
        XCTAssertEqual(VoiceToolCompaction.shorten("   ", cap: 140), "")
        // A single very long word still gets cut rather than blowing the cap.
        XCTAssertLessThanOrEqual(VoiceToolCompaction.shorten(String(repeating: "x", count: 300), cap: 40).count, 41)
    }

    func testAParameterKeepsItsProseONLYWhenItCarriesAFormatOrDefault() {
        // These change what the model sends, so they stay.
        for keep in ["Local 'YYYY-MM-DD HH:MM'.", "Defaults to today.", "0 (off), 5, 10 or 15.",
                     "Their reminders VERBATIM, one per note.", "Omit for all of today's unfinished ones.",
                     "Minutes, 1 to 180."] {
            XCTAssertTrue(VoiceToolCompaction.carriesFormatOrDefault(keep), keep)
        }
        // These merely restate the parameter's own name, so they go.
        for drop in ["The task's title.", "Only tasks with this tag.", "Words from the task's title.",
                     "The smallest concrete first step.", "A short label."] {
            XCTAssertFalse(VoiceToolCompaction.carriesFormatOrDefault(drop), drop)
        }
        // And the real registry keeps the date/time formats the tools need.
        let byName = Dictionary(uniqueKeysWithValues: VoiceToolCompaction.compact(ToolRegistry.voice)
            .compactMap { t -> (String, [String: Any])? in (t["name"] as? String).map { ($0, t) } })
        func prose(_ tool: String, _ param: String) -> String? {
            let props = (byName[tool]?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
            return (props?[param] as? [String: Any])?["description"] as? String
        }
        XCTAssertNotNil(prose("request_call", "when"), "a call time's format must survive")
        XCTAssertNotNil(prose("create_task", "date") ?? prose("schedule_task", "date"), "a date's format must survive")
        XCTAssertNil(prose("create_task", "name"), "but a restatement of the name does not")
    }

    func testAParameterDocumentedByItsEnumLosesItsProse() {
        let tool: [String: Any] = [
            "type": "function", "name": "get_tasks", "description": "Read tasks. Long tail of explanation.",
            "parameters": ["type": "object", "required": ["view"], "properties": [
                "view": ["type": "string", "enum": ["today", "backlog"], "description": "Which tasks to list."],
                "area": ["type": "string", "description": "Only tasks in this life area, taken from context.areas which lists them all."],
            ]],
        ]
        let out = VoiceToolCompaction.compactTool(tool)
        let props = (out["parameters"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let view = props["view"] as? [String: Any] ?? [:]
        XCTAssertNil(view["description"], "the enum values are the documentation")
        XCTAssertEqual((view["enum"] as? [String])?.count, 2, "but the values themselves stay")
        let area = props["area"] as? [String: Any] ?? [:]
        XCTAssertNil(area["description"], "prose that only restates the parameter name goes too")
    }
}
