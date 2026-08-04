import SwiftUI
import AppKit
import PropellerPure
import PropellerUI

/// Meetings home — Figma 640:1859.
struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject var recordingStore: RecordingStore
    @State private var showSearchPalette = false
    @State private var hoveredRowID: String?
    /// nil = all; otherwise owner name or "Speaker N".
    @State private var speakerFilter: String?
    @ObservedObject private var calendar = CalendarService.shared

    /// Browser-style history: `nil` = meetings list, otherwise a recording id.
    /// Figma 640:1859 — chevron.left / chevron.right next to traffic lights.
    @State private var navStack: [String?] = [nil]
    @State private var navIndex: Int = 0
    @State private var suppressNavRecord = false

    /// Stub / empty takes shorter than this stay out of the feed (reqs §1).
    private static let stubDurationThreshold: TimeInterval = 5

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Back is available whenever we can leave the meeting detail (or step history).
    private var canGoBack: Bool {
        if state.isRecording { return false }
        return navIndex > 0 || state.selectedRecordingID != nil
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
            state.isWindowOpen = false
            NSApp.setActivationPolicy(.accessory)
        }
        .onChange(of: state.selectedRecordingID) { _, newID in
            recordNav(to: newID)
        }
        // The pipeline asks for a column when it finishes something («саммари
        // готово» → the summary). Nothing honoured that after the redesign: the
        // request was written and dropped, because the pane's mode is local
        // `@State` and the old detail view was the only reader.
        .onChange(of: state.preferredDetailTab) { _, _ in adoptPreferredColumn() }
        .onAppear { adoptPreferredColumn() }
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
                if state.isRecording { state.stopRecording() }
                else { state.startRecording() }
            }
            .keyboardShortcut("r", modifiers: .command)
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
        guard !state.isRecording else { return }
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
                state.removeRecording(entry)
            },
            onRestoreMeeting: { _ in state.undoDeletion() },
            onToggle: { sidebarVisible = false }
        )
    }

    private func performNav(_ id: String) {
        switch SidebarPresenter.NavAction(rawValue: id) {
        case .record:
            if state.isRecording { state.stopRecording() } else { state.startRecording() }
        case .search:
            showSearchPalette = true
            Analytics.signal("Search.opened")
        case .settings:
            // Handled by the row itself — it is a `SettingsLink`, because
            // nothing callable opens the Settings scene from an accessory app.
            break
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
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                topBar
                    .zIndex(2)
                mainArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if state.isRecording {
                recordingEdgeGlow
                    .allowsHitTesting(false)
                    .zIndex(1)
            }

        }
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
        if let entry = state.selectedRecording, !state.isRecording {
            HStack(spacing: 0) {
                if !sidebarVisible {
                    collapsedChrome
                }
                MeetingPaneHeader(
                    title: entry.title.isEmpty ? "Без названия" : entry.title,
                    time: Self.headerTime(for: entry),
                    participants: participantsLabel(for: entry),
                    onCopy: { copyPaneText(for: entry) },
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
                    Button("Удалить встречу", role: .destructive) { state.removeRecording(entry) }
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

    /// Copies what the pane is currently showing — the summary or the
    /// transcript. The button sits next to that column, so copying the *other*
    /// one would be a surprise.
    private func copyPaneText(for entry: RecordingEntry) {
        let text: String
        switch paneMode {
        case .summary:
            text = Self.recapMarkdown(for: entry)
        case .transcript:
            text = transcriptTurns(for: entry)
                .map { "\($0.speaker) \($0.time)\n\($0.text)" }
                .joined(separator: "\n\n")
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The markdown file when there is one — sharing a file lets the receiving
    /// app decide what to do with it — otherwise the text itself.
    private func shareItems(for entry: RecordingEntry) -> [Any] {
        if paneMode == .summary, let url = AppState.resolvedRecapURL(for: entry) {
            return [url]
        }
        if let url = markdownURL(for: entry) { return [url] }
        let text = Self.recapMarkdown(for: entry)
        return text.isEmpty ? [] : [text]
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

    private static func headerTime(for entry: RecordingEntry) -> String {
        let f = DateFormatter()
        f.locale = SidebarDayGrouping.locale
        f.dateFormat = "HH:mm, d MMMM"
        return f.string(from: entry.date)
    }

    private func participantsLabel(for entry: RecordingEntry) -> String? {
        let names = state.distinctSpeakerNames(for: entry)
        guard !names.isEmpty else { return nil }
        return "\(names.count) участников"
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
                        weight: .medium,
                        enabled: canGoBack
                    ) { goBack() }
                    .help("Назад")

                    IconButton(
                        systemName: "chevron.right",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .medium,
                        enabled: canGoForward
                    ) { goForward() }
                    .help("Вперёд")

                    IconButton(
                        systemName: "magnifyingglass",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .medium
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

                MinimalIconSettingsLink()
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

    /// Mic glow on the leading edge, system on the trailing — live proof both stems work.
    private var recordingEdgeGlow: some View {
        let mic = Double(state.recorder.micLevelHistory.last ?? 0)
        let sys = Double(state.recorder.systemLevelHistory.last ?? 0)
        return ZStack {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.red.opacity(0.15 + mic * 0.55), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 28)
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.clear, Color.cyan.opacity(0.12 + sys * 0.50)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 28)
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.08), value: mic)
        .animation(.easeOut(duration: 0.08), value: sys)
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
        if state.isRecording {
            RecordingInProgressView(state: state, recorder: state.recorder)
                .padding(.horizontal, Tokens.Window.chromePadding)
                .frame(maxWidth: .infinity)
        } else if let entry = state.selectedRecording {
            MeetingPaneBody(
                mode: paneMode,
                summary: RecapPresentation.summary(fromMarkdown: Self.recapMarkdown(for: entry)),
                turns: transcriptTurns(for: entry),
                notes: noteModels(for: entry),
                composer: .init(text: $draftNote) { commitNote(for: entry) },
                // Two facts, two homes: what the transcript is, and why the
                // summary is not here yet. Joined into one line they read as one
                // thought and neither was legible.
                summaryPlaceholder: state.rest(of: entry).disclosure ?? "Саммари пока нет",
                transcriptDisclosure: entry.depthDisclosure
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

    private func noteModels(for entry: RecordingEntry) -> [MeetingNote] {
        MeetingNotes.resolved(items: entry.noteItems, blob: entry.notes)
            .map { MeetingNote(id: $0.id, text: $0.text) }
    }

    /// Diarised segments when they exist, the plain transcript when they do not
    /// — same fallback the detail view has always used.
    private func transcriptTurns(for entry: RecordingEntry) -> [MeetingTranscriptColumn.Turn] {
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

    private func commitNote(for entry: RecordingEntry) {
        let text = draftNote
        draftNote = ""
        recordingStore.appendNote(id: entry.id, text: text)
    }

    private var meetingsHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Window.sectionStackGap) {
                titleBlock
                meetingsList
            }
            .frame(maxWidth: Tokens.Window.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 120)
        }
    }

    /// Figma 640:1877 — h=100, items-end, px=12 py=8, title 40/44/−0.8.
    private var titleBlock: some View {
        MeetingsTitleBlock(
            showRecord: !state.isRecording,
            speakerOptions: filterSpeakerOptions,
            selectedSpeaker: speakerFilter,
            onRecord: { state.startRecording() },
            onSelectSpeaker: { speakerFilter = $0 }
        )
    }

    // MARK: - List

    private var meetingsList: some View {
        // Frame 86 gap=24 between Upcoming / Today blocks; rows inside a section stack flush.
        LazyVStack(alignment: .leading, spacing: Tokens.Window.sectionStackGap) {
            if let next = nextUpcoming {
                sectionBlock(title: "Скоро") {
                    upcomingRow(next)
                }
            }
            ForEach(groupedRecordings, id: \.0) { group, entries in
                sectionBlock(title: group) {
                    ForEach(entries) { entry in
                        meetingRow(entry)
                    }
                }
            }
            if nextUpcoming == nil && groupedRecordings.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Пока нет встреч")
                        .typo(Tokens.Typography.Label.mdMedium)
                        .foregroundStyle(Tokens.Ink.tertiary)
                    Text("Начните запись — или Propeller сам подхватит звонок.")
                        .typo(Tokens.Typography.Label.smMedium)
                        .foregroundStyle(Tokens.Ink.tertiary)
                    Button {
                        state.startRecording()
                    } label: {
                        Text("Записать")
                            .typo(Tokens.Typography.Label.mdMedium)
                            .foregroundStyle(Tokens.Ink.primary)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Tokens.Neutral.aw10, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Запись (⌘R)")
                }
                .padding(.horizontal, 12)
                .padding(.top, 24)
            }
        }
    }

    /// Soonest future calendar event (not the whole day list).
    private var nextUpcoming: UpcomingMeeting? {
        let now = Date()
        return calendar.upcoming
            .filter { $0.start >= now }
            .sorted { $0.start < $1.start }
            .first
    }

    /// Speakers seen in the library: owner first, then Speaker N / others.
    private var filterSpeakerOptions: [String] {
        var set = Set<String>()
        for entry in recordingStore.recordings {
            for name in state.distinctSpeakerNames(for: entry) {
                let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { set.insert(t) }
            }
        }
        let owner = Preferences.shared.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = Array(set).sorted {
            if $0 == owner { return true }
            if $1 == owner { return false }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        if !owner.isEmpty, !list.contains(owner) {
            list.insert(owner, at: 0)
        }
        return list
    }

    private func sectionBlock<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Window.sectionInnerGap) {
            Text(title)
                .typo(Tokens.Typography.Label.smMedium)
                .foregroundStyle(Tokens.Ink.tertiary)
                .padding(.horizontal, 12)
            VStack(spacing: 0) { content() }
        }
    }

    // MARK: - Rows

    private func upcomingRow(_ m: UpcomingMeeting) -> some View {
        let key = "evt-" + m.id
        let hovered = hoveredRowID == key
        return rowChrome(hovered: hovered) {
            timeColumn(start: m.start, end: m.end)
            // Feed preview = topics; calendar events have none yet → blank subtitle.
            textColumn(title: m.title, subtitle: "")
            Spacer(minLength: 0)
            // Mute is the primary action for the single upcoming row (reqs §4).
            rowTrailingSlot(hovered: hovered, busy: false) {
                IconButton(
                    systemName: "mic.slash",
                    prominence: .minimal,
                    iconSize: 14,
                    weight: .medium
                ) { calendar.dismiss(m) }
                .help("Не записывать эту встречу")
            }
        }
        .onHover { inside in
            hoveredRowID = inside ? key : (hoveredRowID == key ? nil : hoveredRowID)
        }
    }

    private func meetingRow(_ entry: RecordingEntry) -> some View {
        let hovered = hoveredRowID == entry.id
        let end = entry.date.addingTimeInterval(entry.duration)
        let busy = isProcessing(entry)
        return rowChrome(hovered: hovered) {
            timeColumn(start: entry.date, end: end)
            textColumn(
                title: entry.title.isEmpty ? "Без названия" : entry.title,
                subtitle: entry.subtitleText
            )
            Spacer(minLength: 0)
            rowTrailingSlot(hovered: hovered, busy: busy) {
                IconButton(
                    systemName: "square.and.arrow.down",
                    prominence: .minimal,
                    iconSize: 14,
                    weight: .medium
                ) { revealInFinder(entry) }
                .help("Показать в Finder")
                IconButton(
                    systemName: "trash",
                    prominence: .minimal,
                    iconSize: 14,
                    weight: .medium
                ) { state.removeRecording(entry) }
                .help("Удалить")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { state.selectRecording(entry) }
        .onHover { inside in
            hoveredRowID = inside ? entry.id : (hoveredRowID == entry.id ? nil : hoveredRowID)
        }
        .contextMenu {
            Button("Показать в Finder") { revealInFinder(entry) }
            Button("Удалить аудио") { state.deleteAudioFile(entry) }
                .disabled(!entry.audioFileExists)
            Divider()
            Button("Удалить встречу", role: .destructive) { state.removeRecording(entry) }
        }
    }

    /// Spinner stays put; on hover, action cluster paints over it.
    private func rowTrailingSlot<Actions: View>(
        hovered: Bool,
        busy: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        ZStack(alignment: .trailing) {
            if busy {
                processingSpinner
            }
            if hovered {
                HStack(spacing: 0, content: actions)
                    .background {
                        // Opaque wash so the spinner doesn't bleed through transparent icons.
                        Capsule()
                            .fill(Color(nsColor: NSColor(calibratedWhite: Tokens.Glass.fillWhite, alpha: 1)))
                            .overlay(Capsule().fill(Tokens.Paint.Bg.surface))
                    }
            }
        }
        .frame(minWidth: busy || hovered ? 32 : 0, minHeight: 32)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// Figma row: h≈52, gap 10, px 12 / py 8, hover fill white/5, radius 12.
    private func rowChrome<Content: View>(
        hovered: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Window.rowRadius, style: .continuous)
                .fill(hovered ? Tokens.Paint.Bg.surface : Color.clear)
        )
    }

    private func timeColumn(start: Date, end: Date) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(Self.timeFormatter.string(from: start))
                .typo(Tokens.Typography.Label.mdMedium)
                .foregroundStyle(Tokens.Ink.primary)
                .frame(height: 20)
            Text(Self.timeFormatter.string(from: end))
                .typo(Tokens.Typography.Label.smMedium)
                .foregroundStyle(Tokens.Ink.quaternary)
                .frame(height: 16)
        }
        .frame(width: 44, alignment: .trailing)
    }

    private func textColumn(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .typo(Tokens.Typography.Label.mdMedium)
                .foregroundStyle(Tokens.Ink.primary)
                .lineLimit(1)
                .frame(height: 20, alignment: .leading)
            Text(subtitle.isEmpty ? " " : subtitle)
                .typo(Tokens.Typography.Label.smMedium)
                .foregroundStyle(subtitle.isEmpty ? Color.clear : Tokens.Ink.quaternary)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    @ViewBuilder
    private var processingSpinner: some View {
        let icon = Image(systemName: "progress.indicator")
            .typo(Tokens.Typography.Label.mdMedium)
            .foregroundStyle(Tokens.Ink.secondary)
            .frame(width: 32, height: 32)
        if #available(macOS 15.0, *) {
            icon.symbolEffect(
                .variableColor.iterative.dimInactiveLayers.nonReversing,
                options: .repeat(.continuous)
            )
        } else {
            ProgressView().controlSize(.small).frame(width: 32, height: 32)
        }
    }

    // MARK: - Helpers

    private func revealInFinder(_ entry: RecordingEntry) {
        if let audioURL = recordingStore.audioURL(for: entry) {
            NSWorkspace.shared.activateFileViewerSelecting([audioURL])
        } else if let mdURL = markdownURL(for: entry) {
            NSWorkspace.shared.activateFileViewerSelecting([mdURL])
        }
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

    private var visibleRecordings: [RecordingEntry] {
        recordingStore.recordings.filter { entry in
            // Hide stubs; keep anything still in the pipeline even if short.
            if entry.duration > 0, entry.duration < Self.stubDurationThreshold, !isProcessing(entry) {
                return false
            }
            if let speakerFilter {
                let names = state.distinctSpeakerNames(for: entry)
                if !names.contains(where: { $0.caseInsensitiveCompare(speakerFilter) == .orderedSame }) {
                    return false
                }
            }
            return true
        }
    }

    private var groupedRecordings: [(String, [RecordingEntry])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!

        var groups: [(String, [RecordingEntry])] = []
        var t: [RecordingEntry] = [], y: [RecordingEntry] = [], w: [RecordingEntry] = [], o: [RecordingEntry] = []

        for rec in visibleRecordings {
            let d = cal.startOfDay(for: rec.date)
            if d >= today { t.append(rec) }
            else if d >= yesterday { y.append(rec) }
            else if d >= weekAgo { w.append(rec) }
            else { o.append(rec) }
        }

        if !t.isEmpty { groups.append(("Сегодня", t)) }
        if !y.isEmpty { groups.append(("Вчера", y)) }
        if !w.isEmpty { groups.append(("На этой неделе", w)) }
        if !o.isEmpty { groups.append(("Ранее", o)) }
        return groups
    }
}

enum SettingsOpener {
    static func open() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
