import AppKit
import ApplicationServices
import Foundation
import PropellerPure

/// Reads the Zoom meeting window's tile tree while a recording runs, and
/// writes the JSONL trace beside the recording (`<id>.calltrace.jsonl`,
/// `MeetingTrace.callWindowTrace`) — a live signal that cannot be taken after
/// the meeting, because the window is gone (plan-speaker-tags.md §5).
///
/// The thin shell over `CallWindowJournal`: every decision — who is speaking,
/// what counts as silence — lives in the pure layer where tests reach it. This
/// type only walks the tree and appends lines.
///
/// Rules it holds:
/// - **Never prompts.** The permission row owns `AXIsProcessTrustedWithOptions`;
///   without the grant there is simply no file, and nothing downstream breaks —
///   the journal's absence is a legal state, not an error.
/// - **Only reads.** No panels opened, nothing pressed in someone else's
///   interface (§11.4).
/// - **Never touches audio.** Capture invariants are not its business; it does
///   not know the recorder exists beyond the anchor date it is handed.
/// - Poll times are seconds since `anchor` — the recorder's start — so the
///   journal lands on the transcript's own clock and no offset is fitted.
final class CallWindowObserver {
    static let shared = CallWindowObserver()

    /// A plain dedicated thread, not a cooperative-pool task: the loop sleeps
    /// and makes synchronous AX IPC calls for the whole meeting, and parking
    /// that on the shared pool starves a pool thread (simplification review
    /// 2026-08-20). State shared with it sits behind `lock`.
    private let lock = NSLock()
    private var stopped = true
    private var paused = false
    private var anchor = Date()
    /// Guards double-arming: a Zoom call detected mid-recording re-asks the
    /// observer to start, and a restart would truncate the trace file.
    private var activeRecordingID: String?
    /// The same machine the offline pass uses — fed by the poll loop, asked by
    /// the live transcript. One smoothing, one owner rule, one answer.
    private var machine = CallWindowJournal.LiveSpeaker()

    /// Poll cadence measured by the probe (H12): 0.4 s sees every hand-off.
    private static let interval: TimeInterval = 0.4

    func start(recordingID: String, anchor: Date, directory: URL) {
        guard AXIsProcessTrusted() else { return }
        lock.lock()
        if !stopped, activeRecordingID == recordingID {
            // Already watching this recording — a second call within one
            // recording must not truncate the trace.
            lock.unlock()
            return
        }
        lock.unlock()
        stop()
        let url = directory.appendingPathComponent("\(recordingID).calltrace.jsonl")
        lock.lock()
        stopped = false
        paused = false
        self.anchor = anchor
        activeRecordingID = recordingID
        machine = CallWindowJournal.LiveSpeaker()
        lock.unlock()
        let thread = Thread { [weak self] in self?.run(traceURL: url) }
        thread.name = "CallWindowObserver"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        lock.lock(); stopped = true; activeRecordingID = nil; lock.unlock()
    }

    /// The recorder's clock stops during a pause and the trace must stop with
    /// it: poll times are the transcript's own seconds, and a wall clock that
    /// keeps running through a pause shifts the whole journal by the pause's
    /// length (found while mapping the live layer, 2026-08-20).
    func pause() {
        lock.lock(); paused = true; lock.unlock()
    }

    /// `elapsed` is the recorder's own position: the anchor is re-derived so
    /// that `now - anchor == elapsed`, and the clocks agree again.
    func resume(elapsed: TimeInterval) {
        lock.lock()
        paused = false
        anchor = Date().addingTimeInterval(-elapsed)
        lock.unlock()
    }

    // MARK: - The live transcript's questions

    /// Who was speaking around second `t`, for a live line being shown right
    /// now. Nil until the owner's tile is locked, and always for the owner —
    /// the line then keeps today's label (`Собеседник`).
    func liveName(at t: Double) -> String? {
        lock.lock(); defer { lock.unlock() }
        return machine.name(at: t)
    }

    /// A finalized owner line — the correlation evidence the owner lock needs.
    func noteOwnerTurn(start: Double, end: Double) {
        lock.lock(); defer { lock.unlock() }
        machine.noteOwnerTurn(start: start, end: end)
    }

    // MARK: - The polling loop

    private func run(traceURL: URL) {
        FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: traceURL) else { return }
        defer { try? handle.close() }

        lock.lock()
        let startAnchor = anchor
        lock.unlock()
        let meta = "{\"meta\":{\"anchorUnix\":\(startAnchor.timeIntervalSince1970)," +
                   "\"interval\":\(Self.interval),\"trusted\":true}}\n"
        try? handle.write(contentsOf: Data(meta.utf8))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while true {
            lock.lock()
            let isStopped = stopped
            let isPaused = paused
            let currentAnchor = anchor
            lock.unlock()
            if isStopped { return }
            if !isPaused {
                let poll = CallWindowJournal.Poll(
                    t: (Date().timeIntervalSince(currentAnchor) * 100).rounded() / 100,
                    tiles: Self.snapshot()
                )
                // A poll with no tiles is still written: "Zoom offered nothing
                // at second N" is a fact the silence accounting needs.
                if let data = try? encoder.encode(poll) {
                    try? handle.write(contentsOf: data)
                    try? handle.write(contentsOf: Data("\n".utf8))
                }
                lock.lock()
                machine.take(poll)
                lock.unlock()
            }
            Thread.sleep(forTimeInterval: Self.interval)
        }
    }

    // MARK: - One pass over the tree (the probe's traceSnapshot, verbatim
    // semantics: raw sizes, per-role order, zoom processes only)

    private static func snapshot() -> [CallWindowJournal.Tile] {
        var out: [CallWindowJournal.Tile] = []
        for app in zoomApps() {
            let process = app.localizedName ?? app.bundleIdentifier ?? "?"
            for window in windows(of: app) {
                let title = string(window, kAXTitleAttribute as String) ?? ""
                var budget = 20000
                walk(window, depth: 0, maxDepth: 25, budget: &budget) { element in
                    let role = string(element, kAXRoleAttribute as String) ?? ""
                    guard role == "AXRow" || role == "AXTabGroup" else { return }
                    guard let description = string(element, kAXDescriptionAttribute as String)
                            ?? string(element, kAXValueAttribute as String) else { return }
                    var size = CGSize.zero
                    if let value = copyAttribute(element, kAXSizeAttribute as String) {
                        _ = AXValueGetValue(value as! AXValue, .cgSize, &size)
                    }
                    out.append(CallWindowJournal.Tile(
                        role: role, description: description,
                        width: size.width, height: size.height,
                        window: title, process: process
                    ))
                }
            }
        }
        return out
    }

    private static func zoomApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            let id = ($0.bundleIdentifier ?? "").lowercased()
            let name = ($0.localizedName ?? "").lowercased()
            return id.contains("zoom") || name.contains("zoom")
        }
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        return nil
    }

    private static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // AX calls are synchronous IPC into Zoom; without a timeout a hung
        // Zoom hangs the poll (and the default is "wait forever"). Half a
        // second is one poll: a slower answer is worth skipping, not waiting.
        AXUIElementSetMessagingTimeout(ax, 0.5)
        return (copyAttribute(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func walk(_ element: AXUIElement, depth: Int, maxDepth: Int,
                             budget: inout Int, _ visit: (AXUIElement) -> Void) {
        guard depth <= maxDepth, budget > 0 else { return }
        budget -= 1
        visit(element)
        let children = (copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
        for child in children {
            walk(child, depth: depth + 1, maxDepth: maxDepth, budget: &budget, visit)
        }
    }
}
