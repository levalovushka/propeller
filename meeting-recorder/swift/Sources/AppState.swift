import AppKit
import AVFoundation
import PropellerPure
import PropellerUI
import SwiftUI

/// Что показывает правая панель.
///
/// Две ветки, не флаг: панель показывает ровно одно, и «настройки открыты, а
/// встреча всё ещё выбрана» — состояние, которого не должно быть выразимо.
enum PaneRoute: Equatable {
    case meeting
    case settings
}

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false

    // Recording
    @Published var recorder = AudioRecorder()
    @Published var player = AudioPlayer()
    /// Что слышно прямо сейчас — живой транскрипт идущей встречи. Отдельный
    /// объект, а не поле: за него подписывается только экран записи, и текст,
    /// приходящий несколько раз в секунду, не должен перерисовывать рельс.
    let live = LiveTranscriptService()
    /// Какую запись сейчас пишем. Не то же, что «выбранная»: во время записи
    /// можно уйти читать другую встречу, и панель обязана понимать, на какую из
    /// двух она смотрит.
    @Published private(set) var activeRecordingID: String?
    /// Время записи. Одна величина, а не две: строка выводится из секунд.
    ///
    /// Раньше рядом жил `@Published var elapsedString`, и тик таймера присваивал
    /// обе — то есть объявлял изменение дважды в секунду, а `MainView` подписан на
    /// `AppState` целиком и пересобирался столько же раз. Заодно это был второй
    /// источник правды о том, сколько идёт встреча.
    @Published var elapsedSeconds: TimeInterval = 0
    var elapsedString: String { Self.formatElapsed(elapsedSeconds) }
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

    /// Poses «Короче» mid-flight: the fragment selected and shimmering while
    /// the model thinks. Reachable no other way — it needs a live model and the
    /// seconds it takes to answer.
    var galleryRewritingSummary = false

    /// Pose a soft-deleted meeting (out of the list). Deletion no longer shows
    /// a «Вернуть» row — ⌘Z restores. Kept so gallery reset can clear the slot.
    func galleryPoseDeletion(_ entry: RecordingEntry?) { pendingDeletion = entry }

    func galleryPoseMicDenied(_ denied: Bool) { micAccessDenied = denied }

    /// Dock one of the rail's two questions. The real answer is derived from
    /// `Preferences`, which a screenshot run may not write — and the pose has to
    /// survive `refreshSetupPrompt`, so it is set here rather than by faking the
    /// defaults behind it.
    func galleryPoseSetupPrompt(_ prompt: SetupPrompt?) { setupPrompt = prompt }

    /// Какая встреча «пишется». Настоящую запись позировать нечем — она требует
    /// микрофона и живого сайдкара, — а панель выбирает вид по этому полю.
    func galleryPoseRecording(_ id: String?) { activeRecordingID = id }

    func galleryPosePaused(_ paused: Bool) { recorder.galleryPosePaused(paused) }
