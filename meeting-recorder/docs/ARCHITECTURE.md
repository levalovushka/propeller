# Propeller — архитектура

_Источник правды по архитектурным решениям форка. Поведение продукта — [SPEC.md](SPEC.md); активные планы/решения — [`../../plan-v2.md`](../../plan-v2.md); инженерная оптимизация — [`../../plan-optimization.md`](../../plan-optimization.md); UI — [`../../design/propeller-ui.md`](../../design/propeller-ui.md)._

## Что это

**Propeller** — нативное macOS-приложение (SwiftUI, macOS 14+, Apple Silicon): запись встреч (mic + system audio), локальная транскрипция на русском (GigaAM-v3 через `gigastt`), диаризация (FluidAudio) → консистентные `Speaker N`, markdown-вывод и LLM-саммари с авто-заголовком/темами/тегами. Живёт в менюбаре + главное окно.

> С plan-v2 Job 3 **вырезаны** библиотека голосов (`PeopleStore`), voice-matching и опрос спикеров. Именование спикеров сведено к консистентным `Speaker N` + владелец-по-микрофону.

Имя бандла / bundle id: `Propeller` / `com.simplyai.meeting-recorder` (id сохранён ради TCC). SPM-таргет бинарника по-прежнему `MeetingRecorder`.

## Ключевые решения

| Решение | Выбор | Почему |
|---|---|---|
| ASR | GigaAM-v3 head **`e2e_rnnt`** через локальный `gigastt serve` (HTTP) | Лучше `rnnt` на реальном Zoom (фаза 0); русский only |
| Доставка ASR | Sidecar `gigastt` внутри `.app`, спаун при старте | Без внешних зависимостей у коллег |
| Диаризация | FluidAudio (не gigastt diar) | На том же Zoom: FluidAudio ≈ 2 спикера, gigastt diar ≈ 14 |
| Язык | Только `ru` | Ограничение модели; мультиязычность убита в бэклоге |
| Вывод markdown | Дефолт **Simple**; Obsidian — опция | Коллеги без Vault |
| Рекап | Ollama → OpenAI → Claude (Auto), или Off | Локально по умолчанию; ключи в Keychain |
| Zoom | **Off / Auto-record** (дефолт Auto) | Запись без подтверждения; отмена через системное уведомление «Не записывать» |
| Спикеры | Консистентные `Speaker N` + владелец-по-микрофону | Библиотека голосов/матчинг вырезаны (plan-v2 Job 3); «тупо и надёжно» |
| Календарь | EventKit, read-only (не Google OAuth) | Читает системный Календарь; без облака, только разрешение |
| Сохранение транскрипта | **Всегда** (сразу после диаризации) | Опроса спикеров и тугла auto-save нет |
| Дистрибуция v1 | DMG, без Sparkle; нотаризация опциональна | Малая команда |
| Иконка | `propellericon.icon` → Assets.car + .icns через `actool` | Liquid Glass + fallback |
| Саммари / заметки | Встреча: табы Transcript / Notes / Summary; sidebar **Summaries** — только summary+notes; заметки пишутся во время записи и якорят LLM (как Granola) | Talat-табы + Granola notes-as-anchors; авто-рекап после save |

## Поток данных

```
ZoomMeetingDetector (Auto) / menu bar / ⌘R / UI
  → AudioRecorder
      mic (.mic.wav) + ScreenCaptureKit system (.sys.wav)
      → offline mix → {id}.wav (+ stems пока аудио хранится)
  → TranscriptionService
      → GigasttSidecar / GigasttClient  (ASR → ASRSegment[])
      → checkpoint status=transcribed_raw
      → FluidAudio diarization → Speaker N + владелец-по-микрофону
      → transcript + PersistedSegment[]
  → MarkdownWriter  (simple | obsidian) → save (транскрипт всегда)
  → RecapService    (если провайдер доступен)
      → generateMetadata → заголовок / темы / теги
```

Статусы записи: `recording → recorded → transcribing → transcribed_raw → transcribed → saved`.

## Компоненты (`swift/Sources/`)

| Файл | Роль |
|---|---|
| `AppState` | `@MainActor` координатор: запись, пайплайн, Zoom, backfill, переименование спикеров |
| `AudioRecorder` | Mic (AVAudioRecorder или VoiceProcessing AEC) + system audio + офлайн-микс |
| `SystemAudioCapture` | ScreenCaptureKit stem (app-scoped фильтр + display-wide fallback) |
| `ZoomMeetingDetector` | Поллы `aomhost` / meeting-window / display-sleep assertion (`caphost` ≠ встреча) |
| `CalendarService` | EventKit: секция Upcoming (read-only, без OAuth) |
| `NoteOverlayController` | Оверлей быстрых заметок ⌃⌥N во время записи |
| `NotificationManager` | UNUserNotificationCenter: интерактивная отмена авто-записи + баннеры |
| `TranscriptionService` | ASR → diarize → `Speaker N` + владелец-по-микрофону |
| `GigasttSidecar` / `GigasttClient` | Жизненный цикл сервера и HTTP |
| `RecordingStore` | Индекс записей + CRUD + retention |
| `MarkdownWriter` / `RecapService` | Экспорт и LLM-саммари + метадата (заголовок/темы/теги) |
| `Preferences` | UserDefaults + Keychain для API-ключей |
| UI | `MainView`, `RecordingDetailView`, `RecordingInProgressView`, `MenuBarPanelView`, `SettingsSheet`, `OnboardingView`, `SearchPalette`, … |

## Хранилище

```
~/.meeting-recorder/
  recordings/   recordings.json, *.wav, *.mic.wav, *.sys.wav
  meetings/     {id}-{slug}.md, {id}-{slug}-recap.md
  people/       # ЛЕГАСИ: больше не читается/не пишется (данные на диске не трогаем)

~/Library/Application Support/Meeting Recorder/
  gigastt-models/   # ~225 МБ GigaAM (имя папки — наследие TCC/эпохи форка)
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
