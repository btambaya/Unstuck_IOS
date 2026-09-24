// Settings → Notifications & calls → Calls (slim settings, 2026-09-24; was
// its own "Calls from Unstuck" screen — calls build-out, docs/calls-build-out.md
// iOS §1). Embedded in NotificationSettingsView:
//
//   • without the Assistant or AI data sharing the whole block is ONE line
//     ("Calls need … · Turn on") — a call can't connect to the assistant, and
//     this phone declines it on arrival (CallCoordinator);
//   • "Let Unstuck call this phone" — the master switch (device-local, applied
//     on receipt); everything below shows only while it's on:
//   • "Only call between [06:00] and [23:00]" — the phone's own guard, the one
//     thing that stops a loud call at a bad time;
//   • the three OPT-IN proactive calls (morning / evening / after a focus
//     block — account-wide, written through `notification_preferences.call_*`
//     via AppModel.setCallProactivePrefs);
//   • "Try a test call" — a REAL call_requests row (kind `test`) one minute
//     from now so the whole server → APNs VoIP → CallKit path rings the phone;
//     a previous live test call is cancelled first (Android's behaviour — the
//     one-live-call-per-label rule would refuse the retry otherwise);
//   • fix-it lines only when something is broken (the microphone refused, no
//     VoIP registration yet).
// The default lead for task calls is gone from here: "Call me about this"
// remembers the last lead picked (same key, which request_call reads).

import AVFoundation
import SwiftUI
import UnstuckCore
import UnstuckDesign
import UnstuckSync

