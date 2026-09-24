// RealtimeCallVoiceLauncher — the CallVoiceLauncher (CallSeams.swift) over the
// realtime voice stack. Once CallKit has activated audio, the coordinator
// calls `start`, and the launcher opens a VoiceRealtimeClient whose session is
// the normal Talk session PLUS the call script:
//
//   instructions = the assistant's voice instructions (scope guardrail + live
//                  app state, AssistantContext.buildVoiceInstructions)
//                  + "\n\n" + CallScript.instructions(session)
//   opening      = CallScript.opening(session) — the verbatim first utterance,
//                  carried by the hidden PRIMER item exactly the way Talk sends
//                  its opening (conversation.item.create + response.create,
//                  deleted after the first reply)
//   tools        = the VOICE_TOOLS schemas filtered to CallScript.callTools,
//                  plus the call-level snooze_call {minutes: integer, default 10}
//   runTool      = snooze_call → CallCoordinator.snoozeActiveCall — the ONE
//                  source of truth: the coordinator hangs up (CXEndCallAction →
//                  performEnd → launcher.stop() + outcome `snoozed`); the
//                  launcher returns the tool result and does NOT end itself
//                  (ending here too raced a second CXEndCallAction + a second
//                  outcome report);
//                  every other call tool → AssistantModel.runVoiceTool (the
//                  same executor as Talk; update_call lands in CallTools)
//
// AUDIO SESSION RULE: the engine runs with `.callKit` ownership — it never
// calls setActive(true) and never deactivates on stop(); CallKit does both.
//
// END CONTRACT: `onEnded` fires at most once, on the main actor, when the
// conversation ends on its own (transport dropped → .failed / clean close →
// .hungUp) and NEVER after `stop()`. A protocol-level `error` event does not
// end the call (the model keeps talking). A snooze never fires `onEnded`.
//
// Built over `CallRealtimeSession` + `Deps` so it runs in XCTest with no
// socket, no AVFoundation and no AppModel (RealtimeCallVoiceLauncherTests).
//
// FALLBACK B (no CallKit — the user tapped the time-sensitive "call" alert):
// `installCallVoiceLauncher` routes `CallCoordinator.onFallbackAnswer` into
// `RealtimeCallVoiceLauncher.shared.pendingSession` (observable). The root
// view presents VoiceModeScreen when it becomes non-nil; VoiceModeScreen
// calls `takePendingSession()` and builds its session from
// `talkConfiguration(for:)` (instructions / primer / tools / runTool) instead
// of the plain Talk opening. In that path snooze_call reports the `snoozed`
// outcome through the coordinator's PERSISTED, ordered outcome reporter
// (CallCoordinator.reportFallbackSnooze — retried, never lost behind a
// tunnel) and the user ends the screen themselves.

import Foundation
import Observation
import UnstuckCore
import UnstuckSync

/// What the launcher needs from a realtime voice session (VoiceRealtimeClient
/// in production; a fake in tests).
protocol CallRealtimeSession: AnyObject, Sendable {
    func start()
    func stop()
    func setMicMuted(_ muted: Bool)
    /// Set when a daily limit ended the session (today's voice minutes, or
    /// the proxy's reply budget) — the plain line for the post-call notice
    /// (VoiceRealtimeClient.dailyLimitNote).
    var dailyLimitNote: String? { get }
}

extension VoiceRealtimeClient: CallRealtimeSession {}

/// Everything a call's realtime session is built from (what the tests and
/// the fallback-B Talk screen consume).
struct CallVoiceSessionConfig {
    let session: CallSession
    /// session.instructions: the assistant's voice instructions + the call script.
    let instructions: String
    /// The verbatim first utterance (CallScript.opening).
    let opening: String
    /// The hidden primer item that carries `opening` — sent exactly like Talk's
    /// opening (VoiceRealtimeClient `opening:`).
    let primer: String
    /// Call tools only (+ snooze_call), realtime function shape.
    let tools: [[String: Any]]
    let runTool: @Sendable (_ name: String, _ argsJSON: String) async -> String
    /// The transport ended on its own (nil = clean close). No-op for fallback B.
    let onTransportEnded: @Sendable (_ error: String?) -> Void

    var toolNames: [String] { tools.compactMap { $0["name"] as? String } }
}

@MainActor
@Observable
final class RealtimeCallVoiceLauncher: CallVoiceLauncher {
    /// The app-wide launcher (bound by `AppModel.installCallVoiceLauncher`).
    static let shared = RealtimeCallVoiceLauncher()

