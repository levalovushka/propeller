import AVFoundation
import PropellerPure
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
    /// The single source of truth for in-flight work
    /// (docs/REFACTOR-PIPELINE-STATE.md). Replaced `transcribeStep` /
    /// `saveStep` / `recapStep` / `busyRecordingID` / `statusMessage` /
    /// `statusIsTransient` — seven fields, ~2000 combinations, one now.
    @Published private(set) var activity: PipelineActivity = .idle

#if GALLERY
    /// Pose for a screenshot. Compiled out of shipping builds, so it cannot
    /// become the second source of truth the whole state refactor removed.
    /// Activity is ephemeral by design — nothing here is persisted.
    func galleryPose(activity: PipelineActivity) { self.activity = activity }

    /// Keeps the worker out of a screenshot run. Posed meetings are fiction —
    /// they have no audio — and a worker that took one seriously would race the
    /// poser for `activity` halfway through a frame.
    var galleryFrozen = false

    /// Forces the summary panel's «Скачать» / «Сгенерировать» branch. The real
    /// answer depends on the user's provider settings and installed models,
    /// neither of which a screenshot run may touch.
    var galleryRecapModelOverride: Bool?

    /// Opens the summary in its editor. Editing is entered by tapping the
    /// rendered recap, i.e. through private `@State` no poser can reach —
    /// without this, "Саммари — правка" photographed the read view.
    var galleryEditingRecap = false
