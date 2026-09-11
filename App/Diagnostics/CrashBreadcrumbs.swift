// CrashBreadcrumbs — a tiny, self-hosted crash/hang recorder.
//
// WHY. Four TestFlight reports (builds 33/34/41) say the app dies during or
// just after the assistant writes several things ("after being asked to add a
// lot of items to the calendar"; "it was successful but then the app stopped
// responding"; "crashed after I tried exiting the AI"). NONE of them carried a
// crash log — they were submitted as FEEDBACK, and Apple only attaches a log
// when the tester has diagnostics sharing on and the process actually faults.
// Worse, the "stopped responding" shape is a WATCHDOG kill (SIGKILL), which no
// in-process handler can catch: the only way to see one is to have written the
// evidence to disk BEFORE the kill lands.
//
// WHAT IT RECORDS
//   • a rolling on-disk trail of short breadcrumbs (`drop`);
//   • uncaught ObjC exceptions  → name, reason, symbolicated stack;
//   • the fatal signals          → signal number + a backtrace, written with
//     async-signal-safe primitives only (a pre-opened fd, write(),
//     backtrace_symbols_fd() — no allocation, no Foundation);
//   • a main-thread STALL detector → "main thread blocked Ns", written while
//     the app is still alive, so a watchdog SIGKILL still leaves its reason.
// On the next launch the file is read once; if it holds a fault line it becomes
// `lastReport`, which Settings → Send feedback offers to attach.
//
// PRIVACY. Breadcrumbs are FIXED, CALLER-SUPPLIED LABELS ONLY — tool names,
// phase markers, counts. Never message text, task names, tokens, ids or any
// other user content; `drop` additionally sanitises and truncates whatever it
// is handed. The file lives in the app's own Application Support container and
// only ever leaves the device when the user taps Send on the feedback composer
// with the attach toggle on.

import Darwin
import Foundation

enum CrashBreadcrumbs {
    /// Rotate once the trail passes this; the tail is what matters.
    private static let maxBytes = 64 * 1024
    /// A line starting with one of these makes the run worth reporting.
    private static let faultPrefixes = ["EXCEPTION", "SIGNAL", "MAINSTALL"]
    /// The main thread is considered stalled after this long without answering.
    private static let stallSeconds: Double = 4.0

    // MARK: - state

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false
    /// Descriptor kept open for the whole run: opening a file is not
    /// async-signal-safe, so the signal handler can only ever write to this.
    nonisolated(unsafe) private static var faultFD: Int32 = -1
    nonisolated(unsafe) private static var written = 0
    nonisolated(unsafe) private static var stallTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var _lastReport: String?