    /// The app-side seams. `live(_:)` binds them to AppModel; tests inject fakes.
    struct Deps {
        var isVoiceConfigured: () -> Bool
        var accessToken: () -> String?
        /// AssistantModel.voiceInstructions() — guardrail + live app state.
        var voiceInstructions: () -> String
        /// AssistantModel.voiceTools() — VOICE_TOOLS.
        var voiceTools: () -> [[String: Any]]
        /// AssistantModel.runVoiceTool(name:argsJSON:) — the Talk executor.
        var runAppTool: (_ name: String, _ argsJSON: String) async -> String
        /// CallCoordinator.snoozeActiveCall(minutes:) — returns the tool result.
        var snooze: (_ minutes: Int) -> String
        /// Fallback B: report `snoozed` for a call that has no CallKit call.
        var reportFallbackSnooze: (_ callId: String, _ minutes: Int) -> Void
        /// AssistantModel.resetVoiceScratch / endVoiceSession (receipts land in
        /// the thread as "While we talked:").
        var sessionWillStart: () -> Void
        var sessionDidEnd: () -> Void
        /// The realtime session over the config (VoiceRealtimeClient +
        /// VoiceAudioEngine(.callKit) in production). nil ⇒ voice unavailable.
        var makeSession: (CallVoiceSessionConfig) -> CallRealtimeSession?
        var now: () -> Date
        /// CallDayContext.lines over the live store — what got done today,
        /// what's open, today's plan — for the call instructions. Default:
        /// nothing (tests; a store that isn't ready).
        var dayContext: (CallKind) -> [String] = { _ in [] }
        /// AppModel.aiConsentGranted — without the account's OK the call
        /// never connects to the assistant (AIConsent). Default: granted (tests).
        var hasAIConsent: () -> Bool = { true }
    }

    /// Fallback B: the call session Talk should open with. Observable so the
    /// root view can present VoiceModeScreen when it becomes non-nil.
    var pendingSession: CallSession?

    @ObservationIgnored private var deps: Deps?
    @ObservationIgnored private var active: Active?
    /// Bumped per start(); a callback from an older session is ignored.
    @ObservationIgnored private var generation = 0
    /// CallKit's mute state — applied to the session (also if set before start).
    @ObservationIgnored private var muted = false

    private struct Active {
        let session: CallSession
        let realtime: CallRealtimeSession
        let onEnded: @MainActor (CallEndReason) -> Void
        let generation: Int
    }

    init(deps: Deps? = nil) { self.deps = deps }

    func bind(_ deps: Deps) { self.deps = deps }

    /// The call the launcher is currently running (nil = idle).
    var activeSession: CallSession? { active?.session }

    /// Read-and-clear the fallback-B hand-off (VoiceModeScreen).
    func takePendingSession() -> CallSession? {
        defer { pendingSession = nil }
        return pendingSession
    }

    // MARK: - CallVoiceLauncher

    func start(_ session: CallSession, onEnded: @escaping @MainActor (CallEndReason) -> Void) {
        // One conversation at a time: a stale one is torn down silently.
        teardownActive()
        guard let deps else { onEnded(.failed("voice launcher not bound")); return }
        guard deps.isVoiceConfigured() else { onEnded(.failed("voice not configured")); return }
        guard let token = deps.accessToken(), !token.isEmpty else { onEnded(.failed("not signed in")); return }
        // The receipt rule already declined a call without the OK; this
        // catches one turned off between the ring and the answer.
        guard deps.hasAIConsent() else { onEnded(.noAIConsent); return }
        generation += 1
        let gen = generation
        let config = makeConfig(session, deps: deps, generation: gen)
        guard let realtime = deps.makeSession(config) else { onEnded(.failed("voice unavailable")); return }
        active = Active(session: session, realtime: realtime, onEnded: onEnded, generation: gen)
        deps.sessionWillStart()
        realtime.setMicMuted(muted)
        realtime.start()
    }

    /// Tear the conversation down. Never deactivates the audio session (the
    /// engine's `.callKit` ownership) and never calls `onEnded`.
    func stop() {
        teardownActive()
        muted = false
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        active?.realtime.setMicMuted(muted)
    }

    // MARK: - fallback B (Talk screen)

