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
    /// Recording currently in ASR / save / recap — drives per-row spinners even
    /// when the user has navigated back to the meetings list.
    @Published private(set) var busyRecordingID: String?
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

    // Selection
    @Published var selectedRecordingID: String?

    // Recovery
    @Published var recoveredCount = 0

    // Window
    @Published var isWindowOpen = false {
        didSet {
            // Live waveforms only matter when the window is visible (E5).
            if isRecording {
                recorder.setMeteringDesired(isWindowOpen)
            }
        }
    }
    /// Must be decided before the first window paint — RootWindow swaps
    /// onboarding card vs main UI from this flag alone.
    /// TEST: always true on launch (keep in sync with bootstrap gate below).
    @Published var showOnboarding = true
    private var didBootstrap = false
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
    let transcriptionService = TranscriptionService()
    private let zoomDetector = ZoomMeetingDetector.shared

    var selectedRecording: RecordingEntry? {
        guard let id = selectedRecordingID else { return nil }
        return recordingStore.recording(for: id)
    }

    // MARK: - Initialization

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        // One-time migration: the legacy hardcoded default was llama3.2 (not bundled
        // and not our team model). Move it to the new default so recaps actually run.
        if Preferences.shared.recapOllamaModel == "llama3.2" {
            Preferences.shared.recapOllamaModel = "qwen2.5:7b"
        }

        recordingStore.load()
        recoveredCount = recordingStore.recoverInterruptedRecordings()
        Task { _ = await recordingStore.recoverMissingFinalMixes() }
        // Retention auto-delete disabled (plan-v2 6.1 → size-nudge; plan-optimization A4).
        NotificationManager.shared.configure()
        NotificationManager.shared.onCancelRecording = { [weak self] in
            self?.cancelRecording()
        }

        // TEST: always show onboarding on launch. Revert to the guarded version
        // below before shipping.
        showOnboarding = true
        // showOnboarding = !Preferences.shared.onboardingCompleted

        setupZoomDetector()

        // Quick-note overlay: register the state; key monitors install only
        // while a recording is active (plan-optimization E7).
        NoteOverlayController.shared.install(state: self)

        // Load upcoming meetings if the user opted into Calendar. Use the
        // requesting path so access is re-prompted after an ad-hoc rebuild
        // resets TCC (otherwise the list silently shows nothing).
        if Preferences.shared.calendarEnabled {
            Task { await CalendarService.shared.enableAndLoad() }
        }

        // Fill in summaries for any past recordings that don't have one yet — no
        // button, no prompt; they just appear once a provider is reachable.
        startSummaryBackfill()
        // Rename leftover "Recording …" titles once a recap already exists
        // (titleManuallySet was falsely latched by the live title field).
        Task { await backfillAutoTitlesFromRecaps() }

        // ASR sidecar starts lazily on first transcription (plan-optimization E1).
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
            recorder.setMeteringDesired(isWindowOpen)
            NoteOverlayController.shared.startMonitoring()

            let now = Date()
            // Calendar title wins over the placeholder (and later over LLM rename).
            if Preferences.shared.calendarEnabled {
                CalendarService.shared.load()
            }
            let placeholder = "Recording \(DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .short))"
            let title = CalendarService.shared.suggestedRecordingTitle(at: now) ?? placeholder
            let entry = RecordingEntry(
                id: recorder.recordingID ?? "",
                filename: (recorder.recordingID ?? "") + ".wav",
                date: now,
                duration: 0,
                title: title,
                status: "recording",
                transcript: nil
            )
            recordingStore.add(entry)
            selectedRecordingID = entry.id
            if title != placeholder {
                NSLog("[AppState] Recording titled from calendar: \(title)")
            }

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
        NoteOverlayController.shared.stopMonitoring()
        recorder.setMeteringDesired(false)
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
        guard isRecording else { return }
        stopDisplayTimer()
        NoteOverlayController.shared.stopMonitoring()
        recorder.setMeteringDesired(false)
        isRecording = false
        let wasZoomLinked = recordingLinkedToZoom
        recordingLinkedToZoom = false
        NotificationManager.shared.clearRecordingNotification()

        do {
            let result = try await recorder.stop()
            recordingDuration = result.duration
            recordingStore.update(id: result.id, status: "recorded", duration: result.duration)
            selectedRecordingID = result.id

            // Ground truth from the .sys stem after stop — not mid-session banners.
            micOnlyRecording = recorder.lastStopWasMicOnly

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
        // Clock display can coalesce wakeups — 0.3s is invisible to the user (S6).
        timer.tolerance = 0.3
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
        statusMessage = entry.status == "transcribed_raw"
            ? "Diarization pending — tap Complete Transcription"
            : ""
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
        let duration = rec.duration > 0 ? rec.duration : recordingDuration
        if !FileManager.default.fileExists(atPath: transcriptPath) {
            // Save first so recap has a companion transcript file.
            await runSave(
                recordingID: rec.id,
                transcriptText: transcript,
                duration: duration
            )
            return
        }
        await runRecap(
            title: rec.title,
            transcriptPath: transcriptPath,
            speakers: speakers,
            notes: rec.notes,
            recordingID: rec.id,
            duration: duration
        )
    }

    func renameRecording(_ entry: RecordingEntry, to newTitle: String) {
        recordingStore.rename(id: entry.id, to: newTitle)
        markDirty()
    }

    /// Append a note tagged with the current recording timecode (used by the
    /// quick-note overlay). No-op unless a recording is in progress.
    func appendTimestampedNote(_ text: String) {
        guard isRecording, let id = recorder.recordingID else { return }
        let line = "[\(AppState.formatElapsed(elapsedSeconds))] \(text)"
        let existing = recordingStore.recording(for: id)?.notes ?? ""
        let combined = existing.isEmpty ? line : existing + "\n" + line
        recordingStore.update(id: id, notes: .some(combined))
        NotificationManager.shared.post(title: "Propeller", body: "Note saved")
    }

    // MARK: - Summary backfill (no-button path)

    private var isBackfilling = false
    /// Single coalesced, thermal/battery-aware backfill schedule (S5/A3).
    private var backfillScheduler: NSBackgroundActivityScheduler?

    /// Resolve the transcript markdown file for a recording (the title slug in the
    /// filename may be stale after a rename), or nil if it hasn't been saved yet.
    private func transcriptMarkdownURL(for entry: RecordingEntry) -> URL? {
        let dir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
        let slug = MarkdownWriter.slugify(entry.title.isEmpty ? entry.id : entry.title)
        let expected = dir.appendingPathComponent("\(entry.id)-\(slug).md")
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let prefix = entry.id + "-"
        return files.first { f in
            f.pathExtension == "md"
                && f.lastPathComponent.hasPrefix(prefix)
                && !f.lastPathComponent.hasSuffix("-recap.md")
        }
    }

    /// Silently generate summaries for recordings that have a transcript but no
    /// summary yet. The user never asks — summaries just appear. Runs sequentially
    /// in the background, yields to live recording/transcription, and quietly does
    /// nothing if no LLM provider is available.
    /// Generate any missing summaries. Returns false when it couldn't run yet
    /// (busy, or no provider reachable) so the caller can retry later.
    @discardableResult
    func backfillMissingSummaries() async -> Bool {
        // Never run the LLM while the user is in (or detected to be in) a call —
        // loading the model is ~4–5 GB and would choke Zoom/Figma. Defer to when idle.
        guard !isBackfilling, !isRecording, !isTranscribing, !zoomMeetingDetected else {
            debugLog("[backfill] skip: busy (backfilling=\(isBackfilling) recording=\(isRecording) transcribing=\(isTranscribing) zoom=\(zoomMeetingDetected))")
            return false
        }

        // Cheap candidate scan BEFORE any network probe (plan-optimization P5).
        let candidates = recordingStore.recordings.filter { rec in
            guard let text = rec.transcript, !text.isEmpty else { return false }
            return !hasRecap(for: rec)
        }
        guard !candidates.isEmpty else {
            debugLog("[backfill] skip: nothing to backfill")
            return true
        }

        let prefs = RecapPreferences.fromShared()
        let backend = await RecapService.shared.resolveBackend(
            kind: prefs.provider, openAIKey: prefs.openAIKey, claudeKey: prefs.claudeKey
        )
        guard case .success(let backendName) = backend else {
            debugLog("[backfill] skip: no provider (\(backend))")
            return false
        }
        debugLog("[backfill] start via \(backendName), model=\(prefs.ollamaModel), \(candidates.count) candidates")

        isBackfilling = true
        defer { isBackfilling = false }

        for rec in candidates {
            if isRecording || isTranscribing { break }           // yield to live work
            guard let text = rec.transcript, !text.isEmpty else { continue }
            // Re-check in case a concurrent save wrote the recap.
            guard !hasRecap(for: rec) else { continue }

            // Ensure a transcript markdown exists (recap is written next to it).
            let mdPath: String
            if let existing = transcriptMarkdownURL(for: rec) {
                mdPath = existing.path
            } else if let saved = try? MarkdownWriter.save(
                title: rec.title, transcript: text, recordingID: rec.id,
                duration: rec.duration,
                speakers: MarkdownWriter.extractSpeakers(from: text), notes: rec.notes
            ) {
                recordingStore.update(id: rec.id, status: "saved")
                mdPath = saved
            } else {
                debugLog("[backfill] \(rec.id): no transcript markdown, skip")
                continue
            }

            debugLog("[backfill] \(rec.id): generating summary…")
            await backfillOne(rec, transcriptPath: mdPath, prefs: prefs)
        }
        debugLog("[backfill] done")
        return true
    }

    /// Kick (or coalesce into) the background summary backfill. Safe to call
    /// repeatedly — one `NSBackgroundActivityScheduler` owns retries so
    /// launch + post-recap don't stack Task.sleep loops (plan-optimization S5).
    func startSummaryBackfill() {
        ensureBackfillScheduler()
        Task { _ = await backfillMissingSummaries() }
    }

    private func ensureBackfillScheduler() {
        guard backfillScheduler == nil else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "app.propeller.summary-backfill")
        scheduler.repeats = true
        scheduler.interval = 60
        scheduler.tolerance = 30
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion(.finished)
                    return
                }
                let ran = await self.backfillMissingSummaries()
                // Deferred when busy / no provider — system retries when freer.
                completion(ran ? .finished : .deferred)
            }
        }
        backfillScheduler = scheduler
    }

    private func backfillOne(_ rec: RecordingEntry, transcriptPath: String, prefs: RecapPreferences) async {
        guard let md = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            debugLog("[backfill] \(rec.id): couldn't read \(transcriptPath)")
            return
        }
        let speakers = MarkdownWriter.extractSpeakers(from: rec.transcript ?? "")
        do {
            let result = try await RecapService.shared.generateRecap(
                title: rec.title, transcriptMarkdown: md, transcriptPath: transcriptPath,
                notes: rec.notes, speakers: speakers, duration: rec.duration,
                recordingID: rec.id, prefs: prefs
            )
            guard case .success(let recap) = result else {
                debugLog("[backfill] \(rec.id): skipped (\(result))")
                return
            }
            debugLog("[backfill] \(rec.id): wrote \(recap.path)")
            await generateMeetingMetadata(recordingID: rec.id, summary: recap.body)
            if selectedRecordingID == rec.id {
                lastRecapPath = recap.path
                recapStep = .done
            }
        } catch {
            debugLog("[backfill] \(rec.id): ERROR \(error.localizedDescription)")
        }
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
        if isTranscribing {
            statusMessage = "Transcription already in progress"
            return
        }
        guard let rec = selectedRecording else { return }
        // Snapshot identity for the whole pipeline — selection may change mid-run (C1).
        let recordingID = rec.id
        let language = rec.language
        let durationAtStart = rec.duration
        guard let audioURL = recordingStore.audioURL(for: rec) else {
            statusMessage = "Audio file not found"
            return
        }

        let ok = await checkDiskSpaceForModelDownload()
        guard ok else { return }

        isTranscribing = true
        beginPipelineWork(recordingID)
        defer {
            isTranscribing = false
            endPipelineWork(recordingID)
            transcriptionService.releaseHeavyResources()
        }

        transcribeStep = .running
        statusMessage = "Loading models..."
        modelDownloadProgress = nil
        recordingStore.update(id: recordingID, status: "transcribing")

        do {
            let progressCb: (String) -> Void = { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    // Keep top-bar status alive even if the user left the detail.
                    self.statusMessage = progress
                }
            }
            let downloadCb: (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    self.modelDownloadProgress = fraction >= 1.0 ? nil : fraction
                }
            }

            // Phase 1: gigastt ASR (the expensive step)
            let rawResult = try await transcriptionService.transcribeAudio(
                audioURL: audioURL,
                languageOverride: language,
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
                id: recordingID,
                transcript: rawText,
                status: "transcribed_raw",
                rawSegmentsJSON: .some(segmentsJSON)
            )

            modelDownloadProgress = nil

            // Phase 2: Diarization
            let result = try await transcriptionService.diarize(
                audioURL: audioURL,
                asrSegments: rawResult.segments,
                progressCallback: progressCb
            )

            let segJSON = encodePersistedSegments(result.mergedSegments)
            recordingStore.update(
                id: recordingID,
                transcript: result.transcript,
                status: "transcribed",
                rawSegmentsJSON: .some(nil),
                mergedSegmentsJSON: .some(segJSON)
            )

            // Always clear .running — leaving it latched when the user navigated
            // away made the UI look forever-busy.
            transcribeStep = .done
            if selectedRecordingID == recordingID {
                transcript = result.transcript
                statusMessage = ""
            }

            let duration = recordingStore.recording(for: recordingID)?.duration ?? durationAtStart
            await runSave(
                recordingID: recordingID,
                transcriptText: result.transcript,
                duration: duration
            )
        } catch {
            transcribeStep = .failed
            modelDownloadProgress = nil
            if selectedRecordingID == recordingID {
                statusMessage = error.localizedDescription
            }
            // If we have a raw transcript (Phase 1 succeeded), keep it as transcribed_raw
            if let current = recordingStore.recording(for: recordingID), current.status == "transcribed_raw" {
                // Don't regress — keep the checkpoint
            } else {
                recordingStore.update(id: recordingID, status: "recorded")
            }
            NSLog("[AppState] Transcription FAILED: \(error)")
        }
    }

    /// Resume diarization for a recording that completed ASR but crashed before
    /// diarization finished. Deserializes the stored segments and runs only Phase 2.
    func completeDiarization() async {
        if isTranscribing {
            statusMessage = "Transcription already in progress"
            return
        }
        guard let rec = selectedRecording else { return }
        let recordingID = rec.id
        let durationAtStart = rec.duration
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
        beginPipelineWork(recordingID)
        defer {
            isTranscribing = false
            endPipelineWork(recordingID)
            transcriptionService.releaseHeavyResources()
        }

        transcribeStep = .running
        statusMessage = "Identifying speakers..."
        recordingStore.update(id: recordingID, status: "transcribing")

        do {
            let result = try await transcriptionService.diarize(
                audioURL: audioURL,
                asrSegments: segments,
                progressCallback: { [weak self] progress in
                    Task { @MainActor in
                        self?.statusMessage = progress
                    }
                }
            )

            let segJSON = encodePersistedSegments(result.mergedSegments)
            recordingStore.update(
                id: recordingID,
                transcript: result.transcript,
                status: "transcribed",
                rawSegmentsJSON: .some(nil),
                mergedSegmentsJSON: .some(segJSON)
            )

            transcribeStep = .done
            if selectedRecordingID == recordingID {
                transcript = result.transcript
                statusMessage = ""
            }

            let duration = recordingStore.recording(for: recordingID)?.duration ?? durationAtStart
            await runSave(
                recordingID: recordingID,
                transcriptText: result.transcript,
                duration: duration
            )
        } catch {
            transcribeStep = .failed
            if selectedRecordingID == recordingID {
                statusMessage = error.localizedDescription
            }
            recordingStore.update(id: recordingID, status: "transcribed_raw")
            NSLog("[AppState] Diarization FAILED: \(error)")
        }
    }

    func runSave(
        recordingID: String,
        transcriptText: String,
        duration: TimeInterval
    ) async {
        guard let rec = recordingStore.recording(for: recordingID) else { return }
        beginPipelineWork(recordingID)
        defer { endPipelineWork(recordingID) }
        saveStep = .running
        recapStep = .pending
        if selectedRecordingID == recordingID {
            recapSkipHint = nil
        }

        do {
            let speakers = MarkdownWriter.extractSpeakers(from: transcriptText)
            let path = try MarkdownWriter.save(
                title: rec.title,
                transcript: transcriptText,
                recordingID: recordingID,
                duration: duration,
                speakers: speakers,
                notes: rec.notes
            )
            recordingStore.update(id: recordingID, status: "saved")
            saveStep = .done
            NotificationManager.shared.post(title: "Propeller", body: "Saved: \(URL(fileURLWithPath: path).lastPathComponent)")
            await runRecap(
                title: rec.title,
                transcriptPath: path,
                speakers: speakers,
                notes: rec.notes,
                recordingID: recordingID,
                duration: duration
            )
        } catch {
            saveStep = .failed
            if selectedRecordingID == recordingID {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Generate LLM recap next to the saved transcript. Skips quietly when no provider is configured.
    func runRecap(
        title: String,
        transcriptPath: String,
        speakers: [String],
        notes: String?,
        recordingID: String,
        duration: TimeInterval
    ) async {
        beginPipelineWork(recordingID)
        defer { endPipelineWork(recordingID) }
        recapStep = .running
        statusMessage = "Generating recap…"
        if selectedRecordingID == recordingID {
            lastRecapPath = nil
        }

        let md: String
        do {
            md = try String(contentsOfFile: transcriptPath, encoding: .utf8)
        } catch {
            recapStep = .failed
            if selectedRecordingID == recordingID {
                statusMessage = "Could not read transcript for recap"
            }
            return
        }

        do {
            let result = try await RecapService.shared.generateRecap(
                title: title,
                transcriptMarkdown: md,
                transcriptPath: transcriptPath,
                notes: notes,
                speakers: speakers,
                duration: duration,
                recordingID: recordingID,
                prefs: RecapPreferences.fromShared()
            )
            switch result {
            case .failure(let reason):
                recapStep = .pending
                if selectedRecordingID == recordingID {
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
                    surfaceMeetingUI(preferSummaryTab: false)
                }
            case .success(let recap):
                recapStep = .done
                if selectedRecordingID == recordingID {
                    lastRecapPath = recap.path
                    recapSkipHint = nil
                    statusMessage = "Summary via \(recap.provider)"
                    surfaceSummaryUI()
                }
                NotificationManager.shared.post(
                    title: "Propeller",
                    body: "Summary ready — notes and summary are in the meeting."
                )
                await generateMeetingMetadata(recordingID: recordingID, summary: recap.body)
            }
        } catch {
            recapStep = .failed
            if selectedRecordingID == recordingID {
                statusMessage = error.localizedDescription
                recapSkipHint = error.localizedDescription
            }
        }

        startSummaryBackfill()
    }

    /// Nesting depth for begin/end around transcribe → save → recap.
    private var pipelineWorkDepth = 0

    private func beginPipelineWork(_ recordingID: String) {
        pipelineWorkDepth += 1
        busyRecordingID = recordingID
    }

    private func endPipelineWork(_ recordingID: String) {
        pipelineWorkDepth = max(0, pipelineWorkDepth - 1)
        if pipelineWorkDepth == 0 {
            busyRecordingID = nil
        } else if busyRecordingID == nil {
            busyRecordingID = recordingID
        }
    }

    /// Re-run metadata for saved meetings still stuck on the default title.
    private func backfillAutoTitlesFromRecaps() async {
        let candidates = recordingStore.recordings.filter { rec in
            Self.isAutoGeneratedTitle(rec.title) && hasRecap(for: rec)
        }
        guard !candidates.isEmpty else { return }
        for rec in candidates {
            let preferred = AppState.recapURL(for: rec)
            let url: URL? = {
                if let preferred, FileManager.default.fileExists(atPath: preferred.path) {
                    return preferred
                }
                return Self.findRecapURL(for: rec)
            }()
            guard let url,
                  let body = try? String(contentsOf: url, encoding: .utf8),
                  !body.isEmpty else { continue }
            await generateMeetingMetadata(recordingID: rec.id, summary: body)
        }
    }

    private static func findRecapURL(for entry: RecordingEntry) -> URL? {
        let dir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let prefix = entry.id + "-"
        return files.first {
            $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix("-recap.md")
        }
    }

    /// Derive title / topics / tags from the finished summary and persist them.
    /// Title is only rewritten for the placeholder "Recording …" — calendar and
    /// manual names are kept. Best-effort: silently no-ops on provider/parse failure.
    private func generateMeetingMetadata(recordingID: String, summary: String) async {
        guard let rec = recordingStore.recording(for: recordingID) else { return }
        // Calendar / user titles must not be overwritten by the LLM.
        let needTitle = Self.isAutoGeneratedTitle(rec.title)
        let meta = await RecapService.shared.generateMetadata(
            summaryMarkdown: summary,
            needTitle: needTitle,
            prefs: RecapPreferences.fromShared()
        )
        guard let meta else { return }
        recordingStore.update(id: recordingID, topics: meta.topics, tags: meta.tags)
        if needTitle, let newTitle = meta.title, !newTitle.isEmpty {
            recordingStore.update(id: recordingID, title: newTitle)
        }
    }

    /// Placeholder stamped at record start when no calendar event matched.
    static func isAutoGeneratedTitle(_ title: String) -> Bool {
        title.hasPrefix("Recording ")
    }

    func reprocess() async {
        transcribeStep = .pending
        saveStep = .pending
        await runTranscribe()
    }

    // MARK: - Per-Segment Reassignment

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

    /// Rename one or more segments (by `index`) to a new speaker label — either
    /// merging into an existing label already used in this recording, or a
    /// freshly typed name. Re-renders the transcript and re-saves. Purely
    /// textual: no voice profile, no learning, since there's no PeopleStore.
    func reassignSegments(_ indices: Set<Int>, toName rawName: String) async {
        guard let rec = selectedRecording else { return }
        guard var segments = loadPersistedSegments(for: rec), !segments.isEmpty else { return }

        let newName = rawName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }

        let touched = indices.compactMap { idx -> PersistedSegment? in
            segments.first(where: { $0.index == idx })
        }
        guard !touched.isEmpty else { return }

        // Update the segment list in place.
        for i in segments.indices where indices.contains(segments[i].index) {
            segments[i].speaker = newName
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
        await runSave(
            recordingID: rec.id,
            transcriptText: newTranscript,
            duration: rec.duration > 0 ? rec.duration : recordingDuration
        )
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
