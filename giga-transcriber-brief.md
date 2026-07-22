# Бриф: локальный транскрибатор встреч на GigaAM-v3 (macOS)

_ФТ + план миграции. Решение принято: форк meeting-recorder, движок — GigaAM через gigastt. Обновлено 2026-07-22 после разведки реального кода._

## Решение

- **База форка:** `tonton-golio/meeting-recorder` (Swift, ScreenCaptureKit, FluidAudio-диаризация, MIT, macOS 14+, Apple Silicon).
- **ASR-движок:** GigaAM-v3 через `ekhodzitsky/gigastt` — локальный Rust-сервер, ONNX/CoreML/ANE, MIT.
- **Почему подтвердилось:** ASR в meeting-recorder изолирован в одной функции; gigastt отдаёт таймстемпы и пунктуацию из коробки. Риск (нестыковка ASR ↔ диаризация по времени) снят.
- **Интерфейс:** переписываем позже — вью-слой отделён от логики, это отдельная фаза.

## Скоуп

### Must have (v1)
- macOS (Apple Silicon), полностью локально.
- Захват микрофон + системный звук (ScreenCaptureKit) — уже есть в базе.
- Триггер: ручной старт/стоп (есть, хоткей Ctrl+Opt+R) + автодетект Zoom (дописать).
- Русский ASR через gigastt (заменить WhisperKit).
- Диаризация по спикерам — **оставляем FluidAudio** из базы (обучаемая библиотека голосов, матчинг людей между встречами).
- Выход: Obsidian-markdown с YAML и `[[wikilinks]]` — **уже есть в базе** (`MarkdownWriter.swift`).
- Рекап по настраиваемому промпту — дописать (LLM-слой).

### Won't have (v1)
- Облако, аккаунты, синк.
- Мультиязычность сверх ru (в этом смысл GigaAM).
- Real-time субтитры (батч-режим: записал → расшифровал).
- Редактор заметок «пока говорят».

## Что уже есть в base (не трогаем)

Разведка `meeting-recorder` (~8300 строк Swift, 19 файлов) показала готовыми:
- **Захват аудио:** `SystemAudioCapture.swift` (ScreenCaptureKit) + `AudioRecorder.swift` — микс в 16 кГц mono WAV, с сохранением mic/system-стемов для source-aware матчинга спикеров.
- **Диаризация + матчинг людей:** `TranscriptionService.diarizeAndMatch()` на FluidAudio (WeSpeaker 256-dim embeddings, cosine similarity, авто-лейблинг известных голосов, подтверждение неизвестных). `PeopleStore.swift` (874) + `PeopleSheet.swift` (960) — библиотека голосов.
- **Markdown-вывод:** `MarkdownWriter.swift` — Obsidian-совместимый, YAML frontmatter, `[[wikilinks]]` на страницы спикеров. Ложится прямо в Vault.
- **Крэш-рекавери:** двухфазный пайплайн (ASR-чекпоинт → диаризация), чтобы падение не теряло дорогой ASR.
- **Инфра:** menu bar app, хоткей, онбординг, настройки, retention-политики, ad-hoc подпись без Apple Developer.

## Точка замены ASR (главное)

Вся связь с WhisperKit заперта в **`TranscriptionService.transcribeAudio()`**. Она возвращает `RawTranscriptionResult { segments, rawText }`, где `segments: [TranscriptionSegment]` нужны диаризации только по полям `.start`, `.end`, `.text`. Диаризация FluidAudio на Whisper **не завязана**. Значит миграция:

1. **Поднять gigastt как sidecar.** Забандлить бинарник `gigastt` в `.app`, спаунить `gigastt serve` (loopback `127.0.0.1:9876`) при старте, глушить при выходе. Модель ~225 МБ INT8 автозагружается на первом запуске.
2. **Переписать тело `transcribeAudio()`:** вместо WhisperKit — HTTP POST WAV на `http://127.0.0.1:9876/v1/transcribe?segments=true&punctuation=true&itn=true`. Ответ — JSON с сегментами `{start, end, text}`.
3. **Ввести свой тип сегмента** (напр. `ASRSegment { start: Float; end: Float; text: String }`) взамен `TranscriptionSegment` из WhisperKit. Поправить сигнатуры `diarizeAndMatch()` и `mergeTranscriptionWithDiarization()` — там нужны только эти три поля, правка механическая.
4. **Выкинуть** из `Package.swift` зависимость WhisperKit; удалить `prepare()`-загрузку Whisper, `availableModels`, языковую логику (`resolveLanguageCode`, `nameToCode`) — фиксируем `ru`. Промпт доменных терминов Whisper заменить на gigastt-биасинг, если нужен (опция).
5. **Диаризацию оставить как есть.** FluidAudio уже отдельный слой.

