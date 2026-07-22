import SwiftUI

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
            case .transcript: return "Transcript"
            case .notes: return "Notes"
            case .recap: return "Summary"
            }
        }
    }

    @State private var tab: DetailTab = .transcript
    @State private var showParticipants = true
    @State private var recapText: String?

    @State private var showingDeleteConfirm = false
    @State private var showingRemoveConfirm = false
    @State private var copiedTranscript = false
    @State private var copiedForChat = false
    @State private var copiedRecap = false
    @State private var editingTitle = false
    @State private var editedTitle = ""
    @State private var editedNotes = ""
    @State private var isEditingTranscript = false
    @State private var editedTranscriptText = ""
    @State private var selectedSegmentIndices: Set<Int> = []
    @State private var showNewPersonSheet = false
    @State private var newPersonName = ""

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
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                detailHeader

                if presentation == .meeting, audioURL != nil {
                    WaveformScrubber(player: state.player, audioURL: audioURL)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }

                Divider()

                if presentation == .meeting, !state.pendingSpeakers.isEmpty {
                    SpeakerConfirmationView(state: state)
                }

                if presentation == .meeting {
                    tabBar
                    Divider()
                    tabContent
                        .frame(maxHeight: .infinity)
                } else {
                    summaryFocusContent
                        .frame(maxHeight: .infinity)
                }
            }

            if presentation == .meeting, showParticipants {
                Divider()
                participantsPanel
                    .frame(width: 220)
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
        .sheet(isPresented: $showNewPersonSheet) {
            newPersonSheet
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if editingTitle {
                    TextField("Title", text: $editedTitle)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .onSubmit {
                            state.renameRecording(entry, to: editedTitle)
                            editingTitle = false
                        }
                        .onExitCommand { editingTitle = false }
                } else {
                    HStack(spacing: 6) {
                        Group {
                            if entry.title.isEmpty {
                                Text("Untitled")
                                    .italic()
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(entry.title)
                            }
                        }
                        .font(.title2.weight(.semibold))

                        Button {
                            editedTitle = entry.title
                            editingTitle = true
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit title")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        editedTitle = entry.title
                        editingTitle = true
                    }
                }

                HStack(spacing: 8) {
                    Text(entry.dateFormatted)
                    if entry.duration > 0 {
                        Text("·"); Text(entry.durationFormatted)
                    }
                    if state.micOnlyRecording {
                        Text("Mic only")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !state.skippedSpeakers.isEmpty {
                Button {
                    state.repromptSkippedSpeakers()
                } label: {
                    Label("\(state.skippedSpeakers.count) skipped — re-prompt", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-prompt \(state.skippedSpeakers.count) skipped speaker(s)")
            } else if state.pendingSpeakers.isEmpty {
                let unresolvedCount = state.unresolvedSpeakerCount(for: entry)
                if unresolvedCount > 0 {
                    Button {
                        state.reopenSpeakerTagging()
                    } label: {
                        Label("Tag \(unresolvedCount) speaker\(unresolvedCount == 1 ? "" : "s")", systemImage: "person.badge.clock")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Re-open speaker confirmation for this recording")
                }
            }

            HStack(spacing: 6) {
                statusPill("Transcribed", step: state.transcribeStep)
                statusPill("Saved", step: state.saveStep)
                statusPill("Summary", step: state.recapStep)
            }

            Button {
                showParticipants.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(showParticipants ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(showParticipants ? "Hide participants" : "Show participants")

            Menu {
                Picker("Language", selection: Binding(
                    get: { entry.language ?? "" },
                    set: { newValue in
                        state.setLanguage(entry, to: newValue.isEmpty ? nil : newValue)
                    }
                )) {
                    Text("Auto").tag("")
                    Text("Danish").tag("da")
                    Text("English").tag("en")
                }
                Divider()
                Button("Reveal audio in Finder") {
                    if let url = audioURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(!entry.audioFileExists)
                Button("Reveal markdown in Finder") {
                    if let url = markdownURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(markdownURL == nil)
                Button("Reveal summary in Finder") {
                    if let url = recapURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(recapURL == nil)
                Divider()
                Button("Delete audio file") { showingDeleteConfirm = true }
                Divider()
                Button("Remove entirely", role: .destructive) { showingRemoveConfirm = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func statusPill(_ label: String, step: PipelineStep) -> some View {
        HStack(spacing: 4) {
            Group {
                switch step {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running:
                    ProgressView().controlSize(.mini)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.quaternary)
                }
            }
            .symbolRenderingMode(.hierarchical)
            Text(label)
                .foregroundStyle(step == .done ? .primary : .secondary)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            actionButtons
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !state.transcript.isEmpty {
            Button {
                copyForChat()
            } label: {
                Label(
                    copiedForChat ? "Copied" : "Copy for chat",
                    systemImage: copiedForChat ? "checkmark" : "bubble.left.and.bubble.right"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(copiedForChat ? .green : nil)
            .help("Copy readable transcript for pasting into chat")
        }

        if tab == .recap, recapURL != nil {
            Button {
                copyRecapForChat()
            } label: {
                Label(
                    copiedRecap ? "Copied" : "Copy summary",
                    systemImage: copiedRecap ? "checkmark" : "doc.text"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(copiedRecap ? .green : nil)
            .help("Copy summary markdown for pasting into chat")
        }

        if entry.status == "transcribed_raw" && entry.audioFileExists {
            Button {
                Task { await state.completeDiarization() }
            } label: {
                if state.transcribeStep == .running {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Identifying speakers...")
                    }
                } else {
                    Label("Complete Transcription", systemImage: "person.wave.2")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(state.transcribeStep == .running)
        }

        Button {
            Task { await state.runTranscribe() }
        } label: {
            if state.transcribeStep == .running && entry.status != "transcribed_raw" {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Transcribing...")
                }
            } else {
                Label(
                    (state.transcribeStep == .done || entry.status == "transcribed_raw") ? "Re-transcribe" : "Transcribe",
                    systemImage: "waveform.badge.mic"
                )
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(state.transcribeStep == .running || !entry.audioFileExists)

        Button {
            // Flush any pending debounced notes save so the markdown gets the freshest notes.
            if isEditingTranscript { commitTranscriptEdit() }
            Self.flushPendingNotesSave()
            Task { await state.runSave() }
        } label: {
            if state.saveStep == .running {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Saving...")
                }
            } else if state.recapStep == .running {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Summary...")
                }
            } else if state.saveStep == .done {
                Label("Saved", systemImage: "checkmark.circle.fill")
            } else {
                Label("Save", systemImage: "square.and.arrow.down")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(state.saveStep == .done && state.recapStep != .failed ? .green : nil)
        .disabled(state.transcript.isEmpty || state.saveStep == .running || state.recapStep == .running)

        if state.saveStep == .done {
            Button {
                Task { await state.regenerateRecap() }
            } label: {
                Label(
                    state.recapStep == .done ? "Re-summarize" : "Summarize",
                    systemImage: "sparkles"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.recapStep == .running)
        }
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
        } else if let text = recapText, !text.isEmpty {
            ScrollView {
                recapRendered(text)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                if let hint = state.recapSkipHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                if state.saveStep == .done {
                    Button {
                        Task { await state.regenerateRecap() }
                    } label: {
                        Label("Generate summary", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text("Save the transcript first — summary is generated after saving.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
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

    private func loadRecapText() {
        if let url = recapURL {
            recapText = try? String(contentsOf: url, encoding: .utf8)
            return
        }
        // Fallback: title may have changed after the file was written.
        let dir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
        let prefix = entry.id + "-"
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
           let match = files.first(where: {
               $0.pathExtension == "md"
                   && $0.lastPathComponent.hasPrefix(prefix)
                   && $0.lastPathComponent.hasSuffix("-recap.md")
           }) {
            recapText = try? String(contentsOf: match, encoding: .utf8)
        } else {
            recapText = nil
        }
    }

    // MARK: - Participants Panel

    private struct Participant: Identifiable {
        let name: String
        let personID: UUID?
        let talkTime: Double
        let segmentIndices: [Int]
        var id: String { name }
    }

    private var participants: [Participant] {
        if let segments = state.loadPersistedSegments(for: entry), !segments.isEmpty {
            var order: [String] = []
            var byName: [String: (UUID?, Double, [Int])] = [:]
            for seg in segments {
                if byName[seg.speaker] == nil {
                    order.append(seg.speaker)
                    byName[seg.speaker] = (seg.personID, 0, [])
                }
                var acc = byName[seg.speaker]!
                acc.1 += max(0, seg.endTime - seg.startTime)
                acc.2.append(seg.index)
                if acc.0 == nil { acc.0 = seg.personID }
                byName[seg.speaker] = acc
            }
            return order.map { name in
                let acc = byName[name]!
                return Participant(name: name, personID: acc.0, talkTime: acc.1, segmentIndices: acc.2)
            }
        }
        // Fallback: names parsed out of the transcript text (no timing data).
        var seen = Set<String>()
        var result: [Participant] = []
        for seg in parsedSegments where !seg.speaker.isEmpty {
            if !seen.contains(seg.speaker) {
                seen.insert(seg.speaker)
                result.append(Participant(name: seg.speaker, personID: nil, talkTime: 0, segmentIndices: []))
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
        .background(.background.secondary)
    }

    private func participantRow(_ p: Participant) -> some View {
        HStack(spacing: 8) {
            AvatarCircle(name: p.name, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(p.name)
                        .font(.callout)
                        .lineLimit(1)
                    if p.personID != nil {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .help("Linked to a saved person")
                    }
                }
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
                } else if let segments = state.loadPersistedSegments(for: entry), !segments.isEmpty {
                    if !selectedSegmentIndices.isEmpty {
                        reassignToolbar(selected: selectedSegmentIndices.count)
                        Divider()
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(segments) { seg in
                                reassignableRow(seg)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.bottom, 8)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(parsedSegments.enumerated()), id: \.offset) { _, seg in
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
        let people = state.peopleStore.people
        let speakers = state.distinctSpeakerNames(for: entry)

        if !people.isEmpty {
            Section("Existing person") {
                ForEach(people) { person in
                    Button(person.name) {
                        applyReassignment(.existingPerson(person), indices: indices)
                    }
                }
            }
        }

        if !speakers.isEmpty {
            Section("Existing speaker label") {
                ForEach(speakers, id: \.self) { name in
                    Button(name) {
                        applyReassignment(.existingSpeakerName(name), indices: indices)
                    }
                }
            }
        }

        Divider()

        Button {
            newPersonName = ""
            // Stash the selection so the sheet's Save commits to the right
            // segments even after the user clicks elsewhere.
            selectedSegmentIndices = indices
            showNewPersonSheet = true
        } label: {
            Label("New person…", systemImage: "person.badge.plus")
        }
    }

    private func applyReassignment(_ target: AppState.SegmentReassignTarget, indices: Set<Int>) {
        Task {
            await state.reassignSegments(indices, to: target)
            selectedSegmentIndices = []
        }
    }

    private var newPersonSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create new person")
                .font(.headline)
            Text("A voice sample from the selected segment\(selectedSegmentIndices.count == 1 ? "" : "s") will be added to their profile.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Name", text: $newPersonName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitNewPerson() }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showNewPersonSheet = false
                    newPersonName = ""
                }
                Button("Create") { submitNewPerson() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPersonName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submitNewPerson() {
        let name = newPersonName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let indices = selectedSegmentIndices
        showNewPersonSheet = false
        newPersonName = ""
        Task {
            await state.reassignSegments(indices, to: .newPerson(name: name))
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
