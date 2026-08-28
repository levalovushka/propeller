import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Геометрия полосы над панелью — та, что иначе разъезжается молча.
///
/// Меряется зондом (`PaneProbe`): у SwiftUI-вью нет своего `NSView`, а сканировать
/// растр по яркости на антиалиасинге текста — гадание.
final class PaneNavBarLayoutTests: XCTestCase {

    private let height: CGFloat = 200

    // MARK: - Действия

    /// Действия прижаты к правой кромке **окна** на любой его ширине.
    ///
    /// До 2026-08-28 они висели плавающим оверлеем в углу панели, и ровно этот
    /// тест стерёг тот угол. Полоса делает то же самое конструкцией: правый
    /// край полосы и есть правый край окна.
    @MainActor
    func testTheActionsHugTheWindowsRightEdgeHoweverWideItGets() throws {
        for wide: CGFloat in [Tokens.Pane.paneMeasure, 1200, 2400] {
            let actions = try XCTUnwrap(probe(width: wide)[PaneProbe.actions], "действия не измерены")
            XCTAssertEqual(
                wide - actions.maxX, Tokens.Pane.NavBar.hPadding, accuracy: 0.5,
                "на ширине \(wide) действия отклеились от правой кромки"
            )
        }
    }

    /// Копирование стоит слева от «Поделиться», а не где придётся.
    ///
    /// Порядок смысловой, а не декоративный: слева то, что остаётся на этой
    /// машине, справа то, что уходит наружу. Тест на порядок — потому что в
    /// `HStack` он держится ровно тем, в каком порядке написаны две строки.
    @MainActor
    func testCopyStandsLeftOfShare() throws {
        let probes = probe()
        let copy = try XCTUnwrap(probes[PaneProbe.copy], "копирование не измерено")
        let share = try XCTUnwrap(probes[PaneProbe.share], "шер не измерен")
        // Против самого шера, а не против кластера: кластер шире обоих, и
        // сравнение с ним истинно при любом порядке — первая версия этой
        // проверки была именно такой и мутацию не поймала.
        XCTAssertLessThanOrEqual(copy.maxX, share.minX, "копирование оказалось правее шера")
        XCTAssertEqual(copy.width, Tokens.Pane.headerButtonSide, accuracy: 0.5)
        XCTAssertEqual(copy.height, Tokens.Pane.headerButtonSide, accuracy: 0.5)
    }

    // MARK: - Хождение

    /// Шевроны стоят у левой кромки — и **не** двигаются от того, что справа.
    @MainActor
    func testTheChevronsStandAtTheLeftEdgeInThatOrder() throws {
        let probes = probe()
        let back = try XCTUnwrap(probes[PaneProbe.back], "«Назад» не измерен")
        let forward = try XCTUnwrap(probes[PaneProbe.forward], "«Вперёд» не измерен")

        XCTAssertEqual(back.minX, Tokens.Pane.NavBar.hPadding, accuracy: 0.5)
        XCTAssertLessThanOrEqual(back.maxX, forward.minX + 0.5, "«Вперёд» оказался левее «Назад»")
        XCTAssertEqual(back.width, Tokens.Sidebar.toggleSide, accuracy: 0.5)
        XCTAssertEqual(back.height, Tokens.Sidebar.toggleSide, accuracy: 0.5)
    }

    /// Со снятым рельсом полоса держит место под светофор и тумблер: иначе
    /// первый же шеврон лёг бы под кнопки окна.
    ///
    /// Число берётся из `Tokens.Window.chromeReserve` — того же, по которому
    /// окно рисует свой тумблер. Двух независимых чисел здесь быть не должно.
    @MainActor
    func testWithTheRailAwayTheChevronsStepAsideForTheWindowsButtons() throws {
        let withRail = try XCTUnwrap(probe(reservesWindowChrome: false)[PaneProbe.back])
        let without = try XCTUnwrap(probe(reservesWindowChrome: true)[PaneProbe.back])
        XCTAssertEqual(
            without.minX - withRail.minX, Tokens.Window.chromeReserve, accuracy: 0.5,
            "место под светофор либо не освобождено, либо освобождено не то"
        )
    }

