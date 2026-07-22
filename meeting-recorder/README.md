# Propeller

Local-first macOS meeting recorder: Russian on-device transcription (GigaAM / gigastt), speaker diarization (FluidAudio), and markdown + optional LLM recap.

Fork of [tonton-golio/meeting-recorder](https://github.com/tonton-golio/meeting-recorder). Product context lives in the parent Propeller repo (`plan-v1.md`, `product-ideas.md`).

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## Features

- **Mic + system audio** — both sides of video calls via ScreenCaptureKit
- **Russian ASR** — GigaAM-v3 (`e2e_rnnt`) via bundled `gigastt` sidecar
- **Speaker diarization** — FluidAudio + learnable People voice library
- **Zoom auto-record** — starts when a call is detected; notification lets you decline; stops when the call ends
- **Markdown export** — Simple (default) or Obsidian; copy-for-chat
- **LLM recap** — Ollama / OpenAI / Claude (optional)
- **Menu bar** — Ctrl+Opt+R global hotkey; always-on processing after stop
- **Crash recovery** — ASR checkpoint (`transcribed_raw`) before diarization

## Requirements

- macOS 14+ (Sonoma), Apple Silicon
- Xcode 15.3+ / Swift 5.10+ to build
- Permissions: Microphone (required), Screen Recording (for system audio)

## Build & Install

```bash
cd meeting-recorder/swift
./build.sh
open -a Propeller
```

Installs `/Applications/Propeller.app`, bundles `tools/gigastt/gigastt` and compiles `propellericon.icon`.

## How it works

1. **Record** — mic (+ optional system audio) → 16 kHz mono WAV, stems retained while audio is kept
2. **Transcribe** — gigastt ASR → timestamped segments
3. **Diarize / match** — FluidAudio + People library
4. **Save** — markdown always; recap if a provider is configured

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/SPEC.md](docs/SPEC.md).

## Data storage

```
~/.meeting-recorder/
  recordings/   # index + wav + stems
  people/       # voice library
  meetings/     # transcripts + recaps
```

## Acknowledgments

- [gigastt](https://github.com/ekhodzitsky/gigastt) — GigaAM serving
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — diarization / embeddings
- Upstream [meeting-recorder](https://github.com/tonton-golio/meeting-recorder)

## License

[MIT](LICENSE)
