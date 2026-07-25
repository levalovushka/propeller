import SwiftUI
import AppKit
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

    var body: some View {
        ZStack(alignment: .bottom) {
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

            if state.selectedRecording == nil, !state.isRecording {
                floatingSearch
                    .padding(.bottom, 16)
            }
        }
        .frame(minWidth: Tokens.Window.contentWidth + Tokens.Window.chromePadding * 2,
               minHeight: 560)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            state.isWindowOpen = true
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            state.isWindowOpen = false
            NSApp.setActivationPolicy(.accessory)
        }
        .onChange(of: state.selectedRecordingID) { _, newID in
            recordNav(to: newID)
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

    // MARK: - Top bar — Figma 640:1861 (slot 76 | back/forward | status+gear)

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Color.clear
                    .frame(width: Tokens.Window.trafficLightSlotWidth, height: 32)

                HStack(spacing: 0) {
                    IconButton(
                        systemName: "chevron.left",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .medium,
                        enabled: canGoBack
                    ) { goBack() }
                    .help("Back")

                    IconButton(
                        systemName: "chevron.right",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .medium,
                        enabled: canGoForward
                    ) { goForward() }
                    .help("Forward")
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 14) {
                if let status = topStatusText {
                    Text(status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.30))
                        .tracking(0.025)
                        .lineLimit(1)
                        .frame(height: 32)
                }

                SettingsLink {
                    MinimalIconGlyph(systemName: "gearshape.fill", iconSize: 15)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
        .frame(height: 32)
        .padding(Tokens.Window.chromePadding)
        .frame(height: Tokens.Window.topBarHeight, alignment: .center)
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
        if let frac = state.modelDownloadProgress {
            return "Downloading model.. \(Int(frac * 100))%"
        }
        if state.busyRecordingID != nil
            || state.transcribeStep == .running
            || state.saveStep == .running
            || state.recapStep == .running {
            return state.statusMessage.isEmpty ? "Working…" : state.statusMessage
        }
        return nil
    }

    // MARK: - Main area

    @ViewBuilder
    private var mainArea: some View {
        Group {
            if state.isRecording {
                RecordingInProgressView(state: state)
            } else if let entry = state.selectedRecording {
                RecordingDetailView(state: state, entry: entry, presentation: .meeting)
            } else {
                meetingsHome
            }
        }
        // Figma Frame 87: px-12, then centred 640 column.
        .padding(.horizontal, Tokens.Window.chromePadding)
        .frame(maxWidth: .infinity)
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
        HStack(alignment: .bottom, spacing: 8) {
            Text("Meetings")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Tokens.Ink.primary)
                .tracking(-0.8)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottomLeading)

            Menu {
                Button("All speakers") { speakerFilter = nil }
                if !filterSpeakerOptions.isEmpty { Divider() }
                ForEach(filterSpeakerOptions, id: \.self) { name in
                    Button {
                        speakerFilter = name
                    } label: {
                        if speakerFilter == name {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                MinimalIconGlyph(
                    systemName: "line.3.horizontal.decrease",
                    iconSize: 15,
                    emphasized: speakerFilter != nil
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Filter by speaker")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: Tokens.Window.titleBlockHeight, alignment: .bottom)
    }

    // MARK: - List

    private var meetingsList: some View {
        // Frame 86 gap=24 between Upcoming / Today blocks; rows inside a section stack flush.
        LazyVStack(alignment: .leading, spacing: Tokens.Window.sectionStackGap) {
            if let next = nextUpcoming {
                sectionBlock(title: "Upcoming") {
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.30))
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
                .help("Don't record this meeting")
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
                title: entry.title.isEmpty ? "Untitled" : entry.title,
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
                .help("Reveal in Finder")
                IconButton(
                    systemName: "trash",
                    prominence: .minimal,
                    iconSize: 14,
                    weight: .medium
                ) { state.removeRecording(entry) }
                .help("Delete")
            }
        }
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
                            .overlay(Capsule().fill(Color.white.opacity(0.05)))
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
                .fill(Color.white.opacity(hovered ? 0.05 : 0))
        )
    }

    private func timeColumn(start: Date, end: Date) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(Self.timeFormatter.string(from: start))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.Ink.primary)
                .frame(height: 20)
            Text(Self.timeFormatter.string(from: end))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.40))
                .frame(height: 16)
        }
        .frame(width: 44, alignment: .trailing)
    }

    private func textColumn(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.Ink.primary)
                .lineLimit(1)
                .frame(height: 20, alignment: .leading)
            Text(subtitle.isEmpty ? " " : subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(subtitle.isEmpty ? 0 : 0.40))
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    @ViewBuilder
    private var processingSpinner: some View {
        let icon = Image(systemName: "progress.indicator")
            .font(.system(size: 14, weight: .medium))
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

    // MARK: - Floating search

    /// Figma 640:1987 — pill, backdrop-blur 12, fill white/10, gap 4, h=36, px=14.
    private var floatingSearch: some View {
        Button { showSearchPalette = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                Text("Search")
                    .padding(.horizontal, 2)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Tokens.Ink.primary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(Color.white.opacity(0.10))
            }
        }
        .buttonStyle(.plain)
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
        // Never key off idle statuses like "recorded" / "transcribed_raw" —
        // that made every unfinished meeting spin forever.
        if entry.status == "recording" { return true }
        return state.busyRecordingID == entry.id
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

        if !t.isEmpty { groups.append(("Today", t)) }
        if !y.isEmpty { groups.append(("Yesterday", y)) }
        if !w.isEmpty { groups.append(("This Week", w)) }
        if !o.isEmpty { groups.append(("Older", o)) }
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