    /// Полоса стоит в одном ряду с шапкой рельса, и это не совпадение чисел, а
    /// одно число: светофор macOS стоит там, где стоит, и обе шапки обязаны
    /// быть одной высоты.
    func testTheBarIsTheSameRowAsTheRailsHeader() {
        XCTAssertEqual(Tokens.Pane.NavBar.height, Tokens.Sidebar.headerHeight)
        XCTAssertEqual(Tokens.Pane.NavBar.hPadding, Tokens.Sidebar.headerPadding)
    }

    // MARK: - Посмотреть глазами

    /// Снимок всех состояний полосы в один кадр — та же ручка, что у панели
    /// (`SUMMARY_SHOT`). Геометрию стерегут тесты выше; это про то, чего они не
    /// видят: вес шеврона, которому некуда идти, и соседство контролов.
    ///
    ///     NAVBAR_SHOT=/tmp/nav.png swift test --filter testTheBarInEveryStateAtOnce
    @MainActor
    func testTheBarInEveryStateAtOnce() throws {
        guard let output = ProcessInfo.processInfo.environment["NAVBAR_SHOT"] else {
            throw XCTSkip("NAVBAR_SHOT не задан")
        }
        let size = CGSize(width: 900, height: 4 * Tokens.Pane.NavBar.height)
        let root = VStack(spacing: 0) {
            // Готовая встреча: истории ещё нет — оба шеврона тихие.
            PaneNavBar(
                back: .init(enabled: false) {}, forward: .init(enabled: false) {},
                reservesWindowChrome: false,
                trailing: { MeetingActions(copy: {}, share: {}) { Button("Показать в Finder") {} } }
            )
            // Она же после перехода — «Назад» живой.
            PaneNavBar(
                back: .init(enabled: true) {}, forward: .init(enabled: false) {},
                reservesWindowChrome: false,
                trailing: { MeetingActions(copy: {}, share: {}) { Button("Показать в Finder") {} } }
            )
            // Идущая запись: имя в полосе, потому что тело — живая лента.
            PaneNavBar(
                back: .init(enabled: true) {}, forward: .init(enabled: true) {},
                reservesWindowChrome: false,
                leading: {
                    MeetingPaneIdentity(meetingID: "rec", title: "Дейлик ВК Камуфляж")
                },
                trailing: {
                    RecordingControls(elapsed: "12:04", isPaused: false, onPause: {}, onStop: {})
                }
            )
            // Раздел со снятым рельсом: справа нет ничего, слева освобождено
            // место под светофор и тумблер.
            PaneNavBar(
                back: .init(enabled: true) {}, forward: .init(enabled: false) {},
                reservesWindowChrome: true,
                trailing: { EmptyView() }
            )
        }
        .frame(width: size.width, height: size.height)
        .background(Tokens.Paint.Bg.page)
        .environment(\.colorScheme, .dark)

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
        try png.write(to: URL(fileURLWithPath: output))
    }

    // MARK: - Приборы

    @MainActor
    private func probe(
        width: CGFloat = Tokens.Pane.paneMeasure,
        reservesWindowChrome: Bool = false
    ) -> [String: CGRect] {
        var collected: [String: CGRect] = [:]
        let root = PaneNavBar(
            back: .init(enabled: true) {},
            forward: .init(enabled: false) {},
            reservesWindowChrome: reservesWindowChrome,
            trailing: {
                MeetingActions(copy: {}, share: {}) {
                    Button("Показать в Finder") {}
                }
            }
        )
        .frame(width: width)
        .frame(height: height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(PaneProbeKey.self) { collected = $0 }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        // `close()` у программно созданного окна освобождает его, а ARC держит
        // ссылку дальше — второй такой замер в одном процессе падает по
        // SIGSEGV. Окно не закрывается вовсе: оно и не показывается.
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        // Доставка префов асинхронна.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        return collected
    }
}
