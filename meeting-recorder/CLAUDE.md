# CLAUDE.md

Guidance for agents working in this repository (Propeller fork of meeting-recorder).

## Project Overview

**Propeller** is a native macOS menu bar + window app (SwiftUI, macOS 14+, arm64) that records meetings (mic + system audio), transcribes Russian speech locally via **GigaAM-v3 / gigastt**, diarizes with **FluidAudio** into consistent `Speaker N` (no voice library — the mic-dominant speaker is labeled with the owner's name), saves markdown (Simple default / Obsidian optional), and optionally generates an LLM summary (Ollama / OpenAI / Claude) with auto title/topics/tags.

Canonical architecture decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Product behaviour: [docs/SPEC.md](docs/SPEC.md). **Living status / defects:** [`../../STATE.md`](../STATE.md). Active plan + decisions: [`../../plan-v2.md`](../archive/plan-v2.md). Engineering optimization: [`../../plan-optimization.md`](../archive/plan-optimization.md). UI: [`../../design/propeller-ui.md`](../design/propeller-ui.md). Historical (phases, brief): [`../../archive/`](../archive/).

## Build & Run

```bash
cd swift
./build.sh          # SPM release → /Applications/Propeller.app (bundles gigastt + propellericon)
open -a Propeller
```

Swift Package Manager (`Package.swift`). GigaAM ASR weights (~247 MB, INT8 set) ship **inside the .app** and are copied to Application Support on first use — no download, transcription works offline. Only the summary model (`qwen3.5:4b`, ~3.4 GB) is fetched over the network.

## Architecture (short)

### Dependencies (SPM)

- **FluidAudio** — on-device speaker diarization + WeSpeaker embeddings
- ASR is **not** an SPM package: bundled `gigastt` binary (HTTP sidecar)

### Data flow

```
AudioRecorder (mic + SCK system stems → 16 kHz mix)   # Process Tap dormant
  → TranscriptionService
      → gigastt (chunked if large) → ASRSegment[]
      → checkpoint (transcribed_raw)
      → FluidAudio diarization → Speaker N + owner-by-mic
  → MarkdownWriter → RecapService (конспект) → metadata (title/topics/tags)
```

### Key components

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full table. Coordinator is `AppState`; Zoom auto-record defaults to **Auto** with a system notification action **«Не записывать»** (`NotificationManager`) that discards the in-progress recording. Transcripts are **always** saved right after diarization (no speaker-confirmation gate, no auto-save toggle). Long meetings: client-side `GigasttChunking` + sidecar body-limit 64 MiB.

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

## Pipeline state — invariants

The pipeline was rebuilt around one state model; the reasoning and every defect it
closed are in [docs/REFACTOR-PIPELINE-STATE.md](docs/REFACTOR-PIPELINE-STATE.md). Read that before
changing how meetings move through the pipeline. The rules below hold today and are enforced by
tests in `PropellerPure` — breaking one should turn a test red, not surprise a user.

**Two dimensions, never mixed.** `RecordingEntry.status` (`RecordingStage`) is what a meeting has
*achieved* and is persisted. `AppState.activity` (`PipelineActivity`) is what is *running*, is
ephemeral, and there is exactly one of it because there is one worker.

- **`RecordingStage.rawValue`s are the strings already on users' disks** — never change one, an older
  build has to keep reading the index. New stages append; unknown values decode to `.recorded` rather
  than throwing (I6).
- **Compare stages with `>=`, not `==`.** `status == .saved` silently goes false at `.summarized`.
- **A phase never moves a stage backwards** — use `advanced(to:)` (I3). Only an explicit user action
  walks a stage back, and it says so at the call site. Getting this wrong once turned "rename a
  meeting" into "re-summarise it".
- **A crash after ASR lands on `.transcribedRaw`, never `.recorded`** (I4) — the difference is an
  hour of GPU work.
- **`.summarized` ⟺ recap file **and** metadata exist** (I9), reconciled both ways in
  `RecordingStore.reconcileSummarizedStage()`. A 1.11 meeting with a summary but no topics is *not*
  done: marking it done strands it, because the worker skips terminal stages.
- **A failure belongs to its recording** (`entry.lastFailure`), never to the app. While set, the
  recording is out of the queue until an explicit retry clears it (I7). Cancellation is *not* a
  failure — parking a superseded job would need a manual retry to undo.
- **Phases never call each other.** Each ends with `kickPipeline()`; `nextJob` derives what is next
  from stages on disk. A phase that returns `.advanced` **must** have moved the stage or parked the
  recording, or the loop asks for the same job forever (caught as `.stalled`, I11).
- **Newest unfinished meeting wins.** The one that just ended is the one someone is waiting to read;
  the backlog is catch-up. Prioritising transcripts over summaries looks equivalent and is not — it
  drops the fresh meeting to the back of the queue right after `.saved`.
- Do not add `@Published` flags to `AppState` for pipeline state. Seven of them were removed; the
  point was to stop having a second source of truth.
- **Changing what a function *means* means reading every caller first** (`grep` the name). Cheap
  check, expensive miss.

## Meeting detection

Which apps count as a call, and which window titles mean "in one", is **data** in
[`PropellerPure/MeetingPlatform.swift`](swift/PropellerPure/MeetingPlatform.swift), covered by
`MeetingPlatformTests`. Adding a service is a row in `MeetingPlatform.all`, not new code in the detector.

- Auto-record starts a recording *without asking*, so a wrong title in `meetingTitleMarkers` records
  something nobody wanted. Idle titles always win over markers — that regression already shipped once
  (RU panels «Настройки»/«Чат» triggered auto-record).
- Store every identifier lowercased; matching lowercases the input, not the table.
- **Контур.Толк identifiers are unverified** — no install was available when they were written. Confirm
  them during a real call with `./tools/detect-meeting-signals.sh толк talk kontur`, then update the row
  and its tests.

## How to work in this repo

The order that pays off here, learned the expensive way:

1. **Types first.** Seven state fields with ~2000 combinations became one enum with two branches, and
   a whole class of "status stuck / spinner on the wrong meeting" bugs stopped being *expressible*.
   No test was needed for that; the bugs simply had nowhere left to live.
2. **Then invariants** — for rules a type can't hold. Written as a test *and* as `checkInvariant`,
   which trips the debugger locally and reports through telemetry from release builds. An invariant
   only checked on the author's machine says nothing about the people actually using the app.
3. **Then tests**, named after what a user saw ("the whole remark highlights at once"), not after the
   function under test.
4. **Documents last**, and only ones that can't drift: the state diagram in
   REFACTOR-PIPELINE-STATE.md §4 is rendered from the types and compared byte-for-byte by
   `PipelineDiagramTests`. A document that *can* go stale *will*.

Everything decidable without AppKit, the disk or the network belongs in `PropellerPure`, where a
test can reach it. `Sources/` is an executable target: nothing there is importable by tests, so logic
left in a view is logic nobody can check. That is where every hand-found bug in this project has been.

Boundaries (`Transcriber`, `RecapBackend`) exist so recorded fixtures can stand in for a live ASR
sidecar and a live model — see `Tests/Fixtures/boundaries/`. Add a fixture when a real service
surprises you; each file there cost a real incident.

## Development practices

- Prefer surgical diffs; don’t expand scope beyond the task.
- Keep `docs/` accurate — update ARCHITECTURE / SPEC when decisions change.
- Push back on approaches that fight the local-first / Russian-only constraints.
- Do not change bundle id or Application Support folder names without an explicit migration plan (TCC / models).
