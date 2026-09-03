// Settings → Notifications → "Calls from Unstuck": what a call is, the
// allowed hours (the phone's own guard, applied on receipt), the default lead
// for task-anchored calls, and "Test call now" — which books a REAL
// call_requests row for one minute from now so the whole server → APNs VoIP →
// CallKit path rings the phone. (The nav row in SettingsFeature is added by
// the integrator.)

import SwiftUI
import UnstuckDesign
import UnstuckSync

struct CallSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uTheme) private var theme

    @State private var windowStart = CallSettingsView.date(CallSettings.windowStart)
    @State private var windowEnd = CallSettingsView.date(CallSettings.windowEnd)
    @State private var lead = CallSettings.defaultLeadMin
    @State private var testState: TestState = .idle

    private enum TestState: Equatable { case idle, booking, booked(String), failed(String) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                explainer

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
            Text(ready ? "This iPhone can take calls." : "Waiting for this iPhone's call token — calls fall back to a notification until it arrives.")
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
            testState = .failed("\(CallSettings.hhmm(at)) is outside your allowed hours (\(CallSettings.windowStart)–\(CallSettings.windowEnd)) — the phone would decline it quietly. Widen the hours above to try it now.")
            return
        }
        testState = .booking
        let client = coord.calls
        Task {
            do {
                try await client.create(userId: uid, callAt: at, label: "Test call",
                                        notes: ["This is what a call from Unstuck sounds like"])
                testState = .booked(CallSettings.hhmm(at))
            } catch {
                testState = .failed("Couldn't book the test call — check your connection and try again.")
            }
        }
    }

    private static func date(_ hhmm: String) -> Date {
        let m = CallSettings.minutesOfDay(hhmm) ?? 8 * 60
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
