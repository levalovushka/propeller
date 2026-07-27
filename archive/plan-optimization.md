# Propeller — план оптимизации (энергия · стабильность · надёжность)

_Компаньон к [plan-v2.md](plan-v2.md). Там — продуктовые джобы; здесь — инженерный слой: сделать Propeller самым «энергоэффективным», стабильным и надёжным приложением для рекапов на рынке. Раунд 1 (E/S/A, 2026-07-23) — энергия в простое и фундамент sidecar; раунд 2 (C/M/P/R/H, 2026-07-24) — корректность данных, живучесть записи, аудио-качество, UI-стоимость и гигиена._

**Целевая установка (из [plan-v2.md](plan-v2.md)):** аудитория — менеджеры, сценарий «установил, настроил и забыл». Значит приложение **постоянно живёт в фоне** (menu bar), а тяжёлая работа (ASR + диаризация + локальная LLM) — редкий пост-митинговый батч. Отсюда главный принцип оптимизации: **в простое приложение должно быть почти невидимым для системы; всё дорогое — лениво, по требованию, с явным освобождением ресурсов после батча.**

Статусы шагов: ☐ не начато · ◐ в работе · ☑ готово.

---

## Что уже сделано правильно (планка)

Осознанные энергорешения, которые НЕ трогаем:

- **`keep_alive: "10s"` для Ollama** ([RecapService.swift:390](../meeting-recorder/swift/Sources/RecapService.swift:390)) — LLM выгружается из RAM между встречами.
- **Двухфазный чекпоинт** (`transcribed_raw` → диаризация) — дорогой ASR не теряется при краше на диаризации.
- **`.accessory` при закрытии окна** ([MainView.swift:28](../meeting-recorder/swift/Sources/MainView.swift:28)) — даёт App Nap усыпить основной процесс.
- **IOKit `IOPMCopyAssertionsByProcess` вместо спауна `pmset`** (plan-v2 1.5).
- **backfill не запускает LLM во время звонка** ([AppState.swift:584](../meeting-recorder/swift/Sources/AppState.swift:584)).
- Дебаунс записи индекса, disk-space preflight, `excludesCurrentProcessAudio`, ephemeral URLSession для LLM.

---

## Блок E — Энергоэффективность

### ☑ E1. Ленивый ASR-sidecar с idle-stop (главный рычаг)

**Как сейчас:** `gigastt serve` спаунится **на старте** — дважды: в [MeetingRecorderApp.swift:6](../meeting-recorder/swift/Sources/MeetingRecorderApp.swift:6) (`AppDelegate`) и в [AppState.swift:108](../meeting-recorder/swift/Sources/AppState.swift:108) (`bootstrap`). Сервер грузит GigaAM-v3 (`--pool-size 1`), становится healthy и живёт до `applicationWillTerminate`.

**Риск/трение:** транскрипция — пост-митинговый батч (`runTranscribe` вызывается только после стопа). Во время звонка gigastt не нужен вообще. Значит отдельный процесс держит ~225 МБ+ модель резидентно в RAM (и тёплой на ANE/GPU) весь день ради задачи на ~30 с несколько раз в сутки. App Nap тут бессилен — это **отдельный дочерний процесс**, OS его не усыпит.

**Решение:**
- Спаунить sidecar **лениво** прямо перед ASR (`prepare()` → `ensureReady()` в [TranscriptionService.swift:44](../meeting-recorder/swift/Sources/TranscriptionService.swift:44) уже это умеет).
- **Останавливать** после завершения батча (транскрипт + диаризация + слив backfill-очереди), с idle-grace 30–60 с.
- Убрать оба warm-up со старта.
- Разделить *download* и *serve*: первую загрузку модели оставить в онбординге с прогрессом (plan-v2 4.5b/5.5), но «скачать» ≠ «держать в памяти».

**Сделано (2026-07-23):** warm-up убран из `AppDelegate` и `bootstrap`; добавлен `GigasttSidecar.stopAfterIdle(45)`; `TranscriptionService.releaseHeavyResources()` вызывается в `defer` у `runTranscribe` / `completeDiarization`. Первая загрузка модели по-прежнему ленивая при первом ASR (явный onboarding-шаг — позже, 4.5b/5.5).

### ☑ E2. Освобождать диаризатор после батча

**Как сейчас:** `TranscriptionService.diarizer` (FluidAudio `OfflineDiarizerManager`) грузится один раз и **никогда не освобождается** ([TranscriptionService.swift:21](../meeting-recorder/swift/Sources/TranscriptionService.swift:21)).

**Риск:** тот же паттерн, что E1 — idle-footprint = GigaAM + FluidAudio одновременно, круглосуточно.

**Решение:** `diarizer = nil` после завершения батча (в связке с idle-grace из E1). Повторная загрузка перед следующим батчем дешева относительно постоянного резидента.

**Сделано (2026-07-23):** `releaseHeavyResources()` обнуляет `diarizer` + `gigasttReady` и планирует idle-stop sidecar.

### ☑ E3. Поллинг Zoom: tolerance + гейт по запуску + интервал

