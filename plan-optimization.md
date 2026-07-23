# Propeller — план оптимизации (энергия · стабильность · надёжность)

_Компаньон к [plan-v2.md](plan-v2.md). Там — продуктовые джобы; здесь — инженерный слой: сделать Propeller самым «энергоэффективным», стабильным и надёжным приложением для рекапов на рынке. Составлено 2026-07-23 по итогам глубокого ревью кодовой базы + сверки с гайдами Apple по энергоэффективности и современными практиками захвата аудио._

**Целевая установка (из [plan-v2.md](plan-v2.md)):** аудитория — менеджеры, сценарий «установил, настроил и забыл». Значит приложение **постоянно живёт в фоне** (menu bar), а тяжёлая работа (ASR + диаризация + локальная LLM) — редкий пост-митинговый батч. Отсюда главный принцип оптимизации: **в простое приложение должно быть почти невидимым для системы; всё дорогое — лениво, по требованию, с явным освобождением ресурсов после батча.**

Статусы шагов: ☐ не начато · ◐ в работе · ☑ готово.

---

## Что уже сделано правильно (планка)

Осознанные энергорешения, которые НЕ трогаем:

- **`keep_alive: "10s"` для Ollama** ([RecapService.swift:390](meeting-recorder/swift/Sources/RecapService.swift:390)) — LLM выгружается из RAM между встречами.
- **Двухфазный чекпоинт** (`transcribed_raw` → диаризация) — дорогой ASR не теряется при краше на диаризации.
- **`.accessory` при закрытии окна** ([MainView.swift:28](meeting-recorder/swift/Sources/MainView.swift:28)) — даёт App Nap усыпить основной процесс.
- **IOKit `IOPMCopyAssertionsByProcess` вместо спауна `pmset`** (plan-v2 1.5).
- **backfill не запускает LLM во время звонка** ([AppState.swift:584](meeting-recorder/swift/Sources/AppState.swift:584)).
- Дебаунс записи индекса, disk-space preflight, `excludesCurrentProcessAudio`, ephemeral URLSession для LLM.

---

## Блок E — Энергоэффективность

### ☐ E1. Ленивый ASR-sidecar с idle-stop (главный рычаг)

**Как сейчас:** `gigastt serve` спаунится **на старте** — дважды: в [MeetingRecorderApp.swift:6](meeting-recorder/swift/Sources/MeetingRecorderApp.swift:6) (`AppDelegate`) и в [AppState.swift:108](meeting-recorder/swift/Sources/AppState.swift:108) (`bootstrap`). Сервер грузит GigaAM-v3 (`--pool-size 1`), становится healthy и живёт до `applicationWillTerminate`.

**Риск/трение:** транскрипция — пост-митинговый батч (`runTranscribe` вызывается только после стопа). Во время звонка gigastt не нужен вообще. Значит отдельный процесс держит ~225 МБ+ модель резидентно в RAM (и тёплой на ANE/GPU) весь день ради задачи на ~30 с несколько раз в сутки. App Nap тут бессилен — это **отдельный дочерний процесс**, OS его не усыпит.

**Решение:**
- Спаунить sidecar **лениво** прямо перед ASR (`prepare()` → `ensureReady()` в [TranscriptionService.swift:44](meeting-recorder/swift/Sources/TranscriptionService.swift:44) уже это умеет).
- **Останавливать** после завершения батча (транскрипт + диаризация + слив backfill-очереди), с idle-grace 30–60 с.
- Убрать оба warm-up со старта.
- Разделить *download* и *serve*: первую загрузку модели оставить в онбординге с прогрессом (plan-v2 4.5b/5.5), но «скачать» ≠ «держать в памяти».

**Шаги:** (1) вынести `ensureReady` из `AppDelegate` и `bootstrap`; (2) добавить `GigasttSidecar.stopAfterIdle(_:)`; (3) дёргать stop в хвосте `runTranscribe`/backfill; (4) первую загрузку модели вынести в явный onboarding-шаг.

### ☐ E2. Освобождать диаризатор после батча

