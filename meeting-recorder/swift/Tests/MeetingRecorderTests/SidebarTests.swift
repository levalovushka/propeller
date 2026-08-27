import XCTest
import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// # What these guard
///
/// Two different things, and they fail for different reasons.
///
/// **The machine** — which appearance a meeting gets. Named after what a person
/// sees, because "the wrong row spun" is the bug, not "activity() returned
/// .processing".
///
/// **The geometry** — that a row is the height the comps drew. This is not
/// pedantry: SwiftUI's `lineSpacing` puts space *between* lines and nothing
/// around the block, so every text block comes out short by one leading and the
/// error compounds down the list. Two points per row is invisible in isolation
/// and a row and a half of drift over a day's meetings. The rail is 42 / 60 /
/// 78 for one, two and three title lines (the tokens' arithmetic, see
/// `testAMeetingRowIsTheHeightItsTokensAddUpTo`); if that stops being true,
/// something changed the type scale and nobody looked at the rail.
final class SidebarTests: XCTestCase {

    // MARK: - The machine

    func testAMeetingBeingRecordedSaysSoWhateverElseIsTrue() {
        let activity = SidebarRowMachine.activity(
            stage: .recording,
            involvement: .working(.transcribing),
            isTerminal: true
        )
        XCTAssertEqual(activity, .recording)
    }

    func testWorkOnAnotherMeetingLeavesThisRowAlone() {
        // The regression this exists for: every row in the list moving because
        // the app was busy with one of them (state `10-other-busy`).
        let activity = SidebarRowMachine.activity(
            stage: .saved,
            involvement: .elsewhere(.summarizing),
            isTerminal: false
        )
        XCTAssertEqual(activity, .none)
    }

    func testВстречаБезВходаПеребиваетРаботу() {
        let activity = SidebarRowMachine.activity(
            stage: .transcribedRaw,
            involvement: .working(.diarizing),
            isTerminal: true
        )
        XCTAssertEqual(activity, .rests)
    }

    func testQueuedLooksLikeNothingIsHappening() {
        for stage in [RecordingStage.recorded, .transcribedRaw, .saved] {
            XCTAssertEqual(
                SidebarRowMachine.activity(stage: stage, involvement: .idle, isTerminal: false),
                SidebarRowActivity.none,
                "\(stage) is queued, and the rail draws queued as still"
            )
        }
    }

    func testSelectionNeverChangesWhatIsHappening() {
        // Two dimensions, never mixed: clicking a meeting must not stop its
        // shimmer, and a shimmer must not look like a selection.
        for selected in [false, true] {
            let state = SidebarRowMachine.state(
                stage: .recorded,
                involvement: .working(.transcribing),
                isTerminal: false,
                isSelected: selected,
                isHovered: false
            )
            XCTAssertEqual(state.activity, .processing)
            XCTAssertEqual(state.isSelected, selected)
        }
    }

    func testEveryStageProducesSomeAppearance() {
        // Adding a stage without thinking about the rail should not be possible
        // to do silently.
        for stage in RecordingStage.allCases {
            _ = SidebarRowMachine.activity(stage: stage, involvement: .idle, isTerminal: false)
        }
        XCTAssertEqual(
            SidebarRowMachine.activity(stage: .recording, involvement: .idle, isTerminal: false),
            .recording
        )
    }

    func testAWorkingRowSaysWhatItIsDoingInsteadOfNothing() {
        // Topics are the *last* thing the pipeline produces, so a meeting
        // mid-flight has none. Without this the quiet line is blank for the
        // whole minute the work takes.
        let text = SidebarRowMachine.preview(
            activity: .processing,
            phaseMessage: PipelineActivity.Phase.diarizing.defaultMessage,
            topics: ""
        )
        XCTAssertEqual(text, "Определяем спикеров…")
    }

    func testAFinishedRowShowsItsTopics() {
        let text = SidebarRowMachine.preview(
            activity: .none, phaseMessage: nil, topics: "Ретро, планирование"
        )
        XCTAssertEqual(text, "Ретро, планирование")
    }

