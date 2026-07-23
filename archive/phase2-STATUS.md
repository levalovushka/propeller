# Phase 2 — ASR: WhisperKit → gigastt HTTP

Дата: 2026-07-22  
Статус: **сделано** (sidecar lifecycle — Фаза 3)

## Что изменилось

- Новый [`GigasttClient.swift`](../meeting-recorder/swift/Sources/GigasttClient.swift): `ASRSegment`, health + `POST /v1/transcribe?segments=true`
- [`TranscriptionService.swift`](../meeting-recorder/swift/Sources/TranscriptionService.swift): WhisperKit выкинут; ASR через gigastt; FluidAudio без изменений
- [`Package.swift`](../meeting-recorder/swift/Package.swift): зависимость WhisperKit удалена
- AppState / Settings / Models / Experiments — под `ASRSegment`, язык фиксирован `ru`
- Head: **e2e_rnnt** (без `punctuation=true` в query)

## Verify

- `./build.sh` → success, app reinstalled
- HTTP smoke (тот же контракт, что у клиента): segments ок
- До Фазы 3 приложение ждёт внешний `gigastt serve` на `127.0.0.1:9876`

## Как руками проверить end-to-end сейчас

```bash
export PATH="$PWD/tools/gigastt:$PATH"
gigastt serve --model-dir tools/gigastt/models-e2e --model-variant e2e_rnnt --port 9876
open -a "Meeting Recorder"
# записать / открыть WAV → Transcribe
```