struct CallSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    @State private var enabled = CallSettings.enabled
    /// Set when the user has refused the microphone: the phone rings, but the
    /// call cannot hear them.
    @State private var micDenied = AVAudioApplication.shared.recordPermission == .denied
    @State private var windowStart = CallSettingsView.date(CallSettings.windowStart)
    @State private var windowEnd = CallSettingsView.date(CallSettings.windowEnd)
    @State private var testState: TestState = .idle
    @State private var showVoipNudge = false
    @State private var nudgeRetried = false

    private enum TestState: Equatable { case idle, booking, booked(String), failed(String) }

    /// Ask for the microphone if iOS has not been asked yet. A call answered
    /// from the lock screen can never show this prompt — the app isn't in the
    /// foreground — so the audio engine fails and EVERY call ends as
    /// "couldn't start" for a user who never opened Talk (audit 2026-09-21).
    /// Asking here, while they're looking at the Calls screen, is the fix.
    static func ensureMicrophone(_ done: @escaping @MainActor (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: done(true)
        case .denied: done(false)
        default: AVAudioApplication.requestRecordPermission { ok in Task { @MainActor in done(ok) } }
        }
    }

    /// The assistant just booked or changed a call (CallTools.dispatch): is
    /// the microphone there for it? Asks only while the app is ACTIVE — from
    /// a lock-screen call or the background the prompt can't show, so it
    /// answers true and the next foreground asks
    /// (AppModel.askForCallMicrophoneIfNeeded). Audit 2026-09-22, C13.
    @MainActor static func microphoneAllowedAfterBooking() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            guard UIApplication.shared.applicationState == .active else { return true }
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// The test call's label + note (the row the button books; the same
    /// label is what a retry cancels first).
    static let testCallLabel = "Test call"
    static let testCallNote = "This is what a call from Unstuck sounds like"

    var body: some View {
        let assistantOn = model.settings.assistantEnabled
        let aiOn = model.aiConsentGranted
        VStack(alignment: .leading, spacing: 0) {
            switch CallsBlockState.resolve(assistantOn: assistantOn, aiSharingOn: aiOn, phoneSwitchOn: enabled) {
            case .needsAssistant:
                needsAssistantLine(assistantOn: assistantOn, aiOn: aiOn)
            case .off, .on:
                SettingsCard {
                    masterSwitch
                    if enabled {
                        CardDivider()
                        hoursRow
                        CardDivider()
                        proactiveRows
                    }
                }
                if enabled, micDenied {
                    fixLine("Calls need the microphone. Turn it on for Unstuck in iOS Settings, or it will ring but can't hear you.")
                        .padding(.top, 10)
                }
                if enabled, showVoipNudge { voipNudge.padding(.top, 10) }
                if enabled { testCallRow.padding(.top, 12) }
            }
            AIConsentNoteLine(host: .callSettings).padding(.top, 8)
        }
        // A call is a conversation with the assistant: switching Calls on,
        // a proactive call or a test call asks for the AI-consent OK first.
        .aiConsentSheet(.callSettings)
        .task {
            model.refreshCallProactivePrefs()
            // The nudge: no VoIP token 10 s after a signed-in launch, once.
            showVoipNudge = VoipPushRegistry.shared.shouldShowNudge(signedIn: model.signedIn)
            if !showVoipNudge, let s = VoipPushRegistry.shared.secondsSinceRegistrationStart,
               s < VoipRegistrationNudge.graceSeconds {
                try? await Task.sleep(nanoseconds: UInt64((VoipRegistrationNudge.graceSeconds - s + 0.2) * 1_000_000_000))
                showVoipNudge = VoipPushRegistry.shared.shouldShowNudge(signedIn: model.signedIn)
            }
        }
    }

    // MARK: the one line when calls can't connect

    /// The Assistant or AI data sharing is off: calls can't connect, so the
    /// block is one line — and "Turn on" switches on what's missing (the
    /// sharing OK asks with the usual sheet).
    private func needsAssistantLine(assistantOn: Bool, aiOn: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(CallsBlockState.needsLine(assistantOn: assistantOn, aiSharingOn: aiOn))
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                if !model.settings.assistantEnabled { model.settings.assistantEnabled = true }
                if !model.aiConsentGranted { model.withAIConsent(.callsOn, from: .callSettings) {} }
            } label: {
                Text("Turn on")
                    .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(theme.palette.ink, in: Capsule())
                    .frame(minHeight: 44).contentShape(Capsule()).padding(.vertical, -7)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-calls-turn-on")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    // MARK: master switch + hours + proactive calls

    private var masterSwitch: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Let Unstuck call this phone").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                Text(enabled ? "It rings when you ask for a call, or at the times you pick below."
                             : "Off. A call booked for this iPhone is declined, and its notes arrive as a notification.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { enabled }, set: { on in
                guard on else {
                    enabled = false
                    CallSettings.enabled = false
                    return
                }
                // On asks for the AI-consent OK first; "Not now" leaves it off.
                model.withAIConsent(.callsOn, from: .callSettings) {
                    enabled = true
                    CallSettings.enabled = true
                    // Ask for the microphone while the app is in front of
                    // them — see ensureMicrophone. Without this a user who
                    // never opens Talk rings, answers, and the engine fails
                    // every time.
                    Self.ensureMicrophone { granted in micDenied = !granted }
                }
            }))
            .labelsHidden()
            .tint(theme.palette.primary)
            .accessibilityLabel("Let Unstuck call this phone")
            .accessibilityIdentifier("settings-calls-switch")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// "Only call between [06:00] and [23:00]" — the only user guard on when
    /// a loud call can ring.
    private var hoursRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Only call between").font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
            HStack(spacing: 8) {
                DatePicker("From", selection: $windowStart, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .onChange(of: windowStart) { _, new in CallSettings.windowStart = CallSettings.hhmm(new) }
                    .accessibilityLabel("Calls from")
                Text("and").font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                DatePicker("Until", selection: $windowEnd, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .onChange(of: windowEnd) { _, new in CallSettings.windowEnd = CallSettings.hhmm(new) }
                    .accessibilityLabel("Calls until")
                Spacer(minLength: 0)
            }
            Text("Outside these hours a call is declined quietly and its notes arrive as a notification.")
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var proactiveRows: some View {
        let prefs = model.callProactivePrefs
        proactiveRow("Morning call", sub: "Plan the day together.",
                     isOn: prefs.morningEnabled, time: prefs.morningTime,
                     setOn: { var p = model.callProactivePrefs; p.morningEnabled = $0; model.setCallProactivePrefs(p) },
                     setTime: { var p = model.callProactivePrefs; p.morningTime = $0; model.setCallProactivePrefs(p) })
        CardDivider()
        proactiveRow("Evening call", sub: "Go over what got done and what moves to tomorrow.",
                     isOn: prefs.eveningEnabled, time: prefs.eveningTime,
                     setOn: { var p = model.callProactivePrefs; p.eveningEnabled = $0; model.setCallProactivePrefs(p) },
                     setTime: { var p = model.callProactivePrefs; p.eveningTime = $0; model.setCallProactivePrefs(p) })
        CardDivider()
        proactiveRow("Call me after a focus block", sub: "When a block ends and its task isn't done yet.",
                     isOn: prefs.afterBlockEnabled, time: nil,
                     setOn: { var p = model.callProactivePrefs; p.afterBlockEnabled = $0; model.setCallProactivePrefs(p) },
                     setTime: { _ in })
    }

    private func proactiveRow(_ title: String, sub: String, isOn: Bool, time: String?,
                              setOn: @escaping (Bool) -> Void, setTime: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(UFont.sans(13, .semibold)).foregroundStyle(theme.palette.ink)
                    Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { isOn }, set: { on in
                    guard on else { setOn(false); return }
                    // On asks for the AI-consent OK first; "Not now" leaves it off.
                    model.withAIConsent(.callsOn, from: .callSettings) {
                        setOn(true)
                        // A proactive call rings a phone that was never asked
                        // for the microphone — Calls default on, so the master
                        // switch's prompt never ran (audit 2026-09-22, C13).
                        // Not while Calls is off here: this phone declines them.
                        if enabled { Self.ensureMicrophone { granted in micDenied = !granted } }
                    }
                }))
                    .labelsHidden()
                    .tint(theme.palette.primary)
                    .accessibilityLabel(title)
            }
            if isOn, let time {
                HStack {
                    Text("At").font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                    Spacer()
                    DatePicker("", selection: Binding(get: { Self.date(time) },
                                                      set: { setTime(CallSettings.hhmm($0)) }),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityLabel("\(title) at")
                }
            }
            if isOn, let warning = proactiveWarning(time: time) {
                Text(warning).font(UFont.sans(12)).foregroundStyle(theme.palette.amberInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Will this proactive call ring HERE? Read from the screen's own state,
    /// so moving the allowed hours or flipping Calls updates it live. The
    /// pickers used to accept times the dispatcher never books or this phone
    /// declines every day (audit 2026-09-22, C12). nil `time` = the
    /// after-block check-in.
    private func proactiveWarning(time: String?) -> String? {
        let start = CallSettings.hhmm(windowStart), end = CallSettings.hhmm(windowEnd)
        guard let time else { return CallSettings.afterBlockWarning(enabled: enabled, start: start, end: end) }
        return CallSettings.proactiveTimeWarning(time, enabled: enabled, start: start, end: end)
    }

    // MARK: fix-it lines (only when broken)

    private func fixLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.amberInk).padding(.top, 1)
                .accessibilityHidden(true)
            Text(text).font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One-time: PushKit produced no VoIP token 10 s after a signed-in launch.
    private var voipNudge: some View {
        VStack(alignment: .leading, spacing: 8) {
            fixLine("Calls can't reach this iPhone yet, so a call arrives as a notification you tap instead of a ring.")
            Button {
                VoipPushRegistry.shared.retryRegistration()
                nudgeRetried = true
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    showVoipNudge = PushRegistrar.shared.voipTokenHex == nil && !CallSettings.voipNudgeDismissed
                }
            } label: {
                Text(nudgeRetried ? "Trying…" : "Try again")
                    .font(UFont.sans(12, .semibold)).foregroundStyle(theme.palette.bg)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(theme.palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(nudgeRetried)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: test call

    private var testCallRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.withAIConsent(.callsOn, from: .callSettings) { bookTestCall() } } label: {
                HStack(spacing: 6) {
                    if testState == .booking { ProgressView().controlSize(.small) }
                    Image(systemName: "phone").font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(testState == .booking ? "Booking a test call…" : "Try a test call")
                        .font(UFont.sans(13, .semibold)).underline()
                }
                .foregroundStyle(theme.palette.ink)
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(testState == .booking || model.coordinator == nil)
            .accessibilityIdentifier("settings-test-call")
            switch testState {
            case .booked(let at):
                Text("Booked. It rings at \(at). Lock your phone and wait.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.greenInk)
            case .failed(let why):
                Text(why).font(UFont.sans(12)).foregroundStyle(theme.palette.red)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                Text("We'll ring you in about a minute.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
            }
        }
    }

    private func bookTestCall() {
        guard let coord = model.coordinator, let uid = coord.auth.currentUserId else {
            testState = .failed("Sign in first."); return
        }
        guard enabled else {
            testState = .failed("Calls are off on this iPhone. Switch them on above to try it.")
            return
        }
        // A test call that rings and then can't hear them is worse than none:
        // the prompt can only appear while the app is in front of them.
        if AVAudioApplication.shared.recordPermission != .granted {
            Self.ensureMicrophone { granted in
                micDenied = !granted
                if granted { bookTestCall() } else {
                    testState = .failed("Calls need the microphone. Turn it on for Unstuck in iOS Settings.")
                }
            }
            return
        }
        // The same guards the assistant's request_call applies (server window
        // 06:00–23:00) plus the user's own allowed hours — otherwise the
        // server would refuse or the phone would decline it quietly and the
        // "Booked — ringing at …" line would be a lie.
        let now = Date()
        let at = now.addingTimeInterval(60)
        if let e = CallToolLogic.timeGuard(at, now: now) {
            testState = .failed(e.replacingOccurrences(of: "error: ", with: "").capitalizedFirst + ".")
            return
        }
        if !CallSettings.isWithinWindow(at) {
            let hours = CallSettings.hoursLabel(start: CallSettings.windowStart, end: CallSettings.windowEnd,
                                                refusing: CallSettings.minuteOfDay(at))
            testState = .failed("\(CallSettings.hhmm(at)) is outside your call hours (\(hours)), so this iPhone would decline it. Widen the hours above to try it now.")
            return
        }
        testState = .booking
        let store = coord.callStore
        Task {
            do {
                // A live earlier test call is cancelled first (Android's
                // bookTestCall): the one-live-call-per-label rule would refuse
                // the retry, and two test rows would ring twice.
                let live = try await store.liveCalls()
                for stale in Self.previousTestCalls(in: live) {
                    _ = try? await store.cancelCall(id: stale.id)
                }
                let row = try await store.client.create(userId: uid, callAt: at, label: Self.testCallLabel,
                                                        notes: [Self.testCallNote], kind: "test")
                try? store.mirror.upsert(row)
                testState = .booked(CallSettings.hhmm(at))
            } catch {
                testState = .failed("Couldn't book the test call. Check your connection and try again.")
            }
        }
    }

    /// The live rows a new test call replaces: the same label (case-
    /// insensitive) — or, once the server stamps kinds, kind `test`.
    static func previousTestCalls(in live: [CallRequest]) -> [CallRequest] {
        live.filter { $0.isLive && ($0.kind == "test" || $0.label.trimmingCharacters(in: .whitespaces).lowercased() == testCallLabel.lowercased()) }
    }

    private static func date(_ hhmm: String) -> Date {
        let m = CallSettings.minutesOfDay(hhmm) ?? 6 * 60
        var c = Time.calendar.dateComponents([.year, .month, .day], from: Date())
        c.hour = m / 60; c.minute = m % 60
        return Time.calendar.date(from: c) ?? Date()
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