    /// Таймер на экране стоит — значит и строка не имеет права говорить, что
    /// запись идёт.
    func testAPausedRecordingSaysSoInsteadOfClaimingItIsRecording() {
        let text = SidebarRowMachine.preview(
            activity: .recording, phaseMessage: nil, topics: "", isPaused: true
        )
        XCTAssertEqual(text, "Пауза")
    }

    // MARK: - Catalogue coverage

    func testTheCatalogueCoversEveryActivity() {
        let covered = Set(SidebarStateCatalog.meetingRows.map(\.state.activity))
        XCTAssertEqual(
            covered, Set(SidebarRowActivity.allCases),
            "a row appearance with no case in the catalogue is one nobody can look at"
        )
    }

    func testTheCatalogueCoversSelectionOfEveryActivity() {
        // Every activity is drawn open as well as closed — except a deletion that
        // has not landed. That row is on its way out of the list; the machine
        // refuses to call it selected, so a selected case for it would be a
        // picture of a state the app cannot reach.
        for activity in SidebarRowActivity.allCases where activity != .deletedUndoable {
            XCTAssertTrue(
                SidebarStateCatalog.meetingRows.contains {
                    $0.state.activity == activity && $0.state.isSelected
                },
                "\(activity) has no selected case — a meeting can always be open"
            )
        }
        XCTAssertFalse(
            SidebarStateCatalog.meetingRows.contains {
                $0.state.activity == .deletedUndoable && $0.state.isSelected
            }
        )
    }

    func testCatalogueIDsAreUnique() {
        let ids = SidebarStateCatalog.meetingRows.map(\.id) + SidebarStateCatalog.navRows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids name screenshot files; duplicates overwrite")
    }

    func testTheTopListFadeStaysOffUntilTheListScrolls() {
        let limit = Tokens.Sidebar.listTopFade
        XCTAssertEqual(SidebarEdgeFade.topHeight(scrollOffset: 0), 0)
        XCTAssertEqual(SidebarEdgeFade.topHeight(scrollOffset: -8), 0)
        XCTAssertEqual(SidebarEdgeFade.topHeight(scrollOffset: 1), 1)
        XCTAssertEqual(SidebarEdgeFade.topHeight(scrollOffset: limit), limit)
        XCTAssertEqual(SidebarEdgeFade.topHeight(scrollOffset: limit + 40), limit)
    }

    func testEveryPipelineStateHasARowAppearance() {
        XCTAssertEqual(
            SidebarStateCatalog.pipelineMapping.count,
            UIStateCatalog.meetingStates.count
        )
    }

    // MARK: - Title text

    func testATitleEndsSoThePreviewCanRunOnFromIt() {
        XCTAssertEqual(SidebarTitleText.terminated("Воркшоп по VK Музыке"), "Воркшоп по VK Музыке.")
        XCTAssertEqual(SidebarTitleText.terminated("Сколько ещё?"), "Сколько ещё?")
        XCTAssertEqual(SidebarTitleText.terminated("Ретро…"), "Ретро…")
        XCTAssertEqual(SidebarTitleText.terminated(""), "")
    }

    func testTheRailShowsTheTitleTheMeetingActuallyHas() {
        // Точку приписывает склейка двух половин, а не название. В рельсе
        // половина одна, и точка в ней — след от вёрстки, которой там нет.
        let model = SidebarMeetingRowModel(
            id: "x", meta: "", title: "Воркшоп по VK Музыке", preview: "", state: .rest
        )
        XCTAssertEqual(model.title, "Воркшоп по VK Музыке")
    }

    // MARK: - Days and durations

    func testTodayHasNoHeaderBecauseNobodyReadsIt() {
        let now = Date()
        XCTAssertNil(SidebarDayGrouping.day(for: now, now: now).header)
    }

