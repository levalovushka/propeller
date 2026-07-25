import SwiftUI
import AppKit
import PropellerUI

// MARK: - Avatar

struct AvatarCircle: View {
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(color)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        if let first = parts.first, let last = parts.dropFirst().first {
            return String(first.prefix(1) + last.prefix(1)).uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }

    private var color: Color {
        // Deterministic hue from name
        var h: UInt32 = 2166136261
        for byte in name.utf8 {
            h ^= UInt32(byte)
            h &*= 16777619
        }
        let hue = Double(h % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}

struct RecordingDetailView: View {
    @ObservedObject var state: AppState
    /// Nested player must be observed directly — `@Published` on AppState
    /// does not forward `AudioPlayer`’s own `@Published` updates.
    @ObservedObject private var player: AudioPlayer
    let entry: RecordingEntry
    /// `.meeting` — full Transcript/Notes/Summary tabs.
    /// `.summaryFocus` — Summaries library: Summary + Notes only (stacked).
    var presentation: Presentation = .meeting

    init(state: AppState, entry: RecordingEntry, presentation: Presentation = .meeting) {
        self.state = state
        self._player = ObservedObject(wrappedValue: state.player)
        self.entry = entry
        self.presentation = presentation
    }

    enum Presentation {
        case meeting
        case summaryFocus
    }

    /// Req order: Summary · Follow-up · Notes · Transcript.
    enum DetailTab: String, CaseIterable, Identifiable {
        case recap
        case followUp
        case notes
        case transcript
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recap: return "Summary"
            case .followUp: return "Follow-up"
            case .notes: return "Notes"
            case .transcript: return "Transcript"
            }
        }
    }

    @State private var tab: DetailTab = .recap   // Summary is the default view
    @State private var recapText: String?
    @State private var followUpText: String?

    @State private var showingDeleteConfirm = false
    @State private var showingRemoveConfirm = false
    @State private var copiedTranscript = false
    @State private var copiedForChat = false
    @State private var copiedRecap = false
    @State private var copiedFollowUp = false
    @State private var editingTitle = false
    @State private var editedTitle = ""
    @State private var titleHovered = false
    @FocusState private var titleFieldFocused: Bool
    @State private var editedNotes = ""
    @State private var isEditingTranscript = false
    @State private var editedTranscriptText = ""
    @State private var isEditingRecap = false
    @State private var editedRecapText = ""
    @State private var isEditingFollowUp = false
    @State private var editedFollowUpText = ""
    @State private var speakerFilter: Set<String> = []
    @State private var selectedSegmentIndices: Set<Int> = []
    @State private var showRenameSheet = false
    @State private var renameSpeakerName = ""
    @State private var renamingParticipant: String?
    /// Karaoke: follow the playhead until the user scrolls manually.
    @State private var followPlaybackScroll = true
    @State private var activeKaraokeID: Int?

    private static var pendingNotesSave: DispatchWorkItem?
    /// Captures the most recent unsaved notes payload so `flushPendingNotesSave`
    /// can write it synchronously even after the work item is cancelled.
    private static var pendingNotesValue: (() -> Void)?
    private static func cancelNotesSave() {
        pendingNotesSave?.cancel()
        pendingNotesSave = nil
        pendingNotesValue = nil
    }
    /// Run any pending debounced notes save immediately, so the note value is
    /// persisted before the next operation (save, switch recording, etc.).
    private static func flushPendingNotesSave() {
        pendingNotesSave?.cancel()
        pendingNotesSave = nil
        pendingNotesValue?()
        pendingNotesValue = nil
    }

    private let speakerColors: [Color] = [
        .blue, .purple, .orange, .teal, .pink, .indigo, .mint, .cyan
    ]

