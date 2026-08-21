import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Meetings home — Figma 640:1859.
struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject var recordingStore: RecordingStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSearchPalette = false
    @ObservedObject private var calendar = CalendarService.shared

    /// Browser-style history over *meetings*, and only meetings.
    ///
    /// It used to be `[String?]`, where `nil` meant «список встреч» — a
    /// destination that stopped existing when the rail became the list. Its one
    /// remaining effect was that «Назад» from the first meeting deselected
    /// everything and left «Пока нет встреч» written across the pane while the
    /// rail was full of them. A meeting is always open when there is one to
    /// open, so the absent destination is gone from the type rather than
    /// guarded at each use.
    @State private var navStack: [String] = []
    @State private var navIndex: Int = 0
    @State private var suppressNavRecord = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Back is available whenever we can leave the meeting detail (or step history).
    ///
    /// Запись ничего из этого не запрещает: она идёт своим ходом, а окно всё это
    /// время остаётся окном — можно уйти в другую встречу и вернуться.
    private var canGoBack: Bool {
        navIndex > 0
    }
    private var canGoForward: Bool { navIndex + 1 < navStack.count }

    /// The rail can be put away — Figma has a `nosidebar` frame for it, where the
    /// collapse toggle and the traffic lights move into the content header.
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    /// Which column the pane is showing. The comps switch this from the action
    /// bar; until that is built it lives in the header's «ещё» menu.
    @State private var paneMode: MeetingPaneMode = .summary
    /// What is being typed into the notes composer.
    @State private var draftNote = ""
    /// Raised by «Поделиться»; the anchor lowers it once the sheet is up.
    @State private var showShareSheet = false
    /// Записываемая встреча, которую попросили удалить. Спрашиваем один раз —
    /// это удаление необратимо, в отличие от всех остальных.
    @State private var discardConfirmation: RecordingEntry?

    /// ⌥Tab между встречами. Живёт у окна, а не у рельса: жест работает и когда
    /// рельс убран, и именно поэтому у него есть своя панель.
    @StateObject private var switching = MeetingSwitchController()

    /// The summary being read and edited, and which meeting it belongs to.
    ///
    /// Held here rather than re-read from disk on every draw — which is what the
    /// pane did while the summary was read-only — because now the newest version
    /// is the one under the caret, and a re-read mid-word would type over it.
    @State private var summary = SummaryDocument.empty
    @State private var summaryOf: String?
    /// The caret and what the action bar does to it. `@StateObject`, so the
    /// selection survives the pane being rebuilt on every keystroke elsewhere.
    @StateObject private var summaryEditing = SummaryEditorController()
    /// Writes are debounced: a summary is saved when typing pauses, and flushed
    /// when the meeting changes or the window closes.
    @State private var summarySave: DispatchWorkItem?

    var body: some View {
        // По очереди, а не крест-накрест (`principles.md` §9): приглашение
        // уходит, и только на освободившееся место приходят колонки. Задержка
        // входа равна длительности ухода — ровно та же хореография, что у
        // подмены содержимого колонки, потому что дефект, от которого она
        // защищает, тот же: два экрана, проступающие друг сквозь друга.
        ZStack {
            // Пока архив не прочитан, окно не показывает ни того ни другого.
            // Индекс читается в `bootstrap()`, то есть уже после первого кадра,
            // и до этого флага «пусто» было неотличимо от «ещё не знаем»: окно с
            // полным архивом успевало показать приглашение и тут же смениться
            // списком.
            //
            // Внешнее условие не под `animation(value:)` — та смотрит только на
            // `showsFirstRun`. Значит содержимое **появляется**, а не
            // проступает: первого кадра ждать нечего, и растянуть его на 420 мс
            // было бы тем же морганием, только медленным.
            if recordingStore.didLoad {
                if showsFirstRun {
                    // Вместо колонок, а не поверх них: пустой рельс и пустая
                    // панель — не фон для приглашения, а ровно то, что оно
                    // заменяет.
                    FirstRunView(onAction: startFirstRecording)
                        .transition(.windowSwap)
                } else {
                    columns
                        .transition(.windowSwap)
                }
            }
        }
        .animation(.default, value: showsFirstRun)
        // Over both columns, because ⌥Tab is a window gesture and the panel is
        // what the rail would have shown if it were up. Centred rather than
        // docked: it is not part of either column, and with the rail away there
        // is no column it could belong to.
        .overlay { switcherPanel }
        // Both columns start at the top of the window, not under the titlebar.
        // This has to be here rather than on the pane alone: the traffic lights
        // are AppKit's and sit where we put them regardless, so a rail that
        // still honours the safe area drops its own 48 pt header below them —
        // the toggle ends up on a second line under the discs.
        .ignoresSafeArea(.container, edges: .top)
        // Keyboard, sheets and lifecycle belong to the window, not the pane —
        // ⌘K has to open the palette with the pointer over the rail too.
        .onAppear {
            state.isWindowOpen = true
            NSApp.setActivationPolicy(.regular)
            selectNewestIfNothingChosen()
            switching.start(
                // The rail's own order: the same list, filtered the same way, so
                // walking it with the key and reading it with the eye agree.
                order: { recordingStore.recordings.filter(\.hasSomethingToShow).map(\.id) },
                selectedID: { state.selectedRecordingID },
                openMeeting: { id in
                    guard let entry = recordingStore.recordings.first(where: { $0.id == id }) else { return }
                    state.selectRecording(entry)
                }
            )
        }
        .onChange(of: recordingStore.recordings.count) { _, _ in
            // The first meeting to arrive in an empty archive opens itself; so
            // does the one that just finished recording.
            selectNewestIfNothingChosen()
        }
        .onDisappear {
            flushSummarySave()
            switching.stop()
            state.isWindowOpen = false
            NSApp.setActivationPolicy(.accessory)
        }
        .onChange(of: state.selectedRecordingID) { _, newID in
            // Before the switch, not after: the pending write belongs to the
            // meeting that was open, and a moment later there is no way to
            // learn which one that was.
            flushSummarySave()
            // Недописанная заметка принадлежит прежней встрече: `MainView` не
            // пересоздаётся при смене выбора, и без сброса `commitNote`
            // подошьёт её к встрече, на которую только что переключились.
            draftNote = ""
            recordNav(to: newID)
            loadSummary()
        }
        // The summary lands when the worker finishes, and the pane is already
        // open on that meeting — so the arrival is an activity change, not a
        // selection one.
        .onChange(of: state.activity) { _, _ in loadSummary() }
        .onAppear {
            loadSummary()
            poseSummarySelectionIfAsked()
        }
        // A shot of a half-swept column differs from the next shot of the same
        // column, and the gallery exists to answer «что изменилось».
        .environment(\.summaryRevealFrozen, isPosedForAScreenshot)
        // The pipeline asks for a column when it finishes something («саммари
        // готово» → the summary). Nothing honoured that after the redesign: the
        // request was written and dropped, because the pane's mode is local
        // `@State` and the old detail view was the only reader.
        .onChange(of: state.preferredDetailTab) { _, _ in adoptPreferredColumn() }
        .onAppear { adoptPreferredColumn() }
        .confirmationDialog(
            "Удалить встречу, которая пишется?",
            isPresented: Binding(
                get: { discardConfirmation != nil },
                set: { if !$0 { discardConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Остановить и удалить", role: .destructive) {
                discardConfirmation = nil
                state.cancelRecording()
            }
            Button("Продолжить запись", role: .cancel) { discardConfirmation = nil }
        } message: {
            Text("Запись остановится, аудио и заметки этой встречи удалятся.")
        }
        .sheet(isPresented: $showSearchPalette) {
            SearchPalette(
                state: state,
                onOpenRecording: { entry in
                    showSearchPalette = false
                    state.selectRecording(entry)
                },
                onClose: { showSearchPalette = false }
            )
        }
        .background {
            Button("") {
                guard !state.isRecording else { return }
                state.startRecording()
            }
            .keyboardShortcut("r", modifiers: .command)
            .hidden()

            // ⌘. останавливает запись из любой встречи, а не только с её
            // экрана: во время записи можно уйти читать другую, и оттуда тоже
            // надо уметь остановиться.
            Button("") {
                guard state.isRecording else { return }
                state.stopRecording()
            }
            .keyboardShortcut(".", modifiers: .command)
            .hidden()

            Button("") {
                showSearchPalette = true
                Analytics.signal("Search.opened")
            }
            .keyboardShortcut("k", modifiers: .command)
            .hidden()
        }
        // No launch-time alert here any more, and nothing replaced it. A modal
        // for catch-up is the one thing the app promised never to do — it also
        // suspends the worker until answered — and the news itself was worse than
        // useless: it told the user their recordings had been interrupted, about a
        // crash of ours, with nothing to do about it. Each of those meetings is in
        // the list, wearing its own state.
    }

    /// There is no list screen any more, so "nothing selected" is not a state
    /// the pane can usefully show — the newest meeting stands in for it.
    private func selectNewestIfNothingChosen() {
        // Also re-run when the chosen meeting has left the list, so the pane
        // never shows something the rail does not. Nothing is filtered out of
        // the rail any more — short recordings are easy enough to delete that
        // hiding them only made the app open meetings nobody could see.
        if let id = state.selectedRecordingID,
           recordingStore.recordings.contains(where: { $0.id == id }) {
            return
        }
        guard let newest = recordingStore.recordings.max(by: { $0.date < $1.date }) else {
            state.selectedRecordingID = nil
            return
        }
        state.selectRecording(newest)
    }

    /// Switch the pane to the column the app asked for, then forget the request —
    /// a sticky one would drag the user back every time the view re-appeared.
    private func adoptPreferredColumn() {
        guard let raw = state.preferredDetailTab else { return }
        switch raw {
        case "recap":      paneMode = .summary
        case "transcript": paneMode = .transcript
        default:           break
        }
        state.preferredDetailTab = nil
    }

    // MARK: - Rail

    /// Кадр галереи снимается в borderless-окне, у которого кнопок нет вовсе:
    /// `SceneWindowChrome` нечего двигать в слот, и слот остаётся пустым. Диски
    /// рисуются только там, где нажимать всё равно не на что; в отгружаемом
    /// окне — настоящие кнопки. Условие стоит здесь, а не в списке аргументов
    /// `PropellerSidebar`: `#if` между аргументами вызова Swift не разбирает.
    private var railTrafficLights: SidebarTrafficLights {
        #if GALLERY
        return GalleryFixture.isActive ? .drawn : .system
        #else
        return .system
        #endif
    }

    private var sidebar: some View {
        PropellerSidebar(
            model: SidebarPresenter.model(state: state, store: recordingStore),
            trafficLights: railTrafficLights,
            onNav: performNav,
            onSelectMeeting: { id in
                guard let entry = recordingStore.recordings.first(where: { $0.id == id }) else { return }
                state.selectRecording(entry)
            },
            onDeleteMeeting: { id in
                guard let entry = recordingStore.recordings.first(where: { $0.id == id }) else { return }
                // Удалить встречу, которая пишется, — единственное удаление в
                // приложении, которое ⌘Z не вернёт: аудио ещё не дописано, и
                // возвращать будет нечего. Поэтому спрашиваем — здесь, а не в
                // `AppState`: вопрос задаёт тот, у кого есть окно.
                if isBeingRecorded(entry) {
                    discardConfirmation = entry
                } else {
                    state.removeRecording(entry, undoManager: undoManager)
                }
            },
            onRestoreMeeting: nil,
            onCopySummary: { id in
                guard let entry = recordingStore.recordings.first(where: { $0.id == id }) else { return }
                copySummary(entry)
            },
            onShareMeeting: { id in
                guard let entry = recordingStore.recordings.first(where: { $0.id == id }) else { return }
                shareMeetingNearCursor(entry)
            },
            onRevealMeeting: { id in
                guard let entry = recordingStore.recordings.first(where: { $0.id == id }) else { return }
                revealInFinder(entry)
            },
            dissolvingMeetingID: state.dissolvingMeetingID,
            onDissolveFinished: { state.finishDissolvingDeletion() },
            // No toggle: the window draws the only one there is (`windowChrome`).
            onToggle: nil,
            onSearch: {
                showSearchPalette = true
                Analytics.signal("Search.opened")
            },
            onPromptAction: { id in
                // The id comes back so the window is not guessing which question
                // it just answered — two of the three steps wear a button.
                switch SetupPrompt(rawValue: id) {
                case .calendar: state.connectCalendarFromRail()
                case .claude:   state.connectClaudeFromRail()
                default:        break
                }
            },
            onPromptSubmit: { id, value in
                guard SetupPrompt(rawValue: id) == .name else { return }
                state.setOwnerNameFromRail(value)
            }
        )
    }

    // MARK: - ⌥Tab

    /// Only with the rail away. With the rail up the list is already on screen and
    /// a plate repeating it over the window reads as a second list rather than as
    /// the same one — the panel exists because the rail cannot be seen, not because
    /// the walk needs a stage.
    ///
    /// Nothing under it is clickable: the gesture that called it is the one that
    /// dismisses it, and a panel you can click but not scroll would promise the
    /// wrong thing.
    private var switcherPanel: some View {
        ZStack {
            if let walk = switching.walk, switching.showsPanel, !sidebarVisible {
                MeetingSwitcherPanel(
                    rows: SidebarPresenter.switcherRows(state: state, store: recordingStore),
                    currentID: walk.currentID,
                    anchorID: walk.anchorID
                )
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        // On the presence of the panel, not on the walk: a step inside it is
        // animated by the panel, and animating both would run two clocks on one
        // movement.
        .animation(.easeOut(duration: Tokens.Pane.Switcher.fade), value: switching.showsPanel)
    }

    /// Колонки окна — рельс и панель. Отдельным свойством, потому что теперь у
    /// окна два вида, и `body` выбирает между ними.
    private var columns: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar
                    // Единственный `move` в приложении, и он остаётся: рельс
                    // уходит за собственный край окна, а не разъезжается с
                    // соседями. Уезжающая строка толкает то, что рядом с ней,
                    // — уезжающая панель освобождает место, которое занимала.
                    //
                    // С «уменьшить движение» — гаснет: 300 pt, идущие сбоку
                    // через всё окно, это ровно тот размах, ради которого
                    // настройку включают.
                    .transition(reduceMotion ? .opacity : .move(edge: .leading))
            }
            contentPane
        }
        .animation(.easeOut(duration: Tokens.Motion.sidebarToggle), value: sidebarVisible)
        // Переключатель рельса живёт здесь, а не на всём окне, потому что он
        // принадлежит колонкам: на экране пустого архива скрывать нечего, и
        // кнопка рядом со светофором обещала бы список, которого ещё нет. Внутри
        // колонок он и уходит вместе с ними — вынесенный наружу, он выскакивал
        // поверх ещё не погасшего приглашения.
        .overlay(alignment: .topLeading) { windowChrome }
    }

    /// Пуст ли архив настолько, что показывать нечего.
    ///
    /// Тот же фильтр, которым живёт рельс (`hasSomethingToShow`), а не
    /// `recordings.isEmpty`: встреча без звука и без текста в списке не
    /// показывается, и окно, которое считало бы её, встретило бы человека
    /// пустым рельсом рядом с пустой панелью — ровно тем, ради чего этот экран
    /// и заведён.
    ///
    /// Идущая запись снимает экран немедленно, ещё до того, как её строка
    /// доедет до индекса: она уже есть, и приглашать записать первую встречу
    /// посреди записи — враньё.
    ///
    /// Настройки снимают его тоже, и это не мелочь: они живут маршрутом панели
    /// (`PaneRoute.settings`), а не окном, — значит экран, занявший окно
    /// целиком, съел бы ⌘, вместе с меню-баром. Пустой архив — не причина
    /// лишиться настроек; наоборот, это состояние, из которого в них идут за
    /// автозапуском и папками.
    private var showsFirstRun: Bool {
        state.paneRoute == .meeting
            && !state.isRecording
            && !recordingStore.recordings.contains(where: \.hasSomethingToShow)
    }

    /// Кнопка пустого экрана. Делает ровно то же, что строка «Новая запись» в
    /// рельсе, включая случай отнятого микрофона: одно поведение на два входа,
    /// потому что разъехавшись они разъедутся молча.
    private func startFirstRecording() {
        performNav(
            (state.micAccessDenied
                ? SidebarPresenter.NavAction.micAccess
                : .record).rawValue
        )
    }

    private func performNav(_ id: String) {
        switch SidebarPresenter.NavAction(rawValue: id) {
        case .record:
            // Stop lives in the recording pane (and ⌘.). This row only starts.
            guard !state.isRecording else { return }
            state.startRecording()
        case .settings:
            state.openSettings()
        case .feedback:
            NSWorkspace.shared.open(Self.issuesURL)
        case .micAccess:
            state.openMicrophoneSettings()
        case nil:
            break
        }
    }

    /// Where «Сообщить о проблеме» goes. Same repository the updater pulls its
    /// appcast from (`build.sh`, `SU_FEED_URL`).
    private static let issuesURL = URL(string: "https://github.com/levalovushka/propeller/issues/new")!

    // MARK: - Content pane

    private var contentPane: some View {
        // Смена того, про кого панель, — одно событие, а не три. Уходит всё, что
        // про встречу: её заголовок, её колонка, её заметки. Раньше уезжала одна
        // левая колонка (по своему ключу «что показано»), а заголовок и заметки
        // подменялись в тот же кадр — и переход читался как «одно не успело уйти,
        // а второе уже здесь».
        //
        // По очереди, а не крест-накрест: сначала пусто, потом новое. Два текста,
        // проступающие друг сквозь друга, и есть то самое мигание.
        ZStack(alignment: .top) {
            paneSubjectContent
                .id(paneSubject)
                .transition(
                    .asymmetric(
                        insertion: .opacity.animation(
                            .easeOut(duration: Tokens.Pane.meetingSwapIn)
                                .delay(Tokens.Pane.meetingSwapOut)
                        ),
                        removal: .opacity.animation(
                            .easeOut(duration: Tokens.Pane.meetingSwapOut)
                        )
                    )
                )
        }
        // Not while a meeting is burning. Deleting the open one moves the selection
        // on purpose *without* an animation (`removeRecording` wraps that call in a
        // transaction that disables them), because during a deletion the rail is
        // already the thing in motion and a second show beside it reads as the
        // layout flinching before it slides. Keying the swap on `paneSubject` put
        // that animation back — which is why the jerk came back at the *start* of a
        // deletion, and only when the meeting being deleted was the open one.
        .animation(state.dissolvingMeetingID == nil ? .default : nil, value: paneSubject)
        // Свечения по краям окна во время записи больше нет. Оно светилось
        // уровнями двух дорожек — то есть отвечало на вопрос «работает ли
        // захват» тем, что красило края экрана всю встречу. На этот вопрос
        // теперь отвечает сам транскрипт: если реплики появляются, звук идёт.
        // Nothing floats over the pane. What the app has to say about a meeting
        // is said by that meeting's row.
        // The rail carries its own 300; the pane only has to stay readable.
        .frame(minWidth: Tokens.Window.contentPaneMinWidth, minHeight: 560)
    }

    private var paneSubjectContent: some View {
        VStack(spacing: 0) {
            topBar
                .zIndex(2)
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Про кого панель — не «что в ней показано». Переключение колонки
    /// (Расшифровка / Саммари) этого не меняет: там своя, более медленная замена,
    /// потому что там меняется смысл, а здесь — только адресат, и его уже назвал
    /// рельс. Идущая запись и та же встреча после стопа — разные предметы: между
    /// ними в панели не остаётся ничего общего.
    private var paneSubject: String {
        if state.paneRoute == .settings { return "settings" }
        guard let entry = state.selectedRecording else { return "empty" }
        return isBeingRecorded(entry) ? "recording-\(entry.id)" : "meeting-\(entry.id)"
    }

    // MARK: - Top bar — Figma 31:4625 (48 tall, same row as the rail's header)

    /// With the rail up, the traffic lights live in *its* header and this bar
    /// starts at the pane's own edge. With the rail away (Figma `nosidebar`,
    /// 31:5083) the lights and the re-open toggle move here instead — the window
    /// buttons never move, so something has to be beside them.
    /// With a meeting open the pane's own header takes this row — Figma
    /// 31:4625. The list has no such header in the comps, so it keeps the
    /// navigation bar it already had.
    @ViewBuilder
    private var topBar: some View {
        if state.paneRoute == .settings {
            HStack(spacing: 0) {
                if !sidebarVisible {
                    collapsedChrome
                }
                SettingsPaneHeader()
            }
            .frame(height: Tokens.Sidebar.headerHeight)
        } else if let entry = state.selectedRecording, isBeingRecorded(entry) {
            HStack(spacing: 0) {
                if !sidebarVisible {
                    collapsedChrome
                }
                RecordingPaneHeader(
                    meetingID: entry.id,
                    title: entry.title,
                    elapsed: state.elapsedString,
                    isPaused: state.isRecordingPaused,
                    onRename: { id, newTitle in state.renameRecording(id: id, to: newTitle) },
                    onPause: {
                        if state.isRecordingPaused {
                            state.resumeRecording()
                        } else {
                            state.pauseRecording()
                        }
                    },
                    onStop: { state.stopRecording() }
                )
            }
            .frame(height: Tokens.Sidebar.headerHeight)
        } else if let entry = state.selectedRecording {
            HStack(spacing: 0) {
                if !sidebarVisible {
                    collapsedChrome
                }
                MeetingPaneHeader(
                    meetingID: entry.id,
                    title: entry.title,
                    // By id, not by `entry`: the rename that arrives when you
                    // switch meetings mid-edit belongs to the meeting it was
                    // typed into, which by then is no longer the selected one.
                    onRename: { id, newTitle in state.renameRecording(id: id, to: newTitle) },
                    share: .init("Поделиться") { showShareSheet = true }
                ) {
                    Picker("Показать", selection: $paneMode) {
                        ForEach(MeetingPaneMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Divider()
                    Button("Показать в Finder") { revealInFinder(entry) }
                    Button("Удалить аудио") { state.deleteAudioFile(entry) }
                        .disabled(!entry.audioFileExists)
                    Divider()
                    Button("Удалить встречу", role: .destructive) {
                        state.removeRecording(entry, undoManager: undoManager)
                    }
                }
            }
            .frame(height: Tokens.Sidebar.headerHeight)
            .overlay(alignment: .trailing) {
                ShareAnchor(isPresented: $showShareSheet) { shareItems(for: entry) }
                    .frame(width: 1, height: 1)
                    .padding(.trailing, Tokens.Pane.headerActionsPadding)
            }
        } else {
            listTopBar
        }
    }

    /// Summary as plain text when there is one — so system Copy lands in
    /// Telegram as readable prose, not as a `.md` filename. File URL only when
    /// there is no summary to share.
    private func shareItems(for entry: RecordingEntry) -> [Any] {
        if let text = plainSummary(for: entry), !text.isEmpty {
            return [text]
        }
        if let url = markdownURL(for: entry) { return [url] }
        let text = Self.recapMarkdown(for: entry)
        return text.isEmpty ? [] : [text]
    }

    /// Summary stripped of markdown — clipboard / share payload for chat apps.
    private func plainSummary(for entry: RecordingEntry) -> String? {
        let markdown = Self.recapMarkdown(for: entry)
        guard !markdown.isEmpty else { return nil }
        let plain = SummaryDocument.parse(markdown: markdown).plainText
        return plain.isEmpty ? nil : plain
    }

    /// What a pane header leaves clear for the traffic lights and the toggle when
    /// the rail is away. Space only — the toggle itself is `windowChrome`, drawn
    /// over both columns at one fixed place.
    private var collapsedChrome: some View {
        Color.clear
            .frame(width: Tokens.Window.chromeReserve, height: Tokens.Sidebar.toggleSide)
    }

    /// The one rail toggle. Not in the rail and not in the pane's header: it is the
    /// window's, so the rail slides out from under it and the button neither moves
    /// nor loses the hover it is under at the moment you press it.
    private var windowChrome: some View {
        SidebarChromeButton(
            symbol: "sidebar.left",
            help: sidebarVisible ? "Скрыть список" : "Показать список"
        ) {
            sidebarVisible.toggle()
        }
        .padding(.leading, Tokens.Window.chromeToggleLeading)
        .padding(.top, Tokens.Window.chromeToggleTop)
    }

    private var listTopBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if !sidebarVisible {
                    collapsedChrome
                }

                HStack(spacing: 0) {
                    IconButton(
                        systemName: "chevron.left",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .regular,
                        enabled: canGoBack
                    ) { goBack() }
                    .help("Назад")

                    IconButton(
                        systemName: "chevron.right",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .regular,
                        enabled: canGoForward
                    ) { goForward() }
                    .help("Вперёд")

                    IconButton(
                        systemName: "magnifyingglass",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .regular
                    ) {
                        showSearchPalette = true
                        Analytics.signal("Search.opened")
                    }
                    .help("Поиск (⌘K)")
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 14) {
                if let status = topStatusText {
                    Text(status)
                        .typo(Tokens.Typography.Label.smRegular)
                        .foregroundStyle(Tokens.Ink.tertiary)
                        .lineLimit(1)
                        .frame(height: 32)
                }

                IconButton(
                    systemName: "gearshape.fill",
                    prominence: .minimal,
                    iconSize: 14,
                    weight: .regular
                ) { state.openSettings() }
                .help("Настройки")
            }
        }
        .frame(height: 32)
        .padding(.horizontal, Tokens.Window.chromePadding)
        .frame(height: Tokens.Sidebar.headerHeight, alignment: .center)
    }

    // MARK: - History navigation

    private func goBack() {
        guard canGoBack else { return }
        navIndex -= 1
        applyNav()
    }

    private func goForward() {
        guard canGoForward else { return }
        navIndex += 1
        applyNav()
    }

    private func applyNav() {
        suppressNavRecord = true
        defer { suppressNavRecord = false }
        guard navStack.indices.contains(navIndex) else { return }
        // Шаг истории на удалённую встречу ничего не делает: снимать выбор
        // здесь значило бы вернуть то самое состояние без выбранной встречи, но
        // теперь ещё и по кнопке «Назад».
        guard let entry = recordingStore.recordings
            .first(where: { $0.id == navStack[navIndex] }) else { return }
        state.selectRecording(entry)
    }

    private func recordNav(to id: String?) {
        guard !suppressNavRecord, let id else { return }
        if navStack.indices.contains(navIndex), navStack[navIndex] == id { return }
        if navIndex + 1 < navStack.count {
            navStack = Array(navStack.prefix(navIndex + 1))
        }
        navStack.append(id)
        navIndex = navStack.count - 1
    }

    private var topStatusText: String? {
        if let frac = state.ollamaSetupProgress {
            let msg = state.ollamaSetupMessage.isEmpty
                ? "Скачиваем модель саммари…"
                : state.ollamaSetupMessage
            if msg.contains("%") { return msg }
            return "\(msg) \(Int(frac * 100))%"
        }
        if let frac = state.modelDownloadProgress {
            return "Загрузка модели… \(Int(frac * 100))%"
        }
        return state.activity.message
    }

    // MARK: - Main area

    /// The pane's two columns — Figma 31:4644.
    ///
    /// There is no meetings list here any more: the rail is the list, and the
    /// newest meeting is chosen on launch. The only reason this can be empty is
    /// an archive with nothing in it yet.
    @ViewBuilder
    private var mainArea: some View {
        if state.paneRoute == .settings {
            // Настройки занимают всю панель: заметок у них нет, делить не с чем.
            // Ширина — саммарийная, её держит `SettingsColumn`.
            SettingsPane(state: state)
                .frame(maxWidth: .infinity)
        } else if let entry = state.selectedRecording, isBeingRecorded(entry) {
            RecordingPaneView(
                live: state.live,
                entry: entry,
                isPaused: state.isRecordingPaused,
                ownerName: Preferences.shared.ownerName,
                transcriptNotes: transcriptNotes(for: entry),
                composer: .init(
                    placeholder: "Начните писать заметку",
                    text: $draftNote
                ) { commitNote(for: entry) }
            )
            .frame(maxWidth: .infinity)
        } else if let entry = state.selectedRecording {
            let document = summaryDocument(for: entry)
            // Считаем один раз: внутри — полный `JSONDecoder().decode` по
            // сегментам встречи, второй вызов в этом же выражении дублировал
            // разбор ради того же результата.
            let turns = transcriptTurns(for: entry)
            MeetingPaneBody(
                mode: paneMode,
                summary: document,
                turns: turns,
                transcriptNotes: transcriptNotes(for: entry),
                // Что стоит на месте саммари, пока саммари нет, — решает
                // `SummaryColumnContent`, и это правило, а не отрисовка.
                summaryContent: SummaryColumnContent.decide(
                    hasSummary: !document.isEmpty,
                    hasTranscript: !turns.isEmpty,
                    rest: state.rest(of: entry)
                ),
                transcriptSource: liveTurnsStandIn(for: entry) ? .live : .stored,
                transcriptDisclosure: entry.depthDisclosure,
                summaryController: summaryEditing,
                // No file behind it, no caret: a summary that cannot be saved
                // must not look like one you can type into.
                onSummaryChange: AppState.resolvedRecapURL(for: entry) == nil
                    ? nil
                    : { document in scheduleSummarySave(document, for: entry) },
                onSummaryRewrite: { rewrite, fragment in
                    runSummaryRewrite(rewrite, over: fragment, of: entry)
                }
            )
            .frame(maxWidth: .infinity)
        } else {
            // Недостижимо, и поэтому пусто. Пока в архиве есть хоть одна
            // встреча, какая-то выбрана: историю больше нельзя отмотать в
            // «ничего», а `selectNewestIfNothingChosen` чинит любой другой
            // способ остаться без выбора. Пустой архив сюда не доходит — там
            // окно занимает `FirstRunView`, ещё до колонок.
            //
            // Здесь стояло «Пока нет встреч», и это была единственная строка в
            // приложении, которая врала прямым текстом: её видели, отмотав
            // «Назад» с полным рельсом встреч рядом.
            Color.clear
        }
    }

    // MARK: - Pane content

    /// Та ли это встреча, которая сейчас пишется.
    ///
    /// Не `state.isRecording`: пока идёт запись, в рельсе можно выбрать любую
    /// другую встречу и читать её — и панель обязана показывать выбранную, а не
    /// ту, которая пишется. Раньше запись была режимом всего окна, и уйти из
    /// неё было некуда.
    private func isBeingRecorded(_ entry: RecordingEntry) -> Bool {
        state.isRecording && entry.id == state.activeRecordingID
    }

    /// Diarised segments when they exist, the plain transcript when they do not
    /// — same fallback the detail view has always used.
    /// Стоит ли сейчас в колонке живой текст вместо готовой расшифровки.
    ///
    /// Встреча только что кончилась, проход по файлу ещё идёт — а живой текст
    /// уже есть, и это всё, что про неё известно. Стирать его в момент нажатия
    /// «стоп» значило бы отнять у человека ровно то, что он читал секунду
    /// назад; настоящая расшифровка займёт это место, когда будет, — и займёт
    /// заменой, а не подменой (`MeetingPaneBody.TranscriptSource`).
    private func liveTurnsStandIn(for entry: RecordingEntry) -> Bool {
        entry.transcript == nil
            && state.live.recordingID == entry.id
            && !state.live.transcript.isEmpty
    }

    private func transcriptTurns(for entry: RecordingEntry) -> [MeetingTranscriptColumn.Turn] {
        if liveTurnsStandIn(for: entry) {
            return liveTurns(state.live.transcript)
        }
        let turns: [TranscriptPresentation.Turn]
        if let json = entry.mergedSegmentsJSON,
           let data = json.data(using: .utf8),
           let segments = try? JSONDecoder().decode([PersistedSegment].self, from: data),
           !segments.isEmpty {
            turns = TranscriptPresentation.turns(from: segments)
        } else if let transcript = entry.transcript, !transcript.isEmpty {
            turns = TranscriptPresentation.turns(parsing: transcript, duration: entry.duration)
        } else if let segments = storedLiveSegments(for: entry) {
            // Черновик, снятый при остановке. Последний в очереди намеренно:
            // это самое неточное, что есть у встречи, и уступает всему
            // настоящему. Зато переживает перезапуск — а до него встреча,
            // ждущая расшифровки, после перезапуска не могла показать ни слова.
            turns = TranscriptPresentation.turns(from: segments)
        } else {
            turns = []
        }
        return turns.enumerated().map { index, turn in
            MeetingTranscriptColumn.Turn(
                id: "t\(index)",
                speaker: turn.speaker,
                time: turn.timestamp,
                text: turn.phrases.map(\.text).joined(separator: " "),
                startSeconds: turn.startSeconds
            )
        }
    }

    /// Живые реплики, показанные как обычный транскрипт: те же имена дорожек,
    /// что поставит финальный проход, — чтобы текст не переименовывал говорящих
    /// в момент, когда его заменят.
    /// Черновик живого текста с диска, если он ещё нужен.
    private func storedLiveSegments(for entry: RecordingEntry) -> [PersistedSegment]? {
        guard let json = entry.liveSegmentsJSON,
              let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([PersistedSegment].self, from: data),
              !segments.isEmpty else { return nil }
        return segments
    }

    private func liveTurns(_ live: LiveTranscript) -> [MeetingTranscriptColumn.Turn] {
        live.turns.map { turn in
            MeetingTranscriptColumn.Turn(
                id: turn.id,
                speaker: SourceAwareSpeaker.stemsOnly(
                    source: turn.channel == .owner ? .microphone : .system,
                    ownerName: Preferences.shared.ownerName
                ),
                time: turn.timestamp,
                text: turn.text,
                startSeconds: turn.startSeconds
            )
        }
    }

    /// То, что человек написал во время встречи, — для ленты расшифровки.
    ///
    /// Время и текст берутся через `MeetingNotes.placed`: у заметки из старого
    /// архива секунда лежит строкой в начале её же текста, и читать её надо там,
    /// не переписывая архив. Заметка без секунды сюда тоже попадает — и
    /// `NotePlacement` её отбрасывает, потому что решение «в ленту или нет»
    /// принимается в одном месте, а не двумя фильтрами подряд.
    private func transcriptNotes(for entry: RecordingEntry) -> [TranscriptNote] {
        MeetingNotes.resolved(items: entry.noteItems, blob: entry.notes).map { note in
            let placed = MeetingNotes.placed(note)
            return TranscriptNote(
                id: note.id,
                time: placed.seconds.map(Timecode.text) ?? "",
                text: placed.text,
                seconds: placed.seconds
            )
        }
    }

    /// The recap markdown on disk, or empty when the model has not run yet.
    /// `resolvedRecapURL`, never `recapURL`.
    ///
    /// The filename embeds a slug of the title, and the pipeline auto-titles a
    /// meeting *after* writing its recap — so the expected name stops existing
    /// the moment a meeting is named. That is what made the summary vanish from
    /// the newest meeting after the redesign: the file was there all along, the
    /// lookup was asking for the name it used to have.
    private static func recapMarkdown(for entry: RecordingEntry) -> String {
        guard let url = AppState.resolvedRecapURL(for: entry),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    // MARK: - The summary, read and written

    /// Read the recap off disk into the document the pane draws.
    ///
    /// Only when it is a *different* summary than the one already loaded: this
    /// runs on every pipeline heartbeat, and reloading the same text would drop
    /// the caret out of the sentence being typed once a second.
    /// Саммари этой встречи — из буфера правок, если он про неё, иначе прямо с
    /// диска.
    ///
    /// Без второй половины панель успевает нарисовать один кадр новой встречи со
    /// старым буфером: `loadSummary` живёт в `onChange`, а тот приходит после того,
    /// как тело уже посчитано с новым `selectedRecordingID`. Кадр этот теперь
    /// невидим — он попадает внутрь замены, — но колонка успевала *решить* по нему,
    /// что саммари нет, и на смене буфера играла свою вторую замену. Из-за неё
    /// левая колонка приезжала на две десятых позже заголовка и заметок, то есть
    /// ровно тем рассогласованием, которое всё это чинит.
    private func summaryDocument(for entry: RecordingEntry) -> SummaryDocument {
        if summaryOf == entry.id { return summary }
        return SummaryDocument.parse(markdown: Self.recapMarkdown(for: entry))
    }

    private func loadSummary() {
        guard let entry = state.selectedRecording else {
            summary = .empty
            summaryOf = nil
            return
        }
        let sameMeeting = summaryOf == entry.id
        // Дешёвая половина гарда — до чтения файла с диска: та же встреча с
        // уже непустым саммари не читает и не парсит markdown на каждый удар
        // пульса пайплайна. `A || (B && C) == (A || B) && (A || C)`, так что
        // вынести можно без изменения итогового условия.
        guard !sameMeeting || summary.isEmpty else { return }
        let document = SummaryDocument.parse(markdown: Self.recapMarkdown(for: entry))
        guard !sameMeeting || !document.isEmpty else { return }
        // The reveal means «модель это написала», so it plays here and only
        // here: the meeting was already open, it had no summary, and now it
        // does. Opening a meeting that has had one for a week is not an
        // arrival, and the reveal used to play for that too.
        if sameMeeting, summary.isEmpty, !document.isEmpty {
            summaryEditing.armColumnAppear(animated: !isPosedForAScreenshot)
        }
        summaryOf = entry.id
        summary = document
    }

    /// Hold the edit, then write it when typing stops.
    ///
    /// Not on every keystroke: the file is on the user's disk, possibly inside
    /// an Obsidian vault with a watcher on it, and a write per character is a
    /// re-index per character. 0.8 s is the same pause the notes have used since
    /// they were a single blob.
    private func scheduleSummarySave(_ document: SummaryDocument, for entry: RecordingEntry) {
        summary = document
        summaryOf = entry.id
        summarySave?.cancel()
        let markdown = document.markdown
        let work = DispatchWorkItem {
            state.saveSummary(markdown, for: entry)
            // Разряжается сам: без этого `summarySave` продолжает указывать на
            // уже выполненный элемент до следующей правки, и любой более
            // поздний `flushSummarySave()` находит его «ожидающим» и пишет тот
            // же markdown повторно — вслепую, в чужую по времени встречу.
            summarySave = nil
        }
        summarySave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.summarySaveDelay, execute: work)
    }

    private static let summarySaveDelay: TimeInterval = 0.8

    /// Write a pending edit right now — switching meetings, closing the window.
    ///
    /// Сначала `perform()`, потом `cancel()`: наоборот `perform()` у уже
    /// отменённого `DispatchWorkItem` — no-op (libdispatch смотрит на флаг
    /// отмены и выходит), и правка молча терялась. Отмена после — чтобы уже
    /// поставленный `asyncAfter` не выполнил тот же блок второй раз. Сам блок
    /// после сохранения обнуляет `summarySave`, поэтому если таймер уже
    /// сработал сам, `summarySave` тут `nil` и флаш ничего не делает — не
    /// перезаписывает файл встречи, которая уже не открыта.
    private func flushSummarySave() {
        guard let work = summarySave else { return }
        summarySave = nil
        work.perform()
        work.cancel()
    }

    /// Ask the model to say the selected fragment differently, and put its
    /// answer where the selection was.
    ///
    /// While it thinks: the wash and the bar are gone, the fragment shimmers.
    /// If the model comes back empty or with the same words, the text stays as
    /// it was — there is no failure state here to report.
    private func runSummaryRewrite(
        _ rewrite: SummaryRewrite, over fragment: String, of entry: RecordingEntry
    ) {
        guard !summaryEditing.isRewriting else { return }
        // `rewriteTarget` is pinned by the bar before this runs — the click has
        // usually already cleared `selection` by the time we get here.
        summaryEditing.isRewriting = true
        // «Подробнее» adds detail, and detail has to come from what was said.
        // «Короче» gets nothing extra: handed the meeting while cutting, a model
        // brings things back in.
        let transcript = rewrite.needsTranscript ? entry.transcript : nil
        Task { @MainActor in
            guard let rewritten = await state.rewriteSummaryFragment(
                fragment, instruction: rewrite.instruction, transcript: transcript
            ) else {
                summaryEditing.cancelRewrite()
                return
            }
            await summaryEditing.applyRewrite(rewritten)
        }
    }

    /// True only in the state-gallery build. There is nothing to freeze in the
    /// app: the reveal is the summary arriving, and it is meant to be seen.
    private var isPosedForAScreenshot: Bool {
        #if GALLERY
        return state.galleryFrozen
        #else
        return false
        #endif
    }

    /// «Саммари — правка» on the state board: text selected, the action bar
    /// under it. Posed rather than performed — the exporter draws the window
    /// offscreen, where nothing is first responder and no caret exists.
    private func poseSummarySelectionIfAsked() {
        #if GALLERY
        guard state.galleryEditingRecap else { return }
        let rewriting = state.galleryRewritingSummary
        // A bullet, because that is most of a summary — and after the editor has
        // its text, which it gets during the render pass this call follows.
        DispatchQueue.main.async {
            summaryEditing.poseSelection(ofFirst: .bullet)
            summaryEditing.isRewriting = rewriting
        }
        #endif
    }

    private func commitNote(for entry: RecordingEntry) {
        let text = draftNote
        draftNote = ""
        // Тот же вопрос, что и у чёлки: идёт ли эта встреча прямо сейчас.
        // Поле есть только у идущей записи, но спрашивать всё равно надо: у
        // встречи, остановленной секунду назад, поле ещё на экране.
        recordingStore.appendNote(
            id: entry.id,
            text: text,
            offsetSeconds: state.noteOffset(for: entry.id)
        )
    }

    /// The old meetings list — the pre-redesign screen — used to live here:
    /// a title block, an «Скоро» section fed by the calendar, and hand-built rows
    /// with their own hover chrome. Nothing referenced it after the rail took
    /// over, so it sat as dead code holding the only interface a removed feature
    /// had. Deleted 2026-08-04 together with Upcoming; the rail is the list.

    private func revealInFinder(_ entry: RecordingEntry) {
        if let audioURL = recordingStore.audioURL(for: entry) {
            NSWorkspace.shared.activateFileViewerSelecting([audioURL])
        } else if let mdURL = markdownURL(for: entry) {
            NSWorkspace.shared.activateFileViewerSelecting([mdURL])
        }
    }

    private func copySummary(_ entry: RecordingEntry) {
        guard let text = plainSummary(for: entry) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Share sheet for a rail row — hangs off the cursor, not the pane header.
    /// The header button keeps its own `ShareAnchor`; right-click has no view
    /// of its own, so the window's content view and the mouse location stand in.
    private func shareMeetingNearCursor(_ entry: RecordingEntry) {
        let items = shareItems(for: entry)
        guard !items.isEmpty,
              let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }
        let location = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let picker = NSSharingServicePicker(items: items)
        picker.show(
            relativeTo: NSRect(origin: location, size: .zero),
            of: contentView,
            preferredEdge: .minY
        )
    }

    private func markdownURL(for entry: RecordingEntry) -> URL? {
        let slug = MeetingMarkdown.slugify(entry.title.isEmpty ? entry.id : entry.title)
        let filename = "\(entry.id)-\(slug).md"
        let url = URL(fileURLWithPath: Preferences.shared.meetingsPath)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func isProcessing(_ entry: RecordingEntry) -> Bool {
        // Never key off idle stages like `.recorded` / `.transcribedRaw` — that
        // made every unfinished meeting spin forever.
        if entry.status == .recording { return true }
        return state.activity.concerns(entry.id)
    }

}

/// «Настройки» откуда угодно снаружи окна — меню-бар, ⌘,.
///
/// Раньше это была попытка попасть в сцену `Settings` через приватный селектор,
/// и она молча ничего не делала, пока приложение было `.accessory`. Теперь
/// открывать нечего: настройки — состояние панели, значит надо показать окно и
/// поставить панель на них.
enum SettingsOpener {
    @MainActor
    static func open() {
        AppWindowRegistry.showMain(centered: true)
        AppStateRegistry.shared?.openSettings()
    }
}
