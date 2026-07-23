# Phase 3 — gigastt sidecar

Дата: 2026-07-22  
Статус: **сделано**

## Что сделано

- [`GigasttSidecar.swift`](../meeting-recorder/swift/Sources/GigasttSidecar.swift): spawn/kill/restart, health (ждёт `variant=e2e_rnnt`, не `model=loading`), download `--prequantized` при отсутствии модели
- Бинарник бандлится в `Meeting Recorder.app/Contents/MacOS/gigastt` через [`build.sh`](../meeting-recorder/swift/build.sh)
- Старт при launch (`AppDelegate` + `AppState.bootstrap`), стоп при quit
- Dev-fallback: бинарник/модели из `Propeller/tools/gigastt/`
- Prod model dir: `~/Library/Application Support/Meeting Recorder/gigastt-models`

## Verify

- Cold start: app → sidecar ready ~7s (модели уже в tools) → smoke transcribe 16 segs OK
- Quit app → процесс gigastt завершается

## Заметки на Фазу 7

Hardened runtime / notarization для nested Rust-бинарника — отдельная возня (entitlements).
