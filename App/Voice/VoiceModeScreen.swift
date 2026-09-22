// Full-screen realtime voice mode — live speech-to-speech with Qwen-Omni
// (through the Cloudflare proxy). Talk naturally; it listens, reasons, runs your
// scheduling tools, and speaks back, with barge-in. 1:1 with the Android
// VoiceModeScreen. The VoiceSessionModel owns the audio engine + realtime client
// and wires their callbacks to observable UI state; the tool calls reuse the
// SAME dispatcher as text mode.
//
// "UNSTUCK CALLS YOU", FALLBACK B: three presenters can show this cover
// (MainTabScaffold, TodayFeature's gateway mic, the Assistant sheet's Talk
// button). Only ONE VoiceModeScreen is ever up — `VoiceSessionModel.isPresented`
// tells the scaffold not to stack a second cover — so when a tapped call alert
// parks a CallSession on RealtimeCallVoiceLauncher.shared.pendingSession while
// a Talk is already open, THIS screen takes it: the running client is stopped
// (its receipts land in the thread) and a fresh one connects with the call
// configuration (notes read back first, call tools only).
//
// NOTE: the graph compiles + wires end-to-end, but real audio (levels, echo,
// barge-in, sample-rate drift) can only be validated on a device.

import SwiftUI
import AVFoundation
import UnstuckDesign

@MainActor
@Observable
final class VoiceSessionModel {
    /// True while a VoiceModeScreen is on screen (set by its onAppear /
    /// onDisappear). A fallback-B call arriving then is taken over by that
    /// screen instead of a second cover being presented on top of it.
    static fileprivate(set) var isPresented = false

    var state: VoiceState = .connecting
    /// Everything the caption line shows, as ONE reducer (VoiceCaption.swift):
    /// a late user-ASR result must not wipe the reply it caused, and successive
    /// reply segments must not run together.
    private(set) var captions = VoiceCaptionState()
    /// The streaming assistant caption (cleared at the start of each user turn).
    var caption: String { captions.caption }
    /// The user's last transcribed turn, shown briefly until the assistant's
    /// reply starts streaming — so a spoken request isn't silently discarded.
    var userTranscript: String { captions.userTranscript }
    /// A short message for the user: a permission / config / mic error, or a
    /// provider failure mid-session. Shown in the error state AS the status
    /// line, and under the status line in every other state — a note set while
    /// the session stays live (a rate-limited reply) used to be written and
    /// never displayed, which is what "it just went quiet" was (audit
    /// 2026-09-21). Cleared when the assistant speaks again.
    var note: String?
    /// The call this screen is running (fallback B), nil for a plain Talk.
    private(set) var callSession: CallSession?
    /// Hold-to-talk (Settings "Voice: hold to talk", UserDefaults
    /// `unstuck.voice.holdToTalk`): turn_detection null, the mic only opens
    /// while the button is held and the turn commits on release. Read at
    /// connect time so a mid-session toggle applies to the next session.
    private(set) var holdToTalk = false
    /// Hold-to-talk: the button is currently down (drives the state label).
    private(set) var pttPressed = false

    private let model: AppModel
    /// One engine per connection: a stopped client shuts its engine down, and
    /// a take-over (call arriving mid-Talk) connects again on a fresh graph.
    private var audio = VoiceAudioEngine()
    private var client: VoiceRealtimeClient?
    private var interruption: (any NSObjectProtocol)?
    private var routeChange: (any NSObjectProtocol)?
    private var micGranted = false
    /// A capture failure is terminal for the session. onOpen()'s `.listening`
    /// and stop()'s `.closed` land on the main actor AFTER it and used to
    /// overwrite `.error`, hiding `note` — the label only renders the note in
    /// the error state, so the real reason never reached the user.
    private var failed = false
    /// Quiet reconnects after the server failed the session before any reply
    /// (its capacity error — device 2026-09-20 00:41: "Socket is not
    /// connected" on the first try, fine on the second). Per user-initiated start.
    private var reconnects = 0
    private var ended = false

    init(model: AppModel) { self.model = model }

    /// Live = a session is connecting or active (keeps the screen awake).
    var isLive: Bool { state == .connecting || state == .listening || state == .thinking || state == .speaking }

