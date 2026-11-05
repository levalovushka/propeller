import AppKit
import PropellerPure
@testable import PropellerUI
import SwiftUI
import XCTest

/// Снимки экрана идущей записи — по одному на состояние, рядом с путём из
/// `RECORDING_SHOT`:
///
///     RECORDING_SHOT=/tmp/rec.png swift test --filter RecordingPaneShot
///
/// даёт `/tmp/rec-live.png`, `-paused`, `-muted`, `-zero`, `-notes`. Рисуется
/// то же, что в приложении справа от рельса: полоса и лист под ней.
final class RecordingPaneShotTests: XCTestCase {

    private struct Pose {
        let name: String
        var paused = false
        var muted = false
        var canMute = true
        var calendar = true
        var previous = true
        var notes = true
    }

    private static let poses: [Pose] = [
        .init(name: "live"),
        .init(name: "paused", paused: true),
        .init(name: "muted", muted: true),
        .init(name: "miconly", canMute: false),
        .init(name: "zero", calendar: false, previous: false, notes: false),
        .init(name: "notes", previous: false),
        .init(name: "previous", notes: false),
    ]

    @MainActor
    func testShoot() throws {
        guard let output = ProcessInfo.processInfo.environment["RECORDING_SHOT"] else {
            throw XCTSkip("RECORDING_SHOT не задан")
        }
        let base = URL(fileURLWithPath: output)
        for pose in Self.poses {
            let url = base.deletingPathExtension()
                .appendingPathExtension("png")
                .deletingLastPathComponent()
                .appendingPathComponent(
                    base.deletingPathExtension().lastPathComponent + "-\(pose.name).png"
                )
            try shoot(pose, into: url)
        }
    }

    @MainActor
    private func shoot(_ pose: Pose, into url: URL) throws {
        let size = CGSize(width: 1016, height: 760)
        let root = VStack(spacing: 0) {
            PaneNavBar(
                back: .init(enabled: true) {},
                forward: .init(enabled: false) {},
                reservesWindowChrome: false,
                trailing: {
                    RecordingControls(
                        elapsed: "12:04",
                        isPaused: pose.paused,
                        isMicMuted: pose.muted,
                        canMuteMic: pose.canMute,
                        levels: { ([0.02, 0.2, 0.6, 0.1, 0.3], [0.3, 0.05, 0, 0.4, 0.1]) },
                        onPause: {}, onStop: {}
                    )
                }
            )
            RecordingPaneBody(
                identity: .init(
                    meetingID: "shot",
                    title: pose.calendar ? "Дейлик ВК Камуфляж" : "Запись 05.11.2026, 11:00",
                    onRename: { _, _ in }
                ),
                meta: .init(
                    date: Date(timeIntervalSince1970: 1_793_872_800),
                    people: pose.calendar ? .init(rows: Self.roster) : nil
                ),
                previous: pose.previous ? Self.previous : nil,
                isPaused: pose.paused,
                transcriptNotes: pose.notes ? Self.notes : [],
                composer: .init(text: .constant("")) {}
            )
        }
        .environment(\.colorScheme, .dark)
        .frame(width: size.width, height: size.height)
        .background(Tokens.Paint.Bg.page)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    private static let roster: [MeetingRoster.Row] = [
        .init(name: "Левон", origin: .owner, label: "Левон"),
        .init(name: "Илона Саркисова", origin: .call, label: "Илона Саркисова"),
        .init(name: "Костя Замуренко", origin: .call, label: "Костя Замуренко"),
        .init(name: "Даня Москаленко", origin: .call, label: "Даня Москаленко"),
    ]

    private static let previous = RecordingPrevious(
        heading: "Решения с прошлого раза, 29 окт",
        items: [
            "Отказались от «барабана» как центральной фигуры главной страницы.",
            "Кластеры артистов, альбомов и сценариев — плотной сеткой чипсов, без горизонтального скролла.",
            "**Даня Москаленко** — уточнить у Арины оплату и смету по генеративщикам.",
            "**Костя Замуренко** — подготовить материалы для анимаций до согласования с клиентом.",
        ]
    )

    private static let notes: [TranscriptNote] = [
        .init(id: "1", time: "03:12",
              text: "Илона снова про барабан — вопрос закрыт, вернуть к решению от 29-го", seconds: 192),
        .init(id: "2", time: "09:40",
              text: "Смета у Дани ещё не готова, Арина ждёт до пятницы", seconds: 580),
    ]
}
