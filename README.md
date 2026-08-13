# Propeller — local-first Russian meeting transcription for macOS

Native macOS app (SwiftUI): record both sides of a call on one clock (Core Audio process tap + mic in a single aggregate device), transcribe with **GigaAM / gigastt** — live during the meeting and again offline for the record — diarize with **FluidAudio**, save markdown, summarise with an LLM (bundled Ollama / OpenAI / Claude) and edit that summary in place.

Fork of [tonton-golio/meeting-recorder](https://github.com/tonton-golio/meeting-recorder), productized as **Propeller**.

## Quick start

```bash
# Needs: Apple Silicon, macOS 14.4+, Xcode 15.3+, and a gigastt binary
# Place gigastt at tools/gigastt/gigastt (not committed — download separately)

cd meeting-recorder/swift
./build.sh
open -a Propeller
```

## Repo layout

| Path | What |
|---|---|
| `STATE.md` | **Living status: what works, what's broken, per component.** Start here. |
| `meeting-recorder/` | App source (Swift package + `build.sh`) |
| `COLLEAGUES.md` | Install + usage guide handed to testers |
| `vocab/` | Russian meeting jargon → gigastt hotwords (source for the built-in list) |
| `design/` | UI spec, the principles list, state gallery, «no dead ends» |
| `tools/` | `gigastt` + models (not in git), Ollama runtime, echo and live-transcript probes |
| `product-ideas.md` | Idea / decision ledger (killed / deferred with reasons) |
| `archive/` | Decision history — plans, reviews, migration brief, phase status notes, retired docs. Superseded by `STATE.md` wherever they disagree. |
| `DOCS.md` | Documentation layers and rules: what goes where |
| `propellericon.icon` | App icon (Icon Composer) |

**Source of truth: [`STATE.md`](STATE.md)** — component-by-component status and open defects. When any other document disagrees with it, `STATE.md` wins.

Supporting docs of record: [architecture](meeting-recorder/docs/ARCHITECTURE.md) · [product spec](meeting-recorder/docs/SPEC.md) · [agent guide](meeting-recorder/CLAUDE.md).

## Not in this repo

- `gigastt` binary and GigaAM model weights (`tools/`) — `build.sh` bundles the INT8 set into the .app, so fetch them once with
  `tools/gigastt/gigastt download --prequantized --model-variant e2e_rnnt --model-dir tools/gigastt/models-e2e`
- SPM / Xcode build products
- Raw Zoom WAVs and personal transcript dumps from validation

## License

App code under `meeting-recorder/` is MIT (upstream). Documentation and Propeller-specific materials in this monorepo follow the same unless noted.
