import SwiftUI

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
    let entry: RecordingEntry
    /// `.meeting` — full Transcript/Notes/Summary tabs.
    /// `.summaryFocus` — Summaries library: Summary + Notes only (stacked).
    var presentation: Presentation = .meeting

    enum Presentation {
        case meeting
        case summaryFocus
    }

    enum DetailTab: String, CaseIterable, Identifiable {
        case transcript
        case notes
        case recap
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcript: return "Transcription"
            case .notes: return "Notes"
            case .recap: return "Summary"
            }
        }
    }

    @State private var tab: DetailTab = .recap   // Summary is the default view
    @State private var showParticipants = true
    @State private var recapText: String?

    @State private var showingDeleteConfirm = false
    @State private var showingRemoveConfirm = false
    @State private var copiedTranscript = false
    @State private var copiedForChat = false
    @State private var copiedRecap = false
    @State private var editingTitle = false
    @State private var editedTitle = ""
    @State private var titleHovered = false
    @FocusState private var titleFieldFocused: Bool
    @State private var editedNotes = ""
    @State private var isEditingTranscript = false
    @State private var editedTranscriptText = ""
    @State private var isEditingRecap = false
    @State private var editedRecapText = ""
    @State private var speakerFilter: Set<String> = []
    @State private var selectedSegmentIndices: Set<Int> = []
    @State private var showRenameSheet = false
    @State private var renameSpeakerName = ""

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
            // Flush any pending debounced notes save so we don't lose keystrokes.
            Self.flushPendingNotesSave()
            editingTitle = false
            isEditingTranscript = false
            selectedSegmentIndices = []
            editedNotes = entry.notes ?? ""
            recapText = nil
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
            applyPreferredTab()
        }
        .onChange(of: entry.id) { _, _ in
            if presentation == .meeting { autoLoadAudioForPlayer() }
            loadRecapText()
        }
        .onChange(of: state.preferredDetailTab) { _, _ in
            applyPreferredTab()
        }
        .task(id: "\(entry.id)-\(state.recapStep.rawValue)-\(tab.rawValue)-\(presentation)") {
            if tab == .recap || presentation == .summaryFocus { loadRecapText() }
        }
    }

    private func applyPreferredTab() {
        guard presentation == .meeting, let raw = state.preferredDetailTab else { return }
        let mapped: DetailTab?
        switch raw {
        case "transcript": mapped = .transcript
        case "notes": mapped = .notes
        case "recap", "summary": mapped = .recap
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

    // MARK: - Header

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Meta line: date · participant count, with the … menu trailing.
            HStack(spacing: 14) {
                Text(entry.dateFormatted)
                let count = state.distinctSpeakerNames(for: entry).count
                if count > 0 {
                    Text("\(count) participant\(count == 1 ? "" : "s")")
                }
                if state.micOnlyRecording {
                    Text("Mic only").foregroundStyle(.orange)
                }
                Spacer()
                if let running = runningStatusText {
                    Text(running)
                }
                headerMenu
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            titleField
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    /// Large serif meeting title, editable on hover → click (Enter / click-away commits).
    @ViewBuilder
    private var titleField: some View {
        let titleFont = Font.system(size: 34, weight: .medium, design: .serif)
        if editingTitle {
            TextField("Title", text: $editedTitle)
                .textFieldStyle(.plain)
                .font(titleFont)
                .focused($titleFieldFocused)
                .onSubmit { commitTitleEdit() }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused { commitTitleEdit() }
                }
                .onExitCommand { editingTitle = false }
        } else {
            HStack(spacing: 10) {
                Group {
                    if entry.title.isEmpty {
                        Text("Untitled").italic().foregroundStyle(.secondary)
                    } else {
                        Text(entry.title)
                    }
                }
                .font(titleFont)

                Image(systemName: "pencil")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
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

    private var headerMenu: some View {
        Menu {
            Button("Reveal audio in Finder") {
                if let url = audioURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(!entry.audioFileExists)
            Button("Reveal summary in Finder") {
                if let url = recapURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(recapURL == nil)
            Divider()
            Button("Delete audio file") { showingDeleteConfirm = true }
            Button("Remove entirely", role: .destructive) { showingRemoveConfirm = true }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
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
            Spacer()
            tabActionIcons
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func tabButton(_ t: DetailTab) -> some View {
        let selected = tab == t
        return Button { tab = t } label: {
            Text(t.title)
                .font(.system(size: 15, weight: .medium))   // constant weight — no jump on select
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selected ? Color.primary : Color.clear)
                        .frame(height: 2)
                }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 22)
    }

    /// Right-aligned icons whose set depends on the active tab.
    @ViewBuilder
    private var tabActionIcons: some View {
        switch tab {
        case .transcript:
            if !state.transcript.isEmpty {
                speakerFilterMenu
                tabIcon(copiedForChat ? "checkmark" : "doc.on.doc",
                        help: "Copy transcript",
                        tint: copiedForChat ? .green : .secondary) { copyForChat() }
            }
        case .notes:
            EmptyView()
        case .recap:
            if let text = recapText, !text.isEmpty {
                if isEditingRecap {
                    tabIcon("checkmark.circle", help: "Done editing") { commitRecapEdit() }
                } else {
                    tabIcon("arrow.clockwise", help: "Re-generate summary") {
                        Task { await state.regenerateRecap() }
                    }
                    tabIcon(copiedRecap ? "checkmark" : "doc.on.doc",
                            help: "Copy summary",
                            tint: copiedRecap ? .green : .secondary) { copyRecapForChat() }
                }
            }
        }
    }

    private func tabIcon(_ system: String, help: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 15))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .padding(.leading, 14)
        .help(help)
    }

    private var speakerFilterMenu: some View {
        let speakers = state.distinctSpeakerNames(for: entry)
        return Menu {
            Button {
                speakerFilter = []
            } label: {
                Label("All speakers", systemImage: speakerFilter.isEmpty ? "checkmark" : "circle")
            }
            Divider()
            ForEach(speakers, id: \.self) { s in
                Button {
                    if speakerFilter.contains(s) { speakerFilter.remove(s) } else { speakerFilter.insert(s) }
                } label: {
                    Label(s, systemImage: speakerFilter.contains(s) ? "checkmark" : "circle")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(speakerFilter.isEmpty ? Color.secondary : Color.accentColor)
        .help("Show only selected speakers")
    }

    @ViewBuilder
    /// Merged speaker blocks, optionally narrowed to the speaker filter selection.
    private var displayedTranscriptSegments: [TranscriptSegment] {
        let merged = parsedSegments
        guard !speakerFilter.isEmpty else { return merged }
        return merged.filter { speakerFilter.contains($0.speaker) }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .transcript:
            transcriptPanel
        case .notes:
            notesPanel
        case .recap:
            recapPanel
        }
    }

    // MARK: - Notes Tab

    private var notesPanel: some View {
        TextEditor(text: $editedNotes)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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

    // MARK: - Recap Tab

    @ViewBuilder
    private var recapPanel: some View {
        if state.recapStep == .running {
            VStack(spacing: 10) {
                Spacer()
                ProgressView().controlSize(.small)
                Text("Generating summary...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEditingRecap {
            TextEditor(text: $editedRecapText)
                .font(.body)
                .monospaced(false)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text = recapText, !text.isEmpty {
            ScrollView {
                recapRendered(text)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // Click anywhere in the summary to edit it (no pencil button).
                    .onTapGesture { editedRecapText = text; isEditingRecap = true }
            }
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(.quaternary)
                Text("No summary yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Text(state.recapSkipHint ?? "The summary is written automatically after a call.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Minimal markdown rendering: headings, bullets, inline styles.
    /// Good enough for recap files without pulling in a markdown engine.
    private func recapRendered(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("### ") {
                    Text(String(trimmed.dropFirst(4)))
                        .font(.headline)
                        .padding(.top, 6)
                } else if trimmed.hasPrefix("## ") {
                    Text(String(trimmed.dropFirst(3)))
                        .font(.title3.weight(.semibold))
                        .padding(.top, 8)
                } else if trimmed.hasPrefix("# ") {
                    Text(String(trimmed.dropFirst(2)))
                        .font(.title2.weight(.semibold))
                        .padding(.top, 8)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inlineMarkdown(String(trimmed.dropFirst(2)))
                    }
                    .padding(.leading, 4)
                } else if trimmed == "---" {
                    Divider().padding(.vertical, 4)
                } else if !trimmed.isEmpty {
                    inlineMarkdown(trimmed)
                }
            }
        }
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
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Spacer()
                    Button {
                        if isEditingTranscript {
                            commitTranscriptEdit()
                        }
                        isEditingTranscript.toggle()
                        if isEditingTranscript {
                            editedTranscriptText = state.transcript
                        }
                    } label: {
                        Label(isEditingTranscript ? "Done" : "Edit", systemImage: isEditingTranscript ? "checkmark.circle" : "pencil")
                            .foregroundStyle(isEditingTranscript ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isEditingTranscript ? "Finish editing" : "Edit transcript")

                    Button {
                        copyRawTranscript()
                    } label: {
                        Image(systemName: copiedTranscript ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copiedTranscript ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy raw transcript")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)

                if isEditingTranscript {
                    TextEditor(text: $editedTranscriptText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                } else {
                    // One block per speaker turn: consecutive same-speaker segments
                    // are merged (pauses become blank lines). Speaker renaming lives
                    // in the participants panel, so per-segment rows aren't needed here.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(displayedTranscriptSegments.enumerated()), id: \.offset) { _, seg in
                                transcriptRow(seg)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.bottom, 8)
                    }
                }
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
        let speaker: String
        let text: String
    }

    private var parsedSegments: [TranscriptSegment] {
        mergeConsecutiveSpeakers(rawParsedSegments)
    }

    /// Fold consecutive segments from the same speaker into one block. Pauses
    /// (the gaps that kept them as separate blocks) become blank lines within
    /// the block, so one speaker reads as one turn, not a stutter of avatars.
    private func mergeConsecutiveSpeakers(_ segs: [TranscriptSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for seg in segs {
            if let last = out.last, last.speaker == seg.speaker, !seg.speaker.isEmpty {
                out[out.count - 1] = TranscriptSegment(
                    timestamp: last.timestamp,          // keep the block's start time
                    speaker: last.speaker,
                    text: last.text + "\n\n" + seg.text // blank line marks the pause
                )
            } else {
                out.append(seg)
            }
        }
        return out
    }

    private var rawParsedSegments: [TranscriptSegment] {
        // Format: [Speaker Name] [MM:SS]\nText\n\n[Speaker Name] [MM:SS]\nText
        let blocks = state.transcript.components(separatedBy: "\n\n")

        return blocks.compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let firstLine = lines.first?.trimmingCharacters(in: .whitespaces),
                  !firstLine.isEmpty else { return nil }

            // Try new format: [Speaker Name] [MM:SS]
            let newPattern = #"^\[(.+?)\]\s*\[(\d+:\d+)\]$"#
            if let regex = try? NSRegularExpression(pattern: newPattern),
               let match = regex.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine)) {
                let speaker = Range(match.range(at: 1), in: firstLine).map { String(firstLine[$0]) } ?? ""
                let ts = Range(match.range(at: 2), in: firstLine).map { String(firstLine[$0]) } ?? ""
                let text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(timestamp: ts, speaker: speaker, text: text)
            }

            // Fallback: old format [MM:SS] Speaker: text or **[MM:SS] Speaker:** text
            let oldPatterns = [
                #"^\*{0,2}\[(\d+:\d+)\]\s*(.+?):\*{0,2}\s*(.*)"#,
                #"^\[(\d+:\d+)\]\s*(.+?):\s*(.*)"#,
            ]
            for pattern in oldPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine)) {
                    let ts = Range(match.range(at: 1), in: firstLine).map { String(firstLine[$0]) } ?? ""
                    let speaker = Range(match.range(at: 2), in: firstLine).map { String(firstLine[$0]) } ?? ""
                    var text = Range(match.range(at: 3), in: firstLine).map { String(firstLine[$0]) } ?? firstLine
                    text = text.replacingOccurrences(of: "**", with: "")
                    // Strip legacy ASR special tokens if present
                    if let tokenRegex = try? NSRegularExpression(pattern: #"<\|[^|]*\|>"#) {
                        text = tokenRegex.stringByReplacingMatches(
                            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
                        ).trimmingCharacters(in: .whitespaces)
                    }
                    guard !text.isEmpty else { return nil }
                    return TranscriptSegment(timestamp: ts, speaker: speaker, text: text)
                }
            }

            // Plain text fallback
            return TranscriptSegment(timestamp: "", speaker: "", text: firstLine)
        }
    }

    private func transcriptRow(_ seg: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !seg.speaker.isEmpty {
                Text(seg.speaker.prefix(1).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(colorFor(speaker: seg.speaker)))
            }

            VStack(alignment: .leading, spacing: 2) {
                if !seg.speaker.isEmpty {
                    HStack(spacing: 6) {
                        Text(seg.speaker)
                            .font(.subheadline.weight(.medium))
                        Button {
                            seekToTimestamp(seg.timestamp)
                        } label: {
                            Text(seg.timestamp)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Play from \(seg.timestamp)")
                    }
                }
                Text(seg.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineSpacing(3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
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
            Text("Renames the selected segment\(selectedSegmentIndices.count == 1 ? "" : "s") — just a text label, no voice profile involved.")
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
        let indices = selectedSegmentIndices
        showRenameSheet = false
        renameSpeakerName = ""
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
        if state.player.totalDuration <= 0 {
            state.player.load(url: url)
        }
        guard state.player.totalDuration > 0 else { return }
        let fraction = max(0, min(1, seconds / state.player.totalDuration))
        state.player.seek(to: fraction)
        state.player.resume()
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
        guard let url = audioURL else { return }
        // Load on first use so totalDuration is known. `load` leaves the player
        // ready but paused, so seek + resume plays from the desired position
        // (calling `play(url:)` would reset to 0 — wrong for tap-to-seek).
        if state.player.totalDuration <= 0 {
            state.player.load(url: url)
        }
        guard state.player.totalDuration > 0 else { return }
        let fraction = max(0, min(1, seconds / state.player.totalDuration))
        state.player.seek(to: fraction)
        state.player.resume()
    }

    /// Pre-load the audio file when the detail view appears or the selected
    /// recording changes, so `totalDuration` is known and the user can scrub
    /// before pressing Play. Skipped if the player is currently playing
    /// (would cancel that session).
    private func autoLoadAudioForPlayer() {
        guard !state.player.isPlaying else { return }
        guard state.player.totalDuration <= 0 else { return }
        if let url = audioURL {
            state.player.load(url: url)
        }
    }
}
