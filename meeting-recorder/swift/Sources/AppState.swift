import AVFoundation
import SwiftUI

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false

    // Recording
    @Published var recorder = AudioRecorder()
    @Published var player = AudioPlayer()
    @Published var elapsedString = "00:00"
    @Published var elapsedSeconds: TimeInterval = 0
    private var displayTimer: Timer?

    // Pipeline
    @Published var transcript = ""
    @Published var transcribeStep: PipelineStep = .pending
    @Published var saveStep: PipelineStep = .pending
    @Published var recapStep: PipelineStep = .pending
    @Published var statusMessage = ""
    /// Hint when recap was skipped (no Ollama / no API key). Cleared on next successful recap.
    @Published var recapSkipHint: String? = nil
    @Published var lastRecapPath: String? = nil
    @Published var recordingDuration: TimeInterval = 0
    /// Model download progress 0.0–1.0. Nil when no download is active.
    @Published var modelDownloadProgress: Double? = nil
    /// Latched true when a recording was completed without system audio capture.
    /// Survives into the detail view so "Mic only" can be shown in the header.
    @Published var micOnlyRecording = false

    // Post-transcription: all speakers pending confirmation
    @Published var pendingSpeakers: [DetectedSpeaker] = []
    @Published var skippedSpeakers: [DetectedSpeaker] = []

    // Surfaced when a speaker is assigned to a person whose existing samples
    // are very dissimilar — catches mis-attribution before we corrupt the
    // person's voice profile.
    @Published var pendingContamination: ContaminationWarning?

    // Selection
    @Published var selectedRecordingID: String?

    // Recovery
    @Published var recoveredCount = 0

    // Window
    @Published var isWindowOpen = false
    @Published var showPeople = false
    @Published var showOnboarding = false
    @Published var showMicPermissionAlert = false
    @Published var zoomMeetingDetected = false
    @Published var diskSpaceWarning: String?
    @Published var showDiskSpaceAlert = false
    /// When set, MainView switches to this sidebar section (e.g. after pipeline).
    @Published var preferredSidebarSection: String?
    /// When set, RecordingDetailView selects this tab (`transcript` / `notes` / `recap`).
    @Published var preferredDetailTab: String?
    private var diskSpaceContinuation: CheckedContinuation<Bool, Never>?

    /// True when the current recording was started because of a Zoom meeting.
    private var recordingLinkedToZoom = false
    /// User cancelled auto-recording for the current Zoom meeting — don't restart it.
    private var ignoredZoomMeeting = false
    /// Set right before an auto-start so `beginRecording` knows to post the
    /// interactive "recording started" notification (manual starts don't).
    private var autoStartedFromMeeting = false

    // Stores & Services
    let recordingStore = RecordingStore()
    let peopleStore = PeopleStore()
    let transcriptionService = TranscriptionService()
    private let zoomDetector = ZoomMeetingDetector.shared

    var selectedRecording: RecordingEntry? {
        guard let id = selectedRecordingID else { return nil }
        return recordingStore.recording(for: id)
    }

    // Global hotkey
    private var globalHotkeyMonitor: Any?

    // MARK: - Initialization

    func bootstrap() {
        recordingStore.load()
        recoveredCount = recordingStore.recoverInterruptedRecordings()
        peopleStore.loadAll()
        recordingStore.performRetentionCleanup()
        NotificationManager.shared.configure()
        NotificationManager.shared.onCancelRecording = { [weak self] in
            self?.cancelRecording()
        }
        setupGlobalHotkey()

        if !Preferences.shared.onboardingCompleted {
            showOnboarding = true
        }

        setupZoomDetector()

        // Surface sidecar boot / model download in the status line.
        Task {
            do {
                try await GigasttSidecar.shared.ensureReady(
                    statusCallback: { [weak self] msg in
                        Task { @MainActor in
                            self?.statusMessage = msg
                        }
                    },
                    downloadProgress: { [weak self] frac in
                        Task { @MainActor in
                            self?.modelDownloadProgress = frac >= 1.0 ? nil : frac
                        }
                    }
                )
                await MainActor.run {
                    if self.statusMessage.hasPrefix("gigastt") || self.statusMessage.hasPrefix("Starting") || self.statusMessage.hasPrefix("Downloading") || self.statusMessage.hasPrefix("Loading gigastt") {
                        self.statusMessage = ""
                    }
                    self.modelDownloadProgress = nil
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = error.localizedDescription
                    self.modelDownloadProgress = nil
                }
            }
        }
    }

    /// Register Ctrl+Opt+R as a system-wide hotkey to toggle recording from any app.
    private func setupGlobalHotkey() {
        let expectedKeyCode = Preferences.shared.hotkeyKeyCode
        let expectedModifiers = NSEvent.ModifierFlags(rawValue: Preferences.shared.hotkeyModifiers)
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let pressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == expectedKeyCode, pressed.contains(expectedModifiers) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isRecording {
                    self.stopRecording()
                } else {
                    self.startRecording()
                }
            }
        }
    }

    // MARK: - Zoom auto-detect

    private func setupZoomDetector() {
        zoomDetector.onMeetingStarted = { [weak self] in
            Task { @MainActor in self?.handleZoomMeetingStarted() }
        }
        zoomDetector.onMeetingEnded = { [weak self] in
            Task { @MainActor in self?.handleZoomMeetingEnded() }
        }
        applyZoomDetectorMode()
    }

    /// Call when the Zoom preference changes in Settings.
    func applyZoomDetectorMode() {
        let mode = Preferences.shared.zoomAutoRecordMode
        if mode == .off {
            zoomDetector.stop()
            zoomMeetingDetected = false
            ignoredZoomMeeting = false
        } else {
            zoomDetector.start()
            zoomMeetingDetected = zoomDetector.isInMeeting
        }
    }

    private func handleZoomMeetingStarted() {
        zoomMeetingDetected = true
        ignoredZoomMeeting = false
        guard Preferences.shared.zoomAutoRecordMode != .off else { return }
        guard !isRecording else {
            // Already recording (manual) — still link so end-of-call can stop it.
            recordingLinkedToZoom = true
            return
        }
        startRecordingFromZoom()
    }

    private func handleZoomMeetingEnded() {
        zoomMeetingDetected = false
        ignoredZoomMeeting = false
        if isRecording && recordingLinkedToZoom {
            statusMessage = "Zoom ended — stopping recording"
            stopRecording()
        }
        recordingLinkedToZoom = false
    }

    /// Start recording a detected Zoom call without asking. A system
    /// notification is posted (in `beginRecording`) so the user can decline.
    func acceptZoomRecordingPrompt() {
        ignoredZoomMeeting = false
        startRecordingFromZoom()
    }

    private func startRecordingFromZoom() {
        guard !isRecording else { return }
        guard !ignoredZoomMeeting else { return }
        recordingLinkedToZoom = true
        autoStartedFromMeeting = true
        startRecording()
        statusMessage = "Recording meeting"
    }

    // MARK: - Disk Space Pre-flight

    /// Check available disk space at `path`. Returns bytes available, or nil on error.
    private func availableBytes(at path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }

    /// Check disk space before recording. Returns true if OK to proceed (enough space or user chose to continue).
    func checkDiskSpaceForRecording() async -> Bool {
        let path = Preferences.shared.recordingsPath
        if let bytes = availableBytes(at: path), bytes < 500_000_000 {
            let mbFree = bytes / 1_000_000
            diskSpaceWarning = "Only \(mbFree) MB free on the recordings disk. Recording may fail if disk fills up."
            return await presentDiskSpaceAlert()
        }
        return true
    }

    /// Check disk space before model download. Returns true if OK to proceed.
    func checkDiskSpaceForModelDownload() async -> Bool {
        let path = NSHomeDirectory()
        if let bytes = availableBytes(at: path), bytes < 4_000_000_000 {
            let gbFree = Double(bytes) / 1_000_000_000
            diskSpaceWarning = String(format: "Only %.1f GB free. Model download may require up to 3 GB.", gbFree)
            return await presentDiskSpaceAlert()
        }
        return true
    }

    /// Presents the disk-space alert and awaits the user's choice.
    /// Resolves any in-flight continuation first to avoid leaks on rapid re-entry.
    private func presentDiskSpaceAlert() async -> Bool {
        // If a prior alert is still in-flight, cancel it cleanly (resume with false)
        // before presenting a new one.
        if let pending = diskSpaceContinuation {
            diskSpaceContinuation = nil
            pending.resume(returning: false)
        }
        showDiskSpaceAlert = true
        return await withCheckedContinuation { continuation in
            diskSpaceContinuation = continuation
        }
    }

    func diskSpaceAlertContinue() {
        showDiskSpaceAlert = false
        diskSpaceContinuation?.resume(returning: true)
        diskSpaceContinuation = nil
    }

    func diskSpaceAlertCancel() {
        showDiskSpaceAlert = false
        diskSpaceContinuation?.resume(returning: false)
        diskSpaceContinuation = nil
    }

    // MARK: - Recording Lifecycle

    func startRecording() {
        // Microphone permission pre-flight
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.startRecordingAfterPermission()
                    } else {
                        self?.showMicPermissionAlert = true
                    }
                }
            }
            return
        case .denied, .restricted:
            showMicPermissionAlert = true
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        startRecordingAfterPermission()
    }

    private func startRecordingAfterPermission() {
        Task {
            let ok = await checkDiskSpaceForRecording()
            guard ok else { return }
            beginRecording()
        }
    }

    private func beginRecording() {
        transcript = ""
        pendingSpeakers = []
        skippedSpeakers = []
        transcribeStep = .pending
        saveStep = .pending
        recapStep = .pending
        recapSkipHint = nil
        lastRecapPath = nil
        statusMessage = ""
        micOnlyRecording = false

        do {
            try recorder.start()
            isRecording = true
            // If Zoom meeting is active and user started manually, still auto-stop on hangup.
            if zoomDetector.isInMeeting || zoomMeetingDetected {
                recordingLinkedToZoom = true
            }
            elapsedString = "00:00"
            elapsedSeconds = 0
            startDisplayTimer()

            let title = "Recording \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            let entry = RecordingEntry(
                id: recorder.recordingID ?? "",
                filename: (recorder.recordingID ?? "") + ".wav",
                date: Date(),
                duration: 0,
                title: title,
                status: "recording",
                transcript: nil
            )
            recordingStore.add(entry)
            selectedRecordingID = entry.id

            // Auto-started from a detected meeting: notify so the user can decline.
            if autoStartedFromMeeting {
                NotificationManager.shared.notifyRecordingStarted()
            }
            autoStartedFromMeeting = false
        } catch {
            statusMessage = "Recording error: \(error.localizedDescription)"
            recordingLinkedToZoom = false
            autoStartedFromMeeting = false
        }
    }

    /// Cancel the in-progress recording and discard it entirely (no transcript,
    /// no saved audio). Triggered by the "Don't record" notification action.
    func cancelRecording() {
        guard isRecording else { return }
        ignoredZoomMeeting = true
        Task { await cancelRecordingAndDiscard() }
    }

    private func cancelRecordingAndDiscard() async {
        stopDisplayTimer()
        isRecording = false
        recordingLinkedToZoom = false
        let id = recorder.recordingID
        do {
            _ = try await recorder.stop()
        } catch {
            NSLog("[AppState] cancelRecording stop error: \(error)")
        }
        if let id, let entry = recordingStore.recording(for: id) {
            recordingStore.remove(entry)
            if selectedRecordingID == id { selectedRecordingID = nil }
        }
        statusMessage = ""
        NotificationManager.shared.clearRecordingNotification()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func stopRecording() {
        Task { await stopRecordingAndWait(autoTranscribe: Preferences.shared.autoTranscribe) }
    }

    /// Stop recording and await final WAV write. Safe to call from quit handlers.
    /// When `autoTranscribe` is false, the transcribe chain is skipped (used on app quit).
    func stopRecordingAndWait(autoTranscribe: Bool = false) async {
        stopDisplayTimer()
        isRecording = false
        let wasZoomLinked = recordingLinkedToZoom
        recordingLinkedToZoom = false
        NotificationManager.shared.clearRecordingNotification()

        do {
            let result = try await recorder.stop()
            recordingDuration = result.duration
            recordingStore.update(id: result.id, status: "recorded", duration: result.duration)
            selectedRecordingID = result.id

            // Latch mic-only flag so RecordingDetailView can show "Mic only" tag
            if recorder.systemAudioWarning != nil && Preferences.shared.captureSystemAudio {
                micOnlyRecording = true
            }

            if autoTranscribe {
                let body = wasZoomLinked
                    ? "Zoom recording stopped. Transcribing..."
                    : "Recording stopped. Transcribing..."
                NotificationManager.shared.post(title: "Propeller", body: body)
                await runTranscribe()
            }
        } catch {
            statusMessage = "Stop error: \(error.localizedDescription)"
            NSLog("[AppState] stopRecording error: \(error)")
        }
    }

    // MARK: - Display Timer

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let secs = self.recorder.elapsed
                self.elapsedSeconds = secs
                self.elapsedString = Self.formatElapsed(secs)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    /// Format elapsed seconds as MM:SS, or H:MM:SS past 1h.
    static func formatElapsed(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    // MARK: - Selection

    func selectRecording(_ entry: RecordingEntry) {
        player.stop()
        selectedRecordingID = entry.id
        transcript = entry.transcript ?? ""
        recordingDuration = entry.duration
        // transcribed_raw: ASR done but diarization pending — show as "partially done"
        if entry.status == "transcribed_raw" {
            transcribeStep = .pending
        } else {
            transcribeStep = entry.transcript != nil ? .done : .pending
        }
        saveStep = entry.status == "saved" ? .done : .pending
        if let recapURL = Self.recapURL(for: entry), FileManager.default.fileExists(atPath: recapURL.path) {
            recapStep = .done
            lastRecapPath = recapURL.path
            recapSkipHint = nil
        } else {
            recapStep = .pending
            lastRecapPath = nil
            recapSkipHint = nil
        }
        statusMessage = entry.status == "transcribed_raw" ? "Diarization pending — click Complete Transcription" : ""
        pendingSpeakers = []
        skippedSpeakers = []
    }

    static func recapURL(for entry: RecordingEntry) -> URL? {
        let slug = MarkdownWriter.slugify(entry.title.isEmpty ? entry.id : entry.title)
        let filename = "\(entry.id)-\(slug)-recap.md"
        return URL(fileURLWithPath: Preferences.shared.meetingsPath)
            .appendingPathComponent(filename)
    }

    /// True when a recap markdown file exists for this recording.
    func hasRecap(for entry: RecordingEntry) -> Bool {
        guard let url = Self.recapURL(for: entry) else { return false }
        if FileManager.default.fileExists(atPath: url.path) { return true }
        // Title may have been renamed after the file was written — scan by id prefix.
        let dir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return false
        }
        let prefix = entry.id + "-"
        return files.contains { file in
            file.pathExtension == "md"
                && file.lastPathComponent.hasPrefix(prefix)
                && file.lastPathComponent.hasSuffix("-recap.md")
        }
    }

    /// Meetings that belong in the Summaries library (have a summary file and/or notes).
    func summaryLibraryEntries() -> [RecordingEntry] {
        recordingStore.recordings.filter { entry in
            hasRecap(for: entry)
                || !(entry.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    /// Bring the main window forward and open the Summary tab after auto-pipeline.
    private func surfaceSummaryUI() {
        preferredSidebarSection = "meetings"
        preferredDetailTab = "recap"
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        isWindowOpen = true
        for window in NSApp.windows where window.frame.width > 400 {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func surfaceMeetingUI(preferSummaryTab: Bool) {
        preferredSidebarSection = "meetings"
        preferredDetailTab = preferSummaryTab ? "recap" : "transcript"
        NSApp.setActivationPolicy(.regular)
        isWindowOpen = true
    }

    /// Regenerate recap for the selected recording (requires saved transcript markdown).
    func regenerateRecap() async {
        guard let rec = selectedRecording, !transcript.isEmpty else { return }
        let speakers = MarkdownWriter.extractSpeakers(from: transcript)
        let slug = MarkdownWriter.slugify(rec.title.isEmpty ? rec.id : rec.title)
        let transcriptPath = URL(fileURLWithPath: Preferences.shared.meetingsPath)
            .appendingPathComponent("\(rec.id)-\(slug).md").path
        if !FileManager.default.fileExists(atPath: transcriptPath) {
            // Save first so recap has a companion transcript file.
            await runSave()
            return
        }
        await runRecap(
            title: rec.title,
            transcriptPath: transcriptPath,
            speakers: speakers,
            notes: rec.notes,
            recordingID: rec.id
        )
    }

    func renameRecording(_ entry: RecordingEntry, to newTitle: String) {
        recordingStore.rename(id: entry.id, to: newTitle)
        markDirty()
    }

    /// Set transcription language for a specific recording. Pass nil to clear (use global default).
    func setLanguage(_ entry: RecordingEntry, to code: String?) {
        recordingStore.update(id: entry.id, language: .some(code))
    }

    // MARK: - Deletion

    func deleteAudioFile(_ entry: RecordingEntry) {
        player.stop()
        recordingStore.deleteAudioFile(for: entry)
    }

    func removeRecording(_ entry: RecordingEntry) {
        player.stop()
        recordingStore.remove(entry)
        if selectedRecordingID == entry.id { selectedRecordingID = nil }
    }

    // MARK: - Pipeline

    /// Guard against concurrent transcriptions if the user taps Re-transcribe mid-run.
    private var isTranscribing = false

    func runTranscribe() async {
        guard !isTranscribing else { return }
        guard let rec = selectedRecording else { return }
        guard let audioURL = recordingStore.audioURL(for: rec) else {
            statusMessage = "Audio file not found"
            return
        }

        let ok = await checkDiskSpaceForModelDownload()
        guard ok else { return }

        isTranscribing = true
        defer { isTranscribing = false }

        transcribeStep = .running
        statusMessage = "Loading models..."
        modelDownloadProgress = nil
        skippedSpeakers = []
        recordingStore.update(id: rec.id, status: "transcribing")

        do {
            let progressCb: (String) -> Void = { [weak self] progress in
                Task { @MainActor in self?.statusMessage = progress }
            }
            let downloadCb: (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    self?.modelDownloadProgress = fraction >= 1.0 ? nil : fraction
                }
            }

            // Phase 1: gigastt ASR (the expensive step)
            let rawResult = try await transcriptionService.transcribeAudio(
                audioURL: audioURL,
                languageOverride: rec.language,
                progressCallback: progressCb,
                downloadProgress: downloadCb
            )

            // Checkpoint: save raw transcript + serialized segments so a crash
            // during diarization doesn't lose the expensive ASR output.
            let rawText = rawResult.rawText
            let segmentsJSON: String? = {
                let encoder = JSONEncoder()
                guard let data = try? encoder.encode(rawResult.segments) else { return nil }
                return String(data: data, encoding: .utf8)
            }()
            recordingStore.update(
                id: rec.id,
                transcript: rawText,
                status: "transcribed_raw",
                rawSegmentsJSON: .some(segmentsJSON)
            )

            modelDownloadProgress = nil

            // Phase 2: Diarization + speaker matching
            let result = try await transcriptionService.diarizeAndMatch(
                audioURL: audioURL,
                asrSegments: rawResult.segments,
                peopleStore: peopleStore,
                progressCallback: progressCb
            )

            transcript = result.transcript
            transcribeStep = .done
            statusMessage = ""
            pendingSpeakers = result.detectedSpeakers
            let segJSON = encodePersistedSegments(result.mergedSegments)
            recordingStore.update(
                id: rec.id,
                transcript: result.transcript,
                status: "transcribed",
                rawSegmentsJSON: .some(nil),
                mergedSegmentsJSON: .some(segJSON)
            )
            persistUnresolvedSpeakers(for: rec.id)

            // Always save once no speakers need confirmation.
            if pendingSpeakers.isEmpty {
                await runSave()
            }
        } catch {
            transcribeStep = .failed
            statusMessage = error.localizedDescription
            modelDownloadProgress = nil
            // If we have a raw transcript (Phase 1 succeeded), keep it as transcribed_raw
            if let current = recordingStore.recording(for: rec.id), current.status == "transcribed_raw" {
                // Don't regress — keep the checkpoint
            } else {
                recordingStore.update(id: rec.id, status: "recorded")
            }
            NSLog("[AppState] Transcription FAILED: \(error)")
        }
    }

    /// Resume diarization for a recording that completed ASR but crashed before
    /// diarization finished. Deserializes the stored segments and runs only Phase 2.
    func completeDiarization() async {
        guard !isTranscribing else { return }
        guard let rec = selectedRecording else { return }
        guard let audioURL = recordingStore.audioURL(for: rec) else {
            statusMessage = "Audio file not found — cannot complete diarization"
            return
        }
        guard let json = rec.rawSegmentsJSON,
              let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([ASRSegment].self, from: data) else {
            statusMessage = "Stored segments not found — re-transcribe instead"
            return
        }

        isTranscribing = true
        defer { isTranscribing = false }

        transcribeStep = .running
        statusMessage = "Identifying speakers..."
        recordingStore.update(id: rec.id, status: "transcribing")

        do {
            let result = try await transcriptionService.diarizeAndMatch(
                audioURL: audioURL,
                asrSegments: segments,
                peopleStore: peopleStore,
                progressCallback: { [weak self] progress in
                    Task { @MainActor in self?.statusMessage = progress }
                }
            )

            transcript = result.transcript
            transcribeStep = .done
            statusMessage = ""
            pendingSpeakers = result.detectedSpeakers
            let segJSON = encodePersistedSegments(result.mergedSegments)
            recordingStore.update(
                id: rec.id,
                transcript: result.transcript,
                status: "transcribed",
                rawSegmentsJSON: .some(nil),
                mergedSegmentsJSON: .some(segJSON)
            )
            persistUnresolvedSpeakers(for: rec.id)

            if pendingSpeakers.isEmpty {
                await runSave()
            }
        } catch {
            transcribeStep = .failed
            statusMessage = error.localizedDescription
            recordingStore.update(id: rec.id, status: "transcribed_raw")
            NSLog("[AppState] Diarization FAILED: \(error)")
        }
    }

    func runSave() async {
        guard let rec = selectedRecording else { return }
        saveStep = .running
        recapStep = .pending
        recapSkipHint = nil

        do {
            let speakers = MarkdownWriter.extractSpeakers(from: transcript)
            let path = try MarkdownWriter.save(
                title: rec.title,
                transcript: transcript,
                recordingID: rec.id,
                duration: recordingDuration,
                speakers: speakers,
                notes: rec.notes
            )
            saveStep = .done
            recordingStore.update(id: rec.id, status: "saved")
            NotificationManager.shared.post(title: "Propeller", body: "Saved: \(URL(fileURLWithPath: path).lastPathComponent)")
            await runRecap(
                title: rec.title,
                transcriptPath: path,
                speakers: speakers,
                notes: rec.notes,
                recordingID: rec.id
            )
        } catch {
            saveStep = .failed
            statusMessage = error.localizedDescription
        }
    }

    /// Generate LLM recap next to the saved transcript. Skips quietly when no provider is configured.
    func runRecap(
        title: String,
        transcriptPath: String,
        speakers: [String],
        notes: String?,
        recordingID: String
    ) async {
        recapStep = .running
        statusMessage = "Generating recap…"
        lastRecapPath = nil

        let md: String
        do {
            md = try String(contentsOfFile: transcriptPath, encoding: .utf8)
        } catch {
            recapStep = .failed
            statusMessage = "Could not read transcript for recap"
            return
        }

        do {
            let result = try await RecapService.shared.generateRecap(
                title: title,
                transcriptMarkdown: md,
                transcriptPath: transcriptPath,
                notes: notes,
                speakers: speakers,
                duration: recordingDuration,
                recordingID: recordingID,
                prefs: RecapPreferences.fromShared()
            )
            switch result {
            case .failure(let reason):
                recapStep = .pending
                switch reason {
                case .disabled:
                    recapSkipHint = nil
                    statusMessage = ""
                    surfaceMeetingUI(preferSummaryTab: false)
                case .noProvider:
                    recapSkipHint = "Summary skipped — start Ollama or add an API key in Settings"
                    statusMessage = recapSkipHint ?? ""
                case .emptyTranscript:
                    recapSkipHint = "Summary skipped — empty transcript"
                    statusMessage = recapSkipHint ?? ""
                }
                // Still surface the meeting so notes + transcript are visible.
                surfaceMeetingUI(preferSummaryTab: false)
            case .success(let recap):
                recapStep = .done
                lastRecapPath = recap.path
                recapSkipHint = nil
                statusMessage = "Summary via \(recap.provider)"
                NotificationManager.shared.post(
                    title: "Propeller",
                    body: "Summary ready — notes and summary are in the meeting."
                )
                surfaceSummaryUI()
            }
        } catch {
            recapStep = .failed
            statusMessage = error.localizedDescription
            recapSkipHint = error.localizedDescription
        }
    }

    func reprocess() async {
        transcribeStep = .pending
        saveStep = .pending
        await runTranscribe()
    }

    // MARK: - Speaker Confirmation

    /// Confirm a high-confidence match. Always adds a voice sample to improve future recognition.
    func confirmSpeaker(_ speaker: DetectedSpeaker) {
        guard let rec = selectedRecording,
              let person = speaker.matchedPerson else { return }
        let audioURL = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(rec.filename)

        Task {
            await peopleStore.addSample(
                to: person,
                audioURL: audioURL,
                startTime: speaker.sampleStartTime,
                endTime: speaker.sampleEndTime,
                embedding: speaker.embedding,
                qualityScore: speaker.sampleQuality,
                captureSource: speaker.captureSource
            )
        }

        // Name is already correct in transcript
        pendingSpeakers.removeAll { $0.id == speaker.id }
        persistUnresolvedSpeakers(for: rec.id)
        checkAutoSave()
    }

    /// Confirm all high-confidence matches in one click.
    func confirmAllMatched() {
        let matched = pendingSpeakers.filter { $0.isHighConfidence }
        for speaker in matched {
            confirmSpeaker(speaker)
        }
    }

    /// Assign speaker to an existing person (correction or low-confidence pick).
    /// If the clip doesn't sound like this person's existing samples, surfaces
    /// a contamination warning so the user can confirm before we write it.
    func addSpeakerToExistingPerson(_ speaker: DetectedSpeaker, person: Person) {
        if let score = peopleStore.similarityToExistingSamples(embedding: speaker.embedding, person: person),
           score < PeopleStore.contaminationThreshold {
            pendingContamination = ContaminationWarning(
                speaker: speaker,
                person: person,
                similarity: score
            )
            return
        }
        commitSpeakerToPerson(speaker, person: person)
    }

    /// Called after the user explicitly confirms a low-similarity assignment.
    func forceAddSpeakerToPerson(_ speaker: DetectedSpeaker, person: Person) {
        commitSpeakerToPerson(speaker, person: person)
        pendingContamination = nil
    }

    private func commitSpeakerToPerson(_ speaker: DetectedSpeaker, person: Person) {
        guard let rec = selectedRecording else { return }
        let audioURL = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(rec.filename)

        Task {
            await peopleStore.addSample(
                to: person,
                audioURL: audioURL,
                startTime: speaker.sampleStartTime,
                endTime: speaker.sampleEndTime,
                embedding: speaker.embedding,
                qualityScore: speaker.sampleQuality,
                captureSource: speaker.captureSource
            )
        }

        // Update transcript with the person's name
        transcript = transcript.replacingOccurrences(
            of: "[\(speaker.assignedName)]",
            with: "[\(person.name)]"
        )
        if let id = selectedRecordingID {
            recordingStore.update(id: id, transcript: transcript)
        }
        pendingSpeakers.removeAll { $0.id == speaker.id }
        persistUnresolvedSpeakers(for: rec.id)
        markDirty()
        checkAutoSave()
    }

    /// Create a new person from this speaker. Adds a voice sample.
    func saveSpeakerAsNewPerson(_ speaker: DetectedSpeaker, name: String) {
        guard let rec = selectedRecording else { return }
        let audioURL = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(rec.filename)

        Task {
            let _ = await peopleStore.createPerson(
                name: name,
                audioURL: audioURL,
                startTime: speaker.sampleStartTime,
                endTime: speaker.sampleEndTime,
                embedding: speaker.embedding,
                qualityScore: speaker.sampleQuality,
                captureSource: speaker.captureSource
            )
        }

        // Update transcript with the real name
        transcript = transcript.replacingOccurrences(
            of: "[\(speaker.assignedName)]",
            with: "[\(name)]"
        )
        if let id = selectedRecordingID {
            recordingStore.update(id: id, transcript: transcript)
        }
        pendingSpeakers.removeAll { $0.id == speaker.id }
        persistUnresolvedSpeakers(for: rec.id)
        markDirty()
        checkAutoSave()
    }

    func skipSpeaker(_ speaker: DetectedSpeaker) {
        pendingSpeakers.removeAll { $0.id == speaker.id }
        skippedSpeakers.append(speaker)
        if let id = selectedRecordingID {
            persistUnresolvedSpeakers(for: id)
        }
        checkAutoSave()
    }

    /// Move all skipped speakers back into pendingSpeakers for re-prompting.
    func repromptSkippedSpeakers() {
        pendingSpeakers.append(contentsOf: skippedSpeakers)
        skippedSpeakers.removeAll()
    }

    // MARK: - Speaker Persistence (re-open tagging later)

    /// Persist the current pending+skipped speaker list onto the selected
    /// recording's `unresolvedSpeakersJSON`, so the user can re-open the
    /// confirmation UI from the detail view after navigating away.
    /// Resolved speakers (already removed from both lists) are not persisted.
    private func persistUnresolvedSpeakers(for recordingID: String) {
        let unresolved = pendingSpeakers + skippedSpeakers
        let encoded: String? = {
            guard !unresolved.isEmpty else { return nil }
            let snapshot = unresolved.map(PersistedSpeaker.init(from:))
            guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        recordingStore.update(id: recordingID, unresolvedSpeakersJSON: .some(encoded))
    }

    /// Re-open the speaker confirmation UI for the selected recording, using
    /// the persisted speaker snapshot. Recommendations and auto-matches are
    /// recomputed against the current PeopleStore so newly added people are
    /// considered.
    func reopenSpeakerTagging() {
        guard let rec = selectedRecording,
              let json = rec.unresolvedSpeakersJSON,
              let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode([PersistedSpeaker].self, from: data),
              !snapshot.isEmpty else {
            return
        }

        let autoThreshold = Preferences.shared.autoMatchThreshold
        let recommendThreshold = Preferences.shared.recommendThreshold

        let restored: [DetectedSpeaker] = snapshot.map { persisted in
            let result = peopleStore.matchWithRecommendations(
                embedding: persisted.embedding,
                source: persisted.captureSource,
                autoThreshold: autoThreshold,
                recommendThreshold: recommendThreshold
            )
            let matchScore: Float? = result.match.map { person in
                peopleStore.bestSimilarity(
                    embedding: persisted.embedding,
                    source: persisted.captureSource,
                    to: person
                )
            }
            return DetectedSpeaker(
                label: persisted.label,
                embedding: persisted.embedding,
                matchedPerson: result.match,
                matchScore: matchScore,
                assignedName: persisted.assignedName,
                sampleStartTime: persisted.sampleStartTime,
                sampleEndTime: persisted.sampleEndTime,
                sampleQuality: persisted.sampleQuality,
                captureSource: persisted.captureSource,
                recommendations: result.recommendations
            )
        }

        pendingSpeakers = restored
        skippedSpeakers = []
    }

    /// Number of unresolved (still-pending or skipped) speakers persisted on
    /// this recording. Drives whether the "Tag speakers" button is shown.
    func unresolvedSpeakerCount(for entry: RecordingEntry) -> Int {
        guard let json = entry.unresolvedSpeakersJSON,
              let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode([PersistedSpeaker].self, from: data) else {
            return 0
        }
        return snapshot.count
    }

    private func checkAutoSave() {
        guard selectedRecording != nil else { return }
        if pendingSpeakers.isEmpty {
            Task { await runSave() }
        }
    }

    // MARK: - Per-Segment Reassignment

    /// Where a segment should be reassigned to. Used by `reassignSegments`.
    enum SegmentReassignTarget {
        /// Just relabel the segment — no Person attribution, no learning.
        /// (e.g. the user wants to merge "Speaker 0" into "Speaker 1".)
        case existingSpeakerName(String)
        /// Attribute to an existing Person and add a corrected voice sample.
        case existingPerson(Person)
        /// Create a new Person from the audio range and attribute the segment.
        case newPerson(name: String)
    }

    /// Load the persisted merged-segments snapshot for a recording, if any.
    func loadPersistedSegments(for entry: RecordingEntry) -> [PersistedSegment]? {
        guard let json = entry.mergedSegmentsJSON,
              let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([PersistedSegment].self, from: data) else {
            return nil
        }
        return segments
    }

    /// True when the recording has a usable per-segment snapshot. The detail
    /// view uses this to decide whether to show the reassignment UI.
    func canReassignSegments(for entry: RecordingEntry) -> Bool {
        guard let segments = loadPersistedSegments(for: entry) else { return false }
        return !segments.isEmpty
    }

    fileprivate func encodePersistedSegments(_ segments: [PersistedSegment]) -> String? {
        guard !segments.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(segments) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reassign one or more segments (by `index`) to a new speaker. Re-renders
    /// the transcript, re-saves the recording, and — for Person targets —
    /// extracts an audio sample and adds it to the Person's voice profile so
    /// the matcher learns from the correction.
    func reassignSegments(_ indices: Set<Int>, to target: SegmentReassignTarget) async {
        guard let rec = selectedRecording else { return }
        guard var segments = loadPersistedSegments(for: rec), !segments.isEmpty else { return }

        let touched = indices.compactMap { idx -> PersistedSegment? in
            segments.first(where: { $0.index == idx })
        }
        guard !touched.isEmpty else { return }

        let learnStart = touched.map(\.startTime).min() ?? 0
        let learnEnd = touched.map(\.endTime).max() ?? 0
        let audioURL = URL(fileURLWithPath: Preferences.shared.recordingsPath)
            .appendingPathComponent(rec.filename)

        // Resolve the target into (newName, personID, optional learn task).
        let newName: String
        var newPersonID: UUID?

        switch target {
        case .existingSpeakerName(let name):
            newName = name
            newPersonID = peopleStore.personWithName(name)?.id
        case .existingPerson(let person):
            newName = person.name
            newPersonID = person.id
            statusMessage = "Adding voice sample to \(person.name)…"
            do {
                let dia = try await transcriptionService.prepareDiarizer()
                _ = await peopleStore.learnSampleFromAudioRange(
                    person: person,
                    audioURL: audioURL,
                    startTime: learnStart,
                    endTime: learnEnd,
                    captureSource: nil,
                    using: dia
                )
            } catch {
                NSLog("[AppState] reassign learn failed: \(error)")
            }
            statusMessage = ""
        case .newPerson(let name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            newName = trimmed
            statusMessage = "Creating \(trimmed)…"
            do {
                let dia = try await transcriptionService.prepareDiarizer()
                if let created = await peopleStore.learnNewPersonFromAudioRange(
                    name: trimmed,
                    audioURL: audioURL,
                    startTime: learnStart,
                    endTime: learnEnd,
                    captureSource: nil,
                    using: dia
                ) {
                    newPersonID = created.id
                }
            } catch {
                NSLog("[AppState] reassign new-person failed: \(error)")
            }
            statusMessage = ""
        }

        // Update the segment list in place.
        for i in segments.indices where indices.contains(segments[i].index) {
            segments[i].speaker = newName
            segments[i].personID = newPersonID
        }

        // Re-render transcript text and persist both.
        let newTranscript = TranscriptionService.formatTranscriptText(from: segments)
        transcript = newTranscript
        let segJSON = encodePersistedSegments(segments)
        recordingStore.update(
            id: rec.id,
            transcript: newTranscript,
            mergedSegmentsJSON: .some(segJSON)
        )
        markDirty()
        checkAutoSave()
    }

    /// Distinct speaker names currently used in the segment list, in
    /// first-occurrence order. Drives the "Move to existing speaker" submenu.
    func distinctSpeakerNames(for entry: RecordingEntry) -> [String] {
        guard let segments = loadPersistedSegments(for: entry) else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for seg in segments where !seen.contains(seg.speaker) {
            seen.insert(seg.speaker)
            ordered.append(seg.speaker)
        }
        return ordered
    }

    /// Drop the per-segment snapshot. Called from RecordingDetailView when the
    /// user manually edits the transcript text — segment timings can no longer
    /// be trusted to match the new text, so we hide the reassignment UI.
    func invalidateSegmentSnapshot(for recordingID: String) {
        recordingStore.update(id: recordingID, mergedSegmentsJSON: .some(nil))
    }

    // MARK: - Dirty Tracking

    /// Reset saveStep to .pending when the user modifies content after a save.
    func markDirty() {
        if saveStep == .done { saveStep = .pending }
    }

    /// Update notes for the selected recording with debounced persistence.
    func updateNotes(_ entry: RecordingEntry, to notes: String) {
        let value: String? = notes.isEmpty ? nil : notes
        recordingStore.update(id: entry.id, notes: .some(value))
        markDirty()
    }

    // MARK: - Helpers

}
