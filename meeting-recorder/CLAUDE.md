# CLAUDE.md

Guidance for agents working in this repository (Propeller fork of meeting-recorder).

## Project Overview

**Propeller** is a native macOS menu bar + window app (SwiftUI, macOS 14+, arm64) that records meetings (mic + system audio), transcribes Russian speech locally via **GigaAM-v3 / gigastt**, diarizes with **FluidAudio**, matches speakers against a local People library, saves markdown (Simple default / Obsidian optional), and optionally generates an LLM recap (Ollama / OpenAI / Claude).

Canonical architecture decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Product backlog: [`../../product-ideas.md`](../../product-ideas.md). Phase plan: [`../../plan-v1.md`](../../plan-v1.md). UI: [`../../design/propeller-ui.md`](../../design/propeller-ui.md).

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
      → FluidAudio diarization
      → PeopleStore matching
  → MarkdownWriter → RecapService
```

### Key components

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full table. Coordinator is `AppState`; Zoom auto-record defaults to **Auto** with a system notification action **«Не записывать»** (`NotificationManager`) that discards the in-progress recording. Transcripts are **always** saved once speakers are resolved (no auto-save toggle).

### UI

- `MainView` — sidebar sections (Meetings / People / Search / Settings) + list + detail
- `RecordingDetailView` / `RecordingInProgressView` / `SpeakerConfirmationView`
- `MenuBarPanelView` — record/stop, recent, quit
- Native `Settings` scene (`SettingsSheet.swift`)

### Data storage

```
~/.meeting-recorder/{recordings,people,meetings}
~/Library/Application Support/Meeting Recorder/gigastt-models/
```

## Development practices

- Prefer surgical diffs; don’t expand scope beyond the task.
- Keep `docs/` accurate — update ARCHITECTURE / SPEC when decisions change.
- Push back on approaches that fight the local-first / Russian-only constraints.
- Do not change bundle id or Application Support folder names without an explicit migration plan (TCC / models).
