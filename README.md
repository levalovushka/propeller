# Propeller — local-first Russian meeting transcription for macOS

Native macOS app (SwiftUI): record Zoom/mic+system audio, transcribe with **GigaAM / gigastt**, diarize with **FluidAudio**, save markdown, optional LLM summary (Ollama / OpenAI / Claude).

Fork of [tonton-golio/meeting-recorder](https://github.com/tonton-golio/meeting-recorder), productized as **Propeller**.

## Quick start

```bash
# Needs: Apple Silicon, macOS 14+, Xcode 15.3+, and a gigastt binary
# Place gigastt at tools/gigastt/gigastt (not committed — download separately)

cd meeting-recorder/swift
./build.sh
open -a Propeller
```

## Repo layout

| Path | What |
|---|---|
| `meeting-recorder/` | App source (Swift package + `build.sh`) |
| `plan-v1.md` | Phase plan |
| `product-ideas.md` | Product backlog |
| `giga-transcriber-brief.md` | Migration brief |
| `design/` | UI spec |
| `phase0`–`phase6/` | Phase status notes (artifacts/models not in git) |
| `propellericon.icon` | App icon (Icon Composer) |

Architecture: [`meeting-recorder/docs/ARCHITECTURE.md`](meeting-recorder/docs/ARCHITECTURE.md).

## Not in this repo

- `gigastt` binary and GigaAM model weights (`tools/`)
- SPM / Xcode build products
- Raw Zoom WAVs and personal transcript dumps from validation

## License

App code under `meeting-recorder/` is MIT (upstream). Documentation and Propeller-specific materials in this monorepo follow the same unless noted.
