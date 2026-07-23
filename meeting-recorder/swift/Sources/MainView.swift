import SwiftUI

struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject var recordingStore: RecordingStore
    @State private var showSearchPalette = false
    @State private var hoveredRowID: String?
    @ObservedObject private var calendar = CalendarService.shared

    var body: some View {
        // No sidebar: a custom top bar hosts nav / search / status / settings,
        // and one centred content column (max 640) below it.
        VStack(spacing: 0) {
            topBar
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 560)
        // Pull the whole layout up under the (hidden) title bar so the top bar
        // sits on the same line as the traffic-light buttons.
        .ignoresSafeArea(.container, edges: .top)
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
                    state.selectRecording(entry)
                },
                onClose: { showSearchPalette = false }
            )
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
        .background(VisualEffectBackground().ignoresSafeArea())
        .alert("Microphone Access Required", isPresented: $state.showMicPermissionAlert) {
            Button("Open System Settings") { state.openMicrophoneSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Propeller needs microphone access to record audio. Please enable it in System Settings > Privacy & Security > Microphone.")
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
    }


    // MARK: - Top bar (nav / search / status / settings)

    private var topBar: some View {
        HStack(spacing: 16) {
            // Back / forward — navigate between the list and an open meeting.
            HStack(spacing: 12) {
                Button { state.selectedRecordingID = nil } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(state.selectedRecording == nil)
                Button {} label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(true)
            }
            .buttonStyle(.plain)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)

            Button { showSearchPalette = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            if let status = topStatusText {
                Text(status)
                    .foregroundStyle(.tertiary)
            }

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 15))
        .padding(.leading, 80)      // clear the macOS traffic-light buttons
        .padding(.trailing, 20)
        .frame(height: 44)
    }

    /// Right-aligned status: model download, else an active pipeline step, else nil.
    private var topStatusText: String? {
        if let frac = state.modelDownloadProgress {
            return "Downloading model.. \(Int(frac * 100))%"
        }
        if state.transcribeStep == .running || state.saveStep == .running || state.recapStep == .running {
            return state.statusMessage.isEmpty ? "Working…" : state.statusMessage
        }
        return nil
    }

    // MARK: - Main area (one centred column, max 540)

    @ViewBuilder
    private var mainArea: some View {
        Group {
            if state.isRecording {
                RecordingInProgressView(state: state)
            } else if let entry = state.selectedRecording {
                RecordingDetailView(state: state, entry: entry, presentation: .meeting)
            } else {
                meetingsList.pageHeader("Meetings")
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Meetings list

    private var meetingsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                let todaysUpcoming = calendar.upcoming
                    .filter { Calendar.current.isDateInToday($0.start) }
                    .prefix(3)
                if !todaysUpcoming.isEmpty {
                    sectionHeader("Upcoming")
                    ForEach(Array(todaysUpcoming)) { m in
                        upcomingRow(m)
                    }
                }
                ForEach(groupedRecordings, id: \.0) { group, entries in
                    sectionHeader(group)
                    ForEach(entries) { entry in
                        meetingRow(entry)
                    }
                }
            }
            .padding(.bottom, 28)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 22)
            .padding(.bottom, 4)
    }

    // MARK: - Upcoming (calendar) row

    private func upcomingRow(_ m: UpcomingMeeting) -> some View {
        let key = "evt-" + m.id
        let hovered = hoveredRowID == key
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(m.whenLabel)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if hovered {
                HStack(spacing: 14) {
                    Button { calendar.dismiss(m) } label: {
                        Image(systemName: "mic.slash")
                    }
                    .help("Don't record this meeting")
                    Button { calendar.dismiss(m) } label: {
                        Image(systemName: "trash")
                    }
                    .help("Dismiss")
                }
                .buttonStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            }
        }
        .opacity(0.85)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(hovered ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredRowID = inside ? key : (hoveredRowID == key ? nil : hoveredRowID)
        }
    }

    // MARK: - Meetings row

    private func meetingRow(_ entry: RecordingEntry) -> some View {
        let hovered = hoveredRowID == entry.id
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.title.isEmpty ? "Untitled" : entry.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(rowMeta(entry))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .layoutPriority(-1)
                }
                if !entry.subtitleText.isEmpty {
                    Text(entry.subtitleText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if hovered {
                rowActions(entry)
            } else {
                avatarStack(entry)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(hovered ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { state.selectRecording(entry) }
        .onHover { inside in
            hoveredRowID = inside ? entry.id : (hoveredRowID == entry.id ? nil : hoveredRowID)
        }
        .contextMenu {
            Button("Reveal in Finder") { revealInFinder(entry) }
            Button("Delete audio file") { state.deleteAudioFile(entry) }
                .disabled(!entry.audioFileExists)
            Divider()
            Button("Delete recording", role: .destructive) { state.removeRecording(entry) }
        }
    }

    /// "17:08 · 19 min" — time of day plus compact duration.
    private func rowMeta(_ entry: RecordingEntry) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        var s = f.string(from: entry.date)
        if entry.duration > 0 {
            let mins = Int(entry.duration) / 60
            s += mins > 0 ? " · \(mins) min" : " · \(Int(entry.duration))s"
        }
        return s
    }

    private func avatarStack(_ entry: RecordingEntry) -> some View {
        let names = state.distinctSpeakerNames(for: entry)
        return HStack(spacing: -6) {
            ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { _, n in
                AvatarCircle(name: n, size: 24)
            }
            if names.count > 3 {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.14))
                    Text("+\(names.count - 3)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 24, height: 24)
            }
        }
    }

    private func rowActions(_ entry: RecordingEntry) -> some View {
        HStack(spacing: 14) {
            Button { revealInFinder(entry) } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Reveal in Finder")
            Button { state.removeRecording(entry) } label: {
                Image(systemName: "trash")
            }
            .help("Delete recording")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
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
