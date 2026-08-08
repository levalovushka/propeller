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
    func testAMeetingRowIsTheHeightItsTokensAddUpTo() {
        // 42 / 60 / 78 for one, two and three title lines: 2×12 padding + 18
        // per title line. The meta line (14) and the 4 pt gap under the title
        // are built but currently hidden — add them back if that row returns.
        let cases: [(String, CGFloat)] = [
            ("Тактика.", 42),
            ("Тактика | Лиды. Обсудили ошибки и предложили пути.", 60),
            ("Воркшоп по VK Музыке. Обсудили этапы, выявили препятствия, наметили следующие шаги.", 78),
        ]
        for (text, expected) in cases {
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
                height, expected, accuracy: 0.6,
                "«\(text.prefix(20))…» should be \(expected) pt tall, measured \(height)"
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

    func testTheTextMarginSurvivesTheRailGivingRoomToItsRows() {
        // The rail's margin is split between the body inset and each row's own
        // padding, and only the split moved (2026-08-04): 12 + 12 became
        // 10 + 14, so titles still start 24 pt in while a hovered or selected
        // fill reaches 2 pt closer to both bezels. Changing one side alone is
        // the mistake this catches — it slides every line in the rail sideways
        // against the header above it.
        XCTAssertEqual(Tokens.Sidebar.bodyHPadding + Tokens.Sidebar.meetingHPadding, 24)
        // Nav labels sit a point tighter for the glyph's own inset — see the
        // token. What matters is that the two blocks keep their relationship.
        XCTAssertEqual(Tokens.Sidebar.bodyHPadding + Tokens.Sidebar.navRowHPadding, 23)
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
        // `state=rest` and `state=hover` are both the same height. They have
        // to be: an `HStack` takes the height of its tallest child, so 16 pt
        // action icons in a 14 pt time line grow the row — and a list that
        // shifts under the pointer as it travels is unusable.
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
        XCTAssertEqual(height(hovered: true), 78, accuracy: 0.6)
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
        // Figma 31:4584 — Ø12 discs at x 24 / 44 / 64, centred on y 24, which is
        // the middle of the 48 pt header. They moved up four points when the
        // header shrank from 56; the flip through container coordinates is the
        // part that is easy to get wrong and impossible to see in a diff.
        let container: CGFloat = 52          // AppKit's titlebar container
        let button: CGFloat = 12
        for (index, expectedX) in [(0, 24.0), (1, 44.0), (2, 64.0)] {
            let origin = SidebarTrafficLightLayout.origin(
                index: index, containerHeight: container, buttonHeight: button
            )
            XCTAssertEqual(origin.x, expectedX, accuracy: 0.01)
            // 52 − 18 − 12 = 22 up from the container's bottom.
            XCTAssertEqual(origin.y, container - 18 - button, accuracy: 0.01)
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
        groups: [.init(id: "today", header: nil, rows: [
            SidebarMeetingRowModel(
                id: "1", meta: "17:30 · 45 мин", title: "Тактика.", preview: "", state: .rest
            ),
        ])]
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
