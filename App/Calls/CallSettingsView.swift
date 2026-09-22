// Settings → "Calls from Unstuck" (calls build-out, docs/calls-build-out.md
// iOS §1): the master Calls on/off switch (device-local, applied on receipt),
// the allowed hours (the phone's own guard) + the default lead for task-
// anchored calls, the three OPT-IN proactive calls (morning plan / evening
// wrap-up / check-in after a block — account-wide, written through
// `notification_preferences.call_*` via AppModel.setCallProactivePrefs), the
// one-time VoIP-registration nudge, and "Test call now" — a REAL
// call_requests row (kind `test`) one minute from now so the whole server →
// APNs VoIP → CallKit path rings the phone; a previous live test call is
// cancelled first (Android's behaviour — the one-live-call-per-label rule
// would refuse the retry otherwise).

import AVFoundation
import SwiftUI
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
    @State private var lead = CallSettings.defaultLeadMin
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                explainer

                masterSwitch.padding(.top, 14)
                if showVoipNudge { voipNudge.padding(.top, 10) }

                SectionLabel("Allowed hours").padding(.top, 22).padding(.bottom, 8)
                VStack(spacing: 0) {
                    hourRow("From", $windowStart) { CallSettings.windowStart = CallSettings.hhmm($0) }
                    Rectangle().fill(theme.palette.line).frame(height: 1)
                    hourRow("Until", $windowEnd) { CallSettings.windowEnd = CallSettings.hhmm($0) }
                }
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
                Text("A call outside these hours is declined quietly and you get the notes as a notification instead. Calls can only be booked between \(CallSettings.serverWindowStart) and \(CallSettings.serverWindowEnd).")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3).padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)

                SectionLabel("Default lead for task calls").padding(.top, 22).padding(.bottom, 8)
                HStack(spacing: 6) {
                    ForEach(CallSettings.leadOptions, id: \.self) { m in leadChip(m) }
                }
                Text("\"Call me about this\" on a scheduled task rings this many minutes before it starts.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3).padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)

                SectionLabel("Calls Unstuck can make on its own").padding(.top, 22).padding(.bottom, 8)
                proactiveCard
                Text("All off unless you switch them on. Unstuck books them between \(CallSettings.serverWindowStart) and \(CallSettings.serverWindowEnd); this iPhone still declines one outside the allowed hours above, or while Calls is off.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3).padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)

                SectionLabel("Try it").padding(.top, 22).padding(.bottom, 8)
                testCallCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 96)
        }
        .background(theme.palette.bg.ignoresSafeArea())
        .navigationTitle("Calls from Unstuck")
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: master switch + proactive calls

    private var masterSwitch: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Calls").font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                Text(enabled ? (micDenied ? "Calls need microphone access — turn it on in iOS Settings, or you'll ring but can't be heard."
                                          : "This iPhone rings for calls you book.")
                             : "Off — a booked call is declined quietly here and you get the notes as a notification.")
                    .font(UFont.sans(12)).foregroundStyle(micDenied && enabled ? theme.palette.red : theme.palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { enabled }, set: { on in
                enabled = on
                CallSettings.enabled = on
                // Ask for the microphone while the app is in front of them —
                // see ensureMicrophone. Without this a user who never opens
                // Talk rings, answers, and the engine fails every time.
                if on { Self.ensureMicrophone { granted in micDenied = !granted } }
            }))
            .labelsHidden()
            .tint(theme.palette.primary)
            .accessibilityLabel("Calls")
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }

    private var proactiveCard: some View {
        let prefs = model.callProactivePrefs
        return VStack(spacing: 0) {
            proactiveRow("Morning planning call", sub: "Rings to walk through the day and plan it with you.",
                         isOn: prefs.morningEnabled, time: prefs.morningTime,
                         setOn: { var p = prefs; p.morningEnabled = $0; model.setCallProactivePrefs(p) },
                         setTime: { var p = prefs; p.morningTime = $0; model.setCallProactivePrefs(p) })
            Rectangle().fill(theme.palette.line).frame(height: 1)
            proactiveRow("Evening wrap-up call", sub: "Rings to go over what got done and what moves to tomorrow.",
                         isOn: prefs.eveningEnabled, time: prefs.eveningTime,
                         setOn: { var p = prefs; p.eveningEnabled = $0; model.setCallProactivePrefs(p) },
                         setTime: { var p = prefs; p.eveningTime = $0; model.setCallProactivePrefs(p) })
            Rectangle().fill(theme.palette.line).frame(height: 1)
            proactiveRow("Check in after a block", sub: "Rings when a block ends without its task marked done — how did it go?",
                         isOn: prefs.afterBlockEnabled, time: nil,
                         setOn: { var p = prefs; p.afterBlockEnabled = $0; model.setCallProactivePrefs(p) },
                         setTime: { _ in })
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }

    private func proactiveRow(_ title: String, sub: String, isOn: Bool, time: String?,
                              setOn: @escaping (Bool) -> Void, setTime: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(UFont.sans(14, .semibold)).foregroundStyle(theme.palette.ink)
                    Text(sub).font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { isOn }, set: { on in
                    setOn(on)
                    // A proactive call rings a phone that was never asked
                    // for the microphone — Calls default on, so the master
                    // switch's prompt never ran (audit 2026-09-22, C13). Not
                    // while Calls is off here: this phone declines them.
                    if on, enabled { Self.ensureMicrophone { granted in micDenied = !granted } }
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
                }
            }
            if isOn, let warning = proactiveWarning(time: time) {
                Text(warning).font(UFont.sans(12)).foregroundStyle(theme.palette.amber)
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

    /// One-time: PushKit produced no VoIP token 10 s after a signed-in launch.
    private var voipNudge: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.amber).padding(.top, 1)
                Text("Calls need Voice-over-IP registration on this iPhone — without it a call arrives as a notification you tap instead of a ring.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                VoipPushRegistry.shared.retryRegistration()
                nudgeRetried = true
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    showVoipNudge = PushRegistrar.shared.voipTokenHex == nil && !CallSettings.voipNudgeDismissed
                }
            } label: {
                Text(nudgeRetried ? "Retrying…" : "Retry registration")
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

    // MARK: pieces

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "phone.arrow.down.left").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.palette.primary)
                Text("Ask, and Unstuck calls you").font(UFont.sans(16, .semibold)).foregroundStyle(theme.palette.ink)
            }
            Text("Say \"call me at three about the James meeting — remind me about A, B and C\", or tick \"Call me about this\" on a task. Your phone rings like a normal call, the notes are read back, then you can tick things off, add a thought, start a timer, or ask for a call-back — all by voice. Nothing is booked unless you ask.")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            deviceStatus
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.bg2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 4)
    }

    private var deviceStatus: some View {
        let ready = PushRegistrar.shared.voipTokenHex != nil
        return HStack(spacing: 6) {
            Circle().fill(ready ? theme.palette.green : theme.palette.ink3).frame(width: 7, height: 7)
            Text(ready ? (enabled ? "This iPhone can take calls." : "This iPhone can take calls — they're switched off below.")
                       : "Waiting for this iPhone's call token — calls fall back to a notification until it arrives.")
                .font(UFont.sans(12)).foregroundStyle(theme.palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func hourRow(_ label: String, _ value: Binding<Date>, commit: @escaping (Date) -> Void) -> some View {
        HStack {
            Text(label).font(UFont.sans(14)).foregroundStyle(theme.palette.ink)
            Spacer()
            DatePicker("", selection: value, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, new in commit(new) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func leadChip(_ m: Int) -> some View {
        let selected = lead == m
        return Button {
            lead = m
            CallSettings.defaultLeadMin = m
        } label: {
            Text("\(m)m")
                .font(UFont.sans(12, .medium))
                .foregroundStyle(selected ? .white : theme.palette.ink2)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? theme.palette.primary : theme.palette.bg2, in: Capsule())
        }.buttonStyle(.plain)
    }

    private var testCallCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Book a test call for one minute from now. Lock your phone — it rings through the real path (server → push → call screen).")
                .font(UFont.sans(13)).foregroundStyle(theme.palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button { bookTestCall() } label: {
                HStack(spacing: 8) {
                    if testState == .booking { ProgressView().tint(.white) }
                    Image(systemName: "phone.fill").font(.system(size: 13, weight: .semibold))
                    Text(testState == .booking ? "Booking…" : "Test call now").font(UFont.sans(14, .semibold))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 11).frame(maxWidth: .infinity)
                .background(theme.palette.primary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(testState == .booking || model.coordinator == nil)
            switch testState {
            case .booked(let at):
                Text("Booked — ringing at \(at). Lock your phone and wait.")
                    .font(UFont.sans(12)).foregroundStyle(theme.palette.green)
            case .failed(let why):
                Text(why).font(UFont.sans(12)).foregroundStyle(theme.palette.red)
            default:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.palette.line, lineWidth: 1))
    }

    private func bookTestCall() {
        guard let coord = model.coordinator, let uid = coord.auth.currentUserId else {
            testState = .failed("Sign in first."); return
        }
        guard enabled else {
            testState = .failed("Calls are off on this iPhone — switch them on above to try it.")
            return
        }
        // A test call that rings and then can't hear them is worse than none:
        // the prompt can only appear while the app is in front of them.
        if AVAudioApplication.shared.recordPermission != .granted {
            Self.ensureMicrophone { granted in
                micDenied = !granted
                if granted { bookTestCall() } else {
                    testState = .failed("Calls need microphone access — turn it on for Unstuck in iOS Settings.")
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
            testState = .failed("\(CallSettings.hhmm(at)) is outside your allowed hours (\(hours)) — the phone would decline it quietly. Widen the hours above to try it now.")
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
                testState = .failed("Couldn't book the test call — check your connection and try again.")
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
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = m / 60; c.minute = m % 60
        return Calendar.current.date(from: c) ?? Date()
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
