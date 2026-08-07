import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt
import PropellerPure

enum AutoRecordMode: String, CaseIterable, Identifiable {
    case off
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Выкл"
        case .auto: return "Автозапись"
        }
    }
}

/// Polls for an active call in any known platform (`MeetingPlatform.all`) —
/// not merely a launched conferencing app.
///
/// Signals, any one of which is enough:
/// - a call-only helper process (Zoom's `aomhost`; `caphost` is idle-safe and ignored)
/// - a window title that reads as a call (needs Screen Recording)
/// - a browser tab on a web-based service, where the title carries both the
///   address and a call marker
/// - a `PreventUserIdleDisplaySleep` assertion held by the app (video call)
///
/// Which titles count is data, in `MeetingPlatform`, with tests. Adding a
/// service is a row there.
///
/// The poll timer runs only while a conferencing app is launched (NSWorkspace
/// launch/terminate notifications) — an idle machine costs zero wakeups
/// (plan-optimization E3).
final class MeetingDetector {
    static let shared = MeetingDetector()

    var onMeetingStarted: (() -> Void)?
    var onMeetingEnded: (() -> Void)?

    private(set) var snapshot = MeetingSnapshot.idle
    var isInMeeting: Bool { debounce.isInMeeting }
    /// Which platform's call is in progress, once one is detected.
    private(set) var activePlatformID: String?

    private var timer: Timer?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    /// Hysteresis lives in `PropellerPure` where it is tested — a detector that
    /// flaps starts and stops recordings on its own.
    private var debounce = MeetingDebounce()
    /// 6s is enough: enterThreshold=2 already adds lag; 2s precision isn't needed (E3).
    private let pollInterval: TimeInterval = 6.0

    private init() {}