    func start() {
        // The three preconditions that silently dead-end Talk, in one line.
        voiceLog.notice("voice start tokenLen=\(self.model.voiceAccessToken?.count ?? -1, privacy: .public) configured=\(self.model.voiceConfigured, privacy: .public) proxy=\(self.model.voiceProxyURL, privacy: .public)")
        guard let token = model.voiceAccessToken, !token.isEmpty else {
            note = "Please sign in to use voice."; state = .error; return
        }
        guard model.voiceConfigured else { note = "Voice isn't set up yet."; state = .error; return }
        note = nil; state = .connecting
        reconnects = 0; ended = false
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                voiceLog.notice("voice mic permission granted=\(granted, privacy: .public)")
                guard granted else { self.note = "Microphone access is needed for voice."; self.state = .error; return }
                self.micGranted = true
                // A call may have arrived while the permission prompt was up —
                // connect() takes it; nothing to restart yet.
                self.connect(token: token)
            }
        }
    }

    /// Fallback B, mid-Talk: a call alert was tapped while this screen is up.
    /// Take the pending session and RESTART with the call configuration.
    /// Before the mic permission lands, `start()`'s connect will take it.
    func takeOverPendingCall() {
        guard RealtimeCallVoiceLauncher.shared.pendingSession != nil, micGranted else { return }
        guard let token = model.voiceAccessToken, !token.isEmpty, model.voiceConfigured else { return }
        // Stop the current conversation; what it changed lands in the thread.
        client?.stop()
        client = nil
        model.assistant.endVoiceSession()
        captions.reset(); note = nil
        state = .connecting
        reconnects = 0
        connect(token: token)
    }

    private func connect(token: String) {
        failed = false
        let proxyURL = model.voiceProxyURL
        let modelId = model.voiceModel
        let assistant = model.assistant
        assistant.resetVoiceScratch()
        var instructions = assistant.voiceInstructions()
        var opening = assistant.voiceOpening()
        var tools = assistant.voiceTools()
        var runTool: @Sendable (String, String) async -> String = { name, argsJSON in
            await assistant.runVoiceTool(name: name, argsJSON: argsJSON)
        }
        // "Unstuck calls you", fallback B (no CallKit): a tapped call alert parks
        // the CallSession on the launcher — take it and run the CALL configuration
        // (notes read back first, call tools only) instead of a plain Talk.
        callSession = nil
        if let call = RealtimeCallVoiceLauncher.shared.takePendingSession(),
           let cfg = RealtimeCallVoiceLauncher.shared.talkConfiguration(for: call) {
            callSession = call
            instructions = cfg.instructions
            opening = cfg.primer
            tools = cfg.tools
            runTool = cfg.runTool
        }
        // A previous client (take-over) already shut its engine down — a fresh
        // graph avoids re-attaching nodes to a stopped AVAudioEngine.
        let engine = VoiceAudioEngine()
        audio = engine
        // Mic acquisition failed (session activate / engine.start() — typically
        // the mic held by another app). Stop the client + surface a note instead
        // of leaving the UI stuck on "Listening…". 1:1 with Android.
        engine.onCaptureError = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.failed = true
                self.client?.stop()
                self.note = "Couldn't access the microphone — it may be in use by another app."
                self.state = .error
            }
        }
        holdToTalk = VoiceRealtimeClient.holdToTalkPreferred
        pttPressed = false
        let rc = VoiceRealtimeClient(
            proxyURL: proxyURL, token: token, model: modelId,
            instructions: instructions, opening: opening, tools: tools, audio: engine,
            runTool: runTool,
            onState: { [weak self] s in Task { @MainActor in
                guard let self, !self.failed else { return }
                // A reply is coming: whatever went wrong before is over.
                if s == .speaking { self.note = nil }
                self.state = s
            } },
            onCaption: { [weak self] role, text, done in
                Task { @MainActor in
                    // One pure reducer (VoiceCaption.swift) — a user ASR result
                    // that lands after the reply started must not wipe its first
                    // words, and a second reply segment must not run into the first.
                    self?.captions.apply(role: role, text: text, done: done)
                }
            },
            onError: { [weak self] msg in voiceLog.error("voice error \(msg, privacy: .public)"); Task { @MainActor in self?.note = msg } },
            holdToTalk: holdToTalk)
        client = rc
        // Dead on arrival (the server failed before any reply): reconnect,
        // twice at most, before telling the user anything.
        rc.onTransportEnded = { [weak self, weak rc] error in
            Task { @MainActor in
                guard let self, let rc, self.client === rc, !self.ended, !self.failed, rc.failedBeforeAnyReply else { return }
                if self.reconnects < 2 {
                    self.reconnects += 1
                    voiceLog.notice("voice reconnect #\(self.reconnects, privacy: .public): the server failed before any reply (\(error ?? "closed", privacy: .public))")
                    self.client = nil
                    self.state = .connecting
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !self.ended, self.client == nil else { return }
                    self.connect(token: token)
                } else {
                    self.note = "The voice server dropped the session twice. Please try again in a moment."
                    self.state = .error
                }
            }
        }
        observeInterruptions()
        rc.start()
    }

    /// Manual Interrupt = a HARD cancel (never ducks). Meaningful only while
    /// the model is responding or playing — `canInterrupt`.
    func interrupt() {
        // Barge-in starts a fresh turn — drop the stale caption + user echo.
        captions.reset()
        client?.interrupt()
    }

    /// The model is generating or its audio is still playing — the Interrupt
    /// button's enablement (BargeInController.modelBusy as the UI sees it).
    var canInterrupt: Bool { state == .speaking || state == .thinking }

    /// Hold-to-talk: press — cancels a playing reply and opens the mic.
    func pttDown() {
        guard holdToTalk, !pttPressed else { return }
        pttPressed = true
        captions.reset()
        client?.pttDown()
    }

    /// Hold-to-talk: release — commits the buffer and asks for the reply.
    func pttUp() {
        guard pttPressed else { return }
        pttPressed = false
        client?.pttUp()
    }

    func end() {
        ended = true
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        if let routeChange { NotificationCenter.default.removeObserver(routeChange) }
        interruption = nil
        routeChange = nil
        if let client { client.stop() } else { audio.shutdown() }
        client = nil
        callSession = nil
        // The session's receipts (and their Undo) land in the shared thread as
        // a local turn so they don't vanish with the overlay.
        model.assistant.endVoiceSession()
    }

    /// End the session if another app (e.g. an incoming call) interrupts audio —
    /// the iOS analog of Android's audio-focus loss — or if the active input
    /// route disappears (e.g. headset unplugged), matching Android's
    /// headset-removal teardown. Idempotent (a take-over reconnects on the
    /// same observers).
    private func observeInterruptions() {
        guard interruption == nil else { return }
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let info = n.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.end() }
        }
        // Headset removal: the OS pulls the old input device. End rather than
        // silently fall back to the built-in mic/speaker mid-call.
        routeChange = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            guard let info = n.userInfo,
                  let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.end() }
        }
    }
}