    private var markdownURL: URL? {
        let slug = MarkdownWriter.slugify(entry.title.isEmpty ? entry.id : entry.title)
        let filename = "\(entry.id)-\(slug).md"
        let url = URL(fileURLWithPath: Preferences.shared.meetingsPath)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var recapURL: URL? {
        if let path = state.lastRecapPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return AppState.recapURL(for: entry).flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
    }

    private var audioURL: URL? {
        state.recordingStore.audioURL(for: entry)
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader

            if presentation == .meeting {
                tabBar
                tabContent
                    .frame(maxHeight: .infinity)
            } else {
                summaryFocusContent
                    .frame(maxHeight: .infinity)
            }
        }
        .foregroundStyle(Tokens.Ink.primary)
        .alert("Delete Audio?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                state.deleteAudioFile(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The audio file will be deleted. Transcript is kept.")
        }
        .alert("Remove Recording?", isPresented: $showingRemoveConfirm) {
            Button("Remove", role: .destructive) {
                state.removeRecording(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the recording and all data.")
        }
        .onChange(of: state.selectedRecordingID) { _, _ in
            // Commit any in-flight transcript edit before swapping recordings,
            // otherwise edits are silently discarded.
            if isEditingTranscript { commitTranscriptEdit() }
            if isEditingRecap { commitRecapEdit() }
            if isEditingFollowUp { commitFollowUpEdit() }
            // Flush any pending debounced notes save so we don't lose keystrokes.
            Self.flushPendingNotesSave()
            editingTitle = false
            isEditingTranscript = false
            isEditingRecap = false
            isEditingFollowUp = false
            selectedSegmentIndices = []
            editedNotes = entry.notes ?? ""
            recapText = nil
            followUpText = nil
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSpeakerSheet
        }
        .onAppear {
            editedNotes = entry.notes ?? ""
            if presentation == .meeting {
                autoLoadAudioForPlayer()
            } else {
                tab = .recap
                loadRecapText()
            }
            loadFollowUpText()
            applyPreferredTab()
        }
        .onChange(of: entry.id) { _, _ in
            if presentation == .meeting { autoLoadAudioForPlayer() }
            loadRecapText()
            loadFollowUpText()
        }
        .onChange(of: state.preferredDetailTab) { _, _ in
            applyPreferredTab()
        }
        .task(id: "\(entry.id)-\(state.recapStep.rawValue)-\(tab.rawValue)-\(presentation)") {
            if tab == .recap || presentation == .summaryFocus { loadRecapText() }
            if tab == .followUp { loadFollowUpText() }
        }
    }

    private func applyPreferredTab() {
        guard presentation == .meeting, let raw = state.preferredDetailTab else { return }
        let mapped: DetailTab?
        switch raw {
        case "transcript": mapped = .transcript
        case "notes": mapped = .notes
        case "recap", "summary": mapped = .recap
        case "followUp", "followup", "follow-up": mapped = .followUp
        default: mapped = DetailTab(rawValue: raw)
        }
        if let mapped {
            tab = mapped
            state.preferredDetailTab = nil
        }
    }

    // MARK: - Summaries library (summary + notes only)

    private var summaryFocusContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryFocusSection(title: "Summary", systemImage: "sparkles") {
                    recapPanelEmbedded
                }
                summaryFocusSection(title: "Notes", systemImage: "square.and.pencil") {
                    TextEditor(text: $editedNotes)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140)
                        .onChange(of: editedNotes) { _, newValue in
                            Self.cancelNotesSave()
                            let commit: () -> Void = {
                                state.updateNotes(entry, to: newValue)
                                Self.pendingNotesValue = nil
                            }
                            Self.pendingNotesValue = commit
                            let work = DispatchWorkItem(block: commit)
                            Self.pendingNotesSave = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                        }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryFocusSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private var recapPanelEmbedded: some View {
        if state.recapStep == .running && state.selectedRecordingID == entry.id {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating summary…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        } else if let text = recapText, !text.isEmpty {
            recapRendered(text)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No summary yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                if let hint = state.recapSkipHint, state.selectedRecordingID == entry.id {
                    Text(hint).font(.caption).foregroundStyle(.tertiary)
                }
                if state.saveStep == .done || entry.status == "saved" {
                    Button {
                        Task { await state.regenerateRecap() }
                    } label: {
                        Label("Generate summary", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Header (aligned with Meetings list chrome)

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(entry.dateFormatted)
                if entry.duration > 0 {
                    Text("·")
                    Text(entry.durationFormatted)
                }
                let count = participants.count
                if count > 0 {
                    Text("·")
                    participantsMenu(count: count)
                }
                if state.micOnlyRecording {
                    Text("·")
                    Text("Mic only").foregroundStyle(Color.orange.opacity(0.8))
                }
                Spacer(minLength: 0)
                if entry.status == "transcribed_raw", state.transcribeStep != .running {
                    Button("Complete Transcription") {
                        Task { await state.completeDiarization() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else if entry.audioFileExists,
                          (entry.status == "recorded" || state.transcribeStep == .failed),
                          state.transcribeStep != .running {
                    Button(state.transcribeStep == .failed ? "Retry" : "Transcribe") {
                        Task { await state.reprocess() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else if let running = runningStatusText {
                    Text(running)
                        .foregroundStyle(Color.white.opacity(0.40))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.40))

            HStack(alignment: .top, spacing: 12) {
                titleField
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    IconButton(
                        systemName: "folder",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .medium,
                        enabled: entry.audioFileExists || markdownURL != nil
                    ) {
                        revealInFinder()
                    }
                    .help("Show in Finder")

                    IconButton(
                        systemName: "trash",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .medium
                    ) {
                        showingRemoveConfirm = true
                    }
                    .help("Delete meeting")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: Tokens.Window.contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Same display type as Meetings list title (40 / semibold / −0.8).
    @ViewBuilder
    private var titleField: some View {
        let titleFont = Font.system(size: 40, weight: .semibold)
        if editingTitle {
            TextField("Title", text: $editedTitle)
                .textFieldStyle(.plain)
                .font(titleFont)
                .tracking(-0.8)
                .foregroundStyle(Tokens.Ink.primary)
                .focused($titleFieldFocused)
                .onSubmit { commitTitleEdit() }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused { commitTitleEdit() }
                }
                .onExitCommand { editingTitle = false }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if entry.title.isEmpty {
                        Text("Untitled").foregroundStyle(Tokens.Ink.tertiary)
                    } else {
                        Text(entry.title).foregroundStyle(Tokens.Ink.primary)
                    }
                }
                .font(titleFont)
                .tracking(-0.8)
                .lineLimit(2)

                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tokens.Ink.tertiary)
                    .opacity(titleHovered ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { titleHovered = $0 }
            .onTapGesture {
                editedTitle = entry.title
                editingTitle = true
                titleFieldFocused = true
            }
        }
    }

    private func participantsMenu(count: Int) -> some View {
        Menu {
            ForEach(participants) { p in
                Button {
                    renamingParticipant = p.name
                    renameSpeakerName = p.name
                    showRenameSheet = true
                } label: {
                    Text(p.name)
                }
            }
        } label: {
            Text("\(count) participant\(count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.40))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Rename participants")
    }

    private func revealInFinder() {
        if let url = audioURL, entry.audioFileExists {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let url = markdownURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let url = recapURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// A short label for whatever pipeline step is currently running, or nil when idle.
    private var runningStatusText: String? {
        if state.transcribeStep == .running { return "Transcribing…" }
        if state.saveStep == .running { return "Saving…" }
        if state.recapStep == .running { return "Summarizing…" }
        return nil
    }

    private func commitTitleEdit() {
        guard editingTitle else { return }   // avoid double-commit on focus loss
        editingTitle = false
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.title else { return }
        state.renameRecording(entry, to: trimmed)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(DetailTab.allCases) { t in
                tabButton(t)
            }
            Spacer(minLength: 8)
            tabActionIcons
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: Tokens.Window.contentWidth)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func tabButton(_ t: DetailTab) -> some View {
        let selected = tab == t
        return Button { tab = t } label: {
            Text(t.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Tokens.Ink.primary : Tokens.Ink.tertiary)
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selected ? Tokens.Ink.primary : Color.clear)
                        .frame(height: 2)
                }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 18)
    }

    /// Right-aligned icons whose set depends on the active tab.
    @ViewBuilder
    private var tabActionIcons: some View {
        HStack(spacing: 0) {
            switch tab {
            case .transcript:
                if !state.transcript.isEmpty {
                    playPauseButton
                    speakerFilterMenu
                    IconButton(
                        systemName: copiedForChat ? "checkmark" : "doc.on.doc",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .medium
                    ) { copyForChat() }
                    .help("Copy transcript")
                }
            case .notes:
                EmptyView()
            case .recap:
                if recapText?.isEmpty == false {
                    if isEditingRecap {
                        IconButton(
                            systemName: "checkmark",
                            prominence: .minimal,
                            iconSize: 14,
                            weight: .medium
                        ) { commitRecapEdit() }
                        .help("Done editing")
                    } else {
                        IconButton(
                            systemName: "arrow.clockwise",
                            prominence: .minimal,
                            iconSize: 14,
                            weight: .medium
                        ) { Task { await state.regenerateRecap() } }
                        .help("Regenerate summary")
                        IconButton(
                            systemName: copiedRecap ? "checkmark" : "doc.on.doc",
                            prominence: .minimal,
                            iconSize: 14,
                            weight: .medium
                        ) { copyRecapForChat() }
                        .help("Copy summary")
                    }
                } else if state.saveStep == .done || entry.status == "saved" {
                    IconButton(
                        systemName: "arrow.clockwise",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .medium
                    ) { Task { await state.regenerateRecap() } }
                    .help("Generate summary")
                }
            case .followUp:
                if followUpText?.isEmpty == false {
                    if isEditingFollowUp {
                        IconButton(
                            systemName: "checkmark",
                            prominence: .minimal,
                            iconSize: 14,
                            weight: .medium
                        ) { commitFollowUpEdit() }
                        .help("Done editing")
                    } else {
                        IconButton(
                            systemName: "arrow.clockwise",
                            prominence: .minimal,
                            iconSize: 14,
                            weight: .medium
                        ) { draftFollowUpFromSummary() }
                        .help("Regenerate follow-up")
                        IconButton(
                            systemName: copiedFollowUp ? "checkmark" : "doc.on.doc",
                            prominence: .minimal,
                            iconSize: 14,
                            weight: .medium
                        ) { copyFollowUp() }
                        .help("Copy follow-up")
                    }
                } else {
                    IconButton(
                        systemName: "arrow.clockwise",
                        prominence: .minimal,
                        iconSize: 14,
                        weight: .medium,
                        enabled: recapText?.isEmpty == false
                    ) { draftFollowUpFromSummary() }
                    .help("Generate follow-up from summary")
                }
            }
        }
    }

    private var playPauseButton: some View {
        IconButton(
            systemName: player.isPlaying ? "pause.fill" : "play.fill",
            prominence: .minimal,
            iconSize: 13,
            weight: .medium,
            enabled: entry.audioFileExists
        ) {
            togglePlayback()
        }
        .help(player.isPlaying ? "Pause" : "Play")
    }

    private func togglePlayback() {
        guard let url = audioURL, entry.audioFileExists else { return }
        if player.isPlaying {
            player.pause()
        } else {
            followPlaybackScroll = true
            // Prefer resume (keeps scrub position). Fall back to a fresh play
            // if the player was never loaded or AVAudioPlayer.play() failed.
            if player.totalDuration > 0, player.resume() {
                return
            }
            player.play(url: url)
        }
    }

    private var speakerFilterMenu: some View {
        let speakers = state.distinctSpeakerNames(for: entry)
        return Menu {
            Button {
                speakerFilter = []
            } label: {
                if speakerFilter.isEmpty {
                    Label("All speakers", systemImage: "checkmark")
                } else {
                    Text("All speakers")
                }
            }
            if !speakers.isEmpty { Divider() }
            ForEach(speakers, id: \.self) { s in
                Button {
                    if speakerFilter.contains(s) { speakerFilter.remove(s) } else { speakerFilter.insert(s) }
                } label: {
                    if speakerFilter.contains(s) {
                        Label(s, systemImage: "checkmark")
                    } else {
                        Text(s)
                    }
                }
            }
        } label: {
            MinimalIconGlyph(
                systemName: "line.3.horizontal.decrease",
                iconSize: 14,
                emphasized: !speakerFilter.isEmpty
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Filter by speaker")
    }

    /// Merged speaker blocks, optionally narrowed to the speaker filter selection.
    private var displayedTranscriptSegments: [TranscriptSegment] {
        let merged = parsedSegments
        guard !speakerFilter.isEmpty else { return merged }
        return merged.filter { speakerFilter.contains($0.speaker) }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        Group {
            switch tab {
            case .transcript:
                transcriptPanel
            case .notes:
                notesPanel
            case .recap:
                recapPanel
            case .followUp:
                followUpPanel
            }
        }
        .frame(maxWidth: Tokens.Window.contentWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Notes Tab

    private var notesPanel: some View {
        TextEditor(text: $editedNotes)
            .font(.system(size: 14))
            .foregroundStyle(Tokens.Ink.primary)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .onChange(of: editedNotes) { _, newValue in
                Self.cancelNotesSave()
                let commit: () -> Void = {
                    state.updateNotes(entry, to: newValue)
                    Self.pendingNotesValue = nil
                }
                Self.pendingNotesValue = commit
                let work = DispatchWorkItem(block: commit)
                Self.pendingNotesSave = work
                // Auto-save on idle — blur/click-away also flushes via flushPendingNotesSave.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            }
            .onDisappear { Self.flushPendingNotesSave() }
    }

    // MARK: - Recap Tab

    @ViewBuilder
    private var recapPanel: some View {
        if state.recapStep == .running {
            VStack(spacing: 10) {
                Spacer()
                ProgressView().controlSize(.small)
                Text("Generating summary…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.Ink.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEditingRecap {
            TextEditor(text: $editedRecapText)
                .font(.system(size: 14))
                .foregroundStyle(Tokens.Ink.primary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDisappear { commitRecapEdit() }
        } else if let text = recapText, !text.isEmpty {
            ScrollView {
                recapRendered(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                    .onTapGesture { editedRecapText = text; isEditingRecap = true }
            }
        } else {
            emptyTabPlaceholder(
                title: "No summary yet",
                detail: state.recapSkipHint ?? "Summary appears automatically after the call is processed."
            )
        }
    }

    // MARK: - Follow-up Tab

    @ViewBuilder
    private var followUpPanel: some View {
        if isEditingFollowUp {
            TextEditor(text: $editedFollowUpText)
                .font(.system(size: 14))
                .foregroundStyle(Tokens.Ink.primary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDisappear { commitFollowUpEdit() }
        } else if let text = followUpText, !text.isEmpty {
            ScrollView {
                recapRendered(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                    .onTapGesture { editedFollowUpText = text; isEditingFollowUp = true }
            }
        } else {
            emptyTabPlaceholder(
                title: "No follow-up yet",
                detail: "A short outbound note for sending. Generate from the summary, then edit in place."
            )
        }
    }

    private func emptyTabPlaceholder(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.Ink.tertiary)
            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.30))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Minimal markdown rendering: headings, bullets, inline styles.
    /// Good enough for recap files without pulling in a markdown engine.
    private func recapRendered(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("### ") {
                    Text(String(trimmed.dropFirst(4)))
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.top, 6)
                } else if trimmed.hasPrefix("## ") {
                    Text(String(trimmed.dropFirst(3)))
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.2)
                        .padding(.top, 8)
                } else if trimmed.hasPrefix("# ") {
                    Text(String(trimmed.dropFirst(2)))
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.3)
                        .padding(.top, 8)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(Color.white.opacity(0.40))
                        inlineMarkdown(String(trimmed.dropFirst(2)))
                    }
                    .padding(.leading, 4)
                } else if trimmed == "---" {
                    Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 4)
                } else if !trimmed.isEmpty {
                    inlineMarkdown(trimmed)
                }
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Tokens.Ink.primary)
        .textSelection(.enabled)
    }

    private func inlineMarkdown(_ line: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(line)
    }

    /// Resolve the recap markdown file on disk, tolerating a title change since
    /// it was written (the filename embeds the title slug).
    private func resolvedRecapURL() -> URL? {
        if let url = recapURL { return url }
        let dir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
        let prefix = entry.id + "-"
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first {
                $0.pathExtension == "md"
                    && $0.lastPathComponent.hasPrefix(prefix)
                    && $0.lastPathComponent.hasSuffix("-recap.md")
            }
    }

    private func loadRecapText() {
        if let url = resolvedRecapURL() {
            recapText = try? String(contentsOf: url, encoding: .utf8)
        } else {
            recapText = nil
        }
    }

    /// Persist an in-app edit of the summary back to its markdown file.
    private func commitRecapEdit() {
        guard isEditingRecap else { return }
        isEditingRecap = false
        let trimmed = editedRecapText
        guard trimmed != (recapText ?? "") else { return }
        guard let url = resolvedRecapURL() else { return }
        do {
            try trimmed.write(to: url, atomically: true, encoding: .utf8)
            recapText = trimmed
        } catch {
            NSLog("[RecordingDetailView] failed to save summary edit: \(error)")
        }
    }

    private func resolvedFollowUpURL() -> URL? {
        let dir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
        let prefix = entry.id + "-"
        if let hit = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first(where: {
                $0.pathExtension == "md"
                    && $0.lastPathComponent.hasPrefix(prefix)
                    && $0.lastPathComponent.hasSuffix("-followup.md")
            }) {
            return hit
        }
        let slug = MarkdownWriter.slugify(entry.title.isEmpty ? entry.id : entry.title)
        return dir.appendingPathComponent("\(entry.id)-\(slug)-followup.md")
    }

    private func loadFollowUpText() {
        guard let url = resolvedFollowUpURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            followUpText = nil
            return
        }
        followUpText = try? String(contentsOf: url, encoding: .utf8)
    }

    private func commitFollowUpEdit() {
        guard isEditingFollowUp else { return }
        isEditingFollowUp = false
        let trimmed = editedFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (followUpText ?? "").trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard let url = resolvedFollowUpURL() else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try trimmed.write(to: url, atomically: true, encoding: .utf8)
            followUpText = trimmed
        } catch {
            NSLog("[RecordingDetailView] failed to save follow-up edit: \(error)")
        }
    }

    /// MVP: draft a short outbound note from the summary until dedicated LLM follow-up lands.
    private func draftFollowUpFromSummary() {
        loadRecapText()
        guard let summary = recapText?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            return
        }
        let body = Self.compressForFollowUp(summary)
        let draft = "# Follow-up\n\n\(body)\n"
        guard let url = resolvedFollowUpURL() else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try draft.write(to: url, atomically: true, encoding: .utf8)
            followUpText = draft
            editedFollowUpText = draft
            isEditingFollowUp = true
        } catch {
            NSLog("[RecordingDetailView] failed to draft follow-up: \(error)")
        }
    }

    /// Keep headings + bullets; drop long prose paragraphs — outbound-friendly.
    private static func compressForFollowUp(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("•") {
                out.append(line)
            } else if t.count <= 140, !t.isEmpty {
                out.append(line)
            }
        }
        let joined = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty {
            return String(markdown.prefix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return joined
    }

    private func copyFollowUp() {
        let text = (isEditingFollowUp ? editedFollowUpText : followUpText) ?? ""
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedFollowUp = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedFollowUp = false }
    }

    // MARK: - Participants Panel

    private struct Participant: Identifiable {
        let name: String
        let talkTime: Double
        let segmentIndices: [Int]
        var id: String { name }
    }

    private var participants: [Participant] {
        if let segments = state.loadPersistedSegments(for: entry), !segments.isEmpty {
            var order: [String] = []
            var byName: [String: (Double, [Int])] = [:]
            for seg in segments {
                if byName[seg.speaker] == nil {
                    order.append(seg.speaker)
                    byName[seg.speaker] = (0, [])
                }
                var acc = byName[seg.speaker]!
                acc.0 += max(0, seg.endTime - seg.startTime)
                acc.1.append(seg.index)
                byName[seg.speaker] = acc
            }
            return order.map { name in
                let acc = byName[name]!
                return Participant(name: name, talkTime: acc.0, segmentIndices: acc.1)
            }
        }
        // Fallback: names parsed out of the transcript text (no timing data).
        var seen = Set<String>()
        var result: [Participant] = []
        for seg in parsedSegments where !seg.speaker.isEmpty {
            if !seen.contains(seg.speaker) {
                seen.insert(seg.speaker)
                result.append(Participant(name: seg.speaker, talkTime: 0, segmentIndices: []))
            }
        }
        return result
    }

    private var participantsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Participants")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                let list = participants
                if list.isEmpty {
                    Text("Speakers appear here after transcription.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                } else {
                    ForEach(list) { p in
                        participantRow(p)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func participantRow(_ p: Participant) -> some View {
        HStack(spacing: 8) {
            AvatarCircle(name: p.name, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name)
                    .font(.callout)
                    .lineLimit(1)
                if p.talkTime > 0 {
                    Text(compactTalkTime(p.talkTime))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if !p.segmentIndices.isEmpty {
                Menu {
                    Section("Reassign all segments") {
                        reassignMenuContent(for: Set(p.segmentIndices))
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func compactTalkTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 60 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s)s"
    }

    // MARK: - Transcript Tab

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            if state.transcript.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    if state.transcribeStep == .running {
                        if let dl = state.modelDownloadProgress {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                                Text(state.statusMessage.isEmpty ? "Downloading model..." : state.statusMessage)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                ProgressView(value: dl)
                                    .progressViewStyle(.linear)
                                    .frame(width: 240)
                                Text("\(Int(dl * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                            Text(state.statusMessage.isEmpty ? "Transcribing..." : state.statusMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "text.quote")
                            .font(.title)
                            .foregroundStyle(.quaternary)
                        Text("No transcript yet")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                        if entry.status == "transcribed_raw" {
                            Button {
                                Task { await state.completeDiarization() }
                            } label: {
                                Label("Complete Transcription", systemImage: "person.wave.2")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(state.transcribeStep == .running)
                        } else if entry.audioFileExists,
                                  ["recorded", "transcribing"].contains(entry.status)
                                    || state.transcribeStep == .failed {
                            Button {
                                Task { await state.reprocess() }
                            } label: {
                                Label(
                                    state.transcribeStep == .failed ? "Retry Transcription" : "Transcribe",
                                    systemImage: "waveform"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(state.transcribeStep == .running)
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if isEditingTranscript {
                    TextEditor(text: $editedTranscriptText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Tokens.Ink.primary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                } else {
                    karaokeTranscriptList
                }
            }
        }
    }

    /// Karaoke list: past = full contrast, future = dim, current = highlighted.
    /// Manual scroll pauses follow until the next remark click.
    private var karaokeTranscriptList: some View {
        let segs = displayedTranscriptSegments
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { idx, seg in
                        transcriptRow(seg, index: idx)
                            .id(idx)
                    }
                }
                .padding(.vertical, 12)
                .padding(.bottom, 8)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in followPlaybackScroll = false }
            )
            .onChange(of: player.currentTime) { _, t in
                guard player.isPlaying else { return }
                let next = segs.firstIndex { t >= $0.startSeconds && t < $0.endSeconds }
                    ?? segs.lastIndex(where: { t >= $0.startSeconds })
                if next != activeKaraokeID {
                    activeKaraokeID = next
                    if followPlaybackScroll, let next {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(next, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: player.isPlaying) { _, playing in
                if !playing { activeKaraokeID = nil }
                else { followPlaybackScroll = true }
            }
        }
    }

    // MARK: - Clipboard

    private func copyRawTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.transcript, forType: .string)
        copiedTranscript = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTranscript = false }
    }

    private func copyForChat() {
        let text = MarkdownWriter.chatClipboardText(
            title: entry.title,
            transcript: state.transcript,
            duration: entry.duration,
            notes: entry.notes
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedForChat = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedForChat = false }
    }

    private func copyRecapForChat() {
        guard let url = recapURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedRecap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedRecap = false }
    }

    // MARK: - Transcript Editing

    private func commitTranscriptEdit() {
        guard editedTranscriptText != state.transcript else { return }
        state.transcript = editedTranscriptText
        if let id = state.selectedRecordingID {
            state.recordingStore.update(id: id, transcript: editedTranscriptText)
            // Free-text edits invalidate per-segment timing/labels — drop the
            // snapshot so the reassignment UI doesn't operate on stale data.
            state.invalidateSegmentSnapshot(for: id)
        }
        selectedSegmentIndices = []
        state.markDirty()
    }

    // MARK: - Transcript Parsing & Display

    private struct TranscriptSegment {
        let timestamp: String
        let startSeconds: Double
        let endSeconds: Double
        let speaker: String
        let text: String
    }

    private var parsedSegments: [TranscriptSegment] {
        // Prefer timed persisted segments for karaoke; fall back to text parse.
        if let persisted = state.loadPersistedSegments(for: entry), !persisted.isEmpty {
            let mapped = persisted.map { seg in
                TranscriptSegment(
                    timestamp: formatTimestamp(seg.startTime),
                    startSeconds: seg.startTime,
                    endSeconds: max(seg.endTime, seg.startTime + 0.01),
                    speaker: seg.speaker,
                    text: seg.text
                )
            }
            return mergeConsecutiveSpeakers(mapped)
        }
        return mergeConsecutiveSpeakers(rawParsedSegments)
    }

    /// Fold consecutive same-speaker segments into one turn (space-joined),
    /// matching `TranscriptionService.collapseConsecutiveSameSpeaker`. Persisted
    /// ASR slices are fine-grained — joining with blank lines made each phrase
    /// look like its own paragraph with huge gaps.
    private func mergeConsecutiveSpeakers(
        _ segs: [TranscriptSegment],
        maxGap: Double = 5.0
    ) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for seg in segs {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let last = out.last,
               last.speaker == seg.speaker,
               !seg.speaker.isEmpty,
               (seg.startSeconds - last.endSeconds) <= maxGap {
                out[out.count - 1] = TranscriptSegment(
                    timestamp: last.timestamp,
                    startSeconds: last.startSeconds,
                    endSeconds: max(seg.endSeconds, last.endSeconds),
                    speaker: last.speaker,
                    text: last.text + " " + trimmed
                )
            } else {
                out.append(TranscriptSegment(
                    timestamp: seg.timestamp,
                    startSeconds: seg.startSeconds,
                    endSeconds: seg.endSeconds,
                    speaker: seg.speaker,
                    text: trimmed
                ))
            }
        }
        return out
    }

    private var rawParsedSegments: [TranscriptSegment] {
        // Format: [Speaker Name] [MM:SS]\nText\n\n[Speaker Name] [MM:SS]\nText
        let blocks = state.transcript.components(separatedBy: "\n\n")
        var starts: [(ts: String, speaker: String, text: String, start: Double)] = []

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let firstLine = lines.first?.trimmingCharacters(in: .whitespaces),
                  !firstLine.isEmpty else { continue }

            let newPattern = #"^\[(.+?)\]\s*\[(\d+:\d+)\]$"#
            if let regex = try? NSRegularExpression(pattern: newPattern),
               let match = regex.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine)) {
                let speaker = Range(match.range(at: 1), in: firstLine).map { String(firstLine[$0]) } ?? ""
                let ts = Range(match.range(at: 2), in: firstLine).map { String(firstLine[$0]) } ?? ""
                let text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                starts.append((ts, speaker, text, Self.parseTimestamp(ts)))
                continue
            }

            let oldPatterns = [
                #"^\*{0,2}\[(\d+:\d+)\]\s*(.+?):\*{0,2}\s*(.*)"#,
                #"^\[(\d+:\d+)\]\s*(.+?):\s*(.*)"#,
            ]
            var matched = false
            for pattern in oldPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine)) {
                    let ts = Range(match.range(at: 1), in: firstLine).map { String(firstLine[$0]) } ?? ""
                    let speaker = Range(match.range(at: 2), in: firstLine).map { String(firstLine[$0]) } ?? ""
                    var text = Range(match.range(at: 3), in: firstLine).map { String(firstLine[$0]) } ?? firstLine
                    text = text.replacingOccurrences(of: "**", with: "")
                    if let tokenRegex = try? NSRegularExpression(pattern: #"<\|[^|]*\|>"#) {
                        text = tokenRegex.stringByReplacingMatches(
                            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
                        ).trimmingCharacters(in: .whitespaces)
                    }
                    guard !text.isEmpty else { break }
                    starts.append((ts, speaker, text, Self.parseTimestamp(ts)))
                    matched = true
                    break
                }
            }
            if !matched {
                starts.append(("", "", firstLine, 0))
            }
        }

        let fallbackEnd = max(entry.duration, starts.last.map(\.start) ?? 0) + 1
        return starts.enumerated().map { i, item in
            let end = i + 1 < starts.count ? starts[i + 1].start : fallbackEnd
            return TranscriptSegment(
                timestamp: item.ts,
                startSeconds: item.start,
                endSeconds: max(end, item.start + 0.01),
                speaker: item.speaker,
                text: item.text
            )
        }
    }

    private static func parseTimestamp(_ ts: String) -> Double {
        let parts = ts.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    private func transcriptRow(_ seg: TranscriptSegment, index: Int) -> some View {
        let playing = player.isPlaying
        let t = player.currentTime
        let isCurrent = playing && t >= seg.startSeconds && t < seg.endSeconds
        let isFuture = playing && t < seg.startSeconds
        let opacity = isFuture ? 0.35 : 1.0

        return HStack(alignment: .top, spacing: 10) {
            if !seg.speaker.isEmpty {
                Text(seg.speaker.prefix(1).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(colorFor(speaker: seg.speaker).opacity(isFuture ? 0.45 : 1)))
            }

            VStack(alignment: .leading, spacing: 2) {
                if !seg.speaker.isEmpty {
                    HStack(spacing: 6) {
                        Text(seg.speaker)
                            .font(.system(size: 13, weight: .medium))
                        if !seg.timestamp.isEmpty {
                            Text(seg.timestamp)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.white.opacity(0.30))
                        }
                    }
                }
                Text(seg.text)
                    .font(.system(size: 14, weight: .medium))
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Tokens.Ink.primary)
        .opacity(opacity)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isCurrent ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            followPlaybackScroll = true
            activeKaraokeID = index
            seekToSeconds(seg.startSeconds)
        }
        .animation(.easeOut(duration: 0.12), value: isCurrent)
        .animation(.easeOut(duration: 0.12), value: isFuture)
    }

    private func colorFor(speaker: String) -> Color {
        let hash = abs(speaker.hashValue)
        return speakerColors[hash % speakerColors.count]
    }

    // MARK: - Reassignable Transcript Rows

    private func reassignableRow(_ seg: PersistedSegment) -> some View {
        let selected = selectedSegmentIndices.contains(seg.index)
        let timestamp = formatTimestamp(seg.startTime)

        return HStack(alignment: .top, spacing: 10) {
            Text(seg.speaker.prefix(1).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(colorFor(speaker: seg.speaker)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(seg.speaker)
                        .font(.subheadline.weight(.medium))
                    Button {
                        seekToSeconds(seg.startTime)
                    } label: {
                        Text(timestamp)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Play from \(timestamp)")

                    Spacer()

                    reassignMenu(for: seg)
                        .opacity(selected ? 1 : 0.0001)
                }
                Text(seg.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineSpacing(3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if selectedSegmentIndices.contains(seg.index) {
                selectedSegmentIndices.remove(seg.index)
            } else {
                selectedSegmentIndices.insert(seg.index)
            }
        }
        .contextMenu {
            reassignMenuContent(for: [seg.index])
        }
    }

    private func reassignToolbar(selected: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(selected) segment\(selected == 1 ? "" : "s") selected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Button("Clear") {
                selectedSegmentIndices = []
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Spacer()

            Menu {
                reassignMenuContent(for: selectedSegmentIndices)
            } label: {
                Label("Reassign to…", systemImage: "person.crop.circle.badge.plus")
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    private func reassignMenu(for seg: PersistedSegment) -> some View {
        Menu {
            reassignMenuContent(for: [seg.index])
        } label: {
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 22)
    }

    @ViewBuilder
    private func reassignMenuContent(for indices: Set<Int>) -> some View {
        let speakers = state.distinctSpeakerNames(for: entry)

        if !speakers.isEmpty {
            Section("Existing speaker label") {
                ForEach(speakers, id: \.self) { name in
                    Button(name) {
                        applyReassignment(name, indices: indices)
                    }
                }
            }
            Divider()
        }

        Button {
            renameSpeakerName = ""
            // Stash the selection so the sheet's Save commits to the right
            // segments even after the user clicks elsewhere.
            selectedSegmentIndices = indices
            showRenameSheet = true
        } label: {
            Label("New name…", systemImage: "person.badge.plus")
        }
    }

    private func applyReassignment(_ name: String, indices: Set<Int>) {
        Task {
            await state.reassignSegments(indices, toName: name)
            selectedSegmentIndices = []
        }
    }

    private var renameSpeakerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename speaker")
                .font(.headline)
            Text(
                renamingParticipant != nil
                    ? "Renames every line for this speaker in the transcript."
                    : "Renames the selected segment\(selectedSegmentIndices.count == 1 ? "" : "s") — just a text label."
            )
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Name", text: $renameSpeakerName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitRename() }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showRenameSheet = false
                    renameSpeakerName = ""
                    renamingParticipant = nil
                }
                Button("Save") { submitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameSpeakerName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submitRename() {
        let name = renameSpeakerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let indices: Set<Int>
        if let from = renamingParticipant {
            if let segs = state.loadPersistedSegments(for: entry) {
                indices = Set(segs.filter { $0.speaker == from }.map(\.index))
            } else if let p = participants.first(where: { $0.name == from }) {
                indices = Set(p.segmentIndices)
            } else {
                indices = []
            }
        } else {
            indices = selectedSegmentIndices
        }
        showRenameSheet = false
        renameSpeakerName = ""
        renamingParticipant = nil
        guard !indices.isEmpty else { return }
        Task {
            await state.reassignSegments(indices, toName: name)
            selectedSegmentIndices = []
        }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func seekToSeconds(_ seconds: Double) {
        guard let url = audioURL else { return }
        if player.totalDuration <= 0 {
            player.load(url: url)
        }
        guard player.totalDuration > 0 else { return }
        let fraction = max(0, min(1, seconds / player.totalDuration))
        player.seek(to: fraction)
        if !player.resume() {
            player.play(url: url)
            player.seek(to: fraction)
            _ = player.resume()
        }
    }

    /// Seek the audio player to the given MM:SS (or H:MM:SS) timestamp and start playing.
    private func seekToTimestamp(_ timestamp: String) {
        let parts = timestamp.split(separator: ":").map(String.init)
        let seconds: Double
        switch parts.count {
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return }
            seconds = m * 60 + s
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return }
            seconds = h * 3600 + m * 60 + s
        default:
            return
        }
        seekToSeconds(seconds)
    }

    /// Pre-load the audio file when the detail view appears or the selected
    /// recording changes, so `totalDuration` is known and the user can scrub
    /// before pressing Play. Skipped if the player is currently playing
    /// (would cancel that session).
    private func autoLoadAudioForPlayer() {
        guard !player.isPlaying else { return }
        guard player.totalDuration <= 0 else { return }
        if let url = audioURL {
            player.load(url: url)
        }
    }
}