    /// The session VoiceModeScreen builds for a call answered without CallKit:
    /// same instructions / primer / tools; snooze_call reports the outcome and
    /// returns — the screen stays up until the user ends it. nil until bound.
    func talkConfiguration(for session: CallSession) -> CallVoiceSessionConfig? {
        guard let deps else { return nil }
        let comp = Self.compose(session: session, baseInstructions: deps.voiceInstructions(),
                                voiceTools: deps.voiceTools(), now: deps.now(), dayContext: deps.dayContext(session.kind))
        return CallVoiceSessionConfig(
            session: session, instructions: comp.instructions, opening: comp.opening,
            primer: comp.primer, tools: comp.tools,
            runTool: { [weak self] name, argsJSON in
                await self?.runFallbackTool(name, argsJSON, callId: session.callId) ?? "error: the call has ended"
            },
            onTransportEnded: { _ in })
    }

    // MARK: - composition (pure; tested)

    struct Composition {
        let instructions: String
        let opening: String
        let primer: String
        let tools: [[String: Any]]
    }

    /// instructions = base + call script; opening = CallScript.opening; primer
    /// wraps the opening; tools = call tools only (+ snooze_call).
    static func compose(session: CallSession, baseInstructions: String, voiceTools: [[String: Any]],
                        now: Date = Date(), dayContext: [String] = []) -> Composition {
        let opening = CallScript.opening(session, now: now)
        return Composition(
            instructions: baseInstructions + "\n\n" + CallScript.instructions(session, now: now, dayContext: dayContext),
            opening: opening,
            primer: primer(opening: opening),
            tools: callToolSchemas(from: voiceTools))
    }

    /// The hidden primer: the trigger for the opening, which the call
    /// instructions carry verbatim. It must NOT quote the opening itself:
    /// with both the instructions and the primer quoting it, the model spoke
    /// it twice, as two message items in one response — every call, measured
    /// through the proxy 2026-09-21 (Zubair heard every greeting twice).
    /// Pointing at the instructions instead: once, every time.
    static func primer(opening: String) -> String {
        _ = opening
        return "(The call just connected — YOU rang them; this is not the user speaking. Say your opening line now, once, exactly as your instructions give it, then listen. Never repeat it later.)"
    }

    /// The voice schemas filtered to CallScript.callTools (in that order —
    /// since the calls build-out that is EVERY voice tool: a call is the full
    /// assistant); the call-only extras from the registry's call surface
    /// (`ToolRegistry.call` — `snoozeCallSchema` is the fallback when the
    /// registry lacks snooze_call), update_call from `updateCallSchema` when
    /// neither surface carries one.
    static func callToolSchemas(from voiceTools: [[String: Any]]) -> [[String: Any]] {
        var byName: [String: [String: Any]] = [:]
        for t in voiceTools + ToolRegistry.call {
            if let n = t["name"] as? String, byName[n] == nil { byName[n] = t }
        }
        return CallScript.callTools.compactMap { name in
            if let s = byName[name] { return s }
            if name == "snooze_call" { return snoozeCallSchema }
            return name == "update_call" ? updateCallSchema : nil
        }
    }

    /// Call-level: "call me back in ten". `{minutes: integer, default 10}`.
    static let snoozeCallSchema: [String: Any] = [
        "type": "function", "name": "snooze_call",
        "description": "\"Call me back in ten\" — hang up now and ring again in `minutes`. Say the minutes out loud, then a quick goodbye.",
        "parameters": [
            "type": "object",
            "properties": ["minutes": ["type": "integer", "description": "Minutes until the call-back (1–180).", "default": 10]],
            "required": [],
        ],
    ]

    /// Mirrors tools.ts `update_call` (used when VOICE_TOOLS lacks it).
    static let updateCallSchema: [String: Any] = [
        "type": "function", "name": "update_call",
        "description": "Change this call's notes for later (replaces them, verbatim), or its label/time.",
        "parameters": [
            "type": "object",
            "properties": [
                "callId": ["type": "string", "description": "The call id from the call context."],
                "notes": ["type": "array", "items": ["type": "string"], "description": "Replaces the notes, verbatim."],
                "label": ["type": "string", "description": "New label."],
                "when": ["type": "string", "description": "New local 'YYYY-MM-DD HH:MM'."],
            ],
            "required": ["callId"],
        ],
    ]