    func start() {
        guard launchObserver == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        launchObserver = workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, Self.isConferencingApp(note) else { return }
            self.startPolling()
        }
        terminateObserver = workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, Self.isConferencingApp(note) else { return }
            self.stopPolling(endedMeeting: true)
        }

        if Self.isAnyConferencingAppRunning() {
            startPolling()
        }
    }

    func stop() {
        if let o = launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            launchObserver = nil
        }
        if let o = terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            terminateObserver = nil
        }
        stopPolling(endedMeeting: true)
    }

    /// Force a synchronous probe (tests / Settings “Check now”).
    @discardableResult
    func probe() -> MeetingSnapshot {
        let snap = Self.captureSnapshot()
        snapshot = snap
        return snap
    }

    // MARK: - Poll loop

    private func startPolling() {
        guard timer == nil else { return }
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = pollInterval * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPolling(endedMeeting: Bool) {
        timer?.invalidate()
        timer = nil
        if endedMeeting, debounce.reset() == .ended {
            activePlatformID = nil
            onMeetingEnded?()
        }
        snapshot = .idle
    }

    private func poll() {
        let snap = Self.captureSnapshot()
        snapshot = snap

        // Every conferencing app quit between the workspace notification and
        // this tick — park the timer rather than poll an empty machine.
        if !snap.appRunning, !snap.inMeeting {
            stopPolling(endedMeeting: true)
            return
        }

        switch debounce.observe(snap) {
        case .started(let platformID):
            activePlatformID = platformID
            onMeetingStarted?()
        case .ended:
            activePlatformID = nil
            onMeetingEnded?()
        case .none:
            break
        }
    }

    // MARK: - Snapshot

    /// Look for a call in any known platform (`MeetingPlatform.all`).
    /// Adding a service is a row in that table — this code does not change.
    static func captureSnapshot() -> MeetingSnapshot {
        let running = NSWorkspace.shared.runningApplications
        let live = MeetingPlatform.all.filter { platform in
            running.contains { platform.owns(bundleID: $0.bundleIdentifier, appName: $0.localizedName) }
        }

        // A browser tab can be the call itself, so a web-capable platform is
        // worth checking even when its desktop app isn't installed.
        let webCapable = MeetingPlatform.all.filter { !$0.webHostFragments.isEmpty }
        guard !live.isEmpty || !webCapable.isEmpty else {
            return .idle
        }

        for platform in live {
            // Cheapest reliable signal first — no window list, no permissions (E3).
            if let helper = platform.callHelperProcesses.first(where: { isProcessRunning(named: $0) }) {
                return MeetingSnapshot(platformID: platform.id, appRunning: true, signals: [helper])
            }
        }

        var signals: [String] = []
        var detected: String?
        let windows = onScreenWindows()
        for platform in live where hasMeetingWindow(platform, in: windows) {
            signals.append("\(platform.id):window")
            detected = detected ?? platform.id
        }
        for platform in webCapable where hasBrowserCall(platform, in: windows) {
            signals.append("\(platform.id):browser")
            detected = detected ?? platform.id
        }
        // Weakest signal: says the display must stay awake, not that a call is
        // on. It counts only for a platform measured to hold it for the call
        // itself (`sleepAssertionMeansCall`) — Контур.Толк holds it while
        // someone shares a screen, and reading that as a call started and
        // stopped recordings on screen share alone (1.15).
        if detected == nil, live.count == 1, live[0].sleepAssertionMeansCall,
           hasDisplaySleepAssertion(for: live[0]) {
            signals.append("display-sleep-assertion")
            detected = live[0].id
        }

        return MeetingSnapshot(platformID: detected, appRunning: !live.isEmpty, signals: signals)
    }

    static func isAnyConferencingAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            MeetingPlatform.all.contains {
                $0.owns(bundleID: app.bundleIdentifier, appName: app.localizedName)
            }
        }
    }

    private static func isConferencingApp(_ note: Notification) -> Bool {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return false
        }
        return MeetingPlatform.all.contains {
            $0.owns(bundleID: app.bundleIdentifier, appName: app.localizedName)
        }
    }

    /// True if a process executable name matches (prefix-safe for truncated names).
    static func isProcessRunning(named name: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard bytes > 0 else { return false }
        let count = Int(bytes) / MemoryLayout<pid_t>.stride
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            // Lowercase the input, not the table — the same rule the rest of
            // `MeetingPlatform` matching follows. The kernel reports `CptHost`.
            if let processName = processName(forPID: pid)?.lowercased(),
               processName == name || processName.hasPrefix(name) {
                return true
            }
        }
        return false
    }

    /// Executable name for a pid, or nil if not resolvable.
    private static func processName(forPID pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// (owner, title) for every on-screen window. Titles are empty without
    /// Screen Recording permission, which is why that signal needs it.
    static func onScreenWindows() -> [(owner: String, title: String)] {
        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.map {
            (
                ($0[kCGWindowOwnerName as String] as? String) ?? "",
                ($0[kCGWindowName as String] as? String) ?? ""
            )
        }
    }

    static func hasMeetingWindow(
        _ platform: MeetingPlatform,
        in windows: [(owner: String, title: String)]
    ) -> Bool {
        windows.contains { window in
            platform.owns(bundleID: nil, appName: window.owner)
                && platform.titleMeansCall(window.title)
        }
    }

    /// A call held in a browser tab. Any browser counts — the title carries both
    /// the service address and the call marker, which is what makes it specific.
    static func hasBrowserCall(
        _ platform: MeetingPlatform,
        in windows: [(owner: String, title: String)]
    ) -> Bool {
        windows.contains { platform.browserTitleMeansCall($0.title) }
    }

    /// Is `platform` holding a PreventUserIdleDisplaySleep assertion right now?
    /// Reads system power assertions straight from IOKit (same data `pmset -g
    /// assertions` prints) instead of spawning a subprocess every poll.
    ///
    /// Attributed to one platform on purpose: the assertion only ever meant
    /// anything as *this app is keeping the display awake*, and which app holds
    /// it is the whole content of the signal.
    static func hasDisplaySleepAssertion(for platform: MeetingPlatform) -> Bool {
        var cfAssertionsRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&cfAssertionsRef) == kIOReturnSuccess,
              let cfAssertionsRef else {
            return false
        }
        let assertionsByPid = cfAssertionsRef.takeRetainedValue() as NSDictionary
        for (key, value) in assertionsByPid {
            guard let pidNumber = key as? NSNumber,
                  let assertions = value as? [NSDictionary] else { continue }
            guard let name = processName(forPID: pid_t(pidNumber.intValue)) else { continue }
            guard platform.ownsProcess(named: name) else { continue }
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String else { continue }
                if type.contains("PreventUserIdleDisplaySleep") || type.contains("NoDisplaySleepAssertion") {
                    return true
                }
            }
        }
        return false
    }

    /// Screen Recording permission is required for reliable meeting-window detection.
    /// Without it `CGWindowListCopyWindowInfo` returns empty titles and that signal is blind.
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}