#endif
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
    /// Failure of the summary-model setup specifically. Separate from
    /// `pipelineError`: onboarding used to show the shared pipeline error, so an
    /// unrelated ASR failure ("gigastt недоступен") appeared on the screen that
    /// offers to download the *summary* model, which reads as that download
    /// having failed.
    @Published var ollamaSetupError: String? = nil
    /// Is the local summary model on disk? Nil until first checked. Drives the
    /// empty-summary panel: without it the UI offers «Сгенерировать», which can
    /// only fail with `HTTP 404: model not found`.
    @Published var localRecapModelReady: Bool? = nil

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
    @Published var meetingDetected = false
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

    /// True when this recording was started by a detected call (any platform),
    /// so hanging up can stop it.
    private var recordingLinkedToCall = false
    /// User declined auto-recording for the call in progress — sticky until the
    /// conferencing app quits, so it isn't asked again mid-call (G3).
    private var ignoredDetectedCall = false
    /// Set right before an auto-start so `beginRecording` knows to post the
    /// interactive "recording started" notification (manual starts don't).
    private var autoStartedFromMeeting = false
    /// Mutex so Stop / Discard / end-of-call can't race two `recorder.stop()` calls.
    private var isTerminalRecordingAction = false

    // Stores & Services
    let recordingStore = RecordingStore()
    /// The two swappable boundaries (see PipelineBoundaries.swift). Concrete in
    /// the app, doubles in a harness — nothing else about the pipeline needs to
    /// change to run it against fixtures.
    let transcriptionService: Transcriber
    private let recapBackend: RecapBackend
    private let meetingDetector = MeetingDetector.shared

    init(
        transcriber: Transcriber? = nil,
        recapBackend: RecapBackend = RecapService.shared
    ) {
        self.transcriptionService = transcriber ?? TranscriptionService()
        self.recapBackend = recapBackend
#if GALLERY
        // Freeze here rather than when the first pose runs: `bootstrap()` kicks
        // the worker before any screen is posed, and the fixture archive holds
        // meetings that look like unfinished work — silent audio the worker
        // would happily send to the ASR sidecar.
        galleryFrozen = GalleryFixture.isActive
#endif
    }

    var selectedRecording: RecordingEntry? {
        guard let id = selectedRecordingID else { return nil }
        return recordingStore.recording(for: id)
    }

    // MARK: - Initialization

    func bootstrap() {
        guard !didBootstrap else { return }
        // A probe run is not a session: the app is up only to answer a question
        // and quit. Left unguarded, the meeting detector saw the very call being
        // probed and started recording it — the first probe left a 0-second stub
        // in the archive, which the pipeline then owed a summary.
        if TapProbe.isRequested { return }
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

        setupMeetingDetector()

        // Quick-note overlay: register the state; key monitors install only
        // while a recording is active (plan-optimization E7).
        NoteOverlayController.shared.install(state: self)

        // Load upcoming meetings if the user opted into Calendar. Use the
        // requesting path so access is re-prompted after an ad-hoc rebuild
        // resets TCC (otherwise the list silently shows nothing).
        if Preferences.shared.calendarEnabled {
            Task { await CalendarService.shared.enableAndLoad() }
        }

        // Everything unfinished — recovered recordings, meetings still owed a
        // transcript, and past meetings still owed a summary — is one queue now.
        kickPipeline()

        // Finish a summary-model download that a quit (or a dropped connection
        // that outlived the in-session retries) left half-done. No-op when the
        // model is already there; delayed so launch stays quiet.
        if Preferences.shared.localRecapModelRequested {
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !isRecording, !isTranscribing, !meetingDetected else { return }
                startOllamaRuntimeDownload()
            }
        }

        // ASR sidecar starts lazily on first transcription (plan-optimization E1).
    }

    // MARK: - Call auto-detect

    private func setupMeetingDetector() {
        meetingDetector.onMeetingStarted = { [weak self] in
            Task { @MainActor in self?.handleCallStarted() }
        }
        meetingDetector.onMeetingEnded = { [weak self] in
            Task { @MainActor in self?.handleCallEnded() }
        }
        applyAutoRecordMode()
    }

    /// Call when the auto-record preference changes in Settings.
    func applyAutoRecordMode() {
        let mode = Preferences.shared.autoRecordMode
        if mode == .off {
            meetingDetector.stop()
            meetingDetected = false
            ignoredDetectedCall = false
        } else {
            meetingDetector.start()
            meetingDetected = meetingDetector.isInMeeting
        }
    }

    private func handleCallStarted() {
        meetingDetected = true
        // A 4 GB model must not stay on the GPU for the duration of a call.
        pausePipeline()
        // Do NOT clear ignoredDetectedCall here — sticky for this call (G3).
        guard Preferences.shared.autoRecordMode != .off else { return }
        guard !isRecording else {
            // Already recording (manual) — still link so end-of-call can stop it (DECIDE-7).
            recordingLinkedToCall = true
            return
        }
        startRecordingFromDetectedCall()
    }

    private func handleCallEnded() {
        meetingDetected = false
        if isRecording && recordingLinkedToCall {
            stopRecording()
        }
        recordingLinkedToCall = false
        // Sticky ignore clears only once the conferencing app is gone (not on brief detector flaps).
        if !MeetingDetector.isAnyConferencingAppRunning() {
            ignoredDetectedCall = false
        }
        kickPipeline()
    }

    /// Start recording a detected call without asking. A system
    /// notification is posted (in `beginRecording`) so the user can decline.
    func acceptDetectedCallPrompt() {
        ignoredDetectedCall = false
        startRecordingFromDetectedCall()
    }

    private func startRecordingFromDetectedCall() {
        guard !isRecording else { return }
        guard !ignoredDetectedCall else { return }
        // Upcoming «Don't record» mutes this calendar session (DECIDE-6).
        if CalendarService.shared.isMutedForRecording() { return }
        recordingLinkedToCall = true
        autoStartedFromMeeting = true
        startRecording()
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
        // BUG-PIPE-03 is gone by construction: there are no global step lights
        // left to wipe, and another meeting's job lives in `activity`.
        recapSkipHint = nil
        lastRecapPath = nil

        // Playback of an older meeting must not keep running under a new
        // recording — it also poisons the next auto-load (release-review rev-7).
        player.stop()
        // Catch-up work yields to the meeting being recorded (D10).
        pausePipeline()

        // Analytics dimension: how the recording began, not which app it was.
        let recordingSource = autoStartedFromMeeting ? "auto" : "manual"

        do {
            try recorder.start()
            isRecording = true
            // Call already in progress and the user started manually — still link it so
            // hanging up stops the recording.
            if meetingDetector.isInMeeting || meetingDetected {
                recordingLinkedToCall = true
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
                status: .recording,
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
            recordingLinkedToCall = false
            autoStartedFromMeeting = false
        }
    }

    /// Cancel the in-progress recording and discard it entirely (no transcript,
    /// no saved audio). Triggered by the "Don't record" notification action.
    func cancelRecording() {
        guard isRecording else { return }
        ignoredDetectedCall = true
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
        recordingLinkedToCall = false
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
        let wasLinkedToCall = recordingLinkedToCall
        recordingLinkedToCall = false
        NotificationManager.shared.clearRecordingNotification()
        player.stop()

        do {
            let result = try await recorder.stop()
            recordingDuration = result.duration
            let micOnly = recorder.lastStopWasMicOnly
            recordingStore.update(
                id: result.id,
                status: .recorded,
                duration: result.duration,
                micOnlyCaptured: micOnly,
                systemCaptureAppScoped: recorder.lastStopWasAppScoped,
                // Persisted so a re-mix after a crash puts the far end back in
                // the same place instead of guessing zero.
                systemStemOffset: recorder.lastStopSystemStemOffset
            )
            selectedRecordingID = result.id

            // Keep for live detail of *this* stop; badge itself reads entry.micOnlyCaptured.
            Analytics.recordingFinished(duration: result.duration, micOnly: micOnly)

            if runPipeline {
                let body = wasLinkedToCall
                    ? "Запись звонка остановлена. Расшифровка…"
                    : "Запись остановлена. Расшифровка…"
                NotificationManager.shared.post(title: "Propeller", body: body)
                kickPipeline()
            }
        } catch {
            NSLog("[AppState] stopRecording error: \(error)")
        }
    }

    // MARK: - Display Timer

    /// Hard ceiling for a single recording (decision 2026-07-25). A meeting that
    /// never gets a detected end (conferencing app left open, detector wedged) would
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
                    NSLog("[AppState] 8h recording ceiling reached — stopping")
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

        // Selecting a meeting no longer restores any pipeline lights: what is
        // running is `activity`, what was achieved is `entry.status`. Neither
        // depends on which row happens to be open (BUG-PIPE-02).
        recapSkipHint = nil
        if let recapURL = Self.recapURL(for: entry), FileManager.default.fileExists(atPath: recapURL.path) {
            lastRecapPath = recapURL.path
        } else {
            lastRecapPath = nil
        }
    }

    static func recapURL(for entry: RecordingEntry) -> URL? {
        let slug = MarkdownWriter.slugify(entry.title.isEmpty ? entry.id : entry.title)
        let filename = "\(entry.id)-\(slug)-recap.md"
        return URL(fileURLWithPath: Preferences.shared.meetingsPath)
            .appendingPathComponent(filename)
    }

    /// Resolve `*-recap.md` on disk. The filename embeds a slug of the title, so
    /// after a rename the expected name no longer exists — hence the fall back to
    /// matching by recording id (`RecapFile`, shared with the reconciler).
    ///
    /// The only recap resolver in the app: there were four, all subtly different (D4).
    static func resolvedRecapURL(for entry: RecordingEntry) -> URL? {
        if let url = recapURL(for: entry), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let dir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.first { RecapFile.isRecap($0.lastPathComponent, for: entry.id) }
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
#if GALLERY
        if let forced = galleryRecapModelOverride { return forced }
#endif
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

    /// Persist a user-visible pipeline error (detail panel + toast).
    func surfacePipelineError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pipelineError = trimmed
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

    // MARK: - Transcript markdown lookup

    /// Resolve the transcript markdown file for a recording (the title slug in the
    /// filename may be stale after a rename), or nil if it hasn't been saved yet.
    private func transcriptMarkdownURL(for entry: RecordingEntry) -> URL? {
        let dir = URL(fileURLWithPath: Preferences.shared.meetingsPath)
        let slug = MarkdownWriter.slugify(entry.title.isEmpty ? entry.id : entry.title)
        let expected = dir.appendingPathComponent("\(entry.id)-\(slug).md")
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.first { RecapFile.isTranscript($0.lastPathComponent, for: entry.id) }
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

    // MARK: - Worker

    /// The single running pipeline loop, or nil when idle.
    private var workerTask: Task<Void, Never>?

    /// What the scheduler is allowed to do right now. These guards used to live
    /// only inside the summary backfill, which is why ASR could still fire in
    /// the middle of a call.
    private var workerPolicy: WorkerPolicy {
        let thermal = ProcessInfo.processInfo.thermalState
        return WorkerPolicy(
            isRecording: isRecording,
            inCall: meetingDetected,
            isThermallyStressed: thermal == .serious || thermal == .critical
        )
    }

    /// Ask the worker to look for work. Safe to call from anywhere, any number
    /// of times — a loop is already running or one gets started, never two.
    func kickPipeline() {
#if GALLERY
        if galleryFrozen { return }
#endif
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runPipelineLoop()
            await MainActor.run { self?.workerTask = nil }
        }
    }

    /// Stop after the current phase. Called when the policy closes — a call
    /// starting mid-summary should not keep Ollama on the GPU for its duration.
    func pausePipeline() {
        workerTask?.cancel()
    }

    /// Throw away work in flight and start over. Used when an edit invalidates
    /// what is being generated right now: a second edit while the first summary
    /// is still running must supersede it, not queue behind it.
    func restartPipeline() {
        guard let running = workerTask else {
            kickPipeline()
            return
        }
        running.cancel()
        Task { [weak self] in
            _ = await running.value      // clears `workerTask` on the way out
            self?.kickPipeline()
        }
    }

    /// Drains the queue one phase at a time. The loop's rules live in
    /// `PipelineDrain` so they can be tested without an ASR sidecar or an LLM;
    /// this supplies the three things only the app knows.
    private func runPipelineLoop() async {
        let stop = await PipelineDrain.run(
            nextJob: { [weak self] in
                guard let self else { return nil }
                return PropellerPure.nextJob(
                    from: self.recordingStore.recordings,
                    policy: self.workerPolicy
                )
            },
            perform: { [weak self] job in
                guard let self else { return .blocked }
                debugLog("[pipeline] → \(job.recordingID) \(job.phase)")
                return await self.run(job)
            }
        )
        switch stop {
        case .finished:
            break
        case .blocked(let job):
            debugLog("[pipeline] blocked on \(job.phase) — waiting for a kick")
        case .cancelled:
            debugLog("[pipeline] paused: \(workerPolicy)")
        case .stalled(let job):
            // A phase claimed progress and made none. Loud, because the loop
            // would otherwise ask for this same job forever.
            checkInvariant("i11.no-stall", false)
            NSLog("[AppState] pipeline stalled on \(job.recordingID) \(job.phase)")
        }
    }

    /// Runs exactly one phase. Phases never call each other — the loop decides
    /// what comes next, from the stage on disk.
    private func run(_ job: PipelineJob) async -> PhaseOutcome {
        switch job.phase {
        case .transcribing:
            await runTranscribe(recordingID: job.recordingID)
        case .diarizing:
            await completeDiarization(recordingID: job.recordingID)
        case .saving:
            guard let rec = recordingStore.recording(for: job.recordingID),
                  let text = rec.transcript, !text.isEmpty else {
                recordFailure(job.recordingID, phase: .saving, message: "Нет транскрипта для сохранения")
                return .advanced
            }
            await runSave(recordingID: rec.id, transcriptText: text, duration: rec.duration)
        case .summarizing:
            return await runSummarize(recordingID: job.recordingID)
        }
        return .advanced
    }

    /// Summary phase entry point: resolves the transcript markdown the recap is
    /// written next to, then runs the one recap path there is.
    private func runSummarize(recordingID: String) async -> PhaseOutcome {
        guard let rec = recordingStore.recording(for: recordingID) else { return .advanced }
        guard let mdURL = transcriptMarkdownURL(for: rec) else {
            recordFailure(recordingID, phase: .summarizing, message: "Транскрипт не найден на диске")
            return .advanced
        }
        return await runRecap(
            title: rec.title,
            transcriptPath: mdURL.path,
            speakers: MarkdownWriter.extractSpeakers(from: rec.transcript ?? ""),
            notes: rec.notes,
            recordingID: recordingID,
            duration: rec.duration
        )
    }

    /// ASR + diarization. Both phases live here because they share everything
    /// except where they start: `.transcribing` runs the full pass, `.diarizing`
    /// resumes from the checkpoint a crash left behind. Keeping them apart meant
    /// ~90 duplicated lines of orchestration (D6).
    func runTranscribe(recordingID explicitID: String? = nil) async {
        await runASR(recordingID: explicitID, phase: .transcribing)
    }

    /// Resume diarization for a recording that finished ASR but crashed before
    /// speakers were assigned — the expensive pass is not repeated.
    func completeDiarization(recordingID explicitID: String? = nil) async {
        await runASR(recordingID: explicitID, phase: .diarizing)
    }

    private func runASR(recordingID explicitID: String?, phase: PipelineActivity.Phase) async {
        if isTranscribing {
            // Only the user-facing path complains; the worker just moves on.
            if phase == .transcribing {
                surfacePipelineError(explicitID != nil ? "В очереди на расшифровку…" : "Расшифровка уже идёт")
            }
            return
        }
        guard let rec = explicitID.flatMap({ recordingStore.recording(for: $0) }) ?? selectedRecording else {
            if phase == .transcribing { surfacePipelineError("Запись не выбрана") }
            return
        }
        let recordingID = rec.id
        let durationAtStart = rec.duration
        guard let audioURL = recordingStore.audioURL(for: rec) else {
            let msg = "Аудиофайл не найден — нельзя расшифровать."
            surfacePipelineError(msg)
            recordFailure(recordingID, phase: phase, message: msg)
            return
        }

        // Only a full pass can need the ASR model on disk.
        if phase == .transcribing {
            guard await checkDiskSpaceForModelDownload() else {
                surfacePipelineError("Расшифровка отменена — мало места на диске.")
                return
            }
        }

        // Resuming needs the checkpoint the earlier pass wrote.
        var checkpoint: [ASRSegment]?
        if phase == .diarizing {
            guard let json = rec.rawSegmentsJSON,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([ASRSegment].self, from: data) else {
                recordFailure(recordingID, phase: phase, message: "Сегменты не найдены — запустите расшифровку заново")
                return
            }
            checkpoint = decoded
        }

        pipelineError = nil
        isTranscribing = true
        beginPipelineWork(recordingID, phase: phase)
        setActivityDetail(phase == .transcribing ? "Загрузка моделей…" : "Определяем спикеров…")
        modelDownloadProgress = nil
        recordingStore.update(id: recordingID, status: .transcribing)

        let progressCb: (String) -> Void = { [weak self] progress in
            Task { @MainActor in self?.setActivityDetail(progress) }
        }

        do {
            let asrSegments: [ASRSegment]
            if let checkpoint {
                asrSegments = checkpoint
            } else {
                let downloadCb: (Double) -> Void = { [weak self] fraction in
                    Task { @MainActor in
                        self?.modelDownloadProgress = fraction >= 1.0 ? nil : fraction
                    }
                }
                let raw = try await transcriptionService.transcribeAudio(
                    audioURL: audioURL,
                    languageOverride: rec.language,
                    progressCallback: progressCb,
                    downloadProgress: downloadCb
                )
                // Checkpoint before diarization: this is the line that saves an
                // hour of GPU if the next step dies (I4).
                recordingStore.update(
                    id: recordingID,
                    transcript: raw.rawText,
                    status: .transcribedRaw,
                    rawSegmentsJSON: .some(Self.encodeASRSegments(raw.segments))
                )
                modelDownloadProgress = nil
                asrSegments = raw.segments
            }

            let result = try await transcriptionService.diarize(
                audioURL: audioURL,
                asrSegments: asrSegments,
                systemStemOffset: recordingStore.recording(for: recordingID)?.systemStemOffset ?? 0,
                progressCallback: progressCb
            )
            recordingStore.update(
                id: recordingID,
                transcript: result.transcript,
                status: .transcribed,
                rawSegmentsJSON: .some(nil),
                mergedSegmentsJSON: .some(encodePersistedSegments(result.mergedSegments))
            )
            if selectedRecordingID == recordingID { transcript = result.transcript }
            Analytics.transcriptionFinished(
                ok: true,
                reason: phase == .diarizing ? "diarize_resume" : nil
            )
            _ = durationAtStart
        } catch {
            modelDownloadProgress = nil
            let msg = error.localizedDescription
            Analytics.transcriptionFinished(ok: false, reason: phase == .diarizing ? "diarize" : "error")
            if selectedRecordingID == recordingID {
                surfacePipelineError(msg)
            } else {
                // Keep it for when they open this meeting later.
                pipelineError = msg
            }
            // Never fall below the checkpoint (I4).
            let current = recordingStore.recording(for: recordingID)?.status
            if current != .transcribedRaw {
                recordingStore.update(id: recordingID, status: phase == .diarizing ? .transcribedRaw : .recorded)
            }
            recordFailure(recordingID, phase: phase, message: msg)
            NSLog("[AppState] \(phase) FAILED: \(error)")
        }

        isTranscribing = false
        endPipelineWork(recordingID)
        transcriptionService.releaseHeavyResources()
        kickPipeline()
    }

    private static func encodeASRSegments(_ segments: [ASRSegment]) -> String? {
        guard let data = try? JSONEncoder().encode(segments) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func runSave(
        recordingID: String,
        transcriptText: String,
        duration: TimeInterval
    ) async {
        guard let rec = recordingStore.recording(for: recordingID) else { return }
        beginPipelineWork(recordingID, phase: .saving)
        defer { endPipelineWork(recordingID) }
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
            advanceStage(recordingID, to: .saved)
            NotificationManager.shared.post(title: "Propeller", body: "Сохранено: \(URL(fileURLWithPath: path).lastPathComponent)")
            kickPipeline()
        } catch {
            recordFailure(recordingID, phase: .saving, message: error.localizedDescription)
            surfacePipelineError(error.localizedDescription)
        }
    }

    /// Generate LLM recap next to the saved transcript. Skips quietly when no provider is configured.
    @discardableResult
    func runRecap(
        title: String,
        transcriptPath: String,
        speakers: [String],
        notes: String?,
        recordingID: String,
        duration: TimeInterval
    ) async -> PhaseOutcome {
        beginPipelineWork(recordingID, phase: .summarizing)
        defer { endPipelineWork(recordingID) }
        setActivityDetail("Генерируем саммари…")
        if selectedRecordingID == recordingID {
            lastRecapPath = nil
        }

        let md: String
        do {
            md = try String(contentsOfFile: transcriptPath, encoding: .utf8)
        } catch {
            Analytics.recapFinished(ok: false, skip: "read_error")
            recordFailure(recordingID, phase: .summarizing, message: "Не удалось прочитать транскрипт")
            if selectedRecordingID == recordingID {
            }
            return .advanced
        }

        // Assume progress; the no-provider branch downgrades this.
        var outcome = PhaseOutcome.advanced
        // A summary appearing for the first time is news — the window comes
        // forward and a notification is posted. Regenerating one after an edit
        // is not: it happens quietly, wherever the user happens to be.
        let isFirstSummary = recordingStore.recording(for: recordingID)
            .map { !hasRecap(for: $0) } ?? true
        do {
            let result = try await recapBackend.generateRecap(
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
                let skip: String
                switch reason {
                case .disabled: skip = "disabled"
                case .noProvider: skip = "no_provider"
                case .emptyTranscript: skip = "empty"
                }
                Analytics.recapFinished(ok: false, skip: skip)
                // Not this meeting's fault: retrying it, or moving to the next
                // one, would fail identically until a provider shows up.
                if reason != .emptyTranscript { outcome = .blocked }
                if reason == .emptyTranscript {
                    recordFailure(recordingID, phase: .summarizing, message: "Пустой транскрипт")
                }
                if selectedRecordingID == recordingID {
                    switch reason {
                    case .disabled:
                        recapSkipHint = nil
                        surfaceMeetingUI(preferSummaryTab: false)
                    case .noProvider:
                        // A skip, not a failure. This used to raise "Не удалось
                        // обработать" plus a system notification after *every*
                        // successful recording, which read as the recording
                        // having broken. The meeting card already explains it and
                        // offers «Скачать»; that is where it belongs.
                        recapSkipHint = "Саммари пропущено — локальная модель ещё не скачана. Кнопка «Скачать» на вкладке «Саммари»."
                        localRecapModelReady = false
                    case .emptyTranscript:
                        recapSkipHint = "Саммари пропущено — пустой транскрипт"
                        surfacePipelineError(recapSkipHint ?? "")
                    }
                    surfaceMeetingUI(preferSummaryTab: false)
                }
            case .success(let recap):
                Analytics.recapFinished(ok: true, backend: recap.provider)
                if selectedRecordingID == recordingID {
                    lastRecapPath = recap.path
                    recapSkipHint = nil
                }
                if isFirstSummary {
                    surfaceSummaryUI(for: recordingID)
                    NotificationManager.shared.post(
                        title: "Propeller",
                        body: "Саммари готово — в карточке встречи."
                    )
                }
                await generateMeetingMetadata(recordingID: recordingID, summary: recap.body)
                // Recap + metadata are both in — this is what `.summarized`
                // means, and it is what takes the meeting out of the queue.
                advanceStage(recordingID, to: .summarized)
                OllamaSidecar.shared.stopAfterIdle(30)
            }
        } catch is CancellationError {
            // Superseded by a newer edit: leave the stage and the entry alone so
            // the restarted loop picks it straight back up.
            debugLog("[pipeline] recap cancelled for \(recordingID)")
            return .advanced
        } catch {
            recordFailure(recordingID, phase: .summarizing, message: error.localizedDescription)
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
        return outcome
    }

    /// Nesting depth for begin/end around transcribe → save → recap.
    private var pipelineWorkDepth = 0
    /// Attach a sidecar progress line to the running phase. No-op when idle —
    /// which is what makes a stale progress line unrepresentable (I1).
    private func setActivityDetail(_ detail: String) {
        guard case .working(let id, let phase, _) = activity else { return }
        activity = .working(recordingID: id, phase: phase, detail: detail)
    }

    private func beginPipelineWork(_ recordingID: String, phase: PipelineActivity.Phase) {
        pipelineWorkDepth += 1
        activity = .working(recordingID: recordingID, phase: phase, detail: nil)
        // A new attempt is starting, so the previous failure is history. The
        // worker never reaches here for a blocked recording, so this only ever
        // fires on an explicit retry.
        if recordingStore.recording(for: recordingID)?.lastFailure != nil {
            clearFailure(recordingID)
        }
    }

    private func endPipelineWork(_ recordingID: String) {
        pipelineWorkDepth = max(0, pipelineWorkDepth - 1)
        if pipelineWorkDepth == 0 {
            activity = .idle
            // Nothing is running any more — a progress line here would be a lie.
        }
        // I1: nothing running ⇒ nothing claiming to run.
        checkInvariant("i1.idle-after-work", pipelineWorkDepth > 0 || activity.isIdle)
    }

    /// Trips the debugger locally, and reports from release builds — an
    /// invariant only checked on the author's machine tells you nothing about
    /// the five colleagues actually using the app.
    private func checkInvariant(_ name: String, _ holds: Bool) {
        guard !holds else { return }
        assertionFailure("invariant \(name) violated")
        NSLog("[AppState] INVARIANT \(name) violated")
        Analytics.signal("Invariant.\(name)")
    }

    /// Record a failure on the recording it happened to. Persisted, so it
    /// outlives other work and a relaunch — and takes the recording out of the
    /// queue until the user retries (I7).
    private func recordFailure(
        _ recordingID: String,
        phase: PipelineActivity.Phase,
        message: String
    ) {
        recordingStore.update(
            id: recordingID,
            lastFailure: .some(PipelineFailure(phase: phase, message: message))
        )
    }

    /// Clear the block so the worker can pick this recording up again.
    func clearFailure(_ recordingID: String) {
        recordingStore.update(id: recordingID, lastFailure: .some(nil))
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
        let meta = await recapBackend.generateMetadata(
            summaryMarkdown: summary,
            needTitle: needTitle,
            prefs: RecapPreferences.fromShared()
        )
        guard let meta else { return }
        // Always written, even when empty: `topics == nil` is the marker for
        // "metadata never ran" that reconciliation reads.
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
    /// a meeting the pipeline re-runs forever.
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
        clearFailure(id)
        // Headphones on a call: FluidAudio often collapses everyone into the owner.
        // If we already have segments + mic/sys stems, re-split by energy — no ASR.
        if recordingStore.recording(for: id)?.mergedSegmentsJSON != nil {
            // Relabelling *is* diarization, so it reports as that phase rather
            // than through a separate status line nobody else can clear.
            beginPipelineWork(id, phase: .diarizing)
            let repaired = await repairSpeakerAttribution(recordingID: id)
            endPipelineWork(id)
            if repaired { return }
        }
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
            segments: segments,
            systemStemOffset: rec.systemStemOffset ?? 0
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
        debugLog("[AppState] stem speaker repair \(recordingID): \(before) → \(after)")
        return true
    }

    /// Download Ollama binary (if needed), start serve, pull the recap model.
    /// Progress → `ollamaSetupProgress` / `ollamaSetupMessage` (onboarding + status bar).
    /// On success, kicks the pipeline so meetings recorded meanwhile get recaps.
    @discardableResult
    func downloadOllamaRuntime() async -> Bool {
        let okDisk = await checkDiskSpaceForModelDownload(.recap)
        guard okDisk else {
            let msg = "Недостаточно места для модели саммари (~3,4 ГБ)."
            ollamaSetupError = msg
            surfacePipelineError(msg)
            return false
        }
        pipelineError = nil
        ollamaSetupError = nil
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
            ollamaSetupError = nil
            localRecapModelReady = true
            Analytics.signal("Ollama.setup.ok")
            // Setup is done and nothing needs the server yet. Without this a
            // launch-time resume check that finds the model already present
            // would leave `ollama serve` resident for the whole session
            // (backfill's own idle-stop is skipped when it has no candidates).
            OllamaSidecar.shared.stopAfterIdle(30)
            // A provider just appeared, which is exactly the condition that
            // parks the loop — everything waiting on a summary can go now.
            kickPipeline()
            return true
        } catch {
            ollamaSetupProgress = nil
            ollamaSetupMessage = ""
            ollamaSetupError = error.localizedDescription
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
        // Only speaker labels changed, so `runSave` rewrites the markdown and
        // the stage stays where it was — same reasoning as the stem relabel.
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

    // MARK: - Dirty Tracking

    /// Move a recording forward to the stage a finished phase reached. Never
    /// backwards — see `RecordingStage.advanced(to:)`.
    private func advanceStage(_ recordingID: String, to reached: RecordingStage) {
        guard let current = recordingStore.recording(for: recordingID)?.status else { return }
        let next = current.advanced(to: reached)
        guard next != current else { return }
        recordingStore.update(id: recordingID, status: next)
    }

    /// Title or notes changed. Both appear in the transcript markdown, so the
    /// file is rewritten — but the summary is built from the transcript text,
    /// which did not change, so it is deliberately left alone. Renaming a
    /// meeting must not cost minutes of GPU.
    func markDirty() {
        guard let id = selectedRecordingID,
              let rec = recordingStore.recording(for: id),
              let text = rec.transcript, !text.isEmpty,
              rec.status >= .saved else { return }
        _ = try? MarkdownWriter.save(
            title: rec.title,
            transcript: text,
            recordingID: id,
            duration: rec.duration,
            speakers: MarkdownWriter.extractSpeakers(from: text),
            notes: rec.notes
        )
    }

    /// Update notes for the selected recording with debounced persistence.
    func updateNotes(_ entry: RecordingEntry, to notes: String) {
        let value: String? = notes.isEmpty ? nil : notes
        recordingStore.update(id: entry.id, notes: .some(value))
        markDirty()
    }

    // MARK: - Helpers

}
