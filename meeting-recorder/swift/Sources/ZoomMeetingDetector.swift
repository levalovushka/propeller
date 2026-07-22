import AppKit
import CoreGraphics
import Darwin
import Foundation

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
final class ZoomMeetingDetector {
    static let shared = ZoomMeetingDetector()

    var onMeetingStarted: (() -> Void)?
    var onMeetingEnded: (() -> Void)?

    private(set) var snapshot = ZoomMeetingSnapshot(zoomRunning: false, inMeeting: false, signals: [])
    private(set) var isInMeeting = false

    private var timer: Timer?
    private var positiveStreak = 0
    private var negativeStreak = 0
    private let enterThreshold = 2
    private let exitThreshold = 3
    private let pollInterval: TimeInterval = 2.0

    private init() {}

    func start() {
        guard timer == nil else { return }
        // Fire immediately, then on interval.
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        positiveStreak = 0
        negativeStreak = 0
        if isInMeeting {
            isInMeeting = false
            onMeetingEnded?()
        }
        snapshot = ZoomMeetingSnapshot(zoomRunning: false, inMeeting: false, signals: [])
    }

    /// Force a synchronous probe (tests / Settings “Check now”).
    @discardableResult
    func probe() -> ZoomMeetingSnapshot {
        let snap = Self.captureSnapshot()
        snapshot = snap
        return snap
    }

    // MARK: - Poll loop

    private func poll() {
        let snap = Self.captureSnapshot()
        snapshot = snap

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

        var signals: [String] = []
        if isProcessRunning(named: "aomhost") {
            signals.append("aomhost")
        }
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
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "us.zoom.xos"
                || app.localizedName?.caseInsensitiveCompare("zoom.us") == .orderedSame
        }
    }

    /// True if a process executable name matches (prefix-safe for truncated names).
    static func isProcessRunning(named name: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard bytes > 0 else { return false }
        let count = Int(bytes) / MemoryLayout<pid_t>.stride
        var buf = [CChar](repeating: 0, count: 1024)
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let n = proc_name(pid, &buf, UInt32(buf.count))
            guard n > 0 else { continue }
            let processName = String(cString: buf)
            if processName == name || processName.hasPrefix(name) {
                return true
            }
        }
        return false
    }

    private static let idleWindowTitles: Set<String> = [
        "", "zoom", "zoom.us", "zoom workplace", "zoom - free account",
        "login", "sign in", "settings", "preferences", "chat", "contacts",
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
            if lower.contains("zoom meeting")
                || lower.contains("webinar")
                || lower.contains("meeting id")
                || lower.hasPrefix("zoom meeting")
                || (lower.contains("meeting") && !lower.contains("workplace")) {
                return true
            }
            // Personalized meeting room / topic titles are non-idle and non-empty.
            // Exclude tiny utility panels by requiring a reasonably long title.
            if title.count >= 4 && !lower.hasPrefix("zoom ") {
                return true
            }
        }
        return false
    }

    /// Video calls typically take PreventUserIdleDisplaySleep named under zoom.us.
    static func hasZoomDisplaySleepAssertion() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        // Look for a display-sleep assertion line that mentions zoom.
        for line in text.split(separator: "\n") {
            let l = line.lowercased()
            guard l.contains("zoom") else { continue }
            if l.contains("preventuseridledisplaysleep")
                || l.contains("nodisplaysleepassertion")
                || l.contains("prevent sleep") {
                return true
            }
        }
        return false
    }
}