#endif
    /// Last pipeline failure shown in the empty transcript / recap panels.
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

    /// Что стоит сейчас в правой панели — встреча или настройки.
    ///
    /// Настройки перестали быть окном (2026-08-07), и это не косметика: окно
    /// настроек в приложении со строкой меню — вторая поверхность, которую надо
    /// найти, поднять и закрыть, ради полутора страниц переключателей. Как
    /// состояние панели они открываются той же строкой рельса, что и встреча, и
    /// закрываются выбором любой встречи.
    ///
    /// Живёт здесь, а не во вью, потому что открыть настройки просят снаружи
    /// окна — из меню-бара и с ⌘, (`SettingsOpener`).
    @Published var paneRoute: PaneRoute = .meeting

    /// Recording was asked for and the microphone is not ours to open.
    ///
    /// An attribute of recording, not a message about it: the row that starts a
    /// recording says so itself, and clicking it goes where the permission is.
    /// A message would have to be read at the moment it appeared — which is the
    /// moment the user is in a call and not looking at this window.
    @Published private(set) var micAccessDenied = false

    // Window
    @Published var isWindowOpen = false {
        didSet {
            // Уровень нужен не только окну: лопасть в чёлке идёт всю запись, и
            // её остановка означает паузу, а не закрытое окно. Экономия E5
            // остаётся там, где потребитель действительно один: вне записи
            // метринг не работает вовсе.
            if isRecording {
                recorder.setMeteringDesired(true)
            }
        }
    }
    /// Must be decided before the first window paint — RootWindow swaps
    /// onboarding card vs main UI from this flag alone.
    @Published var showOnboarding = !Preferences.shared.onboardingCompleted {
        didSet { refreshSetupPrompt() }
    }

    /// The question the rail is still carrying — the calendar, then the name.
    /// Nil for the whole of the app's ordinary life. Decided by
    /// `SetupPromptMachine`; published because the answer lives in `Preferences`,
    /// which SwiftUI cannot watch.
    @Published var setupPrompt: SetupPrompt? = SetupPromptMachine.step(
        setupCompleted: Preferences.shared.onboardingCompleted,
        calendarGranted: Preferences.shared.calendarEnabled,
        calendarAsked: Preferences.shared.setupCalendarAsked,
        knownName: Preferences.shared.userName
    )
    private var didBootstrap = false
    @Published var meetingDetected = false
    @Published var storageLibraryBytes: Int64 = 0
    /// Из них — то, что «Очистить» действительно заберёт. Кэшируется рядом с
    /// общим числом, а не считается на каждый рендер: это проход по архиву со
    /// `stat` на каждый файл, а секция настроек перерисовывается от любой мелочи.
    @Published var storageReclaimableBytes: Int64 = 0
    /// When set, MainView switches to this sidebar section (e.g. after pipeline).
    @Published var preferredSidebarSection: String?
    /// When set, RecordingDetailView selects this tab (`transcript` / `notes` / `recap`).
    @Published var preferredDetailTab: String?

    /// True when this recording was started by a detected call (any platform),
    /// so hanging up can stop it.
    private var recordingLinkedToCall = false
    /// User declined auto-recording for the call in progress — sticky until the
    /// conferencing app quits, so it isn't asked again mid-call (G3).
    private var ignoredDetectedCall = false
    /// Set right before an auto-start so `beginRecording` knows to post the
    /// interactive "recording started" notification (manual starts don't).
    private var autoStartedFromMeeting = false
    /// How the recording in progress began (`auto` / `manual`). `autoStartedFromMeeting`
    /// is cleared as soon as the start finishes, and the question is still asked
    /// at the end — a discard means something different for each.
    private var activeRecordingSource: String?
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
        if TapProbe.isRequested || LiveProbe.isRequested { return }
        didBootstrap = true

        // (model migration lives in `Preferences.recapOllamaModel` so it also
        // covers launches that read the pref before bootstrap runs)

        recordingStore.load()
        // Interrupted recordings are repaired silently. The count used to be
        // announced — a modal, then a floating bar — and it told the user that *their*
        // recordings had been interrupted, about a crash that was ours, with
        // nothing to do about it. Each of those meetings is in the list with its
        // own state; that is where it belongs.
        _ = recordingStore.recoverInterruptedRecordings()
        // Пока микса нет, `audioAvailable` ложно, фаза встрече не причитается и
        // таймер не заводится вовсе — так что запуск, собравший микс, сам её и
        // не обработает, если об этом не сказать. Молчание здесь и было тем
        // «остановились и надеемся, что нас пнут», от которого избавлялись в I12.
        Task { [weak self] in
            _ = await self?.recordingStore.recoverMissingFinalMixes()
            self?.kickPipeline("mixes rebuilt")
        }
        refreshStorageUsage()
        NotificationManager.shared.configure()
        NotificationManager.shared.onCancelRecording = { [weak self] in
            self?.cancelRecording()
        }

        showOnboarding = !Preferences.shared.onboardingCompleted
        adoptSetupAnswersFromOldOnboarding()

        setupMeetingDetector()

        // Чёлка: регистрируем состояние; панель и монитор клавиши поднимаются
        // только на время записи (plan-optimization E7).
        NotchController.shared.install(state: self)

        // Load nearby calendar events if the user opted in. Use the
        // requesting path so access is re-prompted after an ad-hoc rebuild
        // resets TCC (otherwise the list silently shows nothing).
        if Preferences.shared.calendarEnabled {
            Task { await CalendarService.shared.enableAndLoad() }
        }

        // Everything unfinished — recovered recordings, meetings still owed a
        // transcript, and past meetings still owed a summary — is one queue now.
        observeTheWorld()
        kickPipeline("launch")

        // The summary model is part of the installation, not a choice offered on
        // the fifth onboarding screen. Checked on **every** launch and restored
        // when it is missing — models get deleted by disk cleaners, runtimes break
        // after a system update, and the pinned version moves in a new build.
        //
        // «Саммари нет» is a legal depth for one meeting; «нет LLM» is not a legal
        // state for the app (`design/no-dead-ends.md` §5). Delayed so the launch
        // itself stays quiet, and skipped while a recording or a call is going on.
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await ensureSummaryModel()
        }

        // ASR sidecar starts lazily on first transcription (plan-optimization E1).
    }

    // MARK: - The rail's two questions

    /// Re-derive which question the rail carries. Every write behind it goes
    /// through `Preferences`, so this is called after each answer rather than the
    /// answers each maintaining the flag — one place to get it wrong instead of
    /// three.
    func refreshSetupPrompt() {
        setupPrompt = SetupPromptMachine.step(
            setupCompleted: Preferences.shared.onboardingCompleted,
            calendarGranted: Preferences.shared.calendarEnabled,
            calendarAsked: Preferences.shared.setupCalendarAsked,
            knownName: Preferences.shared.userName
        )
    }

    /// Someone upgrading from the six-plate onboarding has already been asked
    /// both of these — the calendar on its own screen, the name on its own. A
    /// stored name is the marker: the old flow always wrote one, defaulting to
    /// the macOS account name, so it cannot be empty on a machine that went
    /// through it. Greeting an existing user with a setup block would say the app
    /// had forgotten the conversation.
    private func adoptSetupAnswersFromOldOnboarding() {
        if Preferences.shared.onboardingCompleted,
           !Preferences.shared.setupCalendarAsked,
           !Preferences.shared.userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Preferences.shared.setupCalendarAsked = true
        }
        refreshSetupPrompt()
    }

    /// «Подключить» on the calendar step.
    ///
    /// The step is spent on the press, not on the grant. Whether macOS then says
    /// yes is the user's business and the calendar's; asking a second time
    /// because they said no would make a suggestion into nagging. If they said
    /// yes, `CalendarService` has the events by the time the block is gone.
    func connectCalendarFromRail() {
        Preferences.shared.setupCalendarAsked = true
        Preferences.shared.calendarEnabled = true
        refreshSetupPrompt()
        Analytics.signal("Setup.calendarAsked")
        Task { await CalendarService.shared.enableAndLoad() }
    }

    /// The name typed into the rail's field.
    ///
    /// Empty is not an answer — the field's own ⏎ is disabled on empty, and this
    /// guards it too, because a blank write would settle the question with
    /// nothing and quietly leave every future transcript on the account-name
    /// fallback without anyone having chosen that.
    func setOwnerNameFromRail(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Preferences.shared.userName = trimmed
        refreshSetupPrompt()
        Analytics.signal("Setup.nameGiven")
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
            stopRecording(auto: true)
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
        recordingLinkedToCall = true
        autoStartedFromMeeting = true
        startRecording()
    }

    // MARK: - Pushes

    /// Everything that reaches the system notification centre goes through here.
    /// Whether it is sent at all, and whether it makes a sound, is `PushPolicy`.
    private func notify(
        _ kind: PushPolicy.Kind,
        title: String = "Propeller",
        body: String,
        isAwaited: Bool = true,
        recapExpected: Bool = false
    ) {
        let context = PushPolicy.Context(
            isRecording: isRecording,
            windowVisible: isWindowOpen,
            appActive: NSApp.isActive,
            isAwaited: isAwaited,
            authorized: NotificationManager.shared.isAuthorized,
            recapExpected: recapExpected
        )
        let surface = PushPolicy.surface(for: kind, in: context)
        switch surface {
        case .none:
            break
        case .banner:
            NotificationManager.shared.post(title: title, body: body, sound: false)
        case .bannerWithSound:
            NotificationManager.shared.post(title: title, body: body, sound: true)
        case .window:
            // No notification channel left, and the state that would have said
            // this lives in the window: bring the window (R8's one exception).
            surfaceMeetingUI(preferSummaryTab: false)
            bringWindowForward()
        }
        // Both halves are measured: a rule nobody counts is a rule nobody keeps
        // (design/notifications.md §7).
        Analytics.signal("Notice.\(kind.rawValue).\(surface.signalName)")
    }

    /// Put the main window in front. Only for a level-3 notice with nowhere else
    /// to go — never for good news, and never during a recording.
    private func bringWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.frame.width > 400 {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Disk Space Pre-flight

    /// Check available disk space at `path`. Returns bytes available, or nil on error.
    private func availableBytes(at path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }

    /// Note a nearly-full disk in the log, and record anyway.
    ///
    /// Nothing is shown. This was a gate that suspended the start on a
    /// continuation until someone answered «Всё равно записать» — on the
    /// auto-record path, a question parked in a window nobody is looking at, with
    /// no timer to resume it, so a detected meeting simply never began. Then it
    /// was a warning, which is not much better: it names a problem the app cannot
    /// solve and the user cannot act on mid-call. If the disk really does fill,
    /// the write fails and *that* failure belongs to the recording, with its own
    /// row and its own «Повторить».
    private func noteDiskSpace() {
        guard let bytes = availableBytes(at: Preferences.shared.recordingsPath),
              bytes < 500_000_000 else { return }
        NSLog("[AppState] starting a recording with \(bytes / 1_000_000) MB free")
    }

    /// Room for the one model still fetched over the network.
    ///
    /// There were two, with one gate for both, and it was wrong in both directions
    /// (4 GB demanded before a 1.1 GB ASR download; a 3.4 GB summary model waved
    /// through with 4 GB free, then running out mid-pull — measured 2026-07-27).
    /// The ASR half is gone entirely: GigaAM's weights ship inside the .app, so
    /// there is nothing to make room for. What is left is 3.4 GB of summary weights
    /// plus the unpacked runtime.
    ///
    /// Answered without asking anyone, and it must stay that way: an answer the
    /// worker waits for is a stall no timer recovers from.
    func hasRoomForSummaryModel() -> Bool {
        guard let bytes = availableBytes(at: NSHomeDirectory()) else { return true }
        return bytes >= 5_000_000_000
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
                        self?.refuseForMicrophone()
                    }
                }
            }
            return
        case .denied, .restricted:
            refuseForMicrophone()
            return
        case .authorized:
            micAccessDenied = false
        @unknown default:
            break
        }

        startRecordingAfterPermission()
    }

    /// Recording was asked for and cannot happen.
    ///
    /// The state goes on the app, not into a message: from here on the rail's
    /// «Новая запись» row *is* the notice, and it stays one until the permission
    /// changes. The push exists because the window is usually closed at this
    /// moment — the user is in the call that asked for the recording.
    private func refuseForMicrophone() {
        autoStartedFromMeeting = false
        recordingLinkedToCall = false
        micAccessDenied = true
        notify(.micDenied, body: "Нет доступа к\u{00A0}микрофону — встреча не записывается")
    }

    private func startRecordingAfterPermission() {
        noteDiskSpace()
        beginRecording()
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
        activeRecordingSource = recordingSource

        do {
            // Ставится до старта: кадры пойдут с первой же сотой секунды, а
            // подписчик у них один и на всю запись.
            recorder.onLiveFrames = { [live] mic, system in
                live.ingest(mic: mic, system: system)
            }
            try recorder.start()
            isRecording = true
            // Call already in progress and the user started manually — still link it so
            // hanging up stops the recording.
            if meetingDetector.isInMeeting || meetingDetected {
                recordingLinkedToCall = true
            }
            elapsedSeconds = 0
            startDisplayTimer()
            recorder.setMeteringDesired(true)
            NotchController.shared.startRecording()

            let now = Date()
            // Calendar title wins over the placeholder (and later over LLM rename).
            if Preferences.shared.calendarEnabled {
                CalendarService.shared.load()
            }
            let placeholder = "Запись \(DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .short))"
            let title = CalendarService.shared.suggestedRecordingTitle(at: now) ?? placeholder
            // Same matched event the title comes from. Taken now because the
            // calendar is only in reach while the meeting is happening.
            let calendarMeta = CalendarService.shared.suggestedRecordingMeta(at: now)
            let entry = RecordingEntry(
                id: recorder.recordingID ?? "",
                filename: (recorder.recordingID ?? "") + ".wav",
                date: now,
                duration: 0,
                title: title,
                status: .recording,
                transcript: nil,
                calendarMeta: calendarMeta
            )
            recordingStore.add(entry)
            // Кого пригласили — то и подсказываем распознавателю, с первой же
            // секунды: живой слой открывает сессии сразу, а подсказки читаются
            // при запуске сервера, не на запросе.
            GigasttSidecar.shared.setMeetingTerms(MeetingHotwords.terms(for: calendarMeta))
            refreshStorageUsage()
            activeRecordingID = entry.id
            selectedRecordingID = entry.id
            // Началась встреча — панель показывает её, даже если в ней были
            // открыты настройки. «Новая запись» нажата из того же рельса, и
            // ничего не произошедшее на экране читается как несработавшая кнопка.
            paneRoute = .meeting
            startLiveTranscript(for: entry.id)
            Analytics.recordingStarted(source: recordingSource)
            if title != placeholder {
                NSLog("[AppState] Recording titled from calendar: \(title)")
            }

            // Auto-started from a detected meeting: notify so the user can decline.
            // The one alarm this app has, and the one that is allowed a sound
            // while recording — the recording is a second old, and an alarm
            // nobody hears is not an alarm.
            //
            // If notifications are denied, surface the window so Discard is
            // reachable (BUG-REC-05): the decline lives in the notification, so
            // without one there is no channel left.
            if autoStartedFromMeeting {
                NotificationManager.shared.notifyRecordingStarted { [weak self] authorized in
                    Task { @MainActor in
                        guard let self, self.isRecording else { return }
                        Analytics.signal(
                            "Notice.recordingStarted.\(authorized ? "sound" : "window")"
                        )
                        guard !authorized else { return }
                        self.surfaceMeetingUI(preferSummaryTab: false)
                        self.bringWindowForward()
                    }
                }
            }
            autoStartedFromMeeting = false
        } catch {
            recordingLinkedToCall = false
            autoStartedFromMeeting = false
        }
    }

    /// Записать живой текст на встречу, чтобы он пережил перезапуск.
    ///
    /// Вызывается один раз, в момент остановки, — до того как сервис его
    /// обнулит. Раньше здесь не сохранялось ничего: текст держался в памяти и
    /// исчезал вместе с процессом, а встреча до конца расшифровки оставалась
    /// без единого слова.
    ///
    /// Пусто на микрофонном пути (живого распознавания там не было) и у встречи,
    /// где никто не сказал ни слова, — писать пустой массив незачем.
    private func persistLiveTranscript() {
        guard let id = live.recordingID, !live.transcript.isEmpty else { return }
        let segments = live.transcript.persistedSegments(
            ownerName: Preferences.shared.ownerName
        )
        guard let data = try? JSONEncoder().encode(segments),
              let json = String(data: data, encoding: .utf8) else { return }
        recordingStore.setLiveSegmentsJSON(json, for: id)
    }

    /// Живой транскрипт — только на общих часах: на микрофонном пути буферов
    /// нет вовсе, и открывать сессию не из чего. Экран тогда честно говорит,
    /// что текст будет после встречи, — это глубина, а не отказ.
    private func startLiveTranscript(for id: String) {
        guard recorder.capturePath == .processTap else {
            live.end()
            return
        }
        live.begin(
            recordingID: id,
            hasSystemAudio: recorder.capturesSystemAudio,
            elapsed: 0
        )
    }

    // MARK: - Пауза

    /// Пауза — состояние записи, а не её конец: встреча остаётся той же, файл
    /// тем же, живой текст на экране остаётся тем, что уже сказано.
    func pauseRecording() {
        guard isRecording, !recorder.isPaused else { return }
        recorder.pause()
        live.pause()
        // Кнопки паузы в чёлке нет, но состояние там есть: лопасть встаёт
        // совсем, и это единственное, что означает неподвижность.
        NotchController.shared.refresh()
        objectWillChange.send()
    }

    func resumeRecording() {
        guard isRecording, recorder.isPaused else { return }
        recorder.resume()
        live.resume(at: recorder.elapsed)
        NotchController.shared.refresh()
        objectWillChange.send()
    }

    var isRecordingPaused: Bool { isRecording && recorder.isPaused }

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
        NotchController.shared.stopRecording()
        recorder.setMeteringDesired(false)
        isRecording = false
        activeRecordingID = nil
        // Записи не будет вовсе — значит и её живого текста тоже.
        live.end()
        recordingLinkedToCall = false
        player.stop()
        let id = recorder.recordingID
        do {
            _ = try await recorder.stop()
        } catch {
            NSLog("[AppState] cancelRecording stop error: \(error)")
        }
        // Read before the entry is removed: the age of the discarded recording
        // is what tells a wrong call detection from a change of mind.
        var age: TimeInterval?
        if let id, let entry = recordingStore.recording(for: id) {
            age = Date().timeIntervalSince(entry.date)
            recordingStore.remove(entry)
            if selectedRecordingID == id { selectedRecordingID = nil }
        }
        Analytics.recordingCancelled(source: activeRecordingSource ?? "manual", age: age)
        activeRecordingSource = nil
        NotificationManager.shared.clearRecordingNotification()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// `auto: true` when nobody pressed anything — the call ended, or the 8-hour
    /// ceiling did. That is the difference between news and telling someone what
    /// they just did themselves.
    func stopRecording(auto: Bool = false) {
        Task { await stopRecordingAndWait(runPipeline: true, auto: auto) }
    }

    /// Stop recording and await final WAV write. Safe to call from quit handlers.
    /// `runPipeline: false` only for app quit — otherwise ASR → save → recap always starts
    /// (gigastt downloads/spawns inside `runTranscribe` on first need).
    func stopRecordingAndWait(runPipeline: Bool = true, auto: Bool = false) async {
        guard isRecording else { return }
        guard !isTerminalRecordingAction else { return }
        isTerminalRecordingAction = true
        defer { isTerminalRecordingAction = false }

        stopDisplayTimer()
        NotchController.shared.stopRecording()
        recorder.setMeteringDesired(false)
        isRecording = false
        activeRecordingID = nil
        // Сессии закрываются, а сказанное остаётся на экране: до конца прохода
        // по файлу это всё, что про встречу известно.
        live.stop()
        persistLiveTranscript()
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
            // Только если человек и так смотрел на эту запись. Во время встречи
            // можно уйти читать другую, и звонок, кончившийся сам, не имеет
            // права утащить с той страницы, которую в этот момент читают.
            if selectedRecordingID == nil || selectedRecordingID == result.id {
                selectedRecordingID = result.id
            }
            // Колонку не переключаем: пока саммари пишется, на его месте стоит
            // расшифровка (`SummaryColumnContent`), и человек продолжает читать
            // ровно то, что читал секунду назад.
            // This is a meeting the user is waiting for, so it is allowed to
            // announce itself when it is done.
            awaitedRecordingIDs.insert(result.id)

            // Keep for live detail of *this* stop; badge itself reads entry.micOnlyCaptured.
            Analytics.recordingFinished(duration: result.duration, micOnly: micOnly)

            if runPipeline {
                // Only an automatic stop is news. Telling someone that they
                // pressed «Стоп» is the textbook nuisance alarm — there is
                // nothing to do about it, and the window already says so.
                if auto {
                    notify(
                        .recordingAutoStopped,
                        body: wasLinkedToCall
                            ? "Звонок закончился — расшифровываем"
                            : "Запись остановлена — расшифровываем"
                    )
                }
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

                if secs >= Self.maxRecordingSeconds, self.isRecording {
                    NSLog("[AppState] 8h recording ceiling reached — stopping")
                    self.stopRecording(auto: true)
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

    /// Настройки в панель. Выбранную встречу не трогаем: она под ними, и
    /// вернуться к ней можно тем же кликом, которым её выбирали.
    func openSettings() {
        paneRoute = .settings
    }

    func selectRecording(_ entry: RecordingEntry) {
        player.stop()
        // Выбрать встречу — значит уйти из настроек. Отдельной кнопки «закрыть»
        // у них нет и не нужно: панель одна, и в ней всегда что-то одно.
        paneRoute = .meeting
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

    /// Recompute how much audio is on disk. Read by Settings, which is where the
    /// archive is actually managed.
    ///
    /// There is no nudge any more. «Библиотека разрослась» named a number and
    /// offered a button to the screen the user was already able to open, on a
    /// schedule of the app's choosing rather than theirs — and Settings shows the
    /// same number with one «Очистить» beside it.
    func refreshStorageUsage() {
        storageLibraryBytes = recordingStore.totalLibraryBytes()
        storageReclaimableBytes = recordingStore.reclaimableAudioBytes()
    }

    /// Open the Summary tab for a finished meeting — without taking the front.
    ///
    /// It used to call `NSApp.activate`, so a summary landing while the user was
    /// writing somewhere else pulled the window over their work. Good news has no
    /// claim on anyone's attention (`design/notifications.md`, R8): the tab is
    /// selected, the notification says it is ready, and opening it is their move.
    private func surfaceSummaryUI(for recordingID: String) {
        guard !isRecording else { return }
        guard selectedRecordingID == recordingID || selectedRecordingID == nil else { return }
        preferredSidebarSection = "meetings"
        preferredDetailTab = "recap"
    }

    private func surfaceMeetingUI(preferSummaryTab: Bool) {
        // Панель показывает встречу, о которой речь, — даже если в ней сейчас
        // открыты настройки. Просить показать колонку и оставить на экране
        // настройки значит не показать ничего.
        paneRoute = .meeting
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
            duration: duration,
            byHand: true
        )
        // A hand-made summary can leave the meeting one metadata pass short of
        // `.summarized`; the worker finishes the job.
        kickPipeline("regenerated")
    }

    /// Persist an edited summary back to its markdown file.
    ///
    /// Straight over the file the model wrote, and that is the whole design: the
    /// summary is one document, not «модельная версия и правки поверх». The
    /// pipeline cannot undo it — a meeting with a recap on disk is never
    /// re-summarised (`SummaryWork.needed` answers `.nothing`), and the one path
    /// that would overwrite it, `regenerateRecap`, is an explicit action nobody
    /// takes by accident.
    ///
    /// Returns false when there is no file to write into, which is also the
    /// answer to «можно ли это править» — the pane asks before offering a caret.
    @discardableResult
    func saveSummary(_ markdown: String, for entry: RecordingEntry) -> Bool {
        guard let url = Self.resolvedRecapURL(for: entry) else { return false }
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty document is a save that would delete the summary. Deleting is
        // an action of its own, and this one is a stray ⌘A followed by Backspace.
        guard !trimmed.isEmpty else { return false }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[AppState] failed to save summary edit: \(error)")
            return false
        }
    }

    /// «Короче» / «Подробнее» over the fragment selected in the summary.
    ///
    /// Returns nil when there is nothing to ask — no model, no key, the model
    /// answered with nothing. The caller leaves the text exactly as it was:
    /// silently doing nothing is the right answer for a request whose whole
    /// value was replacing text with better text.
    func rewriteSummaryFragment(
        _ fragment: String, instruction: String, transcript: String?
    ) async -> String? {
        do {
            let rewritten = try await recapBackend.rewriteFragment(
                fragment, instruction: instruction, transcript: transcript,
                prefs: RecapPreferences.fromShared()
            )
            // Compare what will actually land in the editor after
            // `SummaryRewriteText` flattens lists/newlines — a reply that is
            // only `- ` wrappers around the same words is not a rewrite.
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            let prepared = SummaryRewriteText.plain(rewritten)
            guard !prepared.isEmpty, prepared != trimmed else { return nil }
            return rewritten
        } catch {
            NSLog("[AppState] summary rewrite failed: \(error)")
            return nil
        }
    }

    /// Where this meeting stands, and why — the one answer the interface reads.
    ///
    /// Composed here because the inputs are the app's (what the worker is on, what
    /// the preferences say, whether the model landed) and decided in
    /// `MeetingRest.of`, where a test can reach it.
    func rest(of entry: RecordingEntry) -> MeetingRest {
        MeetingRest.of(
            stage: entry.status,
            failure: entry.lastFailure,
            isWorkingOnIt: activity.concerns(entry.id),
            // Всегда. Провайдера выбирают, саммари — нет: «Выкл» из пикера
            // удалён (`RecapProviderKind`). Параметр пока остаётся у чистой
            // функции вместе с веткой `.done(.summariesOff)`, потому что эта
            // причина `Codable` и уже может лежать на записи у того, кто
            // выключал саммари в 1.15; выкинуть её из типа можно, когда такие
            // записи перестанут встречаться.
            summariesEnabled: true,
            // `needsLocalRecapModel`, not `localRecapModelReady == true`: the
            // question is «is the model the thing we are waiting for», and with a
            // cloud key it never is. It also answers «not asked yet» as ready,
            // which keeps «ждём модель» off a meeting that is merely queued.
            summaryModelReady: !needsLocalRecapModel
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
        case .openai, .claude:
            return false          // cloud: the local model is irrelevant
        case .ollama:
            return true
        }
    }

    /// The technical line, for the panel that has room for it.
    ///
    /// `HTTP 413: body too large` tells the person who can fix it exactly what
    /// happened, and tells everyone else nothing — so it goes where there is room
    /// for it and nobody has to read it in passing. What a person sees is the mark
    /// on the meeting's row and «Не удалось обработать» beside its title.
    func surfacePipelineError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pipelineError = trimmed
        NSLog("[AppState] pipelineError: \(trimmed)")
    }

    func clearPipelineError() {
        pipelineError = nil
    }

    /// Rename by id, because the caller that has one is the one that cannot
    /// trust the selection: the pane header saves a name after the user has
    /// already moved to another meeting.
    func renameRecording(id: String, to newTitle: String) {
        recordingStore.rename(id: id, to: newTitle)
        markDirty()
    }

    func renameRecording(_ entry: RecordingEntry, to newTitle: String) {
        renameRecording(id: entry.id, to: newTitle)
    }

    /// Где на ленте встречи стоит заметка, которую пишут прямо сейчас.
    ///
    /// Nil у любой встречи, кроме той, что пишется, — включая ту, которая
    /// писалась минуту назад. Заметка, дописанная после стопа, не относится ни к
    /// какой секунде разговора, и выдумать ей секунду хуже, чем оставить без.
    func noteOffset(for recordingID: String) -> Double? {
        guard isRecording, recorder.recordingID == recordingID else { return nil }
        return elapsedSeconds
    }

    /// Append a note tagged with the current recording timecode (used by the
    /// quick-note overlay). No-op unless a recording is in progress.
    ///
    /// Returns whether the note landed, so the overlay knows whether it has
    /// something to confirm.
    @discardableResult
    func appendTimestampedNote(_ text: String) -> Bool {
        guard isRecording, let id = recorder.recordingID else { return false }
        // The stamp is a field now, not a prefix typed into the text. It used to
        // be `[12:34] ` glued to the front, which reads fine and answers
        // nothing: a note has to stand beside the remark it was written about,
        // and that remark's time is a number. `MeetingNotes.blob` renders the
        // same prefix back for the file and the prompt, so nothing downstream
        // can tell the difference.
        recordingStore.appendNote(id: id, text: text, offsetSeconds: noteOffset(for: id))
        // No notification here on purpose. It used to post one — with a sound,
        // during a recording, about something the user had just done themselves,
        // with nothing to do about it. Подтверждение живёт там, где печатали:
        // ухо чёлки на 0,7 с показывает, сколько заметок стало (`NotchController`).
        return true
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

    /// Soft-deleted meeting — files still on disk, ⌘Z restores.
    /// Set when delete begins; hard-deleted on the next delete, or on quit.
    @Published var pendingDeletion: RecordingEntry?

    /// Row playing ash + slot collapse. Stays in the store until the slot is
    /// ~zero so the same view can animate height (a re-injected ghost is born
    /// already-dissolving and never fires `onChange`).
    @Published private(set) var dissolvingMeetingID: String?
    private var dissolveFallbackTask: Task<Void, Never>?

    /// The window's undo manager, and only it. Deleting a meeting belongs to the
    /// window, not to whatever has focus: `@Environment(\.undoManager)` follows
    /// the responder chain, so registering there means ⌘Z later asks a different
    /// manager — and finds nothing. It is also often nil here.
    private func resolveUndoManager(_ preferred: UndoManager?) -> UndoManager? {
        AppWindowRegistry.mainWindow()?.undoManager
            ?? NSApp.keyWindow?.undoManager
            ?? preferred
    }

    /// Как список сдвигается, впуская вернувшуюся строку. Nil с «уменьшить
    /// движение»: строка встаёт на место, а соседи не разъезжаются под ней.
    private static var listReflow: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : .easeInOut(duration: Tokens.Motion.listReflow)
    }

    /// Bring back the last soft-deleted meeting (⌘Z).
    func undoDeletion(undoManager: UndoManager? = nil) {
        dissolveFallbackTask?.cancel()
        dissolveFallbackTask = nil
        dissolvingMeetingID = nil

        guard let entry = pendingDeletion else { return }
        pendingDeletion = nil
        let um = resolveUndoManager(undoManager)
        // Mid-ash the row is still in the store — only restore if it left.
        if !recordingStore.recordings.contains(where: { $0.id == entry.id }) {
            withAnimation(Self.listReflow) {
                recordingStore.restore(entry)
            }
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { selectRecording(entry) }
        um?.registerUndo(withTarget: self) { target in
            target.removeRecording(entry, undoManager: um)
        }
        um?.setActionName("Удаление встречи")
    }

    /// Finish a deferred deletion — the audio goes now.
    ///
    /// Called when another meeting is deleted, and on quit. Leaving it
    /// uncommitted would strand the audio: the entry is already out of the
    /// index, so nothing would ever point at those files again.
    func commitPendingDeletion() {
        guard let entry = pendingDeletion else { return }
        pendingDeletion = nil
        recordingStore.remove(entry)
    }

    /// Ash + slot collapse start together; ⌘Z registered immediately.
    func removeRecording(_ entry: RecordingEntry, undoManager: UndoManager? = nil) {
        // Удалить встречу, которая пишется, — это «не записывать её»: другого
        // смысла у действия нет, а убрать строку из списка, оставив рекордер
        // писать в файл удалённой встречи, значит завести запись, к которой не
        // ведёт ни одна дверь. Раньше такого случая не было — встречу нельзя
        // было выбрать во время записи.
        if entry.id == activeRecordingID, isRecording {
            cancelRecording()
            return
        }
        // Удалить встречу, которую прямо сейчас обрабатывают, — это ещё и
        // «перестать её обрабатывать». Иначе фаза доработает до конца на
        // встрече, которой уже нет в индексе, и допишет результат в пустоту:
        // `RecordingStore.update` не найдёт id и молча ничего не сделает. На
        // расшифровке это восемь секунд GPU впустую (замерено 2026-08-09), на
        // саммари — минута модели. Воркер снимается здесь, а не внутри фазы:
        // отмена — это решение о работе, а не о встрече.
        if activity.concerns(entry.id) {
            debugLog("[pipeline] \(entry.id) удалена во время работы — снимаем фазу")
            // Снятая работа — не конец очереди: за этой встречей стоят другие, и
            // `.cancelled` сам по себе никого не будит (дедлайна у отмены нет,
            // если никто не ждёт ретрая). Ждём, пока цикл размотается, и просим
            // его посмотреть заново.
            let running = workerTask
            pausePipeline()
            Task { @MainActor [weak self] in
                await running?.value
                self?.kickPipeline("работа снята вместе со встречей")
            }
        }
        if dissolvingMeetingID != nil {
            finishDissolvingDeletion()
        }
        player.stop()
        let um = resolveUndoManager(undoManager)
        um?.removeAllActions(withTarget: self)
        commitPendingDeletion()

        if selectedRecordingID == entry.id {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { selectNeighbor(afterRemoving: entry) }
        }
        if let window = AppWindowRegistry.mainWindow() {
            window.makeFirstResponder(window.contentView)
        }

        pendingDeletion = entry
        dissolvingMeetingID = entry.id
        // Stay in the store while the existing row collapses — layout moves now.

        um?.registerUndo(withTarget: self) { target in
            target.undoDeletion(undoManager: um)
        }
        um?.setActionName("Удаление встречи")

        dissolveFallbackTask?.cancel()
        dissolveFallbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Tokens.Motion.Ash.duration + 0.05))
            guard !Task.isCancelled else { return }
            if self.dissolvingMeetingID == entry.id {
                self.finishDissolvingDeletion()
            }
        }
    }

    /// Slot is ~zero — pull the entry out with no second layout jump.
    func finishDissolvingDeletion() {
        dissolveFallbackTask?.cancel()
        dissolveFallbackTask = nil
        // The row leaves the store *first*, and the «is dissolving» flag is
        // cleared in the same transaction. The other order asks the rail to
        // paint a row that is no longer dissolving but is still in the list —
        // full height, full opacity — which is the blink before the reflow.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if let entry = pendingDeletion,
               recordingStore.recordings.contains(where: { $0.id == entry.id }) {
                recordingStore.removeDeferred(entry)
            }
            dissolvingMeetingID = nil
        }
        refreshStorageUsage()
    }

    /// Next row down in the rail (older); if this was last, the one above.
    private func selectNeighbor(afterRemoving entry: RecordingEntry) {
        let listed = recordingStore.recordings
            .filter(\.hasSomethingToShow)
            .sorted { $0.date > $1.date }
        guard let idx = listed.firstIndex(where: { $0.id == entry.id }) else {
            selectedRecordingID = nil
            return
        }
        if listed.indices.contains(idx + 1) {
            selectRecording(listed[idx + 1])
        } else if idx > 0 {
            selectRecording(listed[idx - 1])
        } else {
            selectedRecordingID = nil
        }
    }

    /// «Очистить» в настройках: аудио уходит у всех, у кого оно уже лишнее.
    ///
    /// Ни одной встречи при этом не пропадает и ни одна не встаёт — за это
    /// отвечает `AudioReclaim`, а не эта функция.
    @discardableResult
    func deleteAllReclaimableAudio() -> Int {
        player.stop()
        let cleared = recordingStore.deleteAllReclaimableAudio()
        refreshStorageUsage()
        return cleared
    }

    // MARK: - Pipeline

    /// Guard against two ASR passes at once. Released as soon as the pass ends,
    /// so save and summary — separate phases now — never sit behind it.
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
            isThermallyStressed: thermal == .serious || thermal == .critical,
            // Саммари — не опция: воркеру всегда причитается эта фаза.
            summariesEnabled: true
        )
    }

    /// The meeting the user asked for by hand. Outranks recency for as long as
    /// it owes work, then stops mattering — pressing «Повторить» on a meeting
    /// from March should not mean waiting for the whole backlog first.
    private var userRequestedID: String?

    /// Meetings recorded in this session — the ones somebody is sitting there
    /// waiting to read. Everything else the worker touches is catch-up.
    ///
    /// The distinction buys the quiet: a launch that owes summaries for twenty
    /// meetings used to post twenty notifications and pull the window forward
    /// twenty times. Catch-up gets neither.
    private var awaitedRecordingIDs: Set<String> = []

    /// Is this the meeting the user is actually waiting on?
    private func isAwaited(_ recordingID: String) -> Bool {
        awaitedRecordingIDs.contains(recordingID) || recordingID == userRequestedID
    }

    /// What to do now and what to wait for. Recomputed rather than stored: it is
    /// a pure function of the archive, so there is no second copy to go stale.
    private var outlook: PipelineOutlook {
        pipelineOutlook(
            from: recordingStore.recordings,
            policy: workerPolicy,
            preferring: userRequestedID
        )
    }

    /// Ask the worker to look for work. Safe to call from anywhere, any number
    /// of times — a loop is already running or one gets started, never two.
    ///
    /// `reason` is for the log only, and it earns its keep: "why did my Mac just
    /// start summarising" is otherwise unanswerable after the fact.
    func kickPipeline(_ reason: String = "kick") {
#if GALLERY
        if galleryFrozen { return }
#endif
        guard workerTask == nil else { return }
        // The common case at launch is an archive with nothing owed. It should
        // cost one pass over an array — no task, no sidecar, no timer left over.
        let now = outlook
        guard now.job != nil else {
            if now.owed > 0 {
                debugLog("[pipeline] \(reason): \(now.owed) owed, nothing runnable"
                    + (now.pausedByPolicy ? " (paused: \(workerPolicy))" : ""))
            }
            // `outlook.wakeAt` is only retry deadlines. A policy pause (call /
            // recording / heat) used to leave it nil here and rely solely on
            // `onMeetingEnded` — a missed hang-up then stranded the archive.
            // `PipelineDrain.plan` adds the belt-and-braces recheck.
            let wake = PipelineDrain.plan(
                after: .finished, outlook: now, blockedStreak: 0
            ).wakeAt
            scheduleWake(at: wake)
            return
        }
        debugLog("[pipeline] \(reason): starting, \(now.owed) owed")
        workerTask = Task { [weak self] in
            await self?.runPipelineLoop()
            await MainActor.run {
                self?.workerTask = nil
                // Прежде чем разойтись — посмотреть на диск. «Больше нечего
                // делать» это единственный вывод, ошибиться в котором дорого: он
                // гасит таймер, и подобрать потерянный файл будет уже некому до
                // следующего запуска. Один листинг папки на конец дрейна, а не
                // таймер и не наблюдатель за файловой системой: ничего не
                // причитается ⇒ ничего не крутится.
                if let adopted = self?.adoptOrphans(), adopted > 0 {
                    self?.kickPipeline("подобрано с диска: \(adopted)")
                }
            }
        }
    }

    // MARK: - Waking up

    /// Fires at the earliest deadline the pipeline set for itself. One timer,
    /// non-repeating, and invalidated whenever nothing is owed: a live timer
    /// with nothing to do is the single easiest way for a Mac app to waste
    /// power (Apple's energy guide), and this app spends most of its life with a
    /// fully processed archive.
    private var wakeTimer: Timer?

    /// Consecutive drains that ended blocked on a missing summary provider.
    /// Walks the re-check interval out to half an hour so a user who never
    /// installs a model costs nothing.
    private var providerBlockedStreak = 0

    /// Observers for the things that change the answer without anyone asking:
    /// heat, sleep, the app coming forward.
    private var worldObservers: [NSObjectProtocol] = []

    private func scheduleWake(at date: Date?) {
        wakeTimer?.invalidate()
        wakeTimer = nil
        guard let date else { return }
        let delay = max(1, date.timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.kickPipeline("deadline") }
        }
        // Well over Apple's 10%-of-interval guidance, capped so a 20-second
        // retry still feels immediate. Lets the system fold this wakeup into
        // whatever else it was going to do anyway.
        timer.tolerance = min(30, delay * 0.25)
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
        debugLog("[pipeline] next look in \(Int(delay))s")
    }

    /// Подобрать записи с диска и, если кого-то подобрали, дать им ход.
    ///
    /// Файл в папке записей без строки в индексе — это встреча, которой для
    /// человека не существует: её нет в списке, ей не причитается работа, и
    /// никакой таймер за ней не придёт. Раньше её подбирал только запуск
    /// приложения, то есть человек — а он и не знает, что надо перезапустить.
    ///
    /// Кик обязателен: подобранная встреча приходит в стадии `.recorded`, и без
    /// него она просто ляжет в список нерасшифрованной до следующего события.
    /// Кик остаётся вызывающей стороне: у активации окна он безусловный (мы и
    /// так пришли смотреть, есть ли работа), а после дрейна — только если кого-то
    /// подобрали, иначе цикл входил бы сам в себя.
    @discardableResult
    private func adoptOrphans() -> Int {
        // Встречу, чьё «Вернуть» ещё на экране, скан не трогает: он же и
        // дочищает аудио удалённых, а отмена без звука — не отмена.
        let adopted = recordingStore.scanForOrphanRecordings(
            undoableID: pendingDeletion?.id
        )
        refreshStorageUsage()
        return adopted
    }

    /// Everything that can make owed work runnable without a user action. Each
    /// one used to be a way for the archive to stay unfinished until the next
    /// launch: a Mac that got hot mid-backlog stayed paused, a laptop closed
    /// over the weekend slept through its own retry deadline (`Timer` stops
    /// counting while the machine does), and a blocked provider had exactly one
    /// wake source — our own download finishing.
    private func observeTheWorld() {
        guard worldObservers.isEmpty else { return }
        let center = NotificationCenter.default
        worldObservers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.thermalStateChanged() }
        })
        worldObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adoptOrphans()
                self?.kickPipeline("app active")
                // Same two events the pipeline wakes on: a menu-bar app that
                // never quits would otherwise report one session per install.
                Analytics.noteDayBoundary()
            }
        })
        worldObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.kickPipeline("machine woke")
                Analytics.noteDayBoundary()
            }
        })
    }

    private func thermalStateChanged() {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            // Let the current phase finish — cancelling ASR to save heat throws
            // away the minutes it already spent. The loop stops at the next
            // phase boundary because the policy says so.
            debugLog("[pipeline] thermal \(thermal.rawValue): no new phases")
        } else {
            kickPipeline("cooled down")
        }
    }

    private var providerChangeDebounce: Task<Void, Never>?

    /// Summary settings changed — a provider picked, a key typed, a model name
    /// edited. Debounced, because these arrive per keystroke from Settings and
    /// each one would otherwise probe a provider and start a drain.
    func summaryProviderChanged() {
        providerChangeDebounce?.cancel()
        providerChangeDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.applySummaryProviderChange() }
        }
    }

    /// A summary provider may now exist where none did: a model finished
    /// downloading, a key was pasted, the provider setting changed.
    ///
    /// Clears summary failures across the archive, including ones that ran out of
    /// attempts. Those failures were about the environment, not about the
    /// meeting — leaving them parked would mean installing the model fixed
    /// everything except the meetings that were waiting for it.
    func applySummaryProviderChange() {
        providerBlockedStreak = 0
        let cleared = recordingStore.clearFailures(phase: .summarizing)
        if cleared > 0 {
            debugLog("[pipeline] provider changed: \(cleared) meeting(s) back in the queue")
        }
        refreshLocalRecapModelState()
        kickPipeline("provider changed")
    }

    /// Stop after the current phase. Called when the policy closes — a call
    /// starting mid-summary should not keep Ollama on the GPU for its duration.
    func pausePipeline() {
        workerTask?.cancel()
    }

    /// Drains the queue one phase at a time. The loop's rules live in
    /// `PipelineDrain` so they can be tested without an ASR sidecar or an LLM;
    /// this supplies the three things only the app knows.
    private func runPipelineLoop() async {
        let stop = await PipelineDrain.run(
            nextJob: { [weak self] in self?.outlook.job },
            perform: { [weak self] job in
                guard let self else { return .blocked }
                debugLog("[pipeline] → \(job.recordingID) \(job.phase)")
                return await self.run(job)
            }
        )

        // A hand-requested meeting stops jumping the queue once it is done.
        if let requested = userRequestedID,
           recordingStore.recording(for: requested)?.status.nextPhase == nil {
            userRequestedID = nil
        }

        // Whatever stopped the drain, the same question follows: is anything
        // still owed, and what would make it runnable? The answer is a pure
        // function (`PipelineDrain.plan`) because this is the decision that used
        // to be missing: every branch ended with "wait for something to kick us",
        // and three of the four never got kicked.
        let plan = PipelineDrain.plan(
            after: stop, outlook: outlook, blockedStreak: providerBlockedStreak
        )
        providerBlockedStreak = plan.blockedStreak
        if let job = plan.parkStalled {
            // A phase claimed progress and made none. Loud, because the loop
            // would otherwise ask for this same job forever.
            checkInvariant("i11.no-stall", false)
            NSLog("[AppState] pipeline stalled on \(job.recordingID) \(job.phase)")
            recordFailure(
                job.recordingID,
                phase: job.phase,
                // Ours: a phase claimed progress and made none. Retried like
                // everything else, and counted — this is the shape of bug that
                // only ever shows up on someone else's machine.
                message: "Фаза не продвинула стадию",
                kind: .ourFault
            )
        }
        // Blocked for want of a provider is the other moment the answer can have
        // changed since launch.
        if case .blocked = stop { Task { await ensureSummaryModel() } }
        debugLog("[pipeline] stopped: \(stop)")
        scheduleWake(at: plan.wakeAt)
    }

    /// Make sure the app *has* a summary model, and get it if it does not.
    ///
    /// The invariant: «саммари нет» is a legal depth for one meeting, «нет LLM» is
    /// not a legal state for the app (`design/no-dead-ends.md` §5). So this runs on
    /// every launch and every time the pipeline blocks for want of a provider — the
    /// two moments where the answer can have changed — and it neither asks nor
    /// announces anything.
    ///
    /// It used to be gated on `localRecapModelRequested`: nothing was fetched until
    /// someone pressed «Скачать» on the fifth onboarding screen, which made the app
    /// work or not work depending on whether they understood that screen. The flag
    /// stays written for older builds reading the same preferences, and is no longer
    /// read here.
    ///
    /// Cheap when healthy: one manifest check on disk, or one request to a server
    /// that is already up. Nothing is downloaded twice — `startOllamaRuntimeDownload`
    /// is idempotent while a download is in flight.
    func ensureSummaryModel() async {
        // Two of the four inputs are known without touching the disk, so ask them
        // first: a cloud key or summaries turned off means this is not our job at
        // all, and 3.4 GB is not something to fetch on a maybe.
        let provider = Preferences.shared.recapProvider.rawValue
        let quickAnswer = ModelProvisioning.decide(.init(
            usesLocalModel: ModelProvisioning.usesLocalModel(providerRawValue: provider),
            modelInstalled: false,                    // not asked yet
            busyWithAudio: isRecording || meetingDetected || isTranscribing,
            downloadInFlight: ollamaDownloadTask != nil || ollamaSetupProgress != nil
        ))
        switch quickAnswer {
        case .notOurs, .inFlight, .waitForQuiet:
            return
        case .fetch, .alreadyThere:
            break
        }

        let model = Preferences.shared.recapOllamaModel
        let installed = await OllamaSidecar.shared.isModelInstalled(
            model.isEmpty ? OllamaSidecar.defaultModel : model
        )
        localRecapModelReady = installed
        guard installed == false else { return }

        // Distinguishes «первая выдача» from «починка» in telemetry only — the code
        // path is deliberately the same one, because a missing model is a missing
        // model whatever the reason.
        Analytics.signal(
            Preferences.shared.localRecapModelRequested ? "Model.repair" : "Model.provision"
        )
        NSLog("[AppState] summary model missing — fetching it")
        startOllamaRuntimeDownload()
    }

    /// Runs exactly one phase. Phases never call each other — the loop decides
    /// what comes next, from the stage on disk.
    private func run(_ job: PipelineJob) async -> PhaseOutcome {
        switch job.phase {
        case .transcribing, .diarizing:
            // One pass, two entry points: `.transcribing` runs ASR then speakers,
            // `.diarizing` resumes from the checkpoint a crash left behind.
            await runASR(recordingID: job.recordingID, phase: job.phase)
        // `.saving` is no longer scheduled on its own (`RecordingStage.nextPhase`);
        // the summarising job writes the markdown first when it is missing. The
        // case stays because a failure recorded by an older build still names it.
        case .saving, .summarizing:
            return await runSummarize(recordingID: job.recordingID)
        }
        return .advanced
    }

    /// Summary phase entry point: resolves the transcript markdown the recap is
    /// written next to, then runs the one recap path there is.
    private func runSummarize(recordingID: String) async -> PhaseOutcome {
        guard let rec = recordingStore.recording(for: recordingID) else { return .advanced }
        // ASR ran and produced nothing: there was no speech. A result, not a
        // failure — and no attempt could change it. Checked here because this is
        // now the first phase after the transcript.
        guard rec.transcript?.isEmpty == false else {
            recordTerminal(recordingID, phase: .summarizing, reason: .noSpeech)
            return .advanced
        }
        // What is already on disk decides how much work this is. A meeting with a
        // summary but no topics — every calendar-named meeting from 1.11 — needs
        // one short pass over text that exists, not minutes of GPU rewriting a
        // file that is already correct.
        switch SummaryWork.needed(hasRecapFile: hasRecap(for: rec), hasMetadata: !needsMetadata(rec)) {
        case .metadataOnly:
            // The pass reads the summary off disk. If it turns out to be
            // unreadable after all, fall through and make a new one.
            if let summary = Self.loadRecapText(for: rec), !summary.isEmpty {
                return await runMetadataBackfill(rec, summary: summary)
            }
        case .nothing:
            // Recap and metadata are both there and only the stage disagrees.
            // Catch it up rather than regenerating a summary to prove it.
            advanceStage(rec.id, to: .summarized)
            clearFailure(rec.id)
            return .advanced
        case .fullRecap:
            break
        }

        var transcriptURL = transcriptMarkdownURL(for: rec)
        if transcriptURL == nil, let text = rec.transcript, !text.isEmpty {
            // The markdown was deleted outside the app — an Obsidian vault
            // tidy-up. The text is still in the index and the summary is written
            // next to the transcript, so rewrite it instead of failing. Done
            // inside this phase, so the loop still sees the stage move.
            await runSave(recordingID: rec.id, transcriptText: text, duration: rec.duration)
            transcriptURL = transcriptMarkdownURL(for: rec)
        }
        guard let mdURL = transcriptURL else {
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

    /// The short half of the summary phase: topics and tags for a meeting that
    /// already has its summary on disk. One prompt over the finished summary,
    /// where the full path would regenerate the summary itself.
    private func runMetadataBackfill(_ rec: RecordingEntry, summary: String) async -> PhaseOutcome {
        // Nothing to generate with — the same "wait for a provider" state a fresh
        // summary lands in, not a failure on the meeting.
        guard await recapBackend.summaryProviderReady(prefs: RecapPreferences.fromShared()) else {
            return .blocked
        }
        beginPipelineWork(rec.id, phase: .summarizing)
        defer { endPipelineWork(rec.id) }
        setActivityDetail("Определяем темы…")

        await generateMeetingMetadata(recordingID: rec.id, summary: summary)
        return finishMetadata(rec.id)
    }

    /// Close out the metadata pass, whichever way it went.
    ///
    /// The provider was there and still gave us nothing usable: retried on the
    /// ladder, and then *accepted*. Topics are a nicety on top of a summary that
    /// is already written and already readable — a meeting parked with «не
    /// удалось определить темы» would be the app reporting a cosmetic gap as a
    /// broken meeting, which is the opposite of the point. Empty topics mean
    /// "ran, found nothing", so the meeting is done and stops being asked about.
    private func finishMetadata(_ recordingID: String) -> PhaseOutcome {
        guard recordingStore.recording(for: recordingID)?.topics == nil else {
            clearFailure(recordingID)
            advanceStage(recordingID, to: .summarized)
            return .advanced
        }
        let failure = recordFailure(
            recordingID, phase: .summarizing,
            message: "Не удалось определить темы встречи", kind: .transient
        )
        guard failure.isTerminal else { return .advanced }   // a retry is due
        clearFailure(recordingID)
        recordingStore.update(
            id: recordingID,
            topics: [],
            tags: recordingStore.recording(for: recordingID)?.tags ?? []
        )
        advanceStage(recordingID, to: .summarized)
        return .advanced
    }

    /// ASR + diarization. Both phases live here because they share everything
    /// except where they start: `.transcribing` runs the full pass, `.diarizing`
    /// resumes from the checkpoint a crash left behind. Keeping them apart meant
    /// ~90 duplicated lines of orchestration (D6).
    ///
    /// Only the worker calls this. The user-facing buttons ask the queue instead
    /// (`reprocess`, `requestProcessing`) — a direct call while a phase was in
    /// flight used to hit the guard below and vanish, leaving a button that did
    /// nothing.
    private func runASR(recordingID: String, phase: PipelineActivity.Phase) async {
        if isTranscribing {
            // One worker, one ASR — belt and braces rather than a queueing
            // decision, and silent, because nothing is wrong.
            debugLog("[pipeline] ASR already running — ignoring \(recordingID)")
            return
        }
        guard let rec = recordingStore.recording(for: recordingID) else { return }
        let durationAtStart = rec.duration
        guard let audioURL = recordingStore.audioURL(for: rec) else {
            // No audio, and that is not a failure of anything.
            //
            // Two ways to get here, and neither wants a state of its own: the
            // user deleted the audio to reclaim space — in which case the
            // transcript and the summary stay and the meeting reads as normal —
            // or the file went away between the scheduler's check and this line.
            // Either way there is nothing to transcribe and nothing to say: the
            // scheduler already keeps such meetings out of the queue
            // (`audioAvailable`), so this is a race, not a dead end.
            //
            // It used to record a terminal failure, which put «Аудио удалено» on
            // a row whose transcript was sitting right there — an absurd thing to
            // tell someone about a meeting they can read.
            debugLog("[pipeline] \(recordingID) has no audio — nothing owed")
            return
        }

        // The ASR check that used to be here demanded 2 GB free before a
        // transcription — from the days when GigaAM's weights were downloaded. They
        // ship inside the .app now (247 MB, copied to Application Support once), so
        // the gate was refusing to transcribe over a download that does not happen.
        // If the disk really is full, the write fails and *that* failure belongs to
        // the recording, on the same endless ladder as everything else.

        // Resuming needs the checkpoint the earlier pass wrote.
        var checkpoint: [ASRSegment]?
        if phase == .diarizing {
            guard let json = rec.rawSegmentsJSON,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([ASRSegment].self, from: data) else {
                // The stage says «ASR is done», the disk says otherwise. Retrying
                // *this* phase would ask for the same missing bytes forever, and
                // parking it used to ask the user to press «Повторить» for a
                // decision only we could make. So the stage is put back to what is
                // actually on disk and the queue re-runs ASR by itself.
                //
                // This walks a stage backwards, which a phase must never do (I3) —
                // deliberately, and only here: `.transcribedRaw` was a claim about
                // a checkpoint that does not exist, and correcting a false claim is
                // not the same as losing progress.
                NSLog("[AppState] checkpoint gone for \(recordingID) — re-running ASR")
                Analytics.signal("Pipeline.checkpointLost")
                recordingStore.update(id: recordingID, status: .recorded, rawSegmentsJSON: .some(nil))
                clearFailure(recordingID)
                kickPipeline("checkpoint repaired")
                return
            }
            checkpoint = decoded
        }

        pipelineError = nil
        isTranscribing = true
        // Догон разбирает чужую встречу: словарь берётся от неё, а не от той,
        // что записывалась последней. Сервер перезапустится сам, если слова
        // разошлись и никого не слушают.
        GigasttSidecar.shared.setMeetingTerms(MeetingHotwords.terms(for: rec.calendarMeta))
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
                    systemStemOffset: recordingStore.recording(for: recordingID)?.systemStemOffset ?? 0,
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
                mergedSegmentsJSON: .some(encodePersistedSegments(result.mergedSegments)),
                speakerAttribution: result.attribution
            )
            if selectedRecordingID == recordingID {
                transcript = result.transcript
                pipelineError = nil
            }
            // The transcript is in, so whatever went wrong on earlier attempts is
            // history. Cleared here rather than when the attempt starts: the
            // failure is what carries the attempt count, and wiping it up front
            // would make every retry look like the first one — a 20-second loop
            // that never gives up and never reports.
            clearFailure(recordingID)
            Analytics.transcriptionFinished(
                ok: true,
                reason: phase == .diarizing ? "diarize_resume" : nil
            )
            // The markdown is written here, in the same pass, because a transcript
            // that exists and is not on disk is a promise the app has already made
            // («transcripts are always saved right after diarization»).
            //
            // It used to be a scheduled job of its own, which put «Сохраняем…» on
            // the row for one frame of a file write — and worse, when it was folded
            // into the summarising job, an archive with summaries off never got its
            // markdown at all: the summarising job is the one thing that does not
            // run without a provider.
            await runSave(
                recordingID: recordingID,
                transcriptText: result.transcript,
                duration: recordingStore.recording(for: recordingID)?.duration ?? durationAtStart
            )
        } catch is CancellationError {
            // A call started, or the app is quitting. Not a failure: parking the
            // meeting here would mean every interrupted catch-up needed a manual
            // retry afterwards. The stage below keeps the checkpoint.
            restoreStageAfterInterruptedASR(recordingID, phase: phase)
            debugLog("[pipeline] \(phase) cancelled for \(recordingID)")
        } catch let error as URLError where error.code == .cancelled {
            // Same thing, seen through URLSession — the sidecar request was the
            // thing holding the cancellation.
            restoreStageAfterInterruptedASR(recordingID, phase: phase)
            debugLog("[pipeline] \(phase) cancelled (transport) for \(recordingID)")
        } catch let error where Self.meansNobodySpoke(error) {
            // Сайдкар отработал до конца и вернул ноль слов. Это не отказ и не
            // «попробуем ещё раз»: следующая попытка прочитает тот же файл и
            // получит тот же ноль. Терминал объявляется здесь, потому что здесь
            // единственное место, которое смотрело на вход, — `classify` по
            // сообщению этого делать не имеет права.
            modelDownloadProgress = nil
            restoreStageAfterInterruptedASR(recordingID, phase: phase)
            Analytics.transcriptionFinished(ok: false, reason: "no_speech")
            settleSilentRecording(recordingID)
            NSLog("[AppState] \(phase): в \(recordingID) не нашлось речи — \(error.localizedDescription)")
        } catch {
            modelDownloadProgress = nil
            if vanished(recordingID) {
                // То же, что на саммари: работа снята вместе со встречей. Стадию
                // возвращать тоже некуда — записи нет в индексе.
                debugLog("[pipeline] \(recordingID) исчезла во время \(phase) — не сбой")
            } else {
                let msg = error.localizedDescription
                Analytics.transcriptionFinished(ok: false, reason: phase == .diarizing ? "diarize" : "error")
                restoreStageAfterInterruptedASR(recordingID, phase: phase)
                let failure = recordFailure(recordingID, phase: phase, message: msg)
                report(failure, for: recordingID)
                NSLog("[AppState] \(phase) FAILED (attempt \(failure.attempt), \(failure.kind)): \(error)")
            }
        }

        isTranscribing = false
        endPipelineWork(recordingID)
        transcriptionService.releaseHeavyResources()
        kickPipeline("asr done")
    }

    /// Ошибка, которая на самом деле означает «в аудио нет слов».
    ///
    /// Два пути к одному и тому же факту: пустой ответ сайдкара
    /// (`BoundaryResponses.readASR` → `.empty`) и защита в самом сервисе на
    /// случай, если пустой набор сегментов всё же доедет. Оба — про вход, и ни
    /// один не про сеть, поэтому разбирается это по типу ошибки, а не по
    /// подстроке в сообщении.
    private static func meansNobodySpoke(_ error: Error) -> Bool {
        if let asr = error as? GigasttClient.ClientError, case .emptyResult = asr { return true }
        if let svc = error as? TranscriptionService.TranscriptionError, case .noResults = svc { return true }
        return false
    }

    /// Куда девается встреча, в которой никто не говорил (`SilentRecording`).
    ///
    /// Одна из двух дверей, и обе ведут наружу из очереди: промах по кнопке
    /// приложение убирает за собой само, настоящая тишина остаётся в списке и
    /// говорит, что она тишина. Третьей двери — «стоит и ждёт» — здесь нет,
    /// ровно потому, что она тут и была (`design/no-dead-ends.md`).
    private func settleSilentRecording(_ recordingID: String) {
        guard let rec = recordingStore.recording(for: recordingID) else { return }
        let verdict = SilentRecording.verdict(
            duration: rec.duration,
            hasTranscript: rec.transcript?.isEmpty == false,
            hasNotes: MeetingNotes.resolved(items: rec.noteItems, blob: rec.notes).isEmpty == false
        )
        switch verdict {
        case .discard:
            // Без ⌘Z и без анимации пепла: это не удаление, сделанное человеком,
            // а уборка следа от нажатой мимо кнопки. Предложить вернуть пустой
            // wav значило бы сообщить о нём — то самое сообщение, которого в
            // приложении нет (`design/notifications.md` §3).
            Analytics.signal("Pipeline.silentDiscarded")
            NSLog("[AppState] \(recordingID) — \(Int(rec.duration))s тишины, удаляем")
            if selectedRecordingID == recordingID { selectNeighbor(afterRemoving: rec) }
            recordingStore.remove(rec)
            refreshStorageUsage()
        case .rest:
            Analytics.signal("Pipeline.silentRested")
            recordTerminal(recordingID, phase: .transcribing, reason: .noSpeech)
        }
    }

    /// Put the stage back where an unfinished ASR pass leaves it — never below
    /// the checkpoint a completed ASR wrote (I4), because that difference is an
    /// hour of GPU on the next attempt.
    private func restoreStageAfterInterruptedASR(
        _ recordingID: String,
        phase: PipelineActivity.Phase
    ) {
        modelDownloadProgress = nil
        let current = recordingStore.recording(for: recordingID)?.status
        guard current != .transcribedRaw else { return }
        recordingStore.update(
            id: recordingID,
            status: phase == .diarizing ? .transcribedRaw : .recorded
        )
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
            _ = try MarkdownWriter.save(
                title: rec.title,
                transcript: transcriptText,
                recordingID: recordingID,
                duration: duration,
                speakers: speakers,
                notes: rec.notes,
                calendarMeta: rec.calendarMeta
            )
            advanceStage(recordingID, to: .saved)
            clearFailure(recordingID)
            // A file name is not news, and with a summary still to come this is
            // not even the end of the meeting — the policy folds it into the one
            // «готово» per meeting. It only speaks when nothing follows it.
            notify(
                .transcriptSaved,
                body: "Расшифровка готова",
                isAwaited: isAwaited(recordingID),
                // Саммари придёт всегда, поэтому «Расшифровка готова» всегда
                // молчит в пользу одного «готово» на встречу.
                recapExpected: true
            )
            kickPipeline("saved")
        } catch {
            let failure = recordFailure(
                recordingID, phase: .saving, message: error.localizedDescription
            )
            report(failure, for: recordingID)
        }
    }

    /// Generate LLM recap next to the saved transcript. Skips quietly when no provider is configured.
    ///
    /// `byHand` marks the user pressing «Сгенерировать»: they are watching, so a
    /// failure is told to them at once instead of being retried in the
    /// background like the worker's own attempts.
    @discardableResult
    func runRecap(
        title: String,
        transcriptPath: String,
        speakers: [String],
        notes: String?,
        recordingID: String,
        duration: TimeInterval,
        byHand: Bool = false
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
            let failure = recordFailure(
                recordingID, phase: .summarizing,
                message: "Не удалось прочитать транскрипт", kind: .transient
            )
            report(failure, for: recordingID, force: byHand)
            return .advanced
        }

        // Assume progress; the no-provider branch downgrades this.
        var outcome = PhaseOutcome.advanced
        // A first summary for the meeting that just happened is news — the window
        // comes forward and a notification is posted. Regenerating one after an
        // edit is not, and neither is catch-up on the archive: twenty backlog
        // summaries used to mean twenty notifications and twenty attempts to grab
        // focus, which is precisely how a user finds out the app has a backfill.
        let isNews = (recordingStore.recording(for: recordingID)
            .map { !hasRecap(for: $0) } ?? true) && isAwaited(recordingID)
        do {
            let result = try await recapBackend.generateRecap(
                title: title,
                transcriptMarkdown: md,
                transcriptPath: transcriptPath,
                notes: notes,
                speakers: speakers,
                duration: duration,
                recordingID: recordingID,
                prefs: RecapPreferences.fromShared(),
                progress: { [weak self] detail in
                    Task { @MainActor in self?.setActivityDetail(detail) }
                }
            )
            switch result {
            case .failure(let reason):
                let skip: String
                switch reason {
                case .noProvider: skip = "no_provider"
                case .emptyTranscript: skip = "empty"
                }
                Analytics.recapFinished(ok: false, skip: skip)
                // Not this meeting's fault: retrying it, or moving to the next
                // one, would fail identically until a provider shows up.
                if reason != .emptyTranscript { outcome = .blocked }
                if reason == .emptyTranscript {
                    recordFailure(
                        recordingID, phase: .summarizing,
                        message: "В записи не нашлось речи",
                        kind: .terminal, terminalReason: .noSpeech
                    )
                }
                if selectedRecordingID == recordingID {
                    switch reason {
                    case .noProvider:
                        // A skip, not a failure — and no longer a request either:
                        // the model comes on its own (`ensureSummaryModel`), so the
                        // meeting is simply resting at «расшифрована» until it
                        // lands. `MeetingRest.waiting(.model)` is what says so.
                        recapSkipHint = nil
                        localRecapModelReady = false
                    case .emptyTranscript:
                        // Terminal, and stated as depth rather than as an error:
                        // there was no speech, and no attempt changes that.
                        recapSkipHint = nil
                        recordTerminal(recordingID, phase: .summarizing, reason: .noSpeech)
                    }
                    surfaceMeetingUI(preferSummaryTab: false)
                }
            case .success(let recap):
                Analytics.recapFinished(ok: true, backend: recap.provider)
                // Версия конструкции и телеметрия генерации — только у локального
                // пути: облачная конструкция в 1.16.5 не менялась и остаётся
                // без версии, как весь архив до неё.
                if recap.provider == "ollama", let stats = recap.stats {
                    recordingStore.update(
                        id: recordingID,
                        recapGeneratorVersion: RecapGenerationPolicy.generatorVersion
                    )
                    Analytics.recapGenerated(
                        replyTokens: stats.draft?.replyTokens,
                        retried: stats.draft?.retried ?? false,
                        collapsed: stats.draft?.collapsed ?? false,
                        seconds: stats.seconds,
                        bullets: RecapLint.shape(of: recap.body).bullets,
                        chunked: stats.chunked,
                        version: RecapGenerationPolicy.generatorVersion,
                        author: stats.author
                    )
                }
                // The wait a person felt: from the meeting ending to the summary
                // existing. `date` is when the recording began, so the end of it
                // is `date + duration` — no new state to keep in sync.
                if let entry = recordingStore.recording(for: recordingID) {
                    Analytics.summaryWaited(
                        seconds: Date().timeIntervalSince(entry.date.addingTimeInterval(entry.duration)),
                        awaited: isAwaited(recordingID),
                        meetingDuration: entry.duration
                    )
                }
                if selectedRecordingID == recordingID {
                    lastRecapPath = recap.path
                    recapSkipHint = nil
                }
                if isNews {
                    surfaceSummaryUI(for: recordingID)
                    notify(
                        .meetingReady,
                        body: "Саммари готово — в\u{00A0}карточке встречи",
                        isAwaited: isAwaited(recordingID)
                    )
                }
                await generateMeetingMetadata(recordingID: recordingID, summary: recap.body)
                // `.summarized` means recap *and* metadata, so the stage only
                // moves when both are in. A summary that landed without topics
                // stays at `.saved` and comes back through the short metadata
                // pass — not through a second full summary.
                outcome = finishMetadata(recordingID)
                providerBlockedStreak = 0
                if selectedRecordingID == recordingID { pipelineError = nil }
            }
        } catch is CancellationError {
            // Superseded by a newer edit, or a call started: leave the stage and
            // the entry alone so the restarted loop picks it straight back up.
            debugLog("[pipeline] recap cancelled for \(recordingID)")
            return .advanced
        } catch let error as URLError where error.code == .cancelled {
            debugLog("[pipeline] recap cancelled (transport) for \(recordingID)")
            return .advanced
        } catch {
            // Встречу удалили, пока её конспектировали: это снятая работа, а не
            // провал (см. `vanished`). Ни телеметрии, ни ретрая.
            if vanished(recordingID) {
                debugLog("[pipeline] \(recordingID) исчезла во время саммари — не сбой")
                return .advanced
            }
            Analytics.recapFinished(ok: false)
            // "model ... not found" means the pull never finished. That is the
            // provider missing, not this meeting failing — treated as `.blocked`
            // so the meeting keeps its place in the queue and the panel offers
            // «Скачать» instead of a retry that cannot work.
            if error.localizedDescription.lowercased().contains("not found") {
                localRecapModelReady = false
                if selectedRecordingID == recordingID {
                    recapSkipHint = "Саммари пропущено — локальная модель ещё не скачана. Кнопка «Скачать» на вкладке «Саммари»."
                }
                return .blocked
            }
            let failure = recordFailure(
                recordingID, phase: .summarizing, message: error.localizedDescription
            )
            report(failure, for: recordingID, force: byHand)
            if selectedRecordingID == recordingID, failure.isTerminal || byHand {
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
        // The previous failure is deliberately *not* cleared here. It carries the
        // attempt count, and clearing it at the start of every attempt made each
        // retry look like the first — a 20-second loop that never escalated and
        // never gave up. It is cleared where it stops being true: on success, or
        // when the user asks for a fresh start.
    }

    private func endPipelineWork(_ recordingID: String) {
        pipelineWorkDepth = max(0, pipelineWorkDepth - 1)
        if pipelineWorkDepth == 0 {
            activity = .idle
            // Nothing is running any more — a progress line here would be a lie.
            // And nothing needs a 4 GB model resident: one rule, applied wherever
            // the pipeline goes quiet, instead of a `stopAfterIdle` remembered at
            // each of the call sites that finish work. `ensureServerRunning`
            // cancels it again the moment something does need the server, so a
            // backlog drains on one warm server rather than one per meeting.
            OllamaSidecar.shared.stopAfterIdle(30)
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

    /// A failure with nothing left to try. The log line comes from the reason, so
    /// the same sentence is not hand-copied at three call sites — that is exactly
    /// how the toast copy drifted from the gallery's before it was centralised.
    @discardableResult
    private func recordTerminal(
        _ recordingID: String,
        phase: PipelineActivity.Phase,
        reason: MeetingRest.TerminalReason
    ) -> PipelineFailure {
        recordFailure(
            recordingID, phase: phase,
            message: reason.logMessage, kind: .terminal, terminalReason: reason
        )
    }

    /// Record a failure on the recording it happened to, with its own retry plan.
    /// Persisted, so it outlives other work and a relaunch.
    ///
    /// The plan is the whole point: nothing here asks a person for anything, and
    /// only `.terminal` stops the work (`design/no-dead-ends.md`).
    @discardableResult
    /// Встречи больше нет в индексе — значит работа по ней снята, а не провалена.
    ///
    /// Удаление во время фазы снимает воркера (`deleteRecording`), но сама фаза
    /// уже в полёте: она добегает до своего `catch` и раньше записывала «не
    /// удалось». Это врало трижды. В телеметрию уходил сбой саммари, которого не
    /// было (`Recap.finished ok=false`), в лог — «retry in 19s» про встречу, за
    /// которую никто не ждёт, и планировщик ставил под это пробуждение, хотя
    /// обязательства уже нет. Снято с живого таймлайна 2026-08-11, где человек
    /// удалил три обрывка встречи, пока их конспектировали.
    ///
    /// `.advanced` при этом честен: удалённой встречи нет в очереди, поэтому
    /// цикл не может попросить ту же работу снова (I11).
    private func vanished(_ recordingID: String) -> Bool {
        recordingStore.recording(for: recordingID) == nil
    }

    private func recordFailure(
        _ recordingID: String,
        phase: PipelineActivity.Phase,
        message: String,
        kind: FailureKind? = nil,
        terminalReason: MeetingRest.TerminalReason? = nil
    ) -> PipelineFailure {
        let failure = PipelineFailure(
            phase: phase,
            message: message,
            previous: recordingStore.recording(for: recordingID)?.lastFailure,
            kind: kind,
            terminalReason: terminalReason
        )
        recordingStore.update(id: recordingID, lastFailure: .some(failure))
        if let due = failure.nextAttemptAt {
            debugLog("[pipeline] \(recordingID) \(phase) failed (attempt \(failure.attempt)) — retry in \(Int(due.timeIntervalSinceNow))s")
        }
        return failure
    }

    /// Kept for the log and telemetry only — see below.
    ///
    /// Historical note that used to live here: «show a failure only when it has
    /// become the user's problem: the app has stopped retrying». The app does not
    /// stop retrying any more, so that moment no longer exists (or
    /// asked for it by hand). Anything else is the pipeline doing its job, and
    /// announcing it is what made a working catch-up look broken.
    /// Record a failure where it belongs — the log and telemetry — and nowhere else.
    ///
    /// This used to be the path into the interface: it wrote `pipelineError`, which
    /// became a toast and a red row with «Повторить» on it. There is nothing for a
    /// person to do with any of it (`design/no-dead-ends.md`): the ladder retries
    /// forever, and the only failures that stop are the ones where the input is
    /// gone — which the meeting states as a resting reason, not as an error.
    ///
    /// `byHand` is kept by the callers and no longer changes anything here. It used
    /// to mean «the user asked for this, so they get to see it fail»; a hand-made
    /// request that fails now waits on the same ladder as everything else.
    private func report(_ failure: PipelineFailure, for recordingID: String, force: Bool = false) {
        Analytics.signal("Pipeline.failed.\(failure.phase).\(failure.kind.rawValue)")
        NSLog("[AppState] \(failure.phase) failed on \(recordingID) "
              + "(attempt \(failure.attempt), \(failure.kind.rawValue)): \(failure.message)")
        if failure.kind == .ourFault {
            // Loud locally, counted in release: a bug that only reproduces on
            // someone else's machine is one we never hear about otherwise.
            checkInvariant("pipeline.our-fault", false)
        }
    }

    /// Clear the block so the worker can pick this recording up again. No-op when
    /// there is nothing to clear, so a successful phase doesn't rewrite the index.
    func clearFailure(_ recordingID: String) {
        guard recordingStore.recording(for: recordingID)?.lastFailure != nil else { return }
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

    /// «Расшифровать» / «Повторить» on the open meeting.
    ///
    /// Goes through the queue instead of calling ASR directly. A direct call
    /// while the worker happened to be mid-phase hit the re-entrancy guard and
    /// returned — the button did nothing at all, and nothing re-queued the
    /// meeting afterwards. Hand-requested meetings jump the queue, so "through
    /// the queue" does not mean "behind the backlog".
    func reprocess() async {
        guard let id = selectedRecordingID else {
            surfacePipelineError("Запись не выбрана")
            return
        }
        pipelineError = nil
        clearFailure(id)
        userRequestedID = id
        // Headphones on a call: FluidAudio often collapses everyone into the owner.
        // If we already have segments + mic/sys stems, re-split by energy — no ASR.
        if recordingStore.recording(for: id)?.mergedSegmentsJSON != nil {
            // Relabelling *is* diarization, so it reports as that phase rather
            // than through a separate status line nobody else can clear.
            beginPipelineWork(id, phase: .diarizing)
            let repaired = await repairSpeakerAttribution(recordingID: id)
            endPipelineWork(id)
            if repaired {
                kickPipeline("relabelled")
                return
            }
        }
        // A finished meeting owes nothing, so asking for it again has to walk the
        // stage back — the one thing only an explicit user action may do (I3).
        // Guarded on audio: rewinding a meeting whose audio was deleted would
        // strand it at `.recorded` and lose the summary it already has.
        if let rec = recordingStore.recording(for: id),
           rec.status == .summarized, rec.audioAvailable {
            recordingStore.update(id: id, status: .recorded)
        }
        kickPipeline("user asked")
    }

    /// «Завершить» — resume diarization on a meeting whose ASR finished. The
    /// queue already owes exactly that phase for a `.transcribedRaw` meeting, so
    /// the button only has to ask to be next in line.
    func requestProcessing(_ entry: RecordingEntry) {
        pipelineError = nil
        clearFailure(entry.id)
        userRequestedID = entry.id
        kickPipeline("user asked")
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
            notes: rec.notes,
            calendarMeta: rec.calendarMeta
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
        // Answered, not asked. The old gate put the question on screen and
        // suspended this call on a continuation until someone answered — and
        // «Всё равно скачать» with 2 GB free only moved the failure to the middle
        // of a 3.4 GB pull. The refusal says so where the download was started.
        guard hasRoomForSummaryModel() else {
            // Стоит в настройках, где этим управляют, и больше нигде: встреча к
            // нехватке места на диске отношения не имеет, а сделать с этим
            // человек может только одно — освободить место, когда захочет.
            ollamaSetupError = "Недостаточно места для модели саммари (~3,4\u{00A0}ГБ)."
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
            // parks the loop — everything waiting on a summary can go now,
            // including meetings that ran out of attempts while it was missing.
            applySummaryProviderChange()
            return true
        } catch {
            ollamaSetupProgress = nil
            ollamaSetupMessage = ""
            // Тоже только в настройках. Загрузка сама поедет снова — на каждом
            // запуске и на каждой остановке пайплайна из-за провайдера
            // (`ensureSummaryModel`), поэтому это состояние, а не событие.
            ollamaSetupError = error.localizedDescription
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
            notes: rec.notes,
            calendarMeta: rec.calendarMeta
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
