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

    private var task: Task<Void, Never>?

    /// Poll cadence measured by the probe (H12): 0.4 s sees every hand-off.
    private static let interval: TimeInterval = 0.4

    func start(recordingID: String, anchor: Date, directory: URL) {
        guard AXIsProcessTrusted() else { return }
        stop()
        let url = directory.appendingPathComponent("\(recordingID).calltrace.jsonl")
        task = Task.detached(priority: .utility) {
            Self.run(traceURL: url, anchor: anchor)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - The polling loop

    private static func run(traceURL: URL, anchor: Date) {
        FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: traceURL) else { return }
        defer { try? handle.close() }

        let meta = "{\"meta\":{\"anchorUnix\":\(anchor.timeIntervalSince1970)," +
                   "\"interval\":\(interval),\"trusted\":true}}\n"
        try? handle.write(contentsOf: Data(meta.utf8))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while !Task.isCancelled {
            let poll = CallWindowJournal.Poll(
                t: (Date().timeIntervalSince(anchor) * 100).rounded() / 100,
                tiles: snapshot()
            )
            // A poll with no tiles is still written: "Zoom offered nothing at
            // second N" is a fact the journal's silence accounting needs.
            if let data = try? encoder.encode(poll) {
                try? handle.write(contentsOf: data)
                try? handle.write(contentsOf: Data("\n".utf8))
            }
            Thread.sleep(forTimeInterval: interval)
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
