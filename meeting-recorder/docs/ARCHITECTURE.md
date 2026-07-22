# Propeller — архитектура

_Источник правды по архитектурным решениям форка. Продуктовый бэклог — [`../../product-ideas.md`](../../product-ideas.md), план фаз — [`../../plan-v1.md`](../../plan-v1.md), UI — [`../../design/propeller-ui.md`](../../design/propeller-ui.md)._

## Что это

**Propeller** — нативное macOS-приложение (SwiftUI, macOS 14+, Apple Silicon): запись встреч (mic + system audio), локальная транскрипция на русском (GigaAM-v3 через `gigastt`), диаризация (FluidAudio), библиотека голосов, markdown-вывод и LLM-рекап. Живёт в менюбаре + главное окно.

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
| Сохранение транскрипта | **Всегда** (после resolved speakers) | Тугл auto-save убран |
| Дистрибуция v1 | DMG, без Sparkle; нотаризация опциональна | Малая команда |
| Иконка | `propellericon.icon` → Assets.car + .icns через `actool` | Liquid Glass + fallback |
| Саммари / заметки | Встреча: табы Transcript / Notes / Summary; sidebar **Summaries** — только summary+notes; заметки пишутся во время записи и якорят LLM (как Granola) | Talat-табы + Granola notes-as-anchors; авто-рекап после save |

## Поток данных

```
ZoomMeetingDetector (опц.) / hotkey / UI
  → AudioRecorder
      mic (.mic.wav) + ScreenCaptureKit system (.sys.wav)
      → offline mix → {id}.wav (+ stems пока аудио хранится)
  → TranscriptionService
      → GigasttSidecar / GigasttClient  (ASR → ASRSegment[])
      → checkpoint status=transcribed_raw
      → FluidAudio diarization + PeopleStore match
      → transcript + DetectedSpeaker[]
  → MarkdownWriter  (simple | obsidian)
  → RecapService    (если провайдер доступен)
```

Статусы записи: `recording → recorded → transcribing → transcribed_raw → transcribed → saved`.

## Компоненты (`swift/Sources/`)

| Файл | Роль |
|---|---|
| `AppState` | `@MainActor` координатор: запись, пайплайн, Zoom, спикеры |
| `AudioRecorder` | Mic (AVAudioRecorder или VoiceProcessing AEC) + system audio + mix |
| `SystemAudioCapture` | ScreenCaptureKit stem |
| `ZoomMeetingDetector` | Поллы `aomhost` / meeting-window / display-sleep assertion (`caphost` ≠ встреча) |
| `NotificationManager` | UNUserNotificationCenter: интерактивная отмена авто-записи + обычные баннеры |
| `TranscriptionService` | ASR → diarize → match |
| `GigasttSidecar` / `GigasttClient` | Жизненный цикл сервера и HTTP |
| `RecordingStore` / `PeopleStore` | Индексы + CRUD + retention / voice samples |
| `MarkdownWriter` / `RecapService` | Экспорт и LLM-рекап |
| `Preferences` | UserDefaults + Keychain для API-ключей |
| UI | `MainView`, `RecordingDetailView`, `RecordingInProgressView`, `MenuBarPanelView`, `SettingsSheet`, `OnboardingView`, `SpeakerConfirmationView`, `SearchPalette`, … |

## Хранилище

```
~/.meeting-recorder/
  recordings/   recordings.json, *.wav, *.mic.wav, *.sys.wav
  people/       people.json, {uuid}/*.caf
  meetings/     {id}-{slug}.md, {id}-{slug}-recap.md

~/Library/Application Support/Meeting Recorder/gigastt-models/   # имя папки наследие TCC/эпохи форка
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
- FluidAudio embeddings — смена диаризатора ломает People library (см. бэклог).
