# Phase 1 — baseline

Дата: 2026-07-22

- Клон: `meeting-recorder/` (upstream `tonton-golio/meeting-recorder@ddd55cb`)
- Сборка: `swift/build.sh` → success (~87 s)
- Установлено: `/Applications/Meeting Recorder.app` (adhoc sign, arm64)
- Запуск: процесс жив, создан `~/.meeting-recorder/{people,recordings}`

WhisperKit end-to-end запись намеренно не гоняли: модель тяжёлая, ASR всё равно уходит в фазе 2. Capture/UI/FluidAudio в базе считаем валидными через успешную сборку + старт.
