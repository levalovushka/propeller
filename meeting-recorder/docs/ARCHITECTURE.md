# Propeller — архитектура

_Источник правды по архитектурным решениям форка. Поведение продукта — [SPEC.md](SPEC.md); активные планы/решения — [`../../plan-v2.md`](../../archive/plan-v2.md); инженерная оптимизация — [`../../plan-optimization.md`](../../archive/plan-optimization.md); UI — [`../../design/propeller-ui.md`](../../design/propeller-ui.md)._

## Что это

**Propeller** — нативное macOS-приложение (SwiftUI, macOS 14+, Apple Silicon): запись встреч (mic + system audio), локальная транскрипция на русском (GigaAM-v3 через `gigastt`), диаризация (FluidAudio) → консистентные `Speaker N`, markdown-вывод и LLM-саммари с авто-заголовком/темами/тегами. Живёт в менюбаре + главное окно.

> С plan-v2 Job 3 **вырезаны** библиотека голосов (`PeopleStore`), voice-matching и опрос спикеров. Именование спикеров сведено к консистентным `Speaker N` + владелец-по-микрофону.

Имя бандла / bundle id: `Propeller` / `com.simplyai.meeting-recorder` (id сохранён ради TCC). SPM-таргет бинарника по-прежнему `MeetingRecorder`.

## Ключевые решения

| Решение | Выбор | Почему |
|---|---|---|
| ASR | GigaAM-v3 head **`e2e_rnnt`** через локальный `gigastt serve` (HTTP) | Лучше `rnnt` на реальном Zoom (фаза 0); русский only |
| Доставка ASR | Sidecar `gigastt` внутри `.app`, **ленивый** спаун + idle-stop; длинные файлы — **клиентский чанкинг** (`GigasttChunking`) + `--body-limit-bytes 67108864` | Без внешних зависимостей; обход HTTP 413 / duration cap |
| Диаризация | FluidAudio (не gigastt diar) | На том же Zoom: FluidAudio ≈ 2 спикера, gigastt diar ≈ 14 |
| Захват звука | **Единственный путь: process tap + агрегатное устройство** (`ProcessTapCapture`). Микрофон и системный звук снимаются одной IOProc одного устройства, кадр в кадр. Не поднялся — запись честно микрофонная | Замер 2026-07-29: когерентность дорожек в речевой полосе **0.91–0.97** против 0.04 у прежнего пути, сдвиг стемов исчез как класс. ScreenCaptureKit-путь удалён вместе с подъёмом минимума до 14.4: две ветки захвата — это две правды про устройство дорожек, и весь конвейер ниже вынужден уметь обе |
| Минимум macOS | **14.4** | Раньше `AudioHardwareCreateProcessTap` не существует |
| Запись экрана | **Не запрашивается** | Звуку не нужна. Заголовки окон читаются, если разрешение выдано (у прежних пользователей оно есть), но ни спросить его, ни блокировать им онбординг мы больше не будем |
| Область захвата | `CaptureScopePolicy` (что писать) + `TapTargetPolicy` (в какие процессы целиться), обе по таблице `MeetingPlatform` | Core Audio фильтруется процессами, а не приложениями: звонок Zoom играет хелпер `CptHost`. SCK отдавал его вместе с приложением молча, тапу его надо назвать |
| Язык | Только `ru` | Ограничение модели; мультиязычность убита в бэклоге |
| Вывод markdown | Дефолт **Simple**; Obsidian — опция | Коллеги без Vault |
| Рекап | Ollama → OpenAI → Claude (Auto), или Off; промпт = конспект договорённостей + `languageLock` | Локально по умолчанию; ключи в Keychain |
| Zoom | **Off / Auto-record** (дефолт Auto) | Запись без подтверждения; отмена через системное уведомление «Не записывать» |
| Спикеры | Консистентные `Speaker N` + владелец-по-микрофону | Библиотека голосов/матчинг вырезаны (plan-v2 Job 3); «тупо и надёжно» |
| Календарь | EventKit, read-only (не Google OAuth); title при старте записи | Читает системный Календарь; без облака |
| Сохранение транскрипта | **Всегда** (сразу после диаризации) | Опроса спикеров и тугла auto-save нет |
| Дистрибуция v1 | DMG + **Sparkle** (GitHub Releases `appcast.xml`); нотаризация / Developer ID — позже | ad-hoc + ПКМ→Открыть; авто-апдейты с EdDSA; проверка фида **раз в час** (`SUScheduledCheckInterval`, минимум Sparkle) |
| Иконка | `propellericon.icon` → Assets.car + .icns через `actool` | Liquid Glass + fallback |
| Саммари / заметки | Встреча: табы Transcript / Notes / Summary; sidebar **Summaries** — только summary+notes; заметки якорят LLM | Talat-табы + Granola notes-as-anchors; авто-рекап после save |

## Поток данных

```
MeetingDetector (Auto) / menu bar / ⌘R / UI
  → AudioRecorder
      mic (.mic.wav) + ScreenCaptureKit system (.sys.wav)
      → offline mix (стемы уже выровнены; StemTimeline — только для старых записей) → {id}.wav (+ stems)
  → одна очередь, один воркер (AppState.kickPipeline → PipelineDrain)
      фазы: transcribing → diarizing → saving → summarizing
```

**Пайплайн — очередь, а не цепочка вызовов.** Фазы не вызывают друг друга: каждая
двигает стадию записи и заканчивается `kickPipeline()`. Что делать дальше,
`nextJob` выводит из стадий на диске, поэтому очередь переживает краш и не
хранится вторым местом. Подробности и обоснования — [REFACTOR-PIPELINE-STATE.md](REFACTOR-PIPELINE-STATE.md).

Состояние встречи — два независимых измерения:

