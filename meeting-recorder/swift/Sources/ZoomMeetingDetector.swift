import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt

enum ZoomAutoRecordMode: String, CaseIterable, Identifiable {
    case off
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto-record"
        }
    }
}

struct ZoomMeetingSnapshot: Equatable {
    var zoomRunning: Bool
    var inMeeting: Bool
    var signals: [String]
}

/// Polls for an active Zoom call (not merely the idle Zoom app).
///
/// Signals (any one is enough while `zoom.us` is running):
/// - helper process `aomhost` (spawned for calls; `caphost` alone is idle-safe and ignored)
/// - on-screen Zoom window titles that look like a meeting (needs Screen Recording)
/// - `PreventUserIdleDisplaySleep` assertion held by zoom.us (video call)
///
/// The poll timer runs only while Zoom itself is launched (NSWorkspace
/// launch/terminate notifications) — idle with Zoom quit costs zero wakeups
/// (plan-optimization E3).
final class ZoomMeetingDetector {
    static let shared = ZoomMeetingDetector()

    var onMeetingStarted: (() -> Void)?
    var onMeetingEnded: (() -> Void)?

    private(set) var snapshot = ZoomMeetingSnapshot(zoomRunning: false, inMeeting: false, signals: [])
    private(set) var isInMeeting = false

    private var timer: Timer?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var positiveStreak = 0
    private var negativeStreak = 0
    private let enterThreshold = 2
    private let exitThreshold = 3
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
            guard let self, Self.isZoomApp(note) else { return }
            self.startPolling()
        }
        terminateObserver = workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, Self.isZoomApp(note) else { return }
            self.stopPolling(endedMeeting: true)
        }

        if Self.isZoomAppRunning() {
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
    func probe() -> ZoomMeetingSnapshot {
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
        positiveStreak = 0
        negativeStreak = 0
        if endedMeeting, isInMeeting {
            isInMeeting = false
            onMeetingEnded?()
        }
        snapshot = ZoomMeetingSnapshot(zoomRunning: false, inMeeting: false, signals: [])
    }

    private func poll() {
        let snap = Self.captureSnapshot()
        snapshot = snap

        // Zoom quit between workspace notification and this tick — park the timer.
        if !snap.zoomRunning {
            stopPolling(endedMeeting: true)
            return
        }

        if snap.inMeeting {
            positiveStreak += 1
            negativeStreak = 0
            if !isInMeeting && positiveStreak >= enterThreshold {
                isInMeeting = true
                onMeetingStarted?()
            }
        } else {
            negativeStreak += 1
            positiveStreak = 0
            if isInMeeting && negativeStreak >= exitThreshold {
                isInMeeting = false
                onMeetingEnded?()
            }
        }
    }

    // MARK: - Snapshot

    static func captureSnapshot() -> ZoomMeetingSnapshot {
        let zoomRunning = isZoomAppRunning()
        guard zoomRunning else {
            return ZoomMeetingSnapshot(zoomRunning: false, inMeeting: false, signals: [])
        }

        // Cheapest reliable signal first — skip window/IOKit scans when it hits (E3).
        if isProcessRunning(named: "aomhost") {
            return ZoomMeetingSnapshot(zoomRunning: true, inMeeting: true, signals: ["aomhost"])
        }

        var signals: [String] = []
        if hasMeetingWindow() {
            signals.append("meeting-window")
        }
        if hasZoomDisplaySleepAssertion() {
            signals.append("display-sleep-assertion")
        }

        return ZoomMeetingSnapshot(
            zoomRunning: true,
            inMeeting: !signals.isEmpty,
            signals: signals
        )
    }

    static func isZoomAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { isZoomRunningApp($0) }
    }

    private static func isZoomApp(_ note: Notification) -> Bool {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return false
        }
        return isZoomRunningApp(app)
    }

    private static func isZoomRunningApp(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "us.zoom.xos"
            || app.localizedName?.caseInsensitiveCompare("zoom.us") == .orderedSame
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
            if let processName = processName(forPID: pid),
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

    private static let idleWindowTitles: Set<String> = [
        // EN
        "", "zoom", "zoom.us", "zoom workplace", "zoom - free account",
        "login", "sign in", "settings", "preferences", "chat", "contacts",
        // RU (product is Russian-first — idle panels must not start recording)
        "войти", "вход", "настройки", "параметры", "чат", "контакты",
        "зум", "zoom workplace",
    ]

    static func hasMeetingWindow() -> Bool {
        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in info {
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
            guard owner.caseInsensitiveCompare("zoom.us") == .orderedSame else { continue }
            let title = ((window[kCGWindowName as String] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { continue }
            let lower = title.lowercased()
            if idleWindowTitles.contains(lower) { continue }
            // Strong positive signals only — do not treat "any long title" as a meeting
            // (RU idle windows like «Настройки» / «Чат» used to false-trigger auto-record).
            if lower.contains("zoom meeting")
                || lower.contains("webinar")
                || lower.contains("meeting id")
                || lower.hasPrefix("zoom meeting")
                || lower.contains("конференция")
                || lower.contains("вебинар")
                || (lower.contains("meeting") && !lower.contains("workplace")) {
                return true
            }
        }
        return false
    }

    /// Video calls typically hold a PreventUserIdleDisplaySleep assertion.
    /// Reads system power assertions straight from IOKit (same data `pmset -g
    /// assertions` prints) instead of spawning a subprocess every poll.
    static func hasZoomDisplaySleepAssertion() -> Bool {
        var cfAssertionsRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&cfAssertionsRef) == kIOReturnSuccess,
              let cfAssertionsRef else {
            return false
        }
        let assertionsByPid = cfAssertionsRef.takeRetainedValue() as NSDictionary
        for (key, value) in assertionsByPid {
            guard let pidNumber = key as? NSNumber,
                  let assertions = value as? [NSDictionary] else { continue }
            guard let name = processName(forPID: pid_t(pidNumber.intValue)),
                  name.lowercased().contains("zoom") else { continue }
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
