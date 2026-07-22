# Phase 0 — статус валидации

Дата: 2026-07-22  
Статус: **закрыта (2026-07-22)** — ASR «терпимо», head=`e2e_rnnt`, diarizer=FluidAudio. В промпт рекапа заложить подчистку ASR-артефактов.

## Источник

Talat: `~/Library/Application Support/Talat-Tauri/audio/4eaad855-4d77-4e6b-bdb6-bdb04cb115f3/audio.mp3`  
→ 16 kHz mono, **675.9 s (~11.3 мин)**, копия: [`talat_meeting_16k.wav`](talat_meeting_16k.wav)

## ASR: e2e_rnnt vs rnnt

| | e2e_rnnt | rnnt (+punct/itn) |
|---|---|---|
| wall time | ~81 s (RTF 0.119 с диаризацией gigastt) | ~82 s |
| confidence | 0.84 | 0.95 |
| text_len | 6734 | 6636 |
| читаемость | **лучше** | слабее («привет перед» vs «привет, передай») |

Сравнение первых 90 с: [`talat_head_compare.md`](talat_head_compare.md)

### Решение по head

**`e2e_rnnt`** для v1 (читаемые рекапы важнее numeric confidence).

Нужно твоё ухо: [`talat_merged_e2e_fluidaudio.md`](talat_merged_e2e_fluidaudio.md) — приемлемо ли?

## Диаризация

| Движок | Спикеры | Время | Вердикт |
|---|---|---|---|
| gigastt WeSpeaker+polyvoice | **14** (шумные обрывки; доминируют 0 и 1) | внутри ASR ~80s | перекластеризация — **не брать как sole diarizer в v1** |
| **FluidAudio** | **2** (S1 ~229s / S2 ~199s речи) | **2.8 s** | **оставляем для v1** |

Артефакт FluidAudio: [`talat_fluidaudio.json`](talat_fluidaudio.json)  
Сшитый транскрипт: [`talat_merged_e2e_fluidaudio.md`](talat_merged_e2e_fluidaudio.md)

Харнесс: [`FluidDiarize/`](FluidDiarize/)

## Инфра-заметки

- Homebrew gigastt сломан (CLT vs macOS 26) → prebuilt `tools/gigastt/gigastt`
- Для e2e REST: **не** слать `punctuation=true`
- CoreML кэш: `~/Library/Caches/gigastt`
- FluidAudio при первом запуске качает CoreML-модели (warning `Missing coremldata.bin` → retry ok)

## Следующий шаг после твоего ок по ASR

Фаза 1: baseline-сборка форка `meeting-recorder` as-is.
