# Propeller

Local-first macOS meeting recorder: Russian on-device transcription (GigaAM / gigastt), speaker diarization (FluidAudio), and markdown + optional LLM summary.

Fork of [tonton-golio/meeting-recorder](https://github.com/tonton-golio/meeting-recorder). Product context lives in the parent Propeller repo: [`STATE.md`](../STATE.md) is the source of truth, [`docs/SPEC.md`](docs/SPEC.md) the behaviour, and `archive/plan-v2.md` the decision history.

![macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## Features

- **Mic + system audio** — both sides of a call on one clock: a Core Audio process tap and the mic in one aggregate device, sample-for-sample aligned. No Screen Recording permission involved
- **Russian ASR** — GigaAM-v3 (`e2e_rnnt`) via bundled `gigastt` sidecar
- **Speaker diarization** — FluidAudio → consistent `Speaker N`; mic-dominant speaker labeled with the owner's name (no voice library)
- **Auto-record** — starts when a call is detected (`MeetingPlatform`); notification lets you decline; stops when the call ends
- **Live transcript** — two WS sessions to gigastt off the shared-clock capture, owner and far side kept apart, drawn while the meeting runs
- **LLM summary** — Ollama (bundled runtime) / OpenAI / Claude; edited in place, with «Короче» / «Подробнее» over a selection; auto title / topics / tags
- **Calendar** — read-only via EventKit (no OAuth); names recordings
- **Markdown export** — Simple (default) or Obsidian; copy-for-chat
- **Quick notes** — ⌃⌥N overlay during recording (timestamped)
- **Crash recovery** — ASR checkpoint (`transcribed_raw`) before diarization

## Requirements

- macOS 14.4+, Apple Silicon
- Xcode 15.3+ / Swift 5.10+ to build
- Permissions: Microphone (required), Notifications (so auto-record can be declined). Calendar and Accessibility are optional; Screen Recording is not used

## Build & Install

```bash
cd meeting-recorder/swift
./build.sh
open -a Propeller
```

Installs `/Applications/Propeller.app`, bundles `tools/gigastt/gigastt` and compiles `propellericon.icon`.

## How it works

1. **Record** — mic (+ optional system audio) → 16 kHz mono WAV, stems retained while audio is kept
2. **Transcribe** — gigastt ASR → timestamped segments (checkpointed)
3. **Diarize** — FluidAudio → `Speaker N`; owner labeled from the mic stem
4. **Save** — markdown always; LLM summary + title/topics/tags if a provider is configured

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/SPEC.md](docs/SPEC.md).

## Data storage

```
~/.meeting-recorder/
  recordings/   # index + wav + stems
  meetings/     # transcripts + summaries
  people/       # legacy: no longer read/written
```

## Acknowledgments

- [gigastt](https://github.com/ekhodzitsky/gigastt) — GigaAM serving
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — diarization / embeddings
- Upstream [meeting-recorder](https://github.com/tonton-golio/meeting-recorder)

## License

[MIT](LICENSE)