**Как сейчас:** `ZoomMeetingDetector` крутит `Timer` каждые 2.0 с **без `tolerance`** ([ZoomMeetingDetector.swift:47](../meeting-recorder/swift/Sources/ZoomMeetingDetector.swift:47),[:55](../meeting-recorder/swift/Sources/ZoomMeetingDetector.swift:55)). Когда Zoom запущен (часто держат открытым), каждый тик гоняет три дорогих зонда: `proc_listpids(PROC_ALL_PIDS)` — перебор до 4096 pid'ов с `proc_name()` на каждый ([:139](../meeting-recorder/swift/Sources/ZoomMeetingDetector.swift:139)); `CGWindowListCopyWindowInfo` по всем окнам ([:168](../meeting-recorder/swift/Sources/ZoomMeetingDetector.swift:168)); `IOPMCopyAssertionsByProcess` + per-pid `proc_name` ([:200](../meeting-recorder/swift/Sources/ZoomMeetingDetector.swift:200)).

**Риск:** без tolerance таймер полностью ломает timer coalescing (каждый тик = гарантированный wakeup). Полное сканирование таблицы процессов + снапшот окон каждые 2 с, вечно, пока Zoom idle-открыт — ровно анти-паттерн «menu bar utility keeps checking data all day» из гайда Apple.

**Решение:**
- `timer.tolerance = pollInterval * 0.3` минимум.
- Гейтить поллинг фактом запущенности Zoom через `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification`: цикл активен только пока `us.zoom.xos` жив.
- Интервал 5–8 с (`enterThreshold=2` и так добавляет задержку; 2-с точность не нужна).
- Ранний выход из `captureSnapshot`, если более дешёвый сигнал уже сработал (не гонять `proc_listpids` зря).

**Сделано (2026-07-23):** интервал 6 с + tolerance 30 %; таймер только пока Zoom запущен (NSWorkspace); при `aomhost` — ранний return без window/IOKit сканов.

### ☑ E4. Core Audio Process Taps вместо ScreenCaptureKit (стратегический; закрывает Job 1.2)

**Сделано (2026-07-23), затем откат hot path (2026-07-24):** код `ProcessTapAudioCapture` жив, но **не вызывается** — канон снова **SCK-primary** ([STATE.md](../STATE.md)). На живых Zoom: Process Tap часто писал header-only `.sys.wav`; speculative silence-watchdogs давали ложные баннеры. SCK (Screen Recording уже требуется) — единственный live-путь; mid-recording баннер только если capture не стартовал; mic-only — на stop по реальному стему.

### ☑ E5. Метринг-таймер: только когда waveform видим

**Как сейчас:** `startMetering` тикает каждые 0.08 с ([AudioRecorder.swift:244](../meeting-recorder/swift/Sources/AudioRecorder.swift:244)), прыгает на MainActor и аппендит в `@Published micLevelHistory/systemLevelHistory` → инвалидация SwiftUI 12.5 раз/с, **даже когда осциллограмму никто не видит** (окно закрыто, авто-запись Zoom). Часовая встреча ≈ 45 000 MainActor-хопов. Tolerance нет.

**Решение:** гонять метринг только когда `RecordingInProgressView` на экране (пауза при `.accessory` + закрытом окне); снизить до ~10 Гц; добавить tolerance.

**Сделано (2026-07-23):** `setMeteringDesired` связан с `isWindowOpen`; интервал 0.1 с + tolerance 30 %.

### ☑ E6. `os.Logger` вместо `debugLog`

