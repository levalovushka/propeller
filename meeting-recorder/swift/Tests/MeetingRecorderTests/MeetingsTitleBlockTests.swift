import XCTest
import SwiftUI
import AppKit
import SnapshotTesting
import PropellerUI

/// Visual + geometry guards for Meetings title chrome (record / filter alignment).
final class MeetingsTitleBlockTests: XCTestCase {

    override func invokeTest() {
        // Record once with: SNAPSHOT_TESTING_RECORD=1 swift test --filter MeetingsTitleBlock
        withSnapshotTesting(record: ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_RECORD"] == "1" ? .all : .missing) {
            super.invokeTest()
        }
    }

    func testRecordAndFilterMidYAligned() throws {
        let midYs = layoutMidYs(
            MeetingsTitleBlock(
                showRecord: true,
                speakerOptions: ["Alice", "Bob"],
                selectedSpeaker: nil
            )
        )
        let record = try XCTUnwrap(midYs[MeetingsChromeA11y.record], "record midY missing")
        let filter = try XCTUnwrap(midYs[MeetingsChromeA11y.filter], "filter midY missing")
        XCTAssertEqual(
            record, filter, accuracy: 1.0,
            "Record and filter icons must share the same midY (got record=\(record) filter=\(filter))"
        )
    }

    func testTitleBlockSnapshot() {
        let width = Tokens.Window.contentWidth
        let height = Tokens.Window.titleBlockHeight
        let root = MeetingsTitleBlock(
            showRecord: true,
            speakerOptions: ["Alice"],
            selectedSpeaker: nil
        )
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)
        .background(Color.black)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()

        assertSnapshot(of: hosting, as: .image)
    }

    // MARK: - Hosting

    private func layoutMidYs<V: View>(_ root: V) -> [String: CGFloat] {
        var collected: [String: CGFloat] = [:]
        let hosted = root
            .frame(width: Tokens.Window.contentWidth, height: Tokens.Window.titleBlockHeight)
            .environment(\.colorScheme, .dark)
            .onPreferenceChange(MeetingsChromeMidYKey.self) { collected = $0 }

        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Tokens.Window.contentWidth,
                height: Tokens.Window.titleBlockHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: hosted)
        window.contentView = hosting
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        // Preference delivery is async to the next run-loop turn.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        window.close()
        return collected
    }
}
