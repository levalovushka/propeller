import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Meetings home — Figma 640:1859.
struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject var recordingStore: RecordingStore
    @Environment(\.undoManager) private var undoManager
    @State private var showSearchPalette = false
    @ObservedObject private var calendar = CalendarService.shared

    /// Browser-style history: `nil` = meetings list, otherwise a recording id.
    /// Figma 640:1859 — chevron.left / chevron.right next to traffic lights.
    @State private var navStack: [String?] = [nil]
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
        navIndex > 0 || state.selectedRecordingID != nil
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
    /// Raised when the collapsed notes button is pressed, lowered by the
    /// composer once it has the caret — so widening the window lands you in a
    /// new note rather than merely next to one.
    @State private var focusNoteComposer = false
    /// Left column width held while the window grows for the notes, so the
    /// summary does not stretch and snap back. Cleared when the ordinary split
    /// would keep the same width.
    @State private var notesRevealLeft: CGFloat?
    /// Raised by «Поделиться»; the anchor lowers it once the sheet is up.
    @State private var showShareSheet = false
    /// Записываемая встреча, которую попросили удалить. Спрашиваем один раз —
    /// это удаление необратимо, в отличие от всех остальных.
    @State private var discardConfirmation: RecordingEntry?

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
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar
                    .transition(.move(edge: .leading))
            }
            contentPane
        }
        .animation(.easeOut(duration: 0.18), value: sidebarVisible)
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
        }
        .onChange(of: recordingStore.recordings.count) { _, _ in
            // The first meeting to arrive in an empty archive opens itself; so
            // does the one that just finished recording.
            selectNewestIfNothingChosen()
        }
        .onDisappear {
            flushSummarySave()
            state.isWindowOpen = false
            NSApp.setActivationPolicy(.accessory)
        }
        .onChange(of: state.selectedRecordingID) { _, newID in
            // Before the switch, not after: the pending write belongs to the
            // meeting that was open, and a moment later there is no way to
            // learn which one that was.
            flushSummarySave()
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

    private var sidebar: some View {
        PropellerSidebar(
            model: SidebarPresenter.model(state: state, store: recordingStore),
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
            onToggle: { sidebarVisible = false },
            onSearch: {
                showSearchPalette = true
                Analytics.signal("Search.opened")
            },
            onPromptAction: { id in
                // Only the calendar step has a button; the id comes back so the
                // window is not guessing which question it just answered.
                guard SetupPrompt(rawValue: id) == .calendar else { return }
                state.connectCalendarFromRail()
            },
            onPromptSubmit: { id, value in
                guard SetupPrompt(rawValue: id) == .name else { return }
                state.setOwnerNameFromRail(value)
            }
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
        VStack(spacing: 0) {
            topBar
                .zIndex(2)
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Свечения по краям окна во время записи больше нет. Оно светилось
        // уровнями двух дорожек — то есть отвечало на вопрос «работает ли
        // захват» тем, что красило края экрана всю встречу. На этот вопрос
        // теперь отвечает сам транскрипт: если реплики появляются, звук идёт.
        // Nothing floats over the pane. What the app has to say about a meeting
        // is said by that meeting's row.
        // The rail carries its own 300; the pane only has to stay readable.
        .frame(minWidth: Tokens.Window.contentPaneMinWidth, minHeight: 560)
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

    /// Traffic-light slot and the re-open toggle, for when the rail is away.
    private var collapsedChrome: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: Tokens.Sidebar.trafficLightSlotWidth, height: 32)
            SidebarChromeButton(symbol: "sidebar.left", help: "Показать список") {
                sidebarVisible = true
            }
        }
        .padding(.leading, Tokens.Window.chromePadding)
    }

    private var listTopBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if !sidebarVisible {
                    Color.clear
                        .frame(width: Tokens.Sidebar.trafficLightSlotWidth, height: 32)

                    SidebarChromeButton(symbol: "sidebar.left", help: "Показать список") {
                        sidebarVisible = true
                    }
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
                        .typo(Tokens.Typography.Label.smMedium)
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
        if navIndex > 0 {
            navIndex -= 1
            applyNav()
            return
        }
        // Detail open but history empty (e.g. cold open) — still leave to list.
        suppressNavRecord = true
        state.player.stop()
        state.selectedRecordingID = nil
        navStack = [nil]
        navIndex = 0
        suppressNavRecord = false
    }

    private func goForward() {
        guard canGoForward else { return }
        navIndex += 1
        applyNav()
    }

    private func applyNav() {
        suppressNavRecord = true
        defer { suppressNavRecord = false }
        let dest = navStack[navIndex]
        if let id = dest,
           let entry = recordingStore.recordings.first(where: { $0.id == id }) {
            state.selectRecording(entry)
        } else {
            state.player.stop()
            state.selectedRecordingID = nil
        }
    }

    private func recordNav(to id: String?) {
        guard !suppressNavRecord else { return }
        guard navStack.indices.contains(navIndex) else { return }
        if navStack[navIndex] == id { return }
        // Keep list under the first recording so Back always has somewhere to go.
        if id != nil, navStack == [nil], navIndex == 0 {
            navStack = [nil, id]
            navIndex = 1
            return
        }
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
                notes: noteModels(for: entry),
                composer: .init(text: $draftNote) { commitNote(for: entry) },
                onRevealNotes: revealNotes,
                notesFocusRequest: $focusNoteComposer,
                pinnedLeftWidth: $notesRevealLeft
            )
            .frame(maxWidth: .infinity)
        } else if let entry = state.selectedRecording {
            MeetingPaneBody(
                mode: paneMode,
                summary: summary,
                turns: transcriptTurns(for: entry),
                notes: noteModels(for: entry),
                composer: .init(text: $draftNote) { commitNote(for: entry) },
                // Что стоит на месте саммари, пока саммари нет, — решает
                // `SummaryColumnContent`, и это правило, а не отрисовка.
                summaryContent: SummaryColumnContent.decide(
                    hasSummary: !summary.isEmpty && summaryOf == entry.id,
                    hasTranscript: !transcriptTurns(for: entry).isEmpty,
                    rest: state.rest(of: entry)
                ),
                transcriptSource: liveTurnsStandIn(for: entry) ? .live : .stored,
                transcriptDisclosure: entry.depthDisclosure,
                onRevealNotes: revealNotes,
                notesFocusRequest: $focusNoteComposer,
                pinnedLeftWidth: $notesRevealLeft,
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
            Text("Пока нет встреч")
                .typoBlock(Tokens.Pane.Typo.body)
                .foregroundStyle(Tokens.Pane.placeholder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func noteModels(for entry: RecordingEntry) -> [MeetingNote] {
        MeetingNotes.resolved(items: entry.noteItems, blob: entry.notes)
            .map { MeetingNote(id: $0.id, text: $0.text) }
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
        } else {
            turns = []
        }
        return turns.enumerated().map { index, turn in
            MeetingTranscriptColumn.Turn(
                id: "t\(index)",
                speaker: turn.speaker,
                time: turn.timestamp,
                text: turn.phrases.map(\.text).joined(separator: " ")
            )
        }
    }

    /// Живые реплики, показанные как обычный транскрипт: те же имена дорожек,
    /// что поставит финальный проход, — чтобы текст не переименовывал говорящих
    /// в момент, когда его заменят.
    private func liveTurns(_ live: LiveTranscript) -> [MeetingTranscriptColumn.Turn] {
        live.turns.map { turn in
            MeetingTranscriptColumn.Turn(
                id: turn.id,
                speaker: SourceAwareSpeaker.stemsOnly(
                    source: turn.channel == .owner ? .microphone : .system,
                    ownerName: Preferences.shared.ownerName
                ),
                time: turn.timestamp,
                text: turn.text
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
    private func loadSummary() {
        guard let entry = state.selectedRecording else {
            summary = .empty
            summaryOf = nil
            return
        }
        let document = SummaryDocument.parse(markdown: Self.recapMarkdown(for: entry))
        let sameMeeting = summaryOf == entry.id
        guard !sameMeeting || (summary.isEmpty && !document.isEmpty) else { return }
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
        let work = DispatchWorkItem { state.saveSummary(markdown, for: entry) }
        summarySave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.summarySaveDelay, execute: work)
    }

    private static let summarySaveDelay: TimeInterval = 0.8

    /// Write a pending edit right now — switching meetings, closing the window.
    private func flushSummarySave() {
        guard let work = summarySave else { return }
        summarySave = nil
        work.cancel()
        work.perform()
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

    /// The collapsed notes button was pressed. The pane cannot widen itself —
    /// its width is the window's — so the window grows to the right by the
    /// notes' width while the left column keeps the width it already had. The
    /// composer takes the caret as soon as the column exists.
    private func revealNotes() {
        focusNoteComposer = true
        let sidebar = sidebarVisible ? Tokens.Sidebar.width : 0
        let contentWidth: CGFloat
        if let window = AppWindowRegistry.mainWindow() {
            contentWidth = window.contentRect(forFrameRect: window.frame).width
        } else {
            contentWidth = sidebar + Tokens.Window.defaultPaneWidth
        }
        let pane = contentWidth - sidebar
        notesRevealLeft = max(0, pane - Tokens.Pane.notesCollapsedSide)
        AppWindowRegistry.widenMain(
            toContentWidth: WindowReveal.contentWidth(
                revealingNotesBeside: contentWidth,
                sidebar: sidebar,
                collapsedSlot: Tokens.Pane.notesCollapsedSide,
                notesWidth: Tokens.Pane.notesMaxWidth,
                minimumPane: Tokens.Pane.notesCollapseBelow
            )
        )
        // Fallback: a screen edge can clamp the grow short of the settled
        // width, so the ordinary split never matches the pin. Drop it after
        // the window animation either way — by then the pin has done its job.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            notesRevealLeft = nil
        }
    }

    private func commitNote(for entry: RecordingEntry) {
        let text = draftNote
        draftNote = ""
        recordingStore.appendNote(id: entry.id, text: text)
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
        let slug = MarkdownWriter.slugify(entry.title.isEmpty ? entry.id : entry.title)
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
