import SwiftUI

struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject var recordingStore: RecordingStore
    @State private var section: SidebarSection = .meetings
    @State private var showSearchPalette = false

    // People section state
    @State private var selectedPersonID: UUID?
    @State private var showDeletePersonConfirm = false
    @State private var personToDelete: Person?
    @State private var personBusyMessage: String?

    enum SidebarSection: String, Identifiable {
        case meetings, summaries, people
        var id: String { rawValue }
    }

    var body: some View {
        // Plain column layout instead of NavigationSplitView: no floating
        // glass sidebar pane, sidebar is always visible and can't collapse.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)

            Divider()

            HSplitView {
                contentColumn
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
                detailColumn
                    .frame(minWidth: 540, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                recordButton
            }
        }
        .onAppear {
            state.isWindowOpen = true
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            state.isWindowOpen = false
            NSApp.setActivationPolicy(.accessory)
        }
        .task {
            state.bootstrap()
        }
        .sheet(isPresented: $state.showOnboarding) {
            OnboardingView(state: state)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSearchPalette) {
            SearchPalette(
                state: state,
                onOpenRecording: { entry in
                    showSearchPalette = false
                    section = .meetings
                    state.selectRecording(entry)
                },
                onOpenPerson: { person in
                    showSearchPalette = false
                    section = .people
                    selectedPersonID = person.id
                },
                onClose: { showSearchPalette = false }
            )
        }
        .onChange(of: state.showPeople) { _, show in
            // Menu bar "People & Voices" routes here now that People is a
            // sidebar section instead of a modal.
            if show {
                section = .people
                state.showPeople = false
            }
        }
        .onChange(of: state.preferredSidebarSection) { _, raw in
            guard let raw else { return }
            if let next = SidebarSection(rawValue: raw) {
                section = next
            }
            state.preferredSidebarSection = nil
        }
        .background {
            // Window-level shortcuts (no visible UI)
            Button("") {
                if state.isRecording { state.stopRecording() }
                else { state.startRecording() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .hidden()

            Button("") { showSearchPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .alert("Microphone Access Required", isPresented: $state.showMicPermissionAlert) {
            Button("Open System Settings") { state.openMicrophoneSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Propeller needs microphone access to record audio. Please enable it in System Settings > Privacy & Security > Microphone.")
        }
        .alert(
            "Voice doesn't match \(state.pendingContamination?.person.name ?? "this person")",
            isPresented: Binding(
                get: { state.pendingContamination != nil },
                set: { if !$0 { state.pendingContamination = nil } }
            )
        ) {
            Button("Add Anyway", role: .destructive) {
                if let c = state.pendingContamination {
                    state.forceAddSpeakerToPerson(c.speaker, person: c.person)
                }
            }
            Button("Cancel", role: .cancel) {
                state.pendingContamination = nil
            }
        } message: {
            if let c = state.pendingContamination {
                Text("This clip only matches \(c.person.name)'s existing samples at \(c.percentageString). Adding it may degrade future recognition. Are you sure?")
            } else {
                Text("")
            }
        }
        .alert("Delete Person?", isPresented: $showDeletePersonConfirm) {
            Button("Delete", role: .destructive) {
                if let person = personToDelete {
                    state.player.stop()
                    if selectedPersonID == person.id { selectedPersonID = nil }
                    state.peopleStore.delete(person)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the person and all voice samples.")
        }
        .alert("Low Disk Space", isPresented: $state.showDiskSpaceAlert) {
            Button("Continue Anyway") { state.diskSpaceAlertContinue() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(state.diskSpaceWarning ?? "Disk space is low.")
        }
        .alert("Recording Recovered", isPresented: Binding(
            get: { state.recoveredCount > 0 },
            set: { if !$0 { state.recoveredCount = 0 } }
        )) {
            Button("OK") { state.recoveredCount = 0 }
        } message: {
            Text("\(state.recoveredCount) recording\(state.recoveredCount == 1 ? " was" : "s were") interrupted and may need re-transcription.")
        }
        .overlay {
            if let msg = personBusyMessage {
                ZStack {
                    Color.black.opacity(0.25)
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Record button (toolbar)

    private var recordButton: some View {
        Button {
            if state.isRecording { state.stopRecording() }
            else { state.startRecording() }
        } label: {
            Label(
                state.isRecording ? "Stop  \(state.elapsedString)" : "Record",
                systemImage: state.isRecording ? "stop.circle.fill" : "record.circle.fill"
            )
            .monospacedDigit()
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .help(state.isRecording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
    }

    // MARK: - Sidebar (sections)

    private var sidebar: some View {
        List(selection: Binding(
            get: { section },
            set: { newValue in
                if let newValue { section = newValue }
            }
        )) {
            Label("Meetings", systemImage: "waveform")
                .tag(SidebarSection.meetings)

            Label("Summaries", systemImage: "doc.text")
                .tag(SidebarSection.summaries)

            Label {
                Text("People")
            } icon: {
                Image(systemName: "person.2")
                    .overlay(alignment: .topTrailing) {
                        if state.peopleStore.hasHealthIssues {
                            Circle()
                                .fill(.red)
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: -2)
                        }
                    }
            }
            .tag(SidebarSection.people)

            Button {
                showSearchPalette = true
            } label: {
                HStack {
                    Label("Search", systemImage: "magnifyingglass")
                    Spacer()
                    Text("⌘K")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            Button {
                SettingsOpener.open()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
        }
        .listStyle(.sidebar)
    }

    // MARK: - Content column

    @ViewBuilder
    private var contentColumn: some View {
        switch section {
        case .meetings:
            meetingsList
        case .summaries:
            summariesList
        case .people:
            peopleList
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        switch section {
        case .meetings:
            if state.isRecording {
                RecordingInProgressView(state: state)
            } else if let entry = state.selectedRecording {
                RecordingDetailView(state: state, entry: entry, presentation: .meeting)
            } else {
                emptyState
            }
        case .summaries:
            if let entry = state.selectedRecording,
               state.summaryLibraryEntries().contains(where: { $0.id == entry.id }) {
                RecordingDetailView(state: state, entry: entry, presentation: .summaryFocus)
            } else {
                summariesEmptyDetail
            }
        case .people:
            if let personID = selectedPersonID,
               let person = state.peopleStore.people.first(where: { $0.id == personID }) {
                PersonDetailView(
                    person: person,
                    store: state.peopleStore,
                    player: state.player,
                    state: state,
                    onDelete: {
                        personToDelete = person
                        showDeletePersonConfirm = true
                    },
                    busyMessage: $personBusyMessage
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 40, weight: .ultraLight))
                        .foregroundStyle(.quaternary)
                    Text("Select a person")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Meetings list

    private var meetingsList: some View {
        List(selection: Binding(
            get: { state.selectedRecordingID },
            set: { id in
                if let id, let rec = recordingStore.recordings.first(where: { $0.id == id }) {
                    state.selectRecording(rec)
                }
            }
        )) {
            if !recordingStore.recordings.isEmpty {
                ForEach(groupedRecordings, id: \.0) { group, entries in
                    Section(group) {
                        ForEach(entries) { entry in
                            sidebarRow(entry)
                                .tag(entry.id)
                                .contextMenu {
                                    Button("Rename") {
                                        // Trigger rename by selecting and using detail header
                                        state.selectRecording(entry)
                                    }
                                    Button("Reveal in Finder") {
                                        revealInFinder(entry)
                                    }
                                    Divider()
                                    Button("Delete audio file") {
                                        state.deleteAudioFile(entry)
                                    }
                                    .disabled(!entry.audioFileExists)
                                    Divider()
                                    Button("Delete recording", role: .destructive) {
                                        state.removeRecording(entry)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Summaries list

    private var summariesList: some View {
        let entries = state.summaryLibraryEntries()
        return List(selection: Binding(
            get: { state.selectedRecordingID },
            set: { id in
                if let id, let rec = recordingStore.recordings.first(where: { $0.id == id }) {
                    state.selectRecording(rec)
                }
            }
        )) {
            if entries.isEmpty {
                Text("No summaries yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: state.hasRecap(for: entry) ? "sparkles" : "square.and.pencil")
                            .font(.caption)
                            .foregroundStyle(state.hasRecap(for: entry) ? Color.accentColor : .secondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title.isEmpty ? "Untitled" : entry.title)
                                .font(.body)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(entry.dateFormatted)
                                if !(entry.notes?.isEmpty ?? true) {
                                    Text("·"); Text("Notes")
                                }
                                if state.hasRecap(for: entry) {
                                    Text("·"); Text("Summary")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .tag(entry.id)
                    .contextMenu {
                        Button("Open full meeting") {
                            section = .meetings
                            state.selectRecording(entry)
                            state.preferredDetailTab = "recap"
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var summariesEmptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.quaternary)
            Text("No summary selected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("After a call, summaries and notes land here.\nWrite notes during recording to guide the AI.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - People list

    private var peopleList: some View {
        VStack(spacing: 0) {
            if state.peopleStore.hasHealthIssues {
                peopleHealthBanner
            }
            if state.peopleStore.people.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 32, weight: .ultraLight))
                        .foregroundStyle(.quaternary)
                    Text("No saved people yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("People are saved when you name speakers\nafter a recording is transcribed.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedPersonID) {
                    ForEach(state.peopleStore.people) { person in
                        HStack(spacing: 10) {
                            AvatarCircle(name: person.name, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name)
                                    .font(.body)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text("\(person.sampleCount) sample\(person.sampleCount == 1 ? "" : "s")")
                                    Text("·")
                                    Text(compactDuration(person.totalDuration))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(person.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var peopleHealthBanner: some View {
        let issues = state.peopleStore.healthIssues
        return VStack(alignment: .leading, spacing: 6) {
            Label(
                "\(issues.count) issue\(issues.count == 1 ? "" : "s") found",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)

            ForEach(issues) { issue in
                HStack(spacing: 6) {
                    Image(systemName: issue.iconName)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .symbolRenderingMode(.hierarchical)
                    Text(issue.message)
                        .font(.caption2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(10)
    }

    private func compactDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 60 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s)s"
    }

    // MARK: - Meetings row

    private func sidebarRow(_ entry: RecordingEntry) -> some View {
        HStack(spacing: 8) {
            statusDot(entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.dateFormatted)
                    if entry.duration > 0 { Text("·"); Text(entry.durationFormatted) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ entry: RecordingEntry) -> some View {
        switch entry.status {
        case "saved":
            Circle().fill(.green).frame(width: 8, height: 8)
        case "transcribed":
            Circle().fill(.blue).frame(width: 8, height: 8)
        case "transcribed_raw":
            Circle().fill(.yellow).frame(width: 8, height: 8)
        case "transcribing":
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case "recording":
            Circle().fill(.red).frame(width: 8, height: 8)
        default:
            Circle().fill(.quaternary).frame(width: 8, height: 8)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.quaternary)
            VStack(spacing: 4) {
                Text("No recording selected")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Select a recording or press Record to start")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Reveal in Finder

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

    private var groupedRecordings: [(String, [RecordingEntry])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!

        var groups: [(String, [RecordingEntry])] = []
        var t: [RecordingEntry] = [], y: [RecordingEntry] = [], w: [RecordingEntry] = [], o: [RecordingEntry] = []

        for rec in recordingStore.recordings {
            let d = cal.startOfDay(for: rec.date)
            if d >= today { t.append(rec) }
            else if d >= yesterday { y.append(rec) }
            else if d >= weekAgo { w.append(rec) }
            else { o.append(rec) }
        }

        if !t.isEmpty { groups.append(("Today", t)) }
        if !y.isEmpty { groups.append(("Yesterday", y)) }
        if !w.isEmpty { groups.append(("This Week", w)) }
        if !o.isEmpty { groups.append(("Older", o)) }
        return groups
    }
}

// MARK: - Settings window opener

/// Opens the native SwiftUI `Settings` scene programmatically (used from the
/// menu bar panel and the sidebar, where `SettingsLink` isn't available).
enum SettingsOpener {
    static func open() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