**Как сейчас:** `debugLog` ([AudioRecorder.swift:6](../meeting-recorder/swift/Sources/AudioRecorder.swift:6)) на каждом из 53 вызовов делает `FileHandle(forWritingAtPath:)` + seek + write + close (3–4 syscall'а), синхронно, **без ротации и лимита**. За месяцы «install & forget» файл растёт неограниченно; работает в релизе.

**Решение:** перейти на `os.Logger` (unified logging) — кольцевой буфер, near-zero-cost когда лог не читают, privacy-aware, без файлового churn и распухания. Многословные логи — за `#if DEBUG`.

**Сделано (2026-07-23):** `debugLog` → `Logger`; verbose SCK callback-логи за `#if DEBUG`.

### ☑ E7. Глобальный монитор клавиш — только во время записи

**Как сейчас:** `NoteOverlayController.install()` зовётся в `bootstrap()` и регистрирует `addGlobalMonitorForEvents(.keyDown)` на весь жизненный цикл ([NoteOverlayController.swift:40](../meeting-recorder/swift/Sources/NoteOverlayController.swift:40)). Замыкание срабатывает на **каждое нажатие во всей системе**, вечно, хотя оверлей нужен только при записи (`toggle()` рано выходит, если `!isRecording`). Держит Input Monitoring/Accessibility включённым постоянно.

**Решение:** ставить глобальный монитор на старте записи, снимать на стопе. Фича сохраняется; per-keystroke-налог и always-on Input Monitoring в простое исчезают (+ приватность).

**Сделано (2026-07-23):** `startMonitoring` / `stopMonitoring` привязаны к begin/stop/cancel записи.

---

## Блок S — Стабильность / надёжность

### ☑ S1. ASR-аплоад стримом с диска, а не весь WAV в RAM

**Итог:** `GigasttClient.transcribe` → `URLSession.upload(for:fromFile:)` — WAV больше не грузится целиком в RAM.

### ☑ S2. Юнит-тесты чистых функций (крупнейший пробел под «самое надёжное»)

**Итог:** модуль `PropellerPure` + `MeetingRecorderTests` (10 тестов): parseMetadata, speakerLabel, mixGain, wavDuration, recovery status. `swift test` зелёный.

### ☑ S3. Backoff и cap на авто-рестарт sidecar

**Итог:** экспоненциальный backoff 1.5→24 с, cap 5 рестартов, потом `lastFailureMessage` и стоп петли.

### ☑ S4. Проверка владения портом 9876

**Итог:** healthy на :9876 принимается только если это наш child `Process`; иначе `SidecarError.portOccupied`.

### ☑ S5. Единый энергоосознанный планировщик backfill

**Итог:** один `NSBackgroundActivityScheduler` (60±30 с, `.utility`); `.deferred` если busy/нет провайдера. `Task.sleep`-цепочки убраны.

### ☑ S6. `.tolerance` всем таймерам

**Как сейчас:** ни у одного таймера нет tolerance — displayTimer 1 с ([AppState.swift:411](../meeting-recorder/swift/Sources/AppState.swift:411)), meterTimer 0.08 с, zoom-поллинг 2 с.

**Решение:** по гайду Apple это правка №1 для энергии. Часы «прошло MM:SS» — tolerance 0.2–0.5 с; остальные — ≥30 % интервала.

**Сделано (2026-07-23):** displayTimer 0.3 с; meterTimer 30 %; zoom 30 %.

---

## Блок A — Архитектура / гигиена (легче, на потом)

- ☑ **A1. Убрать дубль warm-up sidecar** — решено в E1.
- ☐ **A2. Вынести стейт-машину пайплайна из `AppState`** в `PipelineCoordinator`. Не срочно.
- ☑ **A3. `NSBackgroundActivityScheduler` как дом периодики** — backfill на scheduler (S5). Retention-nudge (6.1) — позже.
- ☑ **A4. Убрать мёртвый retention-код** — вызов из bootstrap убран; метод помечен до 6.1.

---

## Приоритеты (impact × усилие)

| # | Правка | Эффект | Усилие |
|---|--------|--------|--------|
| **E1** | Ленивый спаун + idle-stop ASR-sidecar | 🔴 огромный (idle-RAM/wakeups) | Средний |
| **E3** | tolerance + гейт по Zoom + интервал | 🔴 большой | Малый |
| **S6** | `.tolerance` всем таймерам | 🟠 средний | Тривиальный |
| **E6** | `os.Logger` вместо `debugLog` | 🟠 средний + гигиена | Малый |
| **E7** | Глобальный монитор только при записи | 🟠 средний + приватность | Малый |
| **E2** | Освобождать диаризатор после батча | 🟠 средний | Малый |
| **E5** | Метринг только при видимом waveform | 🟠 средний | Малый |
| **S3** | Backoff + cap на рестарт sidecar | 🔵 надёжность | Малый |
| **S1** | `uploadTask(fromFile:)` для ASR | 🔵 память | Малый |
| **S2** | Юнит-тесты чистых функций | 🔵 надёжность | Средний |
| **E4** | Core Audio Taps вместо SCK (+Job 1.2) | 🟠 стратегический | Большой |

---

## Релизная нарезка

**Оптимизация R1 — «незаметен в простое» (быстрый низкорисковый заход, один PR):**
☑ E1 · ☑ E3 · ☑ S6 · ☑ E7 · ☑ E6 · ☑ E2 · ☑ E5 · ☑ A1 · ☑ A4. Это малый-эффорт/крупный-эффект пакет; превращает Propeller из «нормального фонового приложения» в «самое энергоэффективное на рынке» без риска для функциональности.

**Оптимизация R2 — «крепкий фундамент»:**
☑ S1 · ☑ S3 · ☑ S4 · ☑ S5 · ☑ S2 · ☑ A3 · ☐ A2 (не срочно).

**Оптимизация R3 — «best on the market по захвату»:**
☑ E4 (Core Audio Process Taps) — код готов, SCK фолбэк; живой Zoom-тест остаётся.

---

# Раунд 2 — глубокое ревью (2026-07-24)

_Составлено по итогам параллельного ревью четырёх слоёв: аудио-захват, ASR-пайплайн, ядро AppState, UI. Пункты R1–R3 выше не повторяются. Статусы: ☐ не начато · ◐ в работе · ☑ готово._

**Метод:** четыре независимых обхода + сверка критичных находок с кодом (grep/чтение). Фокус — корректность данных, живучесть записи, энергия в простое, SwiftUI-стоимость рендера.

**Инфраструктура измерения уже есть** (MVP из `plan-testing-metrics`): `Bench/`, `PropellerMetrics`, `benchmarks/`, signposts через `PipelineMetrics.interval` в пайплайне — улучшения из 🟠-группы валидировать бенчами, не «на глаз».

### Уточнения верификации (2026-07-24)

| Пункт | Уточнение |
|-------|-----------|
| **M2** | В тексте ревью ошибочно «sleep 100 мс» — в коде `Task.sleep(150ms)` (`AudioRecorder.swift:251`). Суть находки верна: sys стартует позже, микс с индекса 0. |
| **C4** | Реальный хак, **намеренно** оставлен для теста онбординга. Не баг «сейчас» — напоминание откатить перед шипом. |
| **H4 / A2** | Не баг-находка, а архитектурный план выноса стейт-машины. Проверять нечего — делать по желанию. |
| **H3** | Захардкоженный `/Users/levonlobanov/...` также в `Bench/Harness.swift:160`, не только в `GigasttSidecar`. |

### Триаж по риску (полный)

| Риск | Пункты | Правило |
|------|--------|---------|
| 🟢 ≈0 — брать сразу | C7 · C6 · H2 · H3 · удаление старого `OnboardingView` (часть H1) | Можно без живого Zoom-теста |
| 🟡 реальные баги — аккуратно + тест | C1 · C2 · C3 · C5 · C8 · C9 · C10 · R1 · R4 · R5 · P5 · P6 | Юнит/ручной сценарий на каждый |
| 🟠 improvement без замера сомнителен | M4 · R2 · M2/M3 | Сначала бенч / A/B по метрикам |
| 🔴 риск-кластер — свежий live-путь E4 | C10 · M2 · M3 · M5 · всё `ProcessTapAudioCapture` | Не трогать пачкой; живой Zoom-тест обязателен |
| ⚠ перед удалением смотреть поштучно | H1 (мёртвый UI: MenuBarPanelView body, participants/reassign, summaryFocus) | Не сносить «оптом» без grep call-sites |

_Примечание:_ C10 уже применён (флаг `didStopWriting`) как защита данных; остаётся в 🔴-кластере по требованию живого теста Process Tap после любых правок захвата.

---

## Блок C — Корректность / потеря данных (делать первым)

### ☑ C1. Пайплайн пишет транскрипт в чужую встречу при смене выбора

**Где:** `AppState.runTranscribe` фиксирует `rec` в начале, но после `await` зовёт `runSave()`, который снова читает `selectedRecording` (`AppState.swift:707–784 → 855–885`).

**Сценарий:** авто-ASR записи A идёт минуты; пользователь кликает B → markdown/статус/рекап/метаданные уезжают в B с текстом A.

**Фикс:** передавать `recordingID` + снапшот транскрипта/длительности параметром по всей цепочке `runTranscribe → runSave → runRecap`; внутри пайплайна не читать `selectedRecording` / `self.transcript` / `self.recordingDuration`. Это же — шаг 0 для A2.

**Сделано (2026-07-24):** `runSave`/`runRecap` принимают `recordingID` + transcript/duration; UI-стейт обновляется только если выбор совпадает.

### ☑ C2. `reprocess` / `completeDiarization` не подключены к UI — тупики статусов

**Где:** определения в `AppState.swift:801, 978`; греп по проекту — только сами определения. UI обещает «Complete Transcription» (`:460`), кнопки нет.

**Фикс:** кнопки Retry/Complete в `RecordingDetailView` для `recorded` / `transcribed_raw`; при `guard isTranscribing` не молчать — `statusMessage`.

**Сделано (2026-07-24):** кнопки в header и empty-state транскрипта; сообщение при concurrent transcribe.

### ☑ C3. ⌘Q / logout во время записи теряет встречу при живом mic-стеме

**Где:** `applicationWillTerminate` только гасит sidecar (`MeetingRecorderApp.swift:9–12`); финальный `.wav` собирается только в `AudioRecorder.stop()`; recovery смотрит только на финальный файл (`RecordingStore.swift:141–147`), orphan-scan пропускает `.mic`/`.sys` (`:217`).

**Фикс:** `applicationShouldTerminate` → `.terminateLater` + `stopRecordingAndWait` + `flush`; в recovery: если нет финала, но есть `<id>.mic.wav` — дособрать микс из стемов.

**Сделано (2026-07-24):** `AppStateRegistry` + `applicationShouldTerminate`; `recoverMissingFinalMixes()` из `.mic`/`.sys`.

### ☐ C4. TEST-хак: онбординг на каждом запуске

_Намеренно оставлен для теста онбординга (верификация 2026-07-24). Перед шипом — откатить._

**Где:** `AppState.swift:99–102` — `showOnboarding = true`, правильная строка закомментирована.

**Фикс перед релизом:** вернуть `showOnboarding = !Preferences.shared.onboardingCompleted`. Тестовый обход — через env/launch arg, не правку кода.

### ☑ C5. Битый `recordings.json` молча перезаписывается пустым индексом

**Где:** `RecordingStore.load` catch → `scanForOrphanRecordings` → `save()` (`:50–53, 238`) уничтожает единственную копию транскриптов/заметок.

**Фикс:** `moveItem` в `recordings.json.corrupt-<ts>` + алерт; подекодный парсинг (`FailableDecodable`); опционально `.bak` перед записью.

**Сделано (2026-07-24):** quarantine corrupt, per-element decode, `.json.bak` перед записью; убран prettyPrinted (P6).

### ☑ C6. Zoom: русские idle-заголовки → ложный авто-старт записи

**Где:** `idleWindowTitles` только EN (`ZoomMeetingDetector.swift:224–227`); fallback «любой title ≥ 4 символов» (`:251–252`) ловит «Настройки»/«Чат»/«Контакты».

**Фикс:** русские (и др.) idle-заголовки; убрать «длинный title» из позитивных сигналов без второго сигнала (`aomhost` / power assertion).

**Сделано (2026-07-24):** RU idle titles; убран слабый fallback «длинный title».

### ☑ C7. `MarkdownWriter.save` удаляет recap при пересохранении транскрипта

**Где:** чистка по prefix `recordingID-` без исключения `-recap.md` (`MarkdownWriter.swift:38–46`). Зеркальная чистка в `RecapService` уже фильтрует recap.

**Фикс:** одна строка — `&& !file.lastPathComponent.hasSuffix("-recap.md")`.

**Сделано (2026-07-24).**

### ☑ C8. Осиротевший `gigastt` после crash/kill блокирует ASR навсегда (S4 ловит своего сироту)

**Где:** `GigasttSidecar.startIfNeeded` (`:123–131`): health OK + `process == nil` → `portOccupied`. Bench тоже оставляет процесс (`Bench/Harness.swift`).

**Фикс:** PID-файл рядом с моделями; на старте свой сирота → kill/adopt; в конце Bench — `terminate`+`waitUntilExit`. Желательно привязка child к parent (stdin EOF).

**Сделано (2026-07-24):** `gigastt.pid` + `reclaimOrphanIfOurs()`; Bench `defer` terminate.

### ☑ C9. Check-then-act гонка в `ensureReady` → двойной spawn

**Где:** чтение и запись `startTask` в разных критических секциях (`GigasttSidecar.swift:43–59`).

**Фикс:** create-or-return в одном `lock`, либо переписать sidecar в `actor` (закроет и C10).

**Сделано (2026-07-24):** атомарный create-or-return; clear только у creator.

### ☑ C10. Straggler-буфер после `stop()` может затереть весь system-stem

**Где:** `ProcessTapAudioCapture` / `SystemAudioCapture`: `audioFile = nil`, но `outputURL` жив; запоздалый IOProc/`appendPCM` делает `AVAudioFile(forWriting:)` → truncate файла.

**Фикс:** флаг `isStopped` / обнуление `outputURL` на очереди записи; запрет пересоздания файла после stop.

**Сделано (2026-07-24):** `didStopWriting` + `outputURL = nil` на write/sample queue.

---

## Блок M — Память / аудио-качество

### ☐ M1. Офлайн-микс грузит оба стема целиком (~2 ГБ пика на час)

**Где:** `AudioRecorder.readAndResample` (`:477–515`) + `mix` (`:395–445`). При OOM — молчаливый mic-only фолбэк (`:388–392`).

**Фикс:** стриминговый микс чанками (как `WaveformScrubber.loadPeaksChunked`); gain — первым проходом или из `AudioEnergySummary`.

### ☐ M2. Mic/sys стемы суммируются без выравнивания старта и дрейфа

**Где:** sys стартует асинхронно позже mic (`AudioRecorder.swift:125–129`); перед миксом — `Task.sleep(150ms)` (`:251`, не 100 мс); микс с индекса 0 (`:437–440`); host-time / PTS игнорируются. 🟠 без замера + 🔴 live E4.

**Фикс:** зафиксировать host-time старта mic и первого sys-буфера; pad тишиной в начало sys; на длинных записях — drift по длительностям стемов. Валидировать бенчем / живым Zoom, не править «вслепую».

### ☐ M3. Смена/пропажа output-устройства → тихая потеря sys-звука

**Где:** агрегат ProcessTap прибит к UID на старте; нет listener на `kAudioHardwarePropertyDefaultOutputDevice`; watchdog отменяется навсегда после первого audible буфера; SCK `didStopWithError` только логирует.

**Фикс:** listener → пересборка агрегата; `onCaptureIssueDetected` / рестарт стрима; редкий пульс «буферы ещё идут» (30–60 с).

### ☐ M4. Hard-clip суммы mic+sys (комментарий обещает soft clamp)

**Где:** `AudioRecorder.swift:440–442`. Одновременная речь → клиппинг в самых важных для ASR местах.

**Фикс:** soft limiter (`tanh` / knee) или второй проход с нормализацией пика суммы.

### ☐ M5. VoiceProcessed mic: диск-I/O под `NSLock` в аудио-колбэке; `.endOfStream` на каждый буфер

**Где:** `AudioRecorder.swift:618–652`, `:633–643`.

**Фикс:** узкий лок на скаляры; запись на serial queue; в стриме — `.noDataNow`, `.endOfStream` только на stop.

---

## Блок P — Производительность UI / энергия (после C)

### ☐ P1. SearchPalette: полнотекстовый поиск ≥6 раз на кейстрок

**Где:** `matchedRecordings` — computed, дергается из chips/items/footer/onKeyPress (`SearchPalette.swift:164–190`).

**Фикс:** `@State` + `.onChange(of: query)` / `.task(id:)` с debounce; один проход.

### ☐ P2. RecordingDetailView: regex-парсинг транскрипта в body на каждый рендер

**Где:** `displayedTranscriptSegments` → компиляция `NSRegularExpression` на каждый блок (`:965+`); view наблюдает весь `AppState` (~25 `@Published`).

**Фикс:** `static let` паттерны; кэш парса в `@State` на `.onChange(of: transcript)`; сузить наблюдения (см. P4).

### ☐ P3. Живая волна ~1 Гц вместо 10: вложенный `AudioRecorder` не наблюдается

**Где:** `RecordingInProgressView` смотрит только `state`, читает `state.recorder.micLevelHistory`; `@Published recorder` публикует только замену ссылки.

**Фикс:** `@ObservedObject var recorder: AudioRecorder` (передать `state.recorder`). То же для `player` / `recordingStore` где нужно.

### ☐ P4. Целый `AppState` в каждой view → секундные пересборки дерева

**Фикс:** `@Observable` (macOS 14+) или под-объекты (`RecordingClock`, `PipelineStatus`); view читают только нужное.

### ☑ P5. Backfill: ежеминутный сетевой probe даже когда бэкфиллить нечего

**Где:** `resolveBackend` до проверки кандидатов (`AppState.swift:587–595`); `interval = 60`.

**Фикс:** сначала дешёвый подсчёт кандидатов; при нуле — `.finished` без сети; интервал 15–30 мин.

**Сделано:** дешёвый скан кандидатов до сетевого пробы (`AppState.backfillMissingSummaries`).

### ◐ P6. `RecordingStore.save`: весь архив (транскрипты + JSON-в-JSON) на MainActor + prettyPrinted

**Фикс:** убрать `.prettyPrinted`; write в background; стратегически — сайдкары `<id>.transcript.json` (смягчает C5).

**Сделано наполовину:** `.prettyPrinted` убран. Запись по-прежнему синхронная на MainActor — сайдкары/фоновая запись остаются.

### ☐ P7. `distinctSpeakerNames` / `loadPersistedSegments` декодируют JSON в body на каждый рендер

**Фикс:** кэш по `entry.id`, инвалидация при reassign.

### ☐ P8. N-кратное перечитывание mic/sys стемов в `resolveOwnerName`

**Где:** `TranscriptionService.swift:233–247` — `analyze` в цикле по спикерам; внутри — аллокации буферов по 4096 кадров.

**Фикс:** один проход по каждому стему на все окна; один буфер на файл; vDSP для RMS.

---

## Блок R — Надёжность sidecar / LLM

### ☐ R1. `restart()` гоняется со `stop()` → ложный `portOccupied`

**Фикс:** дождаться реального exit в `stop()` / поллить порт до освобождения перед S4.

**Сверено 2026-07-25 — НЕ сделано** (нарезка ошибочно помечала ☑): `stop()` вызывает `terminate()` и планирует SIGKILL через 2 с асинхронно, возвращаясь сразу ([GigasttSidecar.swift:80–89](../meeting-recorder/swift/Sources/GigasttSidecar.swift:80)). `restart()` → `ensureReady()` может успеть до освобождения порта. PID-файл (C8) эту гонку не закрывает.

### ☐ R2. Ollama: таймауты 180/300 с + нет `num_ctx` → молчаливое усечение транскрипта

**Фикс:** выше таймауты или `stream: true`; `options.num_ctx`; бюджет сегментов в промпте с пометкой усечения.

### ☐ R3. ASR HTTP timeout 600 с не масштабируется на длинные встречи

**Фикс:** `max(600, wavDuration * 0.5)`.

### ◐ R4. `downloadModels`: возможен deadlock на stderr-pipe, нет таймаута

**Фикс:** `readabilityHandler` на stderr; таймаут; буфер хвоста строк между чанками.

**Сделано наполовину:** stderr дренится через `readabilityHandler` — deadlock закрыт. **Таймаута всё ещё нет**: зависшая загрузка модели висит бесконечно.

### ◐ R5. `TranscriptionService.gigasttReady` — устаревший кэш; класс без изоляции

**Фикс:** всегда `ensureReady()`; `actor` / `@MainActor`.

**Сделано наполовину:** кэш `gigasttReady` убран, `ensureReady()` зовётся всегда. Класс по-прежнему без изоляции (`class TranscriptionService`).

### ☐ R6. Нет обработки сна Mac / смены input-устройства во время записи

**Фикс:** `willSleep`/`didWake`; listener на default input; перезапуск watchdog целостности.

### ◐ R7. `stopRecordingAndWait` не идемпотентен; `ignoredZoomMeeting` сбрасывается при флапе детектора

**Фикс:** `guard isRecording`; гистерезис ignore (по сессии Zoom / N минут после ended).

**Сделано наполовину:** `guard isRecording` на месте ([AppState.swift:375](../meeting-recorder/swift/Sources/AppState.swift:375)) — идемпотентность закрыта. **Гистерезиса нет**: `ignoredZoomMeeting = false` стоит и в `handleZoomMeetingStarted`, и в `handleZoomMeetingEnded` → см. раунд 3, G3.

---

## Блок H — Гигиена / мёртвый код

### ☐ H1. Удалить мёртвый UI (⚠ поштучно)

Не сносить «оптом» — перед каждым файлом/кластером grep call-sites:

- 🟢 `OnboardingView.swift` целиком (живой путь — `PropellerUI/OnboardingFlowView`) — безопасно
- ⚠ тело `MenuBarPanelView` (оставить/`перенести` `showMainWindow` в `AppWindowRegistry`)
- ⚠ в `RecordingDetailView`: `summaryFocus*`, кластер participants/reassign, `AvatarCircle`, неиспользуемый `markdownURL`

### ☐ H2. Мёртвый код пайплайна / prefs 🟢

- `mergeConsecutiveSameSpeaker` / `formatTranscript(_:speakerNames:)` в `TranscriptionService`
- `summaryLibraryEntries()`, `performRetentionCleanup` + retention prefs (когда 6.1)
- дубли `stripCodeFences`, `todayISO` → оставить Pure + POSIX locale
- 🟢 dev-пути `/Users/levonlobanov/...` в `GigasttSidecar` **и** `Bench/Harness.swift:160` → `#if DEBUG` / env only

### ☐ H3. Мелкие UI/модель

- `DateFormatter` → `static` (`MainView`, `Models.dateFormatted`)
- debounce notes/rename/Keychain (не на каждый кейстрок)
- `markDirty` при программном присвоении notes в `onAppear`
- `ForEach(..., id: \.offset)` → стабильный id сегмента
- версия в `MenuBarPopover` из `LoginItem.appVersionString`
- accessibility: строки как `Button`, `accessibilityLabel` на иконках

### ☐ H4 / A2 — вынос стейт-машины (план, не баг)

Архитектурный рефакторинг, не defect-finding. Делать после стабилизации 🟡:

1. Шаг 0 = C1 (параметры по ID) — уже сделан.
2. `RecordingStatus` enum вместо строк.
3. `PipelineCoordinator` — per-recording pipeline state + очередь.
4. `ZoomAutoRecordController` — флаги ignore/link + гистерезис R7.
5. `SummaryBackfillService` — scheduler + порядок проверок P5.

После шагов 3–5 `AppState` ≈ selection/window/disk-gate (~400 строк вместо ~1080).

---

## Приоритеты раунда 2 (impact × усилие)

| # | Правка | Эффект | Усилие |
|---|--------|--------|--------|
| **C4** | Убрать TEST-онбординг | 🔴 блокер релиза | Тривиальный |
| **C7** | Не удалять recap в MarkdownWriter | 🔴 потеря саммари | Тривиальный |
| **C1** | Пайплайн по recordingID | 🔴 порча данных | Малый |
| **C2** | Кнопки Retry/Complete | 🔴 невосстановимые встречи | Малый |
| **C8** | PID-файл / adopt сироты gigastt | 🔴 ASR мёртв после crash | Малый |
| **C9** | Атомарный ensureReady / actor | 🔴 утечка процесса | Малый |
| **C10** | Stop без truncate стема | 🔴 потеря sys-дорожки | Малый |
| **C3** | terminate + recovery из .mic | 🔴 потеря записи | Средний |
| **C5** | Corrupt-safe recordings.json | 🔴 потеря архива | Средний |
| **C6** | Zoom RU idle titles | 🔴 ложные записи | Малый |
| **P3** | ObservedObject на recorder | 🟠 волна 10 Гц | Тривиальный |
| **P1+P2** | Кэш поиска и парса транскрипта | 🟠 UI-фризы | Малый |
| **M1** | Стриминговый микс | 🟠 RAM / длинные встречи | Средний |
| **M2+M3** | Sync стемов + смена устройства | 🟠 качество ASR / живучесть | Средний |
| **H1** | Удалить мёртвый UI | 🔵 гигиена | Малый |
| **R2** | Ollama num_ctx / таймауты | 🟠 качество рекапов | Малый |
| **P5+P6** | Backfill + save индекса | 🟠 энергия / UI | Малый |
| **A2/H4** | PipelineCoordinator | 🔵 архитектура | Большой |

---

## Релизная нарезка раунда 2 (с учётом триажа)

**R4 — 🟢 + закрытые 🟡 «не теряем данные»:**  
☑ C7 · ☑ C6 · ☑ C1 · ☑ C2 · ☑ C8 · ☑ C9 · ☑ C10* · ☐ C4 (намеренный TEST до шипа) · ☑ H2 · ☑ H3-dev-paths · ☑ OnboardingView delete · ☑ MainView static DateFormatter

\*C10 в 🔴-кластере ProcessTap — нужен живой Zoom-тест после правки.

**R5 — 🟡 живучесть (осторожно):**  
☑ C3 · ☑ C5 · ☑ P5 · ☐ R1 · ◐ R4 · ◐ R5 · ◐ P6 · ◐ R7

_Сверено с кодом 2026-07-25: R1 **не** сделан (не путать с C8/PID-файлом); R4/R5/P6/R7 сделаны наполовину — детали в самих пунктах._

**R6 — 🟠/🔴 только с замером + live E4:**  
☐ M1 · ☐ M2 · ☐ M3 · ☐ M4 · ☐ M5 · ☐ R2 · ☐ R3 · ☐ P8

**R7 — UI (P) и ⚠ H1 поштучно:**  
☐ P1 · ☐ P2 · ☐ P3 · ☐ P4 · ☐ P7 · ☐ H1 (MenuBarPanelView / participants — ещё нет) · ☐ H3-UI debounce/a11y

**R8 — архитектура (не баг):**  
☐ H4/A2

---

# Раунд 3 — сквозной аудит сценариев записи (2026-07-25)

_Метод: трассировка всех путей от интента до готового саммари — поповер, ⌘R, Zoom-автодетект, уведомление «Не записывать», ⌘Q/logout — по коду. Ничего не гонялось вживую._

**Что подтвердилось хорошо:** аудио физически не теряется (mic-стем пишется непрерывно, финальный микс пересобирается из стемов на следующем старте), ASR защищён чекпоинтом `transcribed_raw`, рекап имеет автоматическую страховку (бэкфилл), заметки безопасны (дебаунс 0.6 с + флаш на Stop и на `onDisappear`, а ASR идёт минутами).

**Общая природа находок:** ничего не **стирается** — но встреча может молча **застрять** в нефинальном статусе. Для «install & forget» это равносильно потере: пользователь не получает саммари и не узнаёт почему.

### ☐ G1. Нет очереди транскрипций — встреча подряд молча остаётся без саммари 🔴

**Где:** `runTranscribe` рано выходит при занятости ([AppState.swift:723](../meeting-recorder/swift/Sources/AppState.swift:723)); очереди отложенных нет (грепом пусто). `isTranscribing` держится **всю** цепочку ASR → диаризация → save → LLM-рекап, то есть минуты.

**Сценарий:** встреча A закончилась → пайплайн пошёл; встреча B закончилась в это же окно → `runTranscribe` возвращается с «Transcription already in progress» → B остаётся `recorded` навсегда. Бэкфилл её не подхватит — он требует уже существующий транскрипт ([:592](../meeting-recorder/swift/Sources/AppState.swift:592)).

**Фикс:** см. G2 — закрывается тем же механизмом.

### ☐ G2. У транскрипции нет автостраховки, в отличие от рекапа 🔴

**Структурная асимметрия.** В тупик ведут три двери, выход из всех — только ручная кнопка:

| Как попали | Статус | Кто вытащит сейчас |
|---|---|---|
| ⌘Q во время записи (`autoTranscribe: false`) | `recorded` | только кнопка |
| Краш/выход на диаризации | `transcribed_raw` | только кнопка |
| Ошибка ASR (сайдкар упал, порт занят) | `recorded` / `transcribed_raw` | только кнопка |

`bootstrap` чинит статусы и миксы, но **не возобновляет пайплайн**.

**Фикс (закрывает G1 и G2 разом): реконсилятор пайплайна.** По образцу существующего бэкфилла рекапов: при старте приложения и после завершения каждой цепочки просканировать записи не в терминальном статусе и продвинуть на шаг вперёд — последовательно, с теми же гардами (не во время записи/звонка). Очередь для G1 получается бесплатным побочным эффектом. Естественно ложится в `PipelineCoordinator` (H4/A2, шаг 3).

### ☐ G3. «Не записывать» отменяется флапом детектора 🟠

**Где:** `ignoredZoomMeeting = false` и в `handleZoomMeetingStarted` ([:155](../meeting-recorder/swift/Sources/AppState.swift:155)), и в `handleZoomMeetingEnded` ([:167](../meeting-recorder/swift/Sources/AppState.swift:167)). При провале сигнала на `exitThreshold=3 × 6 с ≈ 18 с` детектор решит «встреча кончилась», а следующий вход перезапустит запись **вопреки явному отказу пользователя**.

**Фикс:** сделать отказ липким на сессию Zoom — не сбрасывать на ended/started, гасить только при выходе приложения Zoom или по таймауту N минут. Это вторая половина R7.

**Почему важнее, чем кажется:** данные не теряются, но записывается то, что человек осознанно запретил — приватность, а не удобство.

### ☐ G4. Заголовок и теги живут только через рекап 🟠

**Где:** `generateMeetingMetadata` вызывается только после успешного рекапа ([:1026](../meeting-recorder/swift/Sources/AppState.swift:1026)). Рекап выключен или провайдера нет → встреча навсегда «Recording 24.07.2026, 14:30» без тем и тегов. Если рекап прошёл, а метадата не распарсилась — ретрая нет вообще: бэкфилл смотрит только на наличие `-recap.md` и такую встречу пропустит.

**Фикс:** условие «есть рекап, но нет тегов/авто-заголовка» — в тот же реконсилятор (G2).

### ☐ G5. Потолок длительности записи — 8 часов (решено 2026-07-25)

**Где:** лимита нет вообще (грепом пусто). Если конец встречи не задетектится, запись идёт бесконечно; диск проверяется только на старте (500 МБ).

**Решение Левона:** максимум **8 часов**, затем авто-стоп с прогоном обычного пайплайна (не отмена — встреча сохраняется). Плюс имеет смысл периодическая проверка свободного места во время долгой записи, а не только префлайт.

### Порядок работ (решено 2026-07-25)

**Сначала — живые тесты на реальных встречах**, потом остальные фиксы. Причина: раунд 2 закрыл девять 🔴-пунктов, включая правки в путях захвата и терминации; накатывать поверх непроверенного ещё один слой изменений — значит отлаживать всё сразу. Живой прогон нужен и как приёмка E4/C10 (ProcessTap), и как источник первых реальных чисел для baseline из [plan-testing-metrics.md](plan-testing-metrics.md).

**Замечание по E4/ProcessTap:** канон 2026-07-24 — **SCK-primary**; `ProcessTapAudioCapture` dormant (не вызывается). Статус E4 выше переписан. Живые Zoom-тесты и анти-413 чанкинг — в [STATE.md](../STATE.md) Часть 0.

---

## Источники (best practices)

- [Apple — Energy Efficiency Guide: Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
- [Apple — Schedule Background Activity (NSBackgroundActivityScheduler)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/SchedulingBackgroundActivity.html)
- [Apple — Prioritize Work at the Task Level (QoS)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html)
- [Apple — Extend App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)
- [insidegui/AudioCap — Core Audio Process Taps sample (macOS 14.2+)](https://github.com/insidegui/AudioCap)
- [Capturing System Audio on macOS in 2026 (SCK vs Core Audio Taps)](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html)
- [Apple — Meet ScreenCaptureKit (WWDC22)](https://developer.apple.com/videos/play/wwdc2022/10156/)
