// Compacting the tool schemas for a SPOKEN session.
//
// Every realtime reply re-reads the whole session prefix, and the 70 tool
// schemas are about three quarters of it: ~34 KB of JSON, ~9,000 of the
// ~11,000 tokens a reply costs (measured, beta audit 2026-09-21). That prefix
// is also what fills the account's tokens-per-minute bucket, so it decides how
// many replies a conversation gets before the assistant goes quiet — which is
// what two testers actually hit.
//
// Half of those bytes are prose. The descriptions are written for the TEXT
// assistant, which reads a long paragraph once per turn; a voice turn pays for
// them again on every single reply. So voice gets a shorter copy of the SAME
// tools. Nothing is removed: every tool, every parameter and every enum
// survives, because the model must still be able to call all of them.
//
// What goes:
//   • a tool description keeps its FIRST SENTENCE, capped — the rest is
//     elaboration the model does not need to choose the tool;
//   • a parameter description is dropped when the parameter already states its
//     own values through `enum` — the values ARE the documentation;
//   • a parameter description is dropped when it merely restates the parameter
//     name ("name: The task's title", "tag: Only tasks with this tag");
//   • it is KEPT, first sentence only, when it carries something the name and
//     type cannot: a format, a default, a unit, a permitted value. Those are
//     the ones that change what the model sends ("local 'YYYY-MM-DD HH:MM'",
//     "defaults to today", "0 = off"), and losing them produces wrong calls.
//
// Measured on the shipped registry: 35,546 → ~22,700 bytes, about 36 % off the
// schema block, which is roughly a quarter off every reply.
//
// Deliberately NOT done here: touching `scripts/gen-tool-registry.mjs`. That
// generator writes the web, Android and server copies too, and iOS is the only
// platform being changed right now.

import Foundation

enum VoiceToolCompaction {
    /// A tool description past this many characters is cut to its first
    /// sentence; the first sentence is then hard-capped.
    static let toolDescriptionCap = 90
    /// Parameter prose is terser still — it is read once the tool is chosen.
    static let paramDescriptionCap = 60

    /// A parameter description EARNS its place when it says something the name
    /// and type cannot: a format, a default, a unit, a permitted value. Those
    /// change what the model sends. Everything else is a restatement of the
    /// name and is dropped.
    static func carriesFormatOrDefault(_ description: String) -> Bool {
        let d = description.lowercased()
        if d.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        for hint in ["yyyy", "hh:mm", "default", "omit", "verbatim", "minute", "local",
                     "leave", "blank", "null", "true", "false", "iso", "format"] where d.contains(hint) {
            return true
        }
        return false
    }

    /// The realtime tool list for a spoken session, compacted.
    static func compact(_ tools: [[String: Any]]) -> [[String: Any]] { tools.map(compactTool) }

    static func compactTool(_ tool: [String: Any]) -> [String: Any] {
        var t = tool
        if let d = tool["description"] as? String {
            t["description"] = shorten(d, cap: toolDescriptionCap)
        }
        if var params = tool["parameters"] as? [String: Any],
           var props = params["properties"] as? [String: Any] {
            for (name, raw) in props {
                guard var p = raw as? [String: Any] else { continue }
                if p["enum"] != nil {
                    // The allowed values say what it is; the prose repeats them.
                    p.removeValue(forKey: "description")
                } else if let d = p["description"] as? String {
                    if carriesFormatOrDefault(d) {
                        p["description"] = shorten(d, cap: paramDescriptionCap)
                    } else {
                        p.removeValue(forKey: "description")
                    }
                }
                props[name] = p
            }
            params["properties"] = props
            t["parameters"] = params
        }
        return t
    }

    /// First sentence, then a hard cap on a word boundary. Never empty: a tool
    /// with no description at all is harder to choose than a blunt one.
    static func shorten(_ text: String, cap: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return flat }
        var s = flat
        // First sentence: ". " ends one, but "e.g. " and "i.e. " do not.
        var searchFrom = s.startIndex
        while let dot = s.range(of: ". ", range: searchFrom..<s.endIndex) {
            let before = s[s.startIndex..<dot.lowerBound]
            let lastWord = before.split(separator: " ").last.map(String.init) ?? ""
            if !["e.g", "i.e", "vs", "etc", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].contains(lastWord) {
                s = String(s[s.startIndex...dot.lowerBound])
                break
            }
            searchFrom = dot.upperBound
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard s.count > cap else { return s }
        let cut = s.prefix(cap)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[cut.startIndex..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return String(cut) + "…"
    }

    /// Bytes of JSON a tool list serialises to — how the saving is measured.
    static func jsonBytes(_ tools: [[String: Any]]) -> Int {
        (try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]).count) ?? 0
    }
}