**Как сейчас:** `TranscriptionService.diarizer` (FluidAudio `OfflineDiarizerManager`) грузится один раз и **никогда не освобождается** ([TranscriptionService.swift:21](meeting-recorder/swift/Sources/TranscriptionService.swift:21)).

**Риск:** тот же паттерн, что E1 — idle-footprint = GigaAM + FluidAudio одновременно, круглосуточно.

**Решение:** `diarizer = nil` после завершения батча (в связке с idle-grace из E1). Повторная загрузка перед следующим батчем дешева относительно постоянного резидента.

### ☐ E3. Поллинг Zoom: tolerance + гейт по запуску + интервал

**Как сейчас:** `ZoomMeetingDetector` крутит `Timer` каждые 2.0 с **без `tolerance`** ([ZoomMeetingDetector.swift:47](meeting-recorder/swift/Sources/ZoomMeetingDetector.swift:47),[:55](meeting-recorder/swift/Sources/ZoomMeetingDetector.swift:55)). Когда Zoom запущен (часто держат открытым), каждый тик гоняет три дорогих зонда: `proc_listpids(PROC_ALL_PIDS)` — перебор до 4096 pid'ов с `proc_name()` на каждый ([:139](meeting-recorder/swift/Sources/ZoomMeetingDetector.swift:139)); `CGWindowListCopyWindowInfo` по всем окнам ([:168](meeting-recorder/swift/Sources/ZoomMeetingDetector.swift:168)); `IOPMCopyAssertionsByProcess` + per-pid `proc_name` ([:200](meeting-recorder/swift/Sources/ZoomMeetingDetector.swift:200)).

**Риск:** без tolerance таймер полностью ломает timer coalescing (каждый тик = гарантированный wakeup). Полное сканирование таблицы процессов + снапшот окон каждые 2 с, вечно, пока Zoom idle-открыт — ровно анти-паттерн «menu bar utility keeps checking data all day» из гайда Apple.

**Решение:**
- `timer.tolerance = pollInterval * 0.3` минимум.
- Гейтить поллинг фактом запущенности Zoom через `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification`: цикл активен только пока `us.zoom.xos` жив.
- Интервал 5–8 с (`enterThreshold=2` и так добавляет задержку; 2-с точность не нужна).
- Ранний выход из `captureSnapshot`, если более дешёвый сигнал уже сработал (не гонять `proc_listpids` зря).

### ☐ E4. Core Audio Process Taps вместо ScreenCaptureKit (стратегический; закрывает Job 1.2)

**Как сейчас:** `SystemAudioCapture` использует SCK с фантомным видео-потоком (`width/height = 2`, `minimumFrameInterval = 1s`, `queueDepth = 5`, [SystemAudioCapture.swift:122](meeting-recorder/swift/Sources/SystemAudioCapture.swift:122)) — воркэраунд того, что SCK требует видео даже для аудио.

**Риск/трение:** поднимается полный screen-capture-пайплайн, нужен Screen Recording (тяжёлая TCC-поверхность), горит фиолетовый индикатор.

**Решение:** приложение таргетит macOS 14+; **Core Audio Process Taps** (`CATapDescription` + `AudioHardwareCreateProcessTap`) появились в **14.2** — чистый аудио-путь без видео-пайплайна, без Screen Recording ради звука, ниже CPU, с нативным **per-process scoping** (тапнуть именно процесс Zoom). Это ровно цель plan-v2 **Job 1.2** («тянуть только звук встречи»), но надёжнее app-scoped SCK-фильтра. Один переход закрывает энергию и 1.2.

**Нюансы (из практики):** `AVAudioEngine` нельзя перенаправить на CATap-aggregate — нужен `AudioDeviceCreateIOProcIDWithBlock` напрямую; агрегатное устройство требует реальный output как main sub-device + tap с `kAudioAggregateDeviceTapAutoStartKey: true`. Лифт больше остальных — отдельный трек. SCK оставить фолбэком для <14.2 (или поднять минимум до 14.2 — тривиально).

### ☐ E5. Метринг-таймер: только когда waveform видим