    func testYesterdayIsNamedAndDated() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let header = SidebarDayGrouping.day(for: yesterday, now: now).header
        XCTAssertNotNil(header)
        XCTAssertTrue(header!.hasPrefix("Вчера, "), "got \(header ?? "nil")")
    }

    func testAClockSkewedIntoTheFutureIsTreatedAsToday() {
        // A machine whose clock was wrong, or an import. «через −1 день» is not
        // a thing the rail is allowed to write.
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        XCTAssertNil(SidebarDayGrouping.day(for: tomorrow, now: now).header)
    }

    func testDaysGroupTogetherRegardlessOfTime() {
        let cal = Calendar.current
        let now = Date()
        let morning = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: now))!
        let evening = morning.addingTimeInterval(23 * 3600)
        XCTAssertEqual(
            SidebarDayGrouping.day(for: morning, now: now).key,
            SidebarDayGrouping.day(for: evening, now: now).key
        )
    }

    func testNobodyDividesNinetyFiveMinutesInTheirHead() {
        XCTAssertEqual(SidebarMeta.durationText(95 * 60), "1 ч 35 мин")
        XCTAssertEqual(SidebarMeta.durationText(60 * 60), "1 ч")
        XCTAssertEqual(SidebarMeta.durationText(45 * 60), "45 мин")
        XCTAssertEqual(SidebarMeta.durationText(20), "меньше минуты")
    }

    func testALiveRecordingShowsNoDurationYet() {
        // Duration is 0 until the file is closed; «17:30 · меньше минуты»
        // ticking to «1 мин» in the rail is noise, not information.
        let line = SidebarMeta.line(start: Date(), duration: 0)
        XCTAssertFalse(line.contains("·"))
    }

    // MARK: - Geometry

    @MainActor
    func testAMeetingRowIsAlwaysTheSameHeight() {
        // Строка встречи — 32 pt, какой бы длины ни было название: оно живёт в
        // одну строку и обрезается многоточием (Figma 307:7177). До 2026-08-26
        // высота считалась «отступы плюс сколько строк вышло», и список ехал
        // вниз каждый раз, когда у встречи появлялось название подлиннее.
        let titles = [
            "Тактика.",
            "Тактика | Лиды. Обсудили ошибки и предложили пути.",
            "Воркшоп по VK Музыке. Обсудили этапы, выявили препятствия, наметили следующие шаги.",
        ]
        for text in titles {
            let height = measure(
                SidebarMeetingRow(
                    row: SidebarMeetingRowModel(
                        id: "x", meta: "17:30 · 45 мин", title: text, preview: "", state: .rest
                    ),
                    action: {}
                ),
                width: Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2
            )
            XCTAssertEqual(
                height, Tokens.Sidebar.meetingRowHeight, accuracy: 0.6,
                "«\(text.prefix(20))…» вышла \(height) pt вместо \(Tokens.Sidebar.meetingRowHeight)"
            )
        }
    }

    @MainActor
    func testAWorkingRowIsTheSameHeightAsAQuietOne() {
        // У работающей встречи впереди названия стоит анимированная иконка. Она
        // 16 pt в строке с боксом текста 16 — и обязана оставаться ровно такой:
        // `HStack` берёт высоту самого высокого ребёнка, и иконка на точку выше
        // двигала бы список каждый раз, когда встреча уходит в работу.
        let width = Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2
        func height(_ activity: SidebarRowActivity) -> CGFloat {
            measure(
                SidebarMeetingRow(
                    row: SidebarMeetingRowModel(
                        id: "x", meta: "", title: "Тактика | Лиды", preview: "",
                        state: SidebarRowState(activity: activity)
                    ),
                    action: {}
                ),
                width: width
            )
        }
        for activity in SidebarRowActivity.allCases {
            XCTAssertEqual(
                height(activity), Tokens.Sidebar.meetingRowHeight, accuracy: 0.6,
                "\(activity.rawValue) вышла другой высоты"
            )
        }
    }

    @MainActor
    func testEveryRailStyleMeasuresTheLineHeightItDeclares() {
        // The row heights are built out of these boxes, so this is the check
        // that catches a type change at the source rather than three rows later.
        // It is also the one that would have caught `lineSpacing` putting space
        // only *between* lines, which left every block short by one leading.
        let styles: [(String, Tokens.Typography.Style)] = [
            ("navLabel", Tokens.Sidebar.Typo.navLabel),
            ("meta", Tokens.Sidebar.Typo.meta),
            ("meetingTitle", Tokens.Sidebar.Typo.meetingTitle),
            ("sectionHeader", Tokens.Sidebar.Typo.sectionHeader),
            ("footerButton", Tokens.Sidebar.Footer.buttonLabel),
            // `settings.page` здесь нет: 17 pt — единственный кегль, на котором
            // `renderedLineHeight` промахивается (считает по потолкам асцендера
            // и десцендера порознь и даёт 21 против настоящих 20), поэтому
            // заголовок страницы держит бокс названной высотой, а не лидингом.
            // Проверяет его `SettingsLayoutTests`.
            ("settings.subtitle", Tokens.Settings.Typo.subtitle),
            ("settings.control", Tokens.Settings.Typo.control),
        ]
        for (name, style) in styles {
            let height = measure(Text("Тактика").typoBlock(style), width: 240)
            XCTAssertEqual(
                height, style.lineHeight, accuracy: 0.6,
                "\(name) declares \(style.lineHeight) pt per line, measured \(height)"
            )
            XCTAssertGreaterThanOrEqual(
                style.lineSpacingExtra, 0,
                "\(name) asks for a line box tighter than the font lays out — the "
                    + "rows would overlap rather than breathe"
            )
        }
    }

    func testNavRowsAndMeetingRowsStartOnOneMargin() {
        // Отступ рельса делится между полем списка и собственным отступом ряда,
        // и до 2026-08-26 деление было разным у двух блоков: 10 + 14 у встреч и
        // 10 + 13 у навигации, чтобы *глифы* встали на одну линию. В редизайне
        // у обоих рядов один отступ и один кегль, поэтому и линия одна.
        // Разъедутся — весь рельс поедет вбок относительно шапки над ним.
        XCTAssertEqual(Tokens.Sidebar.meetingHPadding, Tokens.Sidebar.navRowHPadding)
        XCTAssertEqual(Tokens.Sidebar.bodyHPadding + Tokens.Sidebar.meetingHPadding, 18)
    }

    func testTheDateHeaderBlockStaysTwentyPointsWhateverTheTypeDoes() {
        // The date line plus its gap is one drawn quantity. Letting the type
        // change grow it shifts every dated section below by the difference.
        XCTAssertEqual(
            Tokens.Sidebar.Typo.sectionHeader.lineHeight + Tokens.Sidebar.sectionHeaderBottomGap,
            Tokens.Sidebar.sectionHeaderBlockHeight,
            accuracy: 0.01
        )
    }

    @MainActor
    func testHoveringARowDoesNotResizeIt() {
        // `State=Rest` и `State=Hover` — одной высоты. Список, который ездит
        // под курсором, пока тот идёт по нему, невозможно использовать.
        let width = Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2
        let title = "Воркшоп по VK Музыке. Обсудили этапы, выявили препятствия, наметили следующие шаги."
        func height(hovered: Bool) -> CGFloat {
            measure(
                SidebarMeetingRow(
                    row: SidebarMeetingRowModel(
                        id: "x", meta: "17:30 · 45 мин", title: title, preview: "",
                        state: SidebarRowState(isHovered: hovered)
                    ),
                    action: {}, onDelete: {}
                ),
                width: width
            )
        }
        XCTAssertEqual(height(hovered: true), height(hovered: false), accuracy: 0.1)
        XCTAssertEqual(height(hovered: true), Tokens.Sidebar.meetingRowHeight, accuracy: 0.6)
    }

    @MainActor
    func testANavRowIsThirtyTwoPoints() {
        let height = measure(
            SidebarNavRow(
                item: SidebarNavItem(id: "x", symbol: "magnifyingglass", title: "Поиск", hint: .shortcut("⌘K")),
                action: {}
            ),
            width: Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2
        )
        XCTAssertEqual(height, Tokens.Sidebar.navRowHeight, accuracy: 0.1)
    }

    /// Плюс «создать проект» есть в макете (`showQuickAction`, 307:6704) и
    /// однажды уже не доехал до приложения. Ширину строки он меняет ровно на
    /// свой бокс и зазор — и это единственное, чем его присутствие можно
    /// померить снаружи: нарисован он прозрачным, пока курсор не пришёл.
    @MainActor
    func testTheQuickActionTakesItsOwnSlotAndNothingMore() {
        func width(quickAction: SidebarNavItem.QuickAction?, handled: Bool) -> CGFloat {
            let item = SidebarNavItem(
                id: "projects", symbol: "folder.fill", title: "Проекты",
                quickAction: quickAction
            )
            let hosting = NSHostingView(
                rootView: SidebarNavRow(item: item, onQuickAction: handled ? {} : nil, action: {})
            )
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.width
        }
        let plus = SidebarNavItem.QuickAction(symbol: "plus", title: "Новый проект")
        let bare = width(quickAction: nil, handled: true)
        XCTAssertEqual(
            width(quickAction: plus, handled: true) - bare,
            Tokens.Sidebar.navIconSide + Tokens.Sidebar.navRowGap,
            accuracy: 0.5,
            "плюс обязан занять свой бокс и зазор — и ни точкой больше"
        )
        // Кнопка без обработчика — тупик, и слота под неё тоже нет.
        XCTAssertEqual(width(quickAction: plus, handled: false), bare, accuracy: 0.5)
    }

    /// Две ступени тона у плюса — решение владельца 2026-08-27, макет даёт
    /// одну. Смысл в разнице: пока курсор на строке, плюс тише её, а когда
    /// курсор на нём — громче. Одинаковые ступени означали бы, что строка не
    /// говорит, куда попадёт клик, — и заметить это глазами почти нельзя.
    @MainActor
    func testThePlusIsQuieterOnTheRowThanUnderTheCursor() {
        func alpha(_ colour: Color) -> CGFloat {
            var value: CGFloat = -1
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                value = NSColor(colour).usingColorSpace(.deviceRGB)!.alphaComponent
            }
            return value
        }
        let onRow = alpha(Tokens.Sidebar.navQuickActionOnRow)
        let onSelf = alpha(Tokens.Sidebar.navQuickActionOnSelf)
        XCTAssertEqual(onRow, 0.30, accuracy: 0.01)
        XCTAssertEqual(onSelf, 0.70, accuracy: 0.01)
        // И тише самой строки, пока она — цель: подпись строки идёт в 90 %.
        XCTAssertLessThan(onRow, alpha(Tokens.Sidebar.navLabel))
    }

    @MainActor
    func testTheQuickActionDoesNotMakeTheRowTaller() {
        let height = measure(
            SidebarNavRow(
                item: SidebarNavItem(
                    id: "projects", symbol: "folder.fill", title: "Проекты",
                    quickAction: .init(symbol: "plus", title: "Новый проект")
                ),
                onQuickAction: {},
                action: {}
            ),
            width: Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2
        )
        XCTAssertEqual(height, Tokens.Sidebar.navRowHeight, accuracy: 0.1)
    }

    func testTheMeetingListStartsWhereTheCompsPutIt() {
        // Body inset 10, four nav rows of 32, then the gap: the first meeting
        // begins 206 pt down the rail. There used to be a rule in that gap; it
        // is gone and the gap walked 12 → 20 → 28 → 20, so this number is the
        // one thing that proves the separation is still intentional whitespace.
        let listTop = Tokens.Sidebar.headerHeight
            + Tokens.Sidebar.bodyVPadding
            + Tokens.Sidebar.navRowHeight * 4
            + Tokens.Sidebar.blockGap
        XCTAssertEqual(listTop, 206)
    }

    // MARK: - Traffic lights

    func testTheTrafficLightsSitInTheRailsHeader() {
        // Ø12 discs at x 20 / 40 / 60, centred on y 24 — the middle of the 48 pt
        // header. Числа сняты с экспорта слота (76×32, центры 18 / 38 / 58) плюс
        // поле шапки 8, а не с глаза: до 2026-08-26 здесь стояло 24 / 44 / 64 из
        // старых макетов. Переворот через координаты контейнера — та часть,
        // которую легко ошибить и невозможно увидеть в диффе.
        let container: CGFloat = 52          // AppKit's titlebar container
        // Два размера кнопки: нарисованный в макете диск и настоящая кнопка
        // macOS. Центры у них обязаны совпасть — угол не обязан ничем.
        for button in [CGFloat(12), CGFloat(14)] {
            for (index, expectedCenter) in [(0, 26.0), (1, 46.0), (2, 66.0)] {
                let origin = SidebarTrafficLightLayout.origin(
                    index: index, containerHeight: container,
                    buttonWidth: button, buttonHeight: button
                )
                XCTAssertEqual(origin.x + button / 2, expectedCenter, accuracy: 0.01,
                               "кнопка \(button): центр диска \(index)")
                // Центр на 24 от верха окна, то есть container − 24 − половина
                // кнопки от низа контейнера.
                XCTAssertEqual(origin.y + button / 2, container - 24, accuracy: 0.01,
                               "кнопка \(button): центр по вертикали")
            }
        }
        XCTAssertEqual(
            SidebarTrafficLightLayout.centerYFromWindowTop(),
            Tokens.Sidebar.headerHeight / 2,
            accuracy: 0.01,
            "the discs must be centred in the header they sit in"
        )
    }

    @MainActor
    func testTheRailsHeaderStartsAtTheTopOfATitledWindow() {
        // The bug this exists for: a titled `.fullSizeContentView` window insets
        // its content by the titlebar height, so the rail's 48 pt header began
        // ~28 pt down while AppKit had already put the traffic lights at 18 —
        // the toggle ended up on a second line under the discs.
        //
        // Every gallery board is shot in a *borderless* window, which has no
        // titlebar and no inset, so the exporter cannot see this at all. Hence a
        // real titled window here.
        let size = CGSize(width: Tokens.Sidebar.width, height: 400)
        var midY: CGFloat?

        let root = PropellerSidebar(model: Self.railModel, trafficLights: .drawn, onToggle: {})
            .frame(width: size.width, height: size.height)
            .onPreferenceChange(SidebarHeaderMidYKey.self) { midY = $0 }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let value = midY else {
            return XCTFail("the header never reported its position")
        }
        // SwiftUI's `.global` grows down from the top of the window's content.
        XCTAssertEqual(
            value, Tokens.Sidebar.headerHeight / 2, accuracy: 1.0,
            "the header must be centred on \(Tokens.Sidebar.headerHeight / 2) pt — where the traffic lights are"
        )
        XCTAssertEqual(
            value,
            SidebarTrafficLightLayout.centerYFromWindowTop(),
            accuracy: 1.0,
            "header and traffic lights must share a centre line"
        )
    }

    private static let railModel = SidebarModel(
        nav: [.init(id: "record", symbol: SidebarNavItem.propellerMarkSymbol, title: "Новая запись", hint: .shortcut("⌘R"))],
        body: .archive(groups: [.init(id: "today", header: nil, rows: [
            SidebarMeetingRowModel(
                id: "1", meta: "17:30 · 45 мин", title: "Тактика", preview: "", state: .rest
            ),
        ])])
    )

    // MARK: - The sweep

    func testTheSweepMatchesTheFrameFigmaDrew() {
        // At travel 0 this is the static gradient in the comps: a line across a
        // 252 × 16 row at 113.913°, with the band centred at 43.876 % of it.
        let line = SidebarSweep.gradientLine(
            angle: Tokens.Sidebar.shimmerAngle,
            size: CGSize(width: 252, height: 16),
            travel: 0
        )
        // Mostly horizontal, running left-to-right and slightly downward — the
        // sign of the y component is the part that is easy to get backwards.
        XCTAssertLessThan(line.start.x, line.end.x)
        XCTAssertLessThan(line.start.y, line.end.y)
        // Symmetric about the centre of the box.
        XCTAssertEqual((line.start.x + line.end.x) / 2, 0.5, accuracy: 0.001)
        XCTAssertEqual((line.start.y + line.end.y) / 2, 0.5, accuracy: 0.001)
    }

    func testTheSweepDoesNotDivideByZeroOnAnUnlaidOutRow() {
        let line = SidebarSweep.gradientLine(
            angle: Tokens.Sidebar.shimmerAngle, size: .zero, travel: 0
        )
        XCTAssertEqual(line.start, UnitPoint.leading)
        XCTAssertEqual(line.end, UnitPoint.trailing)
    }

    // MARK: - Hosting

    @MainActor
    private func measure<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }
}