struct VoiceModeScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: VoiceSessionModel?

    var body: some View {
        ZStack {
            theme.palette.bg.ignoresSafeArea()

            // Close (X)
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.palette.ink2)
                            .frame(width: 40, height: 40).background(theme.palette.bg2, in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Close voice mode")
                }
                Spacer()
            }
            .padding(18)

            if let session { center(session) } else { ProgressView() }

            // End
            VStack {
                Spacer()
                Button { dismiss() } label: {
                    Text("End")
                        .font(UFont.sans(15, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(theme.palette.coral, in: Capsule())
                }.buttonStyle(.plain).padding(.bottom, 48)
            }
        }
        .onAppear { VoiceSessionModel.isPresented = true }
        .task {
            if session == nil { let s = VoiceSessionModel(model: model); session = s; s.start() }
        }
        .onDisappear {
            VoiceSessionModel.isPresented = false
            session?.end(); UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: session?.isLive ?? false) { _, live in
            UIApplication.shared.isIdleTimerDisabled = live   // keep the screen awake mid-call
        }
        // A call alert tapped while THIS Talk is open: take the pending call
        // here (the scaffold won't present a second cover over us).
        .onChange(of: RealtimeCallVoiceLauncher.shared.pendingSession != nil) { _, hasCall in
            if hasCall { session?.takeOverPendingCall() }
        }
        // Backgrounding/locking the app under a fullScreenCover does NOT fire
        // .onDisappear, so without this a backgrounded session is a zombie call
        // (mic + WebSocket + voiceChat audio session left alive). End it the
        // moment we leave .active — the iOS analog of Android's ON_STOP teardown.
        // end() is idempotent (client.stop() guards _stopped; end() nils client).
        .onChange(of: scenePhase) { _, phase in
            // ONLY a real background (Android's ON_STOP). `.inactive` is a
            // transient resign-active — the microphone permission alert, Control
            // Centre, a banner, an incoming call — and ending there killed the
            // session the user had just started: on a FIRST-EVER Talk the
            // permission prompt itself tore the session down and left a dead
            // screen. Audit + tester report, 2026-09-11.
            if phase == .background { session?.end() }
        }
    }

    private func center(_ session: VoiceSessionModel) -> some View {
        // The orb pulses while the session is live; a tap / the Interrupt
        // button barge in only while the model is responding ("Thinking", a
        // response is generating) or playing ("Speaking") — the hard cancel
        // is a no-op while we're merely listening, so it is disabled then.
        let live = session.isLive && session.state != .connecting
        let canInterrupt = session.canInterrupt
        let orbColor: Color
        switch session.state {
        case .speaking: orbColor = theme.palette.coral
        case .thinking: orbColor = theme.palette.amber
        default: orbColor = theme.palette.primary
        }
        return VStack(spacing: 24) {
            PulsingOrb(active: live,
                       color: orbColor,
                       onTap: canInterrupt ? { session.interrupt() } : nil)
            if let call = session.callSession {
                Text("Unstuck · \(call.label)")
                    .font(UFont.sans(13, .medium)).foregroundStyle(theme.palette.ink3)
                    .multilineTextAlignment(.center)
            }
            Text(stateLabel(session))
                .font(UFont.sans(15, .medium)).foregroundStyle(theme.palette.ink2)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
            // A note while the session is still LIVE (the error state already
            // shows it as the status line above). Without this the one message
            // written for a rate-limited reply was never rendered and the orb
            // just kept pulsing (audit 2026-09-21).
            if session.state != .error, let note = session.note, !note.isEmpty {
                Text(note)
                    .font(UFont.sans(14)).foregroundStyle(theme.palette.ink3)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            // The user's just-spoken turn, shown until the reply starts streaming
            // (so a request isn't silently discarded). Dimmer + quote-marked to
            // distinguish it from the assistant's reply below.
            if session.caption.isEmpty, !session.userTranscript.isEmpty {
                Text("“\(session.userTranscript)”")
                    .font(UFont.sans(15)).foregroundStyle(theme.palette.ink3)
                    .multilineTextAlignment(.center)
            }
            if !session.caption.isEmpty {
                Text(session.caption)
                    .font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
                    .multilineTextAlignment(.center)
            }
            if live {
                HStack(spacing: 12) {
                    Button { session.interrupt() } label: {
                        Text("Interrupt")
                            .font(UFont.sans(15, .semibold)).foregroundStyle(theme.palette.ink)
                            .padding(.horizontal, 24).padding(.vertical, 12)
                            .background(theme.palette.bg2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canInterrupt)
                    .opacity(canInterrupt ? 1 : 0.4)
                    .accessibilityHint(canInterrupt ? "Stops the assistant mid-reply" : "Available while the assistant is speaking")
                    if session.holdToTalk {
                        HoldToTalkButton(pressed: session.pttPressed,
                                         onDown: { session.pttDown() },
                                         onUp: { session.pttUp() })
                    }
                }
            }
        }
        .padding(.horizontal, 32)
    }

    private func stateLabel(_ s: VoiceSessionModel) -> String {
        switch s.state {
        case .connecting: return "Connecting…"
        case .listening:
            // Hold-to-talk: the mic is closed until the button is held.
            if s.holdToTalk { return s.pttPressed ? "Listening…" : "Hold the button to talk" }
            return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        case .error: return s.note ?? "Something went wrong."
        case .closed: return "Ended"
        }
    }
}

/// Hold-to-talk: a press-and-hold capsule. The mic opens on touch-down and
/// the turn commits on release (VoiceRealtimeClient.pttDown / pttUp). A
/// zero-distance DragGesture is the reliable press/release pair in SwiftUI;
/// `onDown` is fired once per press (the model guards re-entry too).
private struct HoldToTalkButton: View {
    @Environment(\.uTheme) private var theme
    let pressed: Bool
    let onDown: () -> Void
    let onUp: () -> Void
    @State private var down = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pressed ? "mic.fill" : "mic")
            Text(pressed ? "Release to send" : "Hold to talk")
        }
        .font(UFont.sans(15, .semibold))
        .foregroundStyle(pressed ? Color.white : theme.palette.ink)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(pressed ? theme.palette.primary : theme.palette.bg2, in: Capsule())
        .scaleEffect(pressed ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !down else { return }
                    down = true
                    onDown()
                }
                .onEnded { _ in
                    down = false
                    onUp()
                }
        )
        .accessibilityLabel("Hold to talk")
        .accessibilityHint("Press and hold while you speak; release to send")
        .accessibilityAddTraits(.isButton)
    }
}

/// A breathing circle; tap to interrupt while the model speaks.
private struct PulsingOrb: View {
    let active: Bool
    let color: Color
    let onTap: (() -> Void)?
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 120, height: 120)
            .scaleEffect(active && pulse ? 1.15 : 1.0)
            .overlay(Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.white.opacity(0.9)))
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
            // Reliable circular hit shape (the scaleEffect/overlay otherwise leave
            // hit-test gaps), and announce it as a button to VoiceOver.
            .contentShape(Circle())
            .onTapGesture { onTap?() }
            .accessibilityLabel(onTap != nil ? "Tap to interrupt" : "Assistant")
            .accessibilityAddTraits(onTap != nil ? .isButton : [])
    }
}