    /// `{minutes}` from the raw tool args; default 10.
    static func snoozeMinutes(_ argsJSON: String) -> Int {
        let parsed = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]
        return CallToolLogic.int(parsed?["minutes"]) ?? 10
    }

    /// The coordinator's clamp (1…180) — the `.snoozed` reason carries the same.
    static func clampSnooze(_ m: Int) -> Int { min(180, max(1, m)) }

    // MARK: - internals

    private func makeConfig(_ session: CallSession, deps: Deps, generation gen: Int) -> CallVoiceSessionConfig {
        let comp = Self.compose(session: session, baseInstructions: deps.voiceInstructions(),
                                voiceTools: deps.voiceTools(), now: deps.now(), dayContext: deps.dayContext(session.kind))
        return CallVoiceSessionConfig(
            session: session, instructions: comp.instructions, opening: comp.opening,
            primer: comp.primer, tools: comp.tools,
            runTool: { [weak self] name, argsJSON in
                await self?.runCallTool(name, argsJSON, generation: gen) ?? "error: the call has ended"
            },
            onTransportEnded: { [weak self] error in
                // The client reports from its URLSession delegate queue → hop.
                // Already on main (tests, the mic-failure path) → synchronous,
                // so "ended exactly once, never after stop()" is deterministic.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.transportEnded(error, generation: gen) }
                } else {
                    Task { @MainActor in self?.transportEnded(error, generation: gen) }
                }
            })
    }

    private func runCallTool(_ name: String, _ argsJSON: String, generation gen: Int) async -> String {
        guard let deps, active?.generation == gen else { return "error: the call has ended" }
        if name == "snooze_call" {
            // The coordinator hangs the call up (async CXEndCallAction →
            // performEnd → our stop()) and reports `snoozed` ONCE. Never
            // `finish` here: that fired onEnded → a second endActiveCall.
            return deps.snooze(Self.snoozeMinutes(argsJSON))
        }
        guard CallScript.callTools.contains(name) else { return "error: \(name) isn't available during a call" }
        return await deps.runAppTool(name, argsJSON)
    }

    private func runFallbackTool(_ name: String, _ argsJSON: String, callId: String) async -> String {
        guard let deps else { return "error: the call has ended" }
        if name == "snooze_call" {
            let m = Self.clampSnooze(Self.snoozeMinutes(argsJSON))
            deps.reportFallbackSnooze(callId, m)
            return "ok: I'll call back in \(m) minutes — say a quick goodbye; they end the call from the screen"
        }
        guard CallScript.callTools.contains(name) else { return "error: \(name) isn't available during a call" }
        return await deps.runAppTool(name, argsJSON)
    }

    private func transportEnded(_ error: String?, generation gen: Int) {
        // Today's voice minutes ran out (Ahmad 2026-09-23) — or another daily
        // limit closed it the same way: the call did not fail — it ends
        // normally, and the notice after it says why in plain words instead
        // of "Couldn't start the call".
        if error != nil, let a = active, a.generation == gen, let note = a.realtime.dailyLimitNote {
            finish(.outOfMinutes(note), generation: gen)
            return
        }
        finish(error.map { .failed($0) } ?? .hungUp, generation: gen)
    }

    /// The conversation ended on its own: tear down, then `onEnded` once. A
    /// stale generation (already stopped, or a newer call) is ignored.
    private func finish(_ reason: CallEndReason, generation gen: Int) {
        guard let a = active, a.generation == gen else { return }
        active = nil
        a.realtime.stop()
        deps?.sessionDidEnd()
        a.onEnded(reason)
    }

    private func teardownActive() {
        guard let a = active else { return }
        active = nil
        a.realtime.stop()
        deps?.sessionDidEnd()
    }
}

// MARK: - AppModel hook