**Как сейчас:** `startMetering` тикает каждые 0.08 с ([AudioRecorder.swift:244](meeting-recorder/swift/Sources/AudioRecorder.swift:244)), прыгает на MainActor и аппендит в `@Published micLevelHistory/systemLevelHistory` → инвалидация SwiftUI 12.5 раз/с, **даже когда осциллограмму никто не видит** (окно закрыто, авто-запись Zoom). Часовая встреча ≈ 45 000 MainActor-хопов. Tolerance нет.

**Решение:** гонять метринг только когда `RecordingInProgressView` на экране (пауза при `.accessory` + закрытом окне); снизить до ~10 Гц; добавить tolerance.

### ☐ E6. `os.Logger` вместо `debugLog`

**Как сейчас:** `debugLog` ([AudioRecorder.swift:6](meeting-recorder/swift/Sources/AudioRecorder.swift:6)) на каждом из 53 вызовов делает `FileHandle(forWritingAtPath:)` + seek + write + close (3–4 syscall'а), синхронно, **без ротации и лимита**. За месяцы «install & forget» файл растёт неограниченно; работает в релизе.

**Решение:** перейти на `os.Logger` (unified logging) — кольцевой буфер, near-zero-cost когда лог не читают, privacy-aware, без файлового churn и распухания. Многословные логи — за `#if DEBUG`.

### ☐ E7. Глобальный монитор клавиш — только во время записи

**Как сейчас:** `NoteOverlayController.install()` зовётся в `bootstrap()` и регистрирует `addGlobalMonitorForEvents(.keyDown)` на весь жизненный цикл ([NoteOverlayController.swift:40](meeting-recorder/swift/Sources/NoteOverlayController.swift:40)). Замыкание срабатывает на **каждое нажатие во всей системе**, вечно, хотя оверлей нужен только при записи (`toggle()` рано выходит, если `!isRecording`). Держит Input Monitoring/Accessibility включённым постоянно.

**Решение:** ставить глобальный монитор на старте записи, снимать на стопе. Фича сохраняется; per-keystroke-налог и always-on Input Monitoring в простое исчезают (+ приватность).

---

## Блок S — Стабильность / надёжность

### ☐ S1. ASR-аплоад стримом с диска, а не весь WAV в RAM

**Как сейчас:** `GigasttClient.transcribe` делает `Data(contentsOf:)` и кладёт в `httpBody` ([GigasttClient.swift:94](meeting-recorder/swift/Sources/GigasttClient.swift:94)). 2-часовая встреча ≈ 230 МБ целиком в памяти + копия в теле запроса.

**Решение:** `URLSession.uploadTask(fromFile:)` — стрим с диска без полной загрузки. Снимает пик памяти и риск тихого фейла под давлением.

### ☐ S2. Юнит-тесты чистых функций (крупнейший пробел под «самое надёжное»)

**Как сейчас:** нет XCTest/swift-testing, только `SpeakerMatchingCoreChecks` (ручной checks-executable).

**Решение:** покрыть чистые функции, где цена ошибки высока: `recoverInterruptedRecordings` (стейт-машина статусов), `mergeTranscriptionWithDiarization` (midpoint-логика), `wavDuration` (парсинг заголовка), `parseMetadata` (битый JSON от LLM), `systemMixGain`/`bufferStats` (границы усиления). Добавить тест-таргет в `Package.swift`.

### ☐ S3. Backoff и cap на авто-рестарт sidecar

**Как сейчас:** `terminationHandler` безусловно ре-`ensureReady()` через 1.5 с на любой неинтенциональный выход ([GigasttSidecar.swift:155](meeting-recorder/swift/Sources/GigasttSidecar.swift:155)).

**Риск:** если бинарник крашится на старте (битая модель, несовместимость) — бесконечный респаун каждые ~1.5 с + health-timeout, жрущий батарею и заливающий лог, без видимой ошибки.

**Решение:** счётчик рестартов + экспоненциальный backoff + порог сдачи, который поднимает внятную ошибку в UI вместо петли.

### ☐ S4. Проверка владения портом 9876

**Как сейчас:** `startIfNeeded` рано возвращается, если `probeHealth()` прошёл ([GigasttSidecar.swift:91](meeting-recorder/swift/Sources/GigasttSidecar.swift:91)) — если :9876 занят чужим процессом, приложение считает его «своим» и молча транскрибирует через незнакомца.

**Решение:** эфемерный порт, записанный в рантайм-файл, либо верификация, что healthy-сервер — наш child (PID/токен).

### ☐ S5. Единый энергоосознанный планировщик backfill

**Как сейчас:** `startSummaryBackfill` ретраит каждые 30 с до 8 раз на старте **и** после каждого рекапа ([AppState.swift:632](meeting-recorder/swift/Sources/AppState.swift:632),[:936](meeting-recorder/swift/Sources/AppState.swift:936)); каждая проба — HTTP к Ollama :11434. Если Ollama не установлена — повторные фейлы; цепочки ретраев накладываются.

**Решение:** заменить `Task.sleep`-циклы на `NSBackgroundActivityScheduler` (deferrable, thermal/battery-aware — идиоматический дом для отложенной фоновой работы). Одна coalesced-очередь вместо накладывающихся.

### ☐ S6. `.tolerance` всем таймерам

**Как сейчас:** ни у одного таймера нет tolerance — displayTimer 1 с ([AppState.swift:411](meeting-recorder/swift/Sources/AppState.swift:411)), meterTimer 0.08 с, zoom-поллинг 2 с.

**Решение:** по гайду Apple это правка №1 для энергии. Часы «прошло MM:SS» — tolerance 0.2–0.5 с; остальные — ≥30 % интервала.

---

## Блок A — Архитектура / гигиена (легче, на потом)

- ☐ **A1. Убрать дубль warm-up sidecar** — решается в E1 (два вызова `ensureReady` при старте).
- ☐ **A2. Вынести стейт-машину пайплайна из `AppState`** (1058 строк: координатор + пайплайн + disk-space + backfill + редактирование сегментов) в `PipelineCoordinator` — станет тестируемой (см. S2). Не срочно.
- ☐ **A3. `NSBackgroundActivityScheduler` как дом периодики** — retention-nudge (Job 6.1), backfill (S5/4.5b), любая maintenance. Сейчас это launch-time и `Task.sleep`.
- ☐ **A4. Убрать мёртвый retention-код** — `performRetentionCleanup` (day-based авто-удаление) живёт в bootstrap ([AppState.swift:79](meeting-recorder/swift/Sources/AppState.swift:79)), хотя plan-v2 6.1 решил заменить на size-nudge и «никогда не удалять само». По умолчанию `retentionDays=0` → no-op, но код противоречит решению. Либо доделать 6.1, либо удалить.

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
E1 · E3 · S6 · E7 · E6 · E2 · E5 · A1 · A4. Это малый-эффорт/крупный-эффект пакет; превращает Propeller из «нормального фонового приложения» в «самое энергоэффективное на рынке» без риска для функциональности.

**Оптимизация R2 — «крепкий фундамент»:**
S1 · S3 · S4 · S5 · S2 (тесты) · A2/A3.

**Оптимизация R3 — «best on the market по захвату»:**
E4 (Core Audio Process Taps) — заодно закрывает застрявший plan-v2 Job 1.2.

---

## Источники (best practices)

- [Apple — Energy Efficiency Guide: Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
- [Apple — Schedule Background Activity (NSBackgroundActivityScheduler)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/SchedulingBackgroundActivity.html)
- [Apple — Prioritize Work at the Task Level (QoS)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html)
- [Apple — Extend App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)
- [insidegui/AudioCap — Core Audio Process Taps sample (macOS 14.2+)](https://github.com/insidegui/AudioCap)
- [Capturing System Audio on macOS in 2026 (SCK vs Core Audio Taps)](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html)
- [Apple — Meet ScreenCaptureKit (WWDC22)](https://developer.apple.com/videos/play/wwdc2022/10156/)