Оценка: замена ASR — компактная правка одного файла + sidecar-менеджмент. Основной незнакомый кусок — спаун/жизненный цикл бинарника gigastt из Swift и бандлинг.

## Что дописать (v1)

- **LLM-рекап по промпту.** Новый слой поверх готового транскрипта: берём `.md`, шлём в локальный LLM (Ollama) или API по настраиваемому промпту, кладём `recap.md` рядом. В базе рекапов нет — это чистое добавление.
- **Автодетект Zoom.** Наблюдать за процессом `zoom.us` / активной аудио-сессией → авто-старт/стоп записи. Ручной старт уже есть, это надстройка.

## Открытые развилки (решить в новом диалоге)

1. **Диаризация: FluidAudio vs gigastt.** gigastt тоже умеет диаризацию (WeSpeaker ResNet34 + polyvoice, `?diarization=true`, лейблы на words/segments). Соблазн убрать FluidAudio и брать всё одним вызовом. НО вокруг FluidAudio-embeddings построена вся People-library (матчинг людей между встречами). Для v1 — оставить FluidAudio (меньше переделок), консолидацию на gigastt рассмотреть позже. _Решение: по умолчанию FluidAudio._
2. **Интеграция gigastt: HTTP sidecar vs нативные биндинги.** Swift-биндинги gigastt «in progress». Для v1 — HTTP (проще, надёжнее). Нативный `gigastt-core` (Rust crate) — позже, если мешает лишний процесс.
3. **Head модели:** `e2e_rnnt` (пунктуация/casing/ITN нативно) vs `rnnt` (ниже WER, пунктуация add-on). Для читаемых рекапов — `e2e_rnnt`. Проверить на своих встречах.
4. **LLM для рекапа:** локальный Ollama (приватность, в духе проекта) vs Claude/OpenAI API (качество). Развилка под конкретный промпт.

## Риски

1. **Диаризация на русском в реальном Zoom** — главный непроверенный риск (farfield, перебивания). Тест на одной реальной записи до всей обвязки.
2. **Sidecar-менеджмент** — спаун/подпись/песочница бинарника gigastt внутри `.app` (entitlements, notarization при раздаче). Решаемо, но это возня.
3. **gigastt — молодой проект** — проверить стабильность CoreML EP на своей macOS, живость. Fallback: CLI-режим (`gigastt transcribe`) вместо сервера.
4. **Цифры WER Сбера** — подтверждены пользователем на практике (GigaAM реально лучше на русском), плюс независимый харнесс gigastt даёт farfield 4.08% / phone 18.50% против whisper.cpp large-v3 17.91% / 32.73%. Риск снят.

## Связь с Vault

meeting-recorder уже пишет Obsidian-markdown с `[[wikilinks]]`. Целевой приток: транскрибатор кладёт `.md` в папку-приёмник (как `raw/talat/`), scheduled task оформляет в `wiki/meetings/`. Свой транскрибатор → второй источник наравне с Talat, без ручного ввода (в духе «Принципа выживания»). Вне скоупа v1.

## Стартовый промпт для нового диалога

> Форкаем `tonton-golio/meeting-recorder` (Swift, macOS) под русский транскрибатор встреч на GigaAM-v3. Полный бриф и план миграции — в приложенном `giga-transcriber-brief.md`. Движок GigaAM берём через локальный сервер `ekhodzitsky/gigastt` по HTTP (`gigastt serve`, loopback:9876), заменяя WhisperKit только в `TranscriptionService.transcribeAudio()`; диаризацию FluidAudio и Obsidian-markdown оставляем как есть. Задачи v1: (1) заменить ASR-слой на gigastt-HTTP, (2) забандлить и заменеджить gigastt-sidecar в .app, (3) добавить LLM-рекап по настраиваемому промпту, (4) автодетект Zoom. Начни с шага 1: покажи точный дифф по `TranscriptionService.swift` и `Package.swift` для замены WhisperKit на gigastt-HTTP, введя тип `ASRSegment`. Код не коммить, пока не согласуем.
