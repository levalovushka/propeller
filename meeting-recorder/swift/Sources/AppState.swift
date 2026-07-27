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
    /// Last pipeline failure shown in the empty transcript / recap panels (and toast).
    /// Cleared when a new ASR/recap attempt starts successfully past the early guards.
    @Published var pipelineError: String? = nil
    /// Hint when recap was skipped (no Ollama / no API key). Cleared on next successful recap.
    @Published var recapSkipHint: String? = nil
    @Published var lastRecapPath: String? = nil
    @Published var recordingDuration: TimeInterval = 0
    /// Model download progress 0.0–1.0. Nil when no download is active.
    @Published var modelDownloadProgress: Double? = nil
    /// Ollama engine/model setup (onboarding + Settings). Nil when idle.
    @Published var ollamaSetupProgress: Double? = nil
    @Published var ollamaSetupMessage = ""
    /// Is the local summary model on disk? Nil until first checked. Drives the
    /// empty-summary panel: without it the UI offers «Сгенерировать», which can
    /// only fail with `HTTP 404: model not found`.
    @Published var localRecapModelReady: Bool? = nil
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
    @Published var showOnboarding = !Preferences.shared.onboardingCompleted
    private var didBootstrap = false
    @Published var showMicPermissionAlert = false
    @Published var zoomMeetingDetected = false
    @Published var diskSpaceWarning: String?
    @Published var showDiskSpaceAlert = false
    /// Library size exceeded the nudge threshold (plan-v2 6.1 / GROW-11). Never auto-deletes.
    @Published var showStorageNudgeAlert = false
    @Published var storageLibraryBytes: Int64 = 0
    /// When set, MainView switches to this sidebar section (e.g. after pipeline).
    @Published var preferredSidebarSection: String?
    /// When set, RecordingDetailView selects this tab (`transcript` / `notes` / `recap`).
    @Published var preferredDetailTab: String?
    private var diskSpaceContinuation: CheckedContinuation<Bool, Never>?

    /// True when the current recording was started because of a Zoom meeting.
    private var recordingLinkedToZoom = false
    /// User cancelled auto-recording for the current Zoom meeting — sticky until Zoom.app quits (G3).
    private var ignoredZoomMeeting = false
    /// Set right before an auto-start so `beginRecording` knows to post the
    /// interactive "recording started" notification (manual starts don't).
    private var autoStartedFromMeeting = false
    /// Mutex so Stop / Discard / Zoom-end can't race two `recorder.stop()` calls.
    private var isTerminalRecordingAction = false
    /// Reconciler guard — one drain of pending `recorded` / `transcribed_raw` at a time.
    private var isReconcilingPipeline = false

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

        // (model migration lives in `Preferences.recapOllamaModel` so it also
        // covers launches that read the pref before bootstrap runs)

        recordingStore.load()
        recoveredCount = recordingStore.recoverInterruptedRecordings()
        Task { _ = await recordingStore.recoverMissingFinalMixes() }
        refreshStorageNudge(presentAlert: true)
        NotificationManager.shared.configure()
        NotificationManager.shared.onCancelRecording = { [weak self] in
            self?.cancelRecording()
        }

        showOnboarding = !Preferences.shared.onboardingCompleted

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
        // (this also catches up titles/topics/tags for meetings whose recap
        // landed before the metadata pass ran — see backfillMissingMetadata)
        startSummaryBackfill()

        // Advance recovered / queued recordings (G1/G2 / BUG-PIPE-01+05).
        Task { await reconcilePendingPipeline() }

        // Finish a summary-model download that a quit (or a dropped connection
        // that outlived the in-session retries) left half-done. No-op when the
        // model is already there; delayed so launch stays quiet.
        if Preferences.shared.localRecapModelRequested {
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !isRecording, !isTranscribing, !zoomMeetingDetected else { return }
                startOllamaRuntimeDownload()
            }
        }

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
        // Do NOT clear ignoredZoomMeeting here — sticky for this Zoom session (G3).
        guard Preferences.shared.zoomAutoRecordMode != .off else { return }
        guard !isRecording else {
            // Already recording (manual) — still link so end-of-call can stop it (DECIDE-7).
            recordingLinkedToZoom = true
            return
        }
        startRecordingFromZoom()
    }

    private func handleZoomMeetingEnded() {
        zoomMeetingDetected = false
        if isRecording && recordingLinkedToZoom {
            statusMessage = "Zoom завершён — останавливаем"
            stopRecording()
        }
        recordingLinkedToZoom = false
        // Sticky ignore clears only when Zoom.app itself is gone (not on brief detector flaps).
        if !ZoomMeetingDetector.isZoomAppRunning() {
            ignoredZoomMeeting = false
        }
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
        // Upcoming «Don't record» mutes this calendar session (DECIDE-6).
        if CalendarService.shared.isMutedForRecording() { return }
        recordingLinkedToZoom = true
        autoStartedFromMeeting = true
        startRecording()
        statusMessage = "Идёт запись"
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
            diskSpaceWarning = "На диске свободно только \(mbFree) МБ. Запись может прерваться, если место закончится."
            return await presentDiskSpaceAlert()
        }
        return true
    }

    /// The two model downloads are very different sizes, and one gate for both
    /// was wrong in both directions: it demanded 4 GB before a 1.1 GB ASR
    /// download, and waved through a 3.4 GB recap model with 4 GB free — the
    /// user passed the check and then ran out mid-pull. Measured 2026-07-27.
    enum ModelDownload {
        /// GigaAM ASR weights (~1.1 GB on disk) + working room.
        case transcription
        /// qwen3.5:4b (~3.4 GB) plus the unpacked Ollama runtime (~0.5 GB).
        case recap

        var requiredBytes: Int64 {
            switch self {
            case .transcription: return 2_000_000_000
            case .recap: return 5_000_000_000
            }
        }

        var humanSize: String {
            switch self {
            case .transcription: return "~1,1 ГБ"
            case .recap: return "~3,9 ГБ"
            }
        }
    }

    /// Check disk space before a model download. Returns true if OK to proceed.
    func checkDiskSpaceForModelDownload(_ kind: ModelDownload = .transcription) async -> Bool {
        let path = NSHomeDirectory()
        if let bytes = availableBytes(at: path), bytes < kind.requiredBytes {
            let gbFree = Double(bytes) / 1_000_000_000
            diskSpaceWarning = String(
                format: "Свободно только %.1f ГБ. Для загрузки нужно %@ плюс запас.",
                gbFree, kind.humanSize
            )
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
        // Don't wipe another meeting's in-flight pipeline lights (BUG-PIPE-03).
        if busyRecordingID == nil {
            transcribeStep = .pending
            saveStep = .pending
            recapStep = .pending
        }
        recapSkipHint = nil
        lastRecapPath = nil
        statusMessage = ""
        micOnlyRecording = false

        // Playback of an older meeting must not keep running under a new
        // recording — it also poisons the next auto-load (release-review rev-7).
        player.stop()

        let recordingSource = autoStartedFromMeeting ? "zoom" : "manual"

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
            let placeholder = "Запись \(DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .short))"
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
            refreshStorageNudge(presentAlert: true)
            selectedRecordingID = entry.id
            Analytics.recordingStarted(source: recordingSource)
            if title != placeholder {
                NSLog("[AppState] Recording titled from calendar: \(title)")
            }

            // Auto-started from a detected meeting: notify so the user can decline.
            // If notifications are denied, surface the window so Discard is reachable (BUG-REC-05).
            if autoStartedFromMeeting {
                NotificationManager.shared.notifyRecordingStarted { [weak self] authorized in
                    Task { @MainActor in
                        guard let self, !authorized, self.isRecording else { return }
                        self.surfaceMeetingUI(preferSummaryTab: false)
                        NSApp.activate(ignoringOtherApps: true)
                        for window in NSApp.windows where window.frame.width > 400 {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                }
            }
            autoStartedFromMeeting = false
        } catch {
            statusMessage = "Ошибка записи: \(error.localizedDescription)"
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
        guard !isTerminalRecordingAction else { return }
        isTerminalRecordingAction = true
        defer { isTerminalRecordingAction = false }

        stopDisplayTimer()
        NoteOverlayController.shared.stopMonitoring()
        recorder.setMeteringDesired(false)
        isRecording = false
        recordingLinkedToZoom = false
        player.stop()
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
        Analytics.recordingCancelled()
        NotificationManager.shared.clearRecordingNotification()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func stopRecording() {
        Task { await stopRecordingAndWait(runPipeline: true) }
    }

    /// Stop recording and await final WAV write. Safe to call from quit handlers.
    /// `runPipeline: false` only for app quit — otherwise ASR → save → recap always starts
    /// (gigastt downloads/spawns inside `runTranscribe` on first need).
    func stopRecordingAndWait(runPipeline: Bool = true) async {
        guard isRecording else { return }
        guard !isTerminalRecordingAction else { return }
        isTerminalRecordingAction = true
        defer { isTerminalRecordingAction = false }

        stopDisplayTimer()
        NoteOverlayController.shared.stopMonitoring()
        recorder.setMeteringDesired(false)
        isRecording = false
        let wasZoomLinked = recordingLinkedToZoom
        recordingLinkedToZoom = false
        NotificationManager.shared.clearRecordingNotification()
        player.stop()

        do {
            let result = try await recorder.stop()
            recordingDuration = result.duration
            let micOnly = recorder.lastStopWasMicOnly
            recordingStore.update(
                id: result.id,
                status: "recorded",
                duration: result.duration,
                micOnlyCaptured: micOnly
            )
            selectedRecordingID = result.id

            // Keep for live detail of *this* stop; badge itself reads entry.micOnlyCaptured.
            micOnlyRecording = micOnly
            Analytics.recordingFinished(duration: result.duration, micOnly: micOnly)

            if runPipeline {
                let body = wasZoomLinked
                    ? "Запись Zoom остановлена. Расшифровка…"
                    : "Запись остановлена. Расшифровка…"
                NotificationManager.shared.post(title: "Propeller", body: body)
                await enqueueOrRunTranscribe(recordingID: result.id)
            }
        } catch {
            statusMessage = "Ошибка остановки: \(error.localizedDescription)"
            NSLog("[AppState] stopRecording error: \(error)")
        }
    }

    // MARK: - Display Timer

    /// Hard ceiling for a single recording (decision 2026-07-25). A meeting that
    /// never gets a detected end (Zoom left open, detector wedged) would
    /// otherwise record until the disk fills. Stops through the normal path, so
    /// the recording is kept and the pipeline runs on it.
    static let maxRecordingSeconds: TimeInterval = 8 * 3600

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let secs = self.recorder.elapsed
                self.elapsedSeconds = secs
                self.elapsedString = Self.formatElapsed(secs)

                if secs >= Self.maxRecordingSeconds, self.isRecording {
                    self.statusMessage = "Запись остановлена — достигнут предел 8 часов"
                    self.stopRecording()
                }
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
        micOnlyRecording = entry.micOnlyCaptured == true

        // While another meeting owns the pipeline, keep global step lights for that
        // job — per-row UI uses busyRecordingID (BUG-PIPE-02).
        let pipelineOwnedElsewhere = busyRecordingID != nil && busyRecordingID != entry.id
        if !pipelineOwnedElsewhere {
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
        }
        statusMessage = entry.status == "transcribed_raw"
            ? "Диаризация не завершена — нажмите «Завершить»"
            : ""
    }

    static func recapURL(for entry: RecordingEntry) -> URL? {
        let slug = MarkdownWriter.slugify(entry.title.isEmpty ? entry.id : entry.title)
        let filename = "\(entry.id)-\(slug)-recap.md"
        return URL(fileURLWithPath: Preferences.shared.meetingsPath)
            .appendingPathComponent(filename)
    }

    /// Resolve `*-recap.md` on disk (tolerates title rename after write).
    static func resolvedRecapURL(for entry: RecordingEntry) -> URL? {
        if let url = recapURL(for: entry), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let dir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let prefix = entry.id + "-"
        return files.first { file in
            file.pathExtension == "md"
                && file.lastPathComponent.hasPrefix(prefix)
                && file.lastPathComponent.hasSuffix("-recap.md")
        }
    }

    static func loadRecapText(for entry: RecordingEntry) -> String? {
        guard let url = resolvedRecapURL(for: entry) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// True when a recap markdown file exists for this recording.
    func hasRecap(for entry: RecordingEntry) -> Bool {
        Self.resolvedRecapURL(for: entry) != nil
    }

    /// Recompute library audio size; optionally surface the one-shot nudge alert.
    func refreshStorageNudge(presentAlert: Bool = false) {
        storageLibraryBytes = recordingStore.totalLibraryBytes()
        let threshold = Preferences.shared.storageNudgeThresholdBytes
        guard storageLibraryBytes > threshold else {
            showStorageNudgeAlert = false
            return
        }
        if presentAlert, !Preferences.shared.storageNudgeSnoozed {
            showStorageNudgeAlert = true
        }
    }

    func snoozeStorageNudge() {
        Preferences.shared.storageNudgeSnoozed = true
        showStorageNudgeAlert = false
    }

    /// Bring the main window forward and open the Summary tab after auto-pipeline.
    /// Skipped while another recording is live so we don't steal focus mid-call (BUG-PIPE-04).
    private func surfaceSummaryUI(for recordingID: String) {
        guard !isRecording else { return }
        guard selectedRecordingID == recordingID || selectedRecordingID == nil else { return }
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
        guard let rec = selectedRecording else {
            surfacePipelineError("Запись не выбрана")
            return
        }
        guard !transcript.isEmpty else {
            let msg = "Сначала нужна расшифровка — без транскрипта саммари не из чего собрать."
            recapSkipHint = msg
            preferredDetailTab = "transcript"
            surfacePipelineError(msg)
            return
        }
        pipelineError = nil
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

    /// Refresh `localRecapModelReady`. Cheap: reads the manifest off disk unless
    /// a server is already up, so it is safe to call whenever the summary tab
    /// is shown.
    func refreshLocalRecapModelState() {
        let model = Preferences.shared.recapOllamaModel
        Task {
            let installed = await OllamaSidecar.shared.isModelInstalled(model)
            await MainActor.run { self.localRecapModelReady = installed }
        }
    }

    /// True when a summary can only come from the local model and that model is
    /// not there yet — i.e. the honest CTA is «Скачать», not «Сгенерировать».
    var needsLocalRecapModel: Bool {
        guard localRecapModelReady == false else { return false }
        switch Preferences.shared.recapProvider {
        case .off, .openai, .claude:
            return false          // cloud / disabled: the local model is irrelevant
        case .ollama:
            return true
        case .auto:
            // Auto falls back to a cloud provider only if a key exists.
            let hasKey = (Preferences.shared.openAIAPIKey?.isEmpty == false)
                || (Preferences.shared.claudeAPIKey?.isEmpty == false)
            return !hasKey
        }
    }

    /// Persist a user-visible pipeline error (detail panel + toast). Does not clear mid-run status.
    func surfacePipelineError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pipelineError = trimmed
        statusMessage = trimmed
        statusIsTransient = false
        NSLog("[AppState] pipelineError: \(trimmed)")
    }

    func clearPipelineError() {
        pipelineError = nil
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
        NotificationManager.shared.post(title: "Propeller", body: "Заметка сохранена")
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
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            debugLog("[backfill] skip: thermalState=\(ProcessInfo.processInfo.thermalState.rawValue)")
            return false
        default:
            break
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
        defer {
            isBackfilling = false
            // Free VRAM after the batch — don't leave qwen resident for Zoom.
            OllamaSidecar.shared.stopAfterIdle(30)
        }

        // Cap batch size so a long backlog doesn't cook the machine in one go.
        for rec in candidates.prefix(2) {
            if isRecording || isTranscribing || zoomMeetingDetected { break }
            if ProcessInfo.processInfo.thermalState == .serious
                || ProcessInfo.processInfo.thermalState == .critical { break }
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
    func startSummaryBackfill(delaySeconds: TimeInterval = 0) {
        ensureBackfillScheduler()
        Task {
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            _ = await backfillMissingSummaries()
            // Runs second so it reuses the model the summaries just loaded.
            await backfillMissingMetadata()
        }
    }

    private func ensureBackfillScheduler() {
        guard backfillScheduler == nil else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "app.propeller.summary-backfill")
        scheduler.repeats = true
        // Was 60s — too aggressive with a 7B local model. Give the machine room.
        scheduler.interval = 180
        scheduler.tolerance = 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion(.finished)
                    return
                }
                let ran = await self.backfillMissingSummaries()
                if ran { await self.backfillMissingMetadata() }
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
        refreshStorageNudge(presentAlert: false)
    }

    func deleteAudioKeepingMeeting(_ entry: RecordingEntry) {
        player.stop()
        recordingStore.deleteAudioKeepingMeeting(entry)
        refreshStorageNudge(presentAlert: false)
    }

    // MARK: - Pipeline

    /// Guard against concurrent ASR/diarization. Cleared before save/recap so a
    /// second Stop can queue (BUG-PIPE-01 / G1).
    private var isTranscribing = false

    /// Queue a transcription if one is already running; otherwise start immediately.
    private func enqueueOrRunTranscribe(recordingID: String) async {
        if isTranscribing {
            statusMessage = "В очереди на расшифровку…"
            debugLog("[pipeline] queued \(recordingID) — ASR busy")
            return
        }
        await runTranscribe(recordingID: recordingID)
    }

    /// Advance the oldest `recorded` / `transcribed_raw` meeting one step.
    /// Called after bootstrap and after each pipeline completion (G2 / BUG-PIPE-05).
    func reconcilePendingPipeline() async {
        guard !isReconcilingPipeline else { return }
        guard !isRecording, !isTranscribing else { return }
        isReconcilingPipeline = true
        defer { isReconcilingPipeline = false }

        let pending = recordingStore.recordings
            .filter { $0.status == "recorded" || $0.status == "transcribed_raw" }
            .sorted { $0.date < $1.date }
        guard let next = pending.first else { return }

        debugLog("[pipeline] reconcile → \(next.id) status=\(next.status)")
        if next.status == "transcribed_raw" {
            await completeDiarization(recordingID: next.id)
        } else {
            await runTranscribe(recordingID: next.id)
        }
    }

    func runTranscribe(recordingID explicitID: String? = nil) async {
        if isTranscribing {
            let msg = explicitID != nil
                ? "В очереди на расшифровку…"
                : "Расшифровка уже идёт"
            statusMessage = msg
            surfacePipelineError(msg)
            return
        }
        let rec: RecordingEntry?
        if let explicitID {
            rec = recordingStore.recording(for: explicitID)
        } else {
            rec = selectedRecording
        }
        guard let rec else {
            surfacePipelineError("Запись не выбрана")
            return
        }
        let recordingID = rec.id
        let language = rec.language
        let durationAtStart = rec.duration
        guard let audioURL = recordingStore.audioURL(for: rec) else {
            surfacePipelineError("Аудиофайл не найден — нельзя расшифровать.")
            return
        }

        let ok = await checkDiskSpaceForModelDownload()
        guard ok else {
            surfacePipelineError("Расшифровка отменена — мало места на диске.")
            return
        }

        pipelineError = nil
        isTranscribing = true
        beginPipelineWork(recordingID)

        transcribeStep = .running
        setTransientStatus("Загрузка моделей…")
        modelDownloadProgress = nil
        recordingStore.update(id: recordingID, status: "transcribing")

        var saveAfterASR: (transcript: String, duration: TimeInterval)?

        do {
            let progressCb: (String) -> Void = { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.statusMessage = progress
                }
            }
            let downloadCb: (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    self.modelDownloadProgress = fraction >= 1.0 ? nil : fraction
                }
            }

            let rawResult = try await transcriptionService.transcribeAudio(
                audioURL: audioURL,
                languageOverride: language,
                progressCallback: progressCb,
                downloadProgress: downloadCb
            )

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

            transcribeStep = .done
            if selectedRecordingID == recordingID {
                transcript = result.transcript
                statusMessage = ""
            }
            Analytics.transcriptionFinished(ok: true)

            let duration = recordingStore.recording(for: recordingID)?.duration ?? durationAtStart
            saveAfterASR = (result.transcript, duration)
        } catch {
            transcribeStep = .failed
            modelDownloadProgress = nil
            let msg = error.localizedDescription
            Analytics.transcriptionFinished(ok: false, reason: "error")
            if selectedRecordingID == recordingID {
                surfacePipelineError(msg)
            } else {
                // Keep error for when they open this meeting later.
                pipelineError = msg
                NSLog("[AppState] Transcription FAILED (background): \(error)")
            }
            if let current = recordingStore.recording(for: recordingID), current.status == "transcribed_raw" {
                // Keep checkpoint
            } else {
                recordingStore.update(id: recordingID, status: "recorded")
            }
            NSLog("[AppState] Transcription FAILED: \(error)")
        }

        // Release ASR lock before save/recap so a second Stop can start ASR.
        isTranscribing = false
        endPipelineWork(recordingID)
        transcriptionService.releaseHeavyResources()

        if let saveAfterASR {
            await runSave(
                recordingID: recordingID,
                transcriptText: saveAfterASR.transcript,
                duration: saveAfterASR.duration
            )
        } else {
            await reconcilePendingPipeline()
        }
    }

    /// Resume diarization for a recording that completed ASR but crashed before
    /// diarization finished. Deserializes the stored segments and runs only Phase 2.
    func completeDiarization(recordingID explicitID: String? = nil) async {
        if isTranscribing {
            statusMessage = "Расшифровка уже идёт"
            return
        }
        let rec: RecordingEntry?
        if let explicitID {
            rec = recordingStore.recording(for: explicitID)
        } else {
            rec = selectedRecording
        }
        guard let rec else { return }
        let recordingID = rec.id
        let durationAtStart = rec.duration
        guard let audioURL = recordingStore.audioURL(for: rec) else {
            statusMessage = "Аудио не найдено — нельзя завершить диаризацию"
            return
        }
        guard let json = rec.rawSegmentsJSON,
              let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([ASRSegment].self, from: data) else {
            statusMessage = "Сегменты не найдены — запустите расшифровку заново"
            return
        }

        isTranscribing = true
        beginPipelineWork(recordingID)

        transcribeStep = .running
        setTransientStatus("Определяем спикеров…")
        recordingStore.update(id: recordingID, status: "transcribing")

        var saveAfter: (transcript: String, duration: TimeInterval)?

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
            Analytics.transcriptionFinished(ok: true, reason: "diarize_resume")

            let duration = recordingStore.recording(for: recordingID)?.duration ?? durationAtStart
            saveAfter = (result.transcript, duration)
        } catch {
            transcribeStep = .failed
            Analytics.transcriptionFinished(ok: false, reason: "diarize")
            if selectedRecordingID == recordingID {
                surfacePipelineError(error.localizedDescription)
            } else {
                pipelineError = error.localizedDescription
            }
            recordingStore.update(id: recordingID, status: "transcribed_raw")
            NSLog("[AppState] Diarization FAILED: \(error)")
        }

        isTranscribing = false
        endPipelineWork(recordingID)
        transcriptionService.releaseHeavyResources()

        if let saveAfter {
            await runSave(
                recordingID: recordingID,
                transcriptText: saveAfter.transcript,
                duration: saveAfter.duration
            )
        } else {
            await reconcilePendingPipeline()
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
            NotificationManager.shared.post(title: "Propeller", body: "Сохранено: \(URL(fileURLWithPath: path).lastPathComponent)")
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
            surfacePipelineError(error.localizedDescription)
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
        setTransientStatus("Генерируем саммари…")
        if selectedRecordingID == recordingID {
            lastRecapPath = nil
        }

        let md: String
        do {
            md = try String(contentsOfFile: transcriptPath, encoding: .utf8)
        } catch {
            recapStep = .failed
            Analytics.recapFinished(ok: false, skip: "read_error")
            if selectedRecordingID == recordingID {
                statusMessage = "Не удалось прочитать транскрипт для саммари"
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
                let skip: String
                switch reason {
                case .disabled: skip = "disabled"
                case .noProvider: skip = "no_provider"
                case .emptyTranscript: skip = "empty"
                }
                Analytics.recapFinished(ok: false, skip: skip)
                if selectedRecordingID == recordingID {
                    switch reason {
                    case .disabled:
                        recapSkipHint = nil
                        statusMessage = ""
                        surfaceMeetingUI(preferSummaryTab: false)
                    case .noProvider:
                        recapSkipHint = "Нет провайдера саммари — запустите Ollama или добавьте API-ключ в Настройках"
                        surfacePipelineError(recapSkipHint ?? "Саммари пропущено")
                        NotificationManager.shared.post(
                            title: "Propeller",
                            body: recapSkipHint ?? "Саммари пропущено"
                        )
                    case .emptyTranscript:
                        recapSkipHint = "Саммари пропущено — пустой транскрипт"
                        surfacePipelineError(recapSkipHint ?? "")
                    }
                    surfaceMeetingUI(preferSummaryTab: false)
                }
            case .success(let recap):
                recapStep = .done
                Analytics.recapFinished(ok: true, backend: recap.provider)
                if selectedRecordingID == recordingID {
                    lastRecapPath = recap.path
                    recapSkipHint = nil
                    statusMessage = "Саммари через \(recap.provider)"
                    statusIsTransient = false
                }
                surfaceSummaryUI(for: recordingID)
                NotificationManager.shared.post(
                    title: "Propeller",
                    body: "Саммари готово — в карточке встречи."
                )
                await generateMeetingMetadata(recordingID: recordingID, summary: recap.body)
                OllamaSidecar.shared.stopAfterIdle(30)
            }
        } catch {
            recapStep = .failed
            Analytics.recapFinished(ok: false)
            // "model ... not found" means the pull never finished — flip the flag
            // so the panel offers «Скачать» instead of a retry that cannot work.
            if error.localizedDescription.lowercased().contains("not found") {
                localRecapModelReady = false
            }
            surfacePipelineError(error.localizedDescription)
            if selectedRecordingID == recordingID {
                recapSkipHint = error.localizedDescription
            }
        }

        startSummaryBackfill(delaySeconds: 60)
        await reconcilePendingPipeline()
    }

    /// Nesting depth for begin/end around transcribe → save → recap.
    private var pipelineWorkDepth = 0
    /// True while `statusMessage` holds a "работаем…" line rather than a result.
    /// Progress lines were being set unconditionally but cleared only when the
    /// finished recording happened to be the selected one, so finishing a recap
    /// from the meetings list left "Генерируем саммари…" in the top bar forever.
    private var statusIsTransient = false

    /// Set an in-progress status. Cleared centrally by `endPipelineWork` so no
    /// individual exit path can forget it.
    private func setTransientStatus(_ message: String) {
        statusMessage = message
        statusIsTransient = true
    }

    private func beginPipelineWork(_ recordingID: String) {
        pipelineWorkDepth += 1
        busyRecordingID = recordingID
    }

    private func endPipelineWork(_ recordingID: String) {
        pipelineWorkDepth = max(0, pipelineWorkDepth - 1)
        if pipelineWorkDepth == 0 {
            busyRecordingID = nil
            // Nothing is running any more — a progress line here would be a lie.
            // Results and errors are not transient and survive.
            if statusIsTransient {
                statusMessage = ""
                statusIsTransient = false
            }
        } else if busyRecordingID == nil {
            busyRecordingID = recordingID
        }
    }

    /// Re-run metadata over meetings that already have a recap but no topics/tags
    /// (or are still stuck on the default title). Catches up 1.11 recordings,
    /// which only ran the pass for auto-titled meetings.
    ///
    /// Same guards as the summary backfill: never during a call, never on a hot
    /// machine, and capped per pass so a long backlog can't cook the Mac.
    private func backfillMissingMetadata() async {
        guard !isRecording, !isTranscribing, !zoomMeetingDetected else { return }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            debugLog("[metadata-backfill] skip: thermal")
            return
        default:
            break
        }

        let candidates = recordingStore.recordings.filter { rec in
            needsMetadata(rec) && hasRecap(for: rec)
        }
        guard !candidates.isEmpty else { return }
        debugLog("[metadata-backfill] \(candidates.count) candidates")

        var did = false
        for rec in candidates.prefix(2) {
            if isRecording || isTranscribing || zoomMeetingDetected { break }
            if ProcessInfo.processInfo.thermalState == .serious
                || ProcessInfo.processInfo.thermalState == .critical { break }
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
            did = true
        }
        if did {
            // Push the idle-stop back so the batch above doesn't get its server
            // killed mid-flight by a timer armed during the summary backfill.
            OllamaSidecar.shared.stopAfterIdle(30)
        }
        debugLog("[metadata-backfill] done")
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
        // Calendar / user titles must not be overwritten by the LLM. The name
        // pattern alone is not enough: someone who renames a meeting to
        // "Запись про бюджет" matches the placeholder prefix, so the explicit
        // manual-rename latch has to win over it.
        let needTitle = Self.isAutoGeneratedTitle(rec.title) && rec.titleManuallySet != true
        // 1.11 skipped this pass entirely unless a title was needed, which meant
        // calendar-titled meetings (now the common case) never got topics or tags
        // at all. The pass runs on the short summary, not the transcript, and
        // `keep_alive` + a single shared num_ctx keep the model resident from the
        // recap call — so it costs one short prompt, not a second cold load.
        let meta = await RecapService.shared.generateMetadata(
            summaryMarkdown: summary,
            needTitle: needTitle,
            prefs: RecapPreferences.fromShared()
        )
        guard let meta else { return }
        // Always written, even when empty: `topics == nil` is the marker for
        // "metadata never ran" that the backfill scans for.
        recordingStore.update(id: recordingID, topics: meta.topics, tags: meta.tags)
        if needTitle, let newTitle = meta.title, !newTitle.isEmpty {
            recordingStore.update(id: recordingID, title: newTitle)
        }
    }

    /// A recap exists but the metadata pass never ran over it. `topics == nil`
    /// means "never ran", `[]` means "ran, found nothing" — so a provider failure
    /// (which writes neither) retries next cycle, while a successful pass never
    /// does. Deliberately *not* keyed on the title still looking auto-generated:
    /// the model is allowed to return `title: null`, and that must not turn into
    /// a meeting the backfill re-runs forever.
    private func needsMetadata(_ rec: RecordingEntry) -> Bool {
        rec.topics == nil
    }

    /// Placeholder stamped at record start when no calendar event matched.
    static func isAutoGeneratedTitle(_ title: String) -> Bool {
        title.hasPrefix("Запись ") || title.hasPrefix("Recording ")
    }

    func reprocess() async {
        guard let id = selectedRecordingID else {
            surfacePipelineError("Запись не выбрана")
            return
        }
        pipelineError = nil
        // Headphones / Zoom: FluidAudio often collapses everyone into the owner.
        // If we already have segments + mic/sys stems, re-split by energy — no ASR.
        if recordingStore.recording(for: id)?.mergedSegmentsJSON != nil {
            setTransientStatus("Уточняем спикеров…")
            if await repairSpeakerAttribution(recordingID: id) {
                return
            }
        }
        setTransientStatus("Запуск расшифровки…")
        saveStep = .pending
        await runTranscribe(recordingID: id)
    }

    /// Re-assign speakers from mic vs system stem energy. Returns false when
    /// stems/segments are missing (caller should fall back to full ASR).
    @discardableResult
    func repairSpeakerAttribution(recordingID: String) async -> Bool {
        guard let rec = recordingStore.recording(for: recordingID),
              let audioURL = recordingStore.audioURL(for: rec),
              let segments = loadPersistedSegments(for: rec),
              !segments.isEmpty else { return false }
        guard let relabeled = transcriptionService.relabelSegmentsFromStems(
            audioURL: audioURL,
            segments: segments
        ) else { return false }

        let before = Set(segments.map(\.speaker))
        let after = Set(relabeled.map(\.speaker))
        let newTranscript = TranscriptionService.formatTranscriptText(from: relabeled)
        let segJSON = encodePersistedSegments(relabeled)
        recordingStore.update(
            id: recordingID,
            transcript: newTranscript,
            mergedSegmentsJSON: .some(segJSON)
        )
        if selectedRecordingID == recordingID {
            transcript = newTranscript
        }
        markDirty()
        // Rewrite markdown only — don't kick another qwen pass just for speaker labels.
        let speakers = MarkdownWriter.extractSpeakers(from: newTranscript)
        _ = try? MarkdownWriter.save(
            title: rec.title,
            transcript: newTranscript,
            recordingID: recordingID,
            duration: rec.duration,
            speakers: speakers,
            notes: rec.notes
        )
        let msg = before == after
            ? "Спикеры без изменений"
            : "Спикеры: \(after.sorted().joined(separator: ", "))"
        statusMessage = msg
        debugLog("[AppState] stem speaker repair \(recordingID): \(before) → \(after)")
        return true
    }

    /// Download Ollama binary (if needed), start serve, pull the recap model.
    /// Progress → `ollamaSetupProgress` / `ollamaSetupMessage` (onboarding + status bar).
    /// On success, kicks summary backfill so meetings recorded meanwhile get recaps.
    @discardableResult
    func downloadOllamaRuntime() async -> Bool {
        let okDisk = await checkDiskSpaceForModelDownload(.recap)
        guard okDisk else {
            surfacePipelineError("Недостаточно места для модели саммари (~3,4 ГБ).")
            return false
        }
        pipelineError = nil
        ollamaSetupProgress = 0
        ollamaSetupMessage = "Подготовка…"
        let model = Preferences.shared.recapOllamaModel
        do {
            try await OllamaSidecar.shared.ensureReady(
                model: model.isEmpty ? OllamaSidecar.defaultModel : model,
                statusCallback: { [weak self] msg in
                    Task { @MainActor in
                        self?.ollamaSetupMessage = msg
                    }
                },
                progress: { [weak self] frac in
                    Task { @MainActor in
                        self?.ollamaSetupProgress = frac
                    }
                }
            )
            ollamaSetupProgress = nil
            ollamaSetupMessage = "Модель готова"
            localRecapModelReady = true
            Analytics.signal("Ollama.setup.ok")
            // Setup is done and nothing needs the server yet. Without this a
            // launch-time resume check that finds the model already present
            // would leave `ollama serve` resident for the whole session
            // (backfill's own idle-stop is skipped when it has no candidates).
            OllamaSidecar.shared.stopAfterIdle(30)
            // Don't slam the GPU with backfill the second the model lands —
            // user may still be mid-call / mid-onboarding.
            startSummaryBackfill(delaySeconds: 120)
            return true
        } catch {
            ollamaSetupProgress = nil
            ollamaSetupMessage = ""
            surfacePipelineError(error.localizedDescription)
            Analytics.signal("Ollama.setup.fail")
            return false
        }
    }

    private var ollamaDownloadTask: Task<Void, Never>?

    /// Fire-and-forget: start Ollama install in background so onboarding / Settings
    /// can proceed immediately. Progress stays in the status bar.
    func startOllamaRuntimeDownload() {
        // Remember the opt-in before the first byte, so quitting mid-download
        // still resumes on the next launch.
        Preferences.shared.localRecapModelRequested = true
        if ollamaDownloadTask != nil || ollamaSetupProgress != nil { return }
        ollamaDownloadTask = Task { [weak self] in
            defer {
                Task { @MainActor in self?.ollamaDownloadTask = nil }
            }
            _ = await self?.downloadOllamaRuntime()
        }
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