    /// The previous run's report, when that run recorded a fault. Resolved once
    /// by `install()`; nil when the last run ended without one.
    static var lastReport: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastReport
    }

    private static var logURL: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let dir = base.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("breadcrumbs.log")
    }

    // MARK: - install

    /// Read the previous run's trail, then arm the handlers. Idempotent.
    static func install() {
        lock.lock()
        if installed { lock.unlock(); return }
        installed = true
        lock.unlock()

        loadPreviousRun()
        openFreshTrail()
        installExceptionHandler()
        installSignalHandlers()
        startStallDetector()
        drop("launch \(appBuild)")
        // Records in THIS run's trail that the previous one faulted — so even a
        // report sent a few sessions later still says "this device has been
        // crashing", not just "the last run was fine".
        if lastReport != nil { drop("previous session faulted") }
    }

    private static func loadPreviousRun() {
        guard let url = logURL, let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return }
        let previous = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard previous.contains(where: { line in faultPrefixes.contains { line.hasPrefix($0) } }) else { return }
        let report = "--- Unstuck diagnostics (previous session) ---\n"
            + "app \(appBuild) · \(deviceLine)\n"
            + previous.joined(separator: "\n")
        lock.lock(); _lastReport = report; lock.unlock()
    }

    private static func openFreshTrail() {
        guard let url = logURL else { return }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        lock.lock(); faultFD = fd; written = 0; lock.unlock()
    }

    // MARK: - breadcrumbs

    /// Record one breadcrumb. `event` MUST be a fixed label (a tool name, a
    /// phase marker) — never user content; it is sanitised and truncated too.
    static func drop(_ event: String) {
        let safe = sanitise(event)
        guard !safe.isEmpty else { return }
        append("\(stamp()) \(Thread.isMainThread ? "main" : "bg  ") \(safe)")
    }

    /// Keep only characters that cannot carry user content of any substance.
    private static func sanitise(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-/ ")
        return String(s.prefix(80).filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
    }

    private static func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard faultFD >= 0 else { return }
        // Past the cap: start the trail over (keeping the tail is what matters,
        // and a fault is written at the very end of a run anyway).
        if written > maxBytes {
            ftruncate(faultFD, 0)
            lseek(faultFD, 0, SEEK_SET)
            written = 0
        }
        var out = line
        out.append("\n")
        out.withUTF8 { buf in
            guard let base = buf.baseAddress else { return }
            written += max(0, write(faultFD, base, buf.count))
        }
    }

    // MARK: - faults

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(24).joined(separator: "\n")
            CrashBreadcrumbs.append("EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "")\n\(stack)")
        }
    }

    private static func installSignalHandlers() {
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { received in
                // ASYNC-SIGNAL-SAFE ONLY below: a pre-opened fd, write(),
                // backtrace*(), stack storage. No allocation, no Foundation.
                let fd = CrashBreadcrumbs.faultFD
                if fd >= 0 {
                    let label: StaticString = "SIGNAL "
                    _ = write(fd, label.utf8Start, label.utf8CodeUnitCount)
                    var digits: (CChar, CChar, CChar) = (CChar(48 + (received / 10) % 10),
                                                         CChar(48 + received % 10), 10)
                    withUnsafeBytes(of: &digits) { _ = write(fd, $0.baseAddress, 3) }
                    withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 32) { frames in
                        guard let base = frames.baseAddress else { return }
                        let count = backtrace(base, Int32(frames.count))
                        backtrace_symbols_fd(base, count, fd)
                    }
                    fsync(fd)
                }
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    /// Ping the main queue once a second; if it has not answered for
    /// `stallSeconds`, write the stall down NOW. A watchdog SIGKILL cannot be
    /// caught — but this line is already on disk when it lands.
    private static func startStallDetector() {
        let queue = DispatchQueue(label: "io.unstucknow.diagnostics", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let state = StallState()
        // Generous leeway so the OS can coalesce the wakeup — this is a
        // liveness ping, not a clock.
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(500))
        timer.setEventHandler {
            let now = Date()
            // The timer queue is suspended with the app. A long gap between our
            // OWN ticks means the process was suspended, not that the main
            // thread was blocked — reset instead of reporting a false stall.
            if let lastTick = state.lastTick, now.timeIntervalSince(lastTick) > 3 {
                state.lastTick = now
                state.pingSentAt = nil
                state.reported = false
                return
            }
            state.lastTick = now
            if let sent = state.pingSentAt {
                let waited = now.timeIntervalSince(sent)
                if waited >= stallSeconds, !state.reported {
                    state.reported = true
                    append("MAINSTALL main thread blocked \(Int(waited))s")
                }
                return   // a ping is still outstanding — don't pile more on
            }
            state.pingSentAt = now
            DispatchQueue.main.async {
                state.pingSentAt = nil
                state.reported = false
            }
        }
        timer.resume()
        lock.lock(); stallTimer = timer; lock.unlock()
    }

    /// The stall detector's shared instants — touched from the detector queue
    /// and the main queue.
    private final class StallState: @unchecked Sendable {
        private let l = NSLock()
        private var _pingSentAt: Date?
        private var _lastTick: Date?
        private var _reported = false
        var pingSentAt: Date? {
            get { l.lock(); defer { l.unlock() }; return _pingSentAt }
            set { l.lock(); _pingSentAt = newValue; l.unlock() }
        }
        var lastTick: Date? {
            get { l.lock(); defer { l.unlock() }; return _lastTick }
            set { l.lock(); _lastTick = newValue; l.unlock() }
        }
        var reported: Bool {
            get { l.lock(); defer { l.unlock() }; return _reported }
            set { l.lock(); _reported = newValue; l.unlock() }
        }
    }

    // MARK: - report handling

    /// The user sent (or declined) the report — don't offer it again.
    static func clearLastReport() {
        lock.lock(); _lastReport = nil; lock.unlock()
    }

    // MARK: - context

    static var appBuild: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private static var deviceLine: String {
        var s = utsname(); uname(&s)
        let model = Mirror(reflecting: s.machine).children.reduce(into: "") { acc, el in
            if let v = el.value as? Int8, v != 0 { acc.append(Character(UnicodeScalar(UInt8(v)))) }
        }
        return "\(model) · \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// "HH:MM:SS.mmm" local-ish (seconds into the UTC day) — enough to read the
    /// gaps between breadcrumbs, no date, no locale.
    private static func stamp() -> String {
        let t = Date().timeIntervalSince1970
        let ms = Int((t - floor(t)) * 1000)
        let secs = Int(t) % 86_400
        return String(format: "%02d:%02d:%02d.%03d", secs / 3600, (secs / 60) % 60, secs % 60, ms)
    }
}