- **`RecordingEntry.status: RecordingStage`** — что достигнуто (персистентно):
  `recording → recorded → transcribing → transcribed_raw → transcribed → saved → summarized`.
  `transcribing` встречается только после краша; `RecordingRecovery` разбирает его при старте.
- **`AppState.activity: PipelineActivity`** — что идёт прямо сейчас (эфемерно,
  одно на приложение: воркер один).
- Ошибка принадлежит записи (`entry.lastFailure`), не приложению, и выводит её
  из очереди до явного «Повторить».

## Компоненты (`swift/Sources/`)

| Файл | Роль |
|---|---|
| `AppState` | `@MainActor` координатор: запись, воркер пайплайна, детект звонков, переименование спикеров |
| `AudioRecorder` | Выбирает путь захвата (`CapturePathPolicy`) и сводит стемы. Общие часы → `ProcessTapCapture`; иначе `AVAudioRecorder` + SCK. `lastStopWasMicOnly`, `capturePath` |
| `ProcessTapCapture` | Тап на процессы встречи (или на всё, кроме себя) внутри приватного агрегатного устройства вместе с микрофоном. Одна IOProc → кольцо → 16 кГц моно стемы. Кадры кладутся по `mSampleTime` (`CaptureCursor`), состав агрегата подбирается лестницей и проверяется фактами (число каналов, пришли ли буферы) |
| `CoreAudioObjects` | Чтение свойств Core Audio без церемонии: устройства, процессы, тапы, состав агрегата |
| `TapProbe` | Отладочный `--tap-probe`: шесть ступеней от сырого устройства до смены устройств на живой записи, с пиком по каждому каналу. Существует потому, что порядок каналов агрегата нигде не задокументирован, а промах по нему молчаливый |
| `SystemAudioCapture` | ScreenCaptureKit stem. Область — `CaptureScopePolicy`: сужаемся на приложение той платформы, чей звонок идёт; нет звонка (или он в браузере) — пишем машину целиком. Отката по тишине нет с 2026-07-29 |
| `CaptureProbe` | Отладочный `--capture-probe` в релизном бинарнике: сравнивает области захвата на живом звонке. Оставлен сознательно 2026-07-29 — разрешение «Запись экрана» выдано бандлу, отдельная утилита мерила бы другую систему, а идентификаторы платформ ещё не все подтверждены |
| `MeetingDetector` | Поллинг звонка в любой платформе из `MeetingPlatform.all` (Zoom, Контур.Толк): helper-процесс, заголовок окна, вкладка браузера, display-sleep assertion |
| `PipelineBoundaries` | `Transcriber` / `RecapBackend` — две подменяемые границы наружу |
| `CalendarService` | EventKit: Upcoming + `suggestedRecordingTitle` при старте записи |
| `NoteOverlayController` | Оверлей быстрых заметок ⌃⌥N во время записи |
| `NotificationManager` | UNUserNotificationCenter: интерактивная отмена авто-записи + баннеры |
| `StateGallery` · `GalleryExport` · `GalleryFixture` | Только под `-DGALLERY` (`./build.sh --gallery`): окно со всеми состояниями из `UIStateCatalog`, экспорт в PNG, фикстурный архив под съёмку. Архив подменяется через `Preferences.galleryArchiveRoot` — ключа нет в обычной сборке, реальные записи не читаются. См. [design/state-gallery.md](../../design/state-gallery.md) |
| `TranscriptionService` | ASR → diarize → `Speaker N` + владелец-по-микрофону |
| `GigasttSidecar` / `GigasttClient` | Жизненный цикл сервера и HTTP (+ chunking) |
| `PropellerPure` | Чистое ядро (988 строк, 111 тестов): стадии и очередь (`RecordingStage`, `PipelineActivity`, `PipelineDrain`), презентация транскрипта (`TranscriptPresentation`), разбор ответов границ (`BoundaryResponses`), платформы созвонов (`MeetingPlatform`), chunking, парсеры, WAV helpers |
| `RecordingStore` | Индекс записей + CRUD + size-nudge (без auto-delete) |
| `MarkdownWriter` / `RecapService` | Экспорт и LLM-конспект + метадата (заголовок/темы/теги) |
| `Preferences` | UserDefaults + Keychain для API-ключей |
| UI | `MainView`, `RecordingDetailView`, `RecordingInProgressView`, `MenuBarPanelView`, `SettingsSheet`, `Onboarding*`, `PropellerUI/`, `SearchPalette`, … |

## Хранилище

```
~/.meeting-recorder/
  recordings/   recordings.json, *.wav, *.mic.wav, *.sys.wav
  meetings/     {id}-{slug}.md, {id}-{slug}-recap.md
  people/       # ЛЕГАСИ: больше не читается/не пишется (данные на диске не трогаем)

~/Library/Application Support/Meeting Recorder/
  gigastt-models/   # ~247 МБ GigaAM INT8, копируются из бандла (имя папки — наследие TCC/эпохи форка)
  hotwords.txt      # словарь Domain terms для gigastt
```

## Сборка и запуск

```bash
cd meeting-recorder/swift
./build.sh                 # release SPM → /Applications/Propeller.app (+ gigastt + icon)
open -a Propeller
```

`build.sh` ищет `propellericon.icon` в корне репо Propeller, бандлит `tools/gigastt/gigastt`, подписывает Dev-сертификатом или ad-hoc.

## Что сознательно не трогаем без миграции

- Bundle id и путь Application Support «Meeting Recorder» — смена сбрасывает TCC / модели.
- Имя SPM-executable `MeetingRecorder` — косметика, не блокер.
- Легаси-данные `~/.meeting-recorder/people/` — не читаем, но и не удаляем без явной миграции.
