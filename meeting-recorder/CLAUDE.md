# CLAUDE.md

Guidance for agents working in this repository (Propeller fork of meeting-recorder).

## Project Overview

**Propeller** is a native macOS menu bar + window app (SwiftUI, macOS 14+, arm64) that records meetings (mic + system audio), transcribes Russian speech locally via **GigaAM-v3 / gigastt**, diarizes with **FluidAudio** into consistent `Speaker N` (no voice library — the mic-dominant speaker is labeled with the owner's name), saves markdown (Simple default / Obsidian optional), and optionally generates an LLM summary (Ollama / OpenAI / Claude) with auto title/topics/tags.

Canonical architecture decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Product behaviour: [docs/SPEC.md](docs/SPEC.md). Active plan + decisions: [`../../plan-v2.md`](../../plan-v2.md). Engineering optimization: [`../../plan-optimization.md`](../../plan-optimization.md). UI: [`../../design/propeller-ui.md`](../../design/propeller-ui.md). Historical (phases, brief): [`../../archive/`](../../archive/).

## Build & Run

```bash
cd swift
./build.sh          # SPM release → /Applications/Propeller.app (bundles gigastt + propellericon)
open -a Propeller
```

Swift Package Manager (`Package.swift`). First ASR use may download ~225 MB GigaAM model into Application Support.

## Architecture (short)

### Dependencies (SPM)

- **FluidAudio** — on-device speaker diarization + WeSpeaker embeddings
- ASR is **not** an SPM package: bundled `gigastt` binary (HTTP sidecar)

### Data flow

```
AudioRecorder (16 kHz mono mix + mic/sys stems)
  → TranscriptionService
      → gigastt (ASRSegment[])
      → checkpoint (transcribed_raw)
      → FluidAudio diarization → Speaker N + owner-by-mic
  → MarkdownWriter → RecapService → metadata (title/topics/tags)
```

### Key components

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full table. Coordinator is `AppState`; Zoom auto-record defaults to **Auto** with a system notification action **«Не записывать»** (`NotificationManager`) that discards the in-progress recording. Transcripts are **always** saved right after diarization (no speaker-confirmation gate, no auto-save toggle).

### UI

- `MainView` — sidebar sections (Meetings / Summaries / Search / Settings) + list + detail. Upcoming (calendar) via `CalendarService`.
- `RecordingDetailView` / `RecordingInProgressView` — tabs Transcript / Notes / Summary
- `NoteOverlayController` — ⌃⌥N quick-note overlay during recording
- `MenuBarPanelView` — record/stop, recent, quit
- Native `Settings` scene (`SettingsSheet.swift`): General / Audio / Transcription / Recap / Export

### Data storage

```
~/.meeting-recorder/{recordings,meetings}   # people/ is legacy: no longer read/written
~/Library/Application Support/Meeting Recorder/{gigastt-models/,hotwords.txt}
```

## Development practices

- Prefer surgical diffs; don’t expand scope beyond the task.
- Keep `docs/` accurate — update ARCHITECTURE / SPEC when decisions change.
- Push back on approaches that fight the local-first / Russian-only constraints.
- Do not change bundle id or Application Support folder names without an explicit migration plan (TCC / models).