extension RealtimeCallVoiceLauncher.Deps {
    /// The production seams over AppModel: the assistant's voice instructions
    /// + tools + executor, the CallKit coordinator's snooze, and a
    /// VoiceRealtimeClient over a `.callKit`-owned VoiceAudioEngine.
    @MainActor
    static func live(_ model: AppModel) -> RealtimeCallVoiceLauncher.Deps {
        RealtimeCallVoiceLauncher.Deps(
            isVoiceConfigured: { [weak model] in model?.voiceConfigured ?? false },
            accessToken: { [weak model] in model?.voiceAccessToken },
            voiceInstructions: { [weak model] in model?.assistant.voiceInstructions() ?? "" },
            voiceTools: { [weak model] in model?.assistant.voiceTools() ?? [] },
            runAppTool: { [weak model] name, argsJSON in
                guard let model else { return "error: the app isn't ready" }
                return await model.assistant.runVoiceTool(name: name, argsJSON: argsJSON)
            },
            snooze: { CallCoordinator.shared.snoozeActiveCall(minutes: $0) },
            // Through the persisted reporter: ordered after the tap's
            // `answered`, retried with backoff, replayed after a kill — a
            // fire-and-forget request here (no-op with no client attached, lost
            // on a transient failure) left rows `answered` with no snooze_until.
            reportFallbackSnooze: { callId, minutes in
                CallCoordinator.shared.reportFallbackSnooze(callId: callId, minutes: minutes)
            },
            sessionWillStart: { [weak model] in model?.assistant.resetVoiceScratch() },
            sessionDidEnd: { [weak model] in model?.assistant.endVoiceSession() },
            makeSession: { [weak model] config in
                guard let model, let token = model.voiceAccessToken, !token.isEmpty else { return nil }
                let audio = VoiceAudioEngine(sessionOwnership: .callKit)
                // A CallKit call plays through the handset receiver (or a
                // headset) unless the user flips it to speaker — the low-echo
                // barge-in profile from the first session.update, without
                // reading AVAudioSession before CallKit has settled the route;
                // later route changes still re-profile through routeProvider.
                // Never hold-to-talk: there is no press UI on the lock screen.
                // The escape hatch as a value, not `config` (non-Sendable) — the
                // capture-mic failure below has always done this.
                let ended = config.onTransportEnded
                // The dial awaits a fresh token (audit 2026-09-22, C14/C15): a
                // call answered on the lock screen of an app suspended overnight
                // otherwise dialled with the token cached at the last foreground
                // (the SDK refreshes only while ACTIVE) — racing the `.answered`
                // report's refresh, which it now joins. `token` is the fallback;
                // a stop() while it resolves means no dial, so nothing reaches
                // the launcher after stop().
                let client = VoiceRealtimeClient(
                    proxyURL: model.voiceProxyURL, token: token,
                    freshToken: { [weak model] force in await model?.freshVoiceAccessToken(forceRefresh: force) },
                    model: model.voiceModel,
                    instructions: config.instructions, opening: config.primer, tools: config.tools,
                    audio: audio, runTool: config.runTool,
                    onState: { _ in }, onCaption: { _, _, _ in },
                    // A provider failure mid-call was discarded, which on a
                    // live phone call is dead air with no hang-up and no
                    // explanation (audit 2026-09-21). End it the way a
                    // transport failure does, so CallKit tears the call down
                    // and the coordinator posts the "here's what it was about"
                    // notification instead.
                    onError: { message in
                        voiceLog.error("voice call failed: \(message, privacy: .public)")
                        ended(message)
                    },
                    holdToTalk: false, initialRoute: .lowEcho)
                client.onTransportEnded = config.onTransportEnded
                // The account keys the allowance the out-of-minutes line names.
                client.minutesAccount = model.coordinator?.auth.currentUserId
                // Mic acquisition failed (engine.start()) — the call can't
                // proceed; degrade to the "here's what it was about" notification.
                audio.onCaptureError = { ended("microphone unavailable") }
                return client
            },
            now: { Date() },
            dayContext: { [weak model] kind in
                guard let model else { return [] }
                let tasks = (try? model.taskRepo?.all()) ?? []
                let blocks = (try? model.db?.fetchAllCalBlocks()) ?? []
                return CallDayContext.lines(kind: kind, tasks: tasks, blocks: blocks, today: Clock.todayISO(), nowHM: localNowHM())
            },
            hasAIConsent: { [weak model] in model?.aiConsentGranted ?? false })
    }
}

extension AppModel {
    /// AppModel.start() hook: bind the realtime launcher to this model and
    /// hand it to the CallKit coordinator (a call answered while the Noop
    /// launcher was installed starts speaking now). Also takes the fallback-B
    /// answer: the tapped "call" alert → `RealtimeCallVoiceLauncher.shared
    /// .pendingSession` → the root view presents VoiceModeScreen, which reads
    /// it via `takePendingSession()` + `talkConfiguration(for:)`.
    func installCallVoiceLauncher() {
        let launcher = RealtimeCallVoiceLauncher.shared
        launcher.bind(.live(self))
        CallCoordinator.shared.attach(launcher: launcher)
        CallCoordinator.shared.onFallbackAnswer = { session in
            RealtimeCallVoiceLauncher.shared.pendingSession = session
        }
    }
}
