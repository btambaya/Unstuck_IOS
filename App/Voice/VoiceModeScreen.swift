// Full-screen realtime voice mode — live speech-to-speech with Qwen-Omni
// (through the Cloudflare proxy). Talk naturally; it listens, reasons, runs your
// scheduling tools, and speaks back, with barge-in. 1:1 with the Android
// VoiceModeScreen. The VoiceSessionModel owns the audio engine + realtime client
// and wires their callbacks to observable UI state; the tool calls reuse the
// SAME dispatcher as text mode.
//
// NOTE: the graph compiles + wires end-to-end, but real audio (levels, echo,
// barge-in, sample-rate drift) can only be validated on a device.

import SwiftUI
import AVFoundation
import UnstuckDesign

@MainActor
@Observable
final class VoiceSessionModel {
    var state: VoiceState = .connecting
    /// The streaming assistant caption (cleared at the start of each user turn).
    var caption = ""
    /// A local note (permission / config / mic error) shown in the ERROR state.
    var note: String?

    private let model: AppModel
    private let audio = VoiceAudioEngine()
    private var client: VoiceRealtimeClient?
    private var interruption: (any NSObjectProtocol)?

    init(model: AppModel) { self.model = model }

    /// Live = a session is connecting or active (keeps the screen awake).
    var isLive: Bool { state == .connecting || state == .listening || state == .speaking }

    func start() {
        guard let token = model.voiceAccessToken, !token.isEmpty else {
            note = "Please sign in to use voice."; state = .error; return
        }
        guard model.voiceConfigured else { note = "Voice isn't set up yet."; state = .error; return }
        note = nil; state = .connecting
        let assistant = model.assistant
        assistant.resetVoiceScratch()
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { self.note = "Microphone access is needed for voice."; self.state = .error; return }
                self.connect(token: token, assistant: assistant)
            }
        }
    }

    private func connect(token: String, assistant: AssistantModel) {
        let proxyURL = model.voiceProxyURL
        let modelId = model.voiceModel
        let instructions = assistant.voiceInstructions()
        let tools = assistant.voiceTools()
        let rc = VoiceRealtimeClient(
            proxyURL: proxyURL, token: token, model: modelId,
            instructions: instructions, tools: tools, audio: audio,
            runTool: { name, argsJSON in await assistant.runVoiceTool(name: name, argsJSON: argsJSON) },
            onState: { [weak self] s in Task { @MainActor in self?.state = s } },
            onCaption: { [weak self] role, text, done in
                Task { @MainActor in
                    guard let self else { return }
                    if role == "user" { self.caption = "" }            // new user turn → clear the reply line
                    else if role == "assistant", !done { self.caption += text }
                }
            },
            onError: { [weak self] msg in Task { @MainActor in self?.note = msg } })
        client = rc
        observeInterruptions()
        rc.start()
    }

    func interrupt() { client?.interrupt() }

    func end() {
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        if let client { client.stop() } else { audio.shutdown() }
        client = nil
    }

    /// End the session if another app (e.g. an incoming call) interrupts audio —
    /// the iOS analog of Android's audio-focus loss.
    private func observeInterruptions() {
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let info = n.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.end() }
        }
    }
}

struct VoiceModeScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme
    @Environment(\.dismiss) private var dismiss
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
        .task {
            if session == nil { let s = VoiceSessionModel(model: model); session = s; s.start() }
        }
        .onDisappear { session?.end(); UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: session?.isLive ?? false) { _, live in
            UIApplication.shared.isIdleTimerDisabled = live   // keep the screen awake mid-call
        }
    }

    @ViewBuilder
    private func center(_ session: VoiceSessionModel) -> some View {
        let live = session.state == .speaking || session.state == .listening
        VStack(spacing: 24) {
            PulsingOrb(active: live,
                       color: session.state == .speaking ? theme.palette.coral : theme.palette.primary,
                       onTap: live ? { session.interrupt() } : nil)
            Text(stateLabel(session))
                .font(UFont.sans(15, .medium)).foregroundStyle(theme.palette.ink2)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
            if !session.caption.isEmpty {
                Text(session.caption)
                    .font(UFont.serifItalic(22)).foregroundStyle(theme.palette.ink)
                    .multilineTextAlignment(.center)
            }
            if live {
                Button { session.interrupt() } label: {
                    Text("Interrupt")
                        .font(UFont.sans(15, .semibold)).foregroundStyle(theme.palette.ink)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(theme.palette.bg2, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 32)
    }

    private func stateLabel(_ s: VoiceSessionModel) -> String {
        switch s.state {
        case .connecting: return "Connecting…"
        case .listening: return "Listening…"
        case .speaking: return "Speaking…"
        case .error: return s.note ?? "Something went wrong."
        case .closed: return "Ended"
        }
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
            .onTapGesture { onTap?() }
            .accessibilityLabel(onTap != nil ? "Interrupt assistant" : "Assistant")
    }
}
