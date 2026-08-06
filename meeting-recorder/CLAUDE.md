# CLAUDE.md

Guidance for agents working in this repository (Propeller fork of meeting-recorder).

## Project Overview

**Propeller** is a native macOS menu bar + window app (SwiftUI, macOS 14.4+, arm64) that records meetings (mic + system audio), transcribes Russian speech locally via **GigaAM-v3 / gigastt**, diarizes with **FluidAudio** into consistent `Speaker N` (no voice library — the mic-dominant speaker is labeled with the owner's name), saves markdown (Simple default / Obsidian optional), and optionally generates an LLM summary (Ollama / OpenAI / Claude) with auto title/topics/tags.

Canonical architecture decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Product behaviour: [docs/SPEC.md](docs/SPEC.md). **Living status / defects:** [`../../STATE.md`](../STATE.md). Active plan + decisions: [`../../plan-v2.md`](../archive/plan-v2.md). Engineering optimization: [`../../plan-optimization.md`](../archive/plan-optimization.md). UI: [`../../design/propeller-ui.md`](../design/propeller-ui.md). Historical (phases, brief): [`../../archive/`](../archive/).

## Build & Run

```bash
cd swift
./build.sh          # SPM release → /Applications/Propeller.app (bundles gigastt + propellericon)
open -a Propeller
```

Swift Package Manager (`Package.swift`). GigaAM ASR weights (~247 MB, INT8 set) ship **inside the .app** and are copied to Application Support on first use — no download, transcription works offline. Only the summary model (`qwen3.5:4b`, ~3.4 GB) is fetched over the network — automatically, on first
launch and whenever it goes missing (`AppState.ensureSummaryModel`, decision in
`PropellerPure/ModelProvisioning`). «Саммари нет» is a legal depth for one meeting; «нет LLM» is not a
legal state for the app, so there is no consent gate and no «Скачать» button to press.

## Architecture (short)

### Dependencies (SPM)

- **FluidAudio** — on-device speaker diarization + WeSpeaker embeddings
- ASR is **not** an SPM package: bundled `gigastt` binary (HTTP sidecar)

### Data flow

```
AudioRecorder → ProcessTapCapture (тап + агрегат: обе дорожки одной IOProc,
                кадр в кадр) → 16 kHz стемы + микс с нулевого кадра
                ↳ запасной путь: AVAudioRecorder + SCK, стем на своём сдвиге
  → TranscriptionService
      → gigastt (chunked if large) → ASRSegment[]
      → checkpoint (transcribed_raw)
      → FluidAudio diarization → Speaker N + owner-by-mic
  → MarkdownWriter → RecapService (конспект) → metadata (title/topics/tags)
```

### Key components

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full table. Coordinator is `AppState`; Zoom auto-record defaults to **Auto** with a system notification action **«Не записывать»** (`NotificationManager`) that discards the in-progress recording. Transcripts are **always** saved right after diarization (no speaker-confirmation gate, no auto-save toggle). Long meetings: client-side `GigasttChunking` + sidecar body-limit 64 MiB.

### UI

- `MainView` — левый рельс (`PropellerSidebar`) + контентная панель. Upcoming (calendar) via `CalendarService`.
- `PropellerUI/Sidebar.swift` — рельс редизайна (Figma 31:4581): 300 pt, заголовок окна 48 pt со светофором, меню, список встреч по дням. Чистая презентация: принимает `SidebarModel`, отдаёт id. Какой вид получает встреча — `PropellerPure/SidebarRowState.swift` (`SidebarRowMachine`), и это единственное место, где решение принимается; `Sources/SidebarPresenter.swift` только читает поля.
- Все токены цвета — пары «тёмная / светлая» (`Tokens.dual`), тема разрешается AppKit'ом в момент отрисовки. Светлые значения выведены, а не нарисованы: правятся в одном месте, в `Tokens.Paint` / `Tokens.Sidebar`.
- `RecordingDetailView` — карточка встречи (легаси-путь, вкладки Transcript / Notes / Summary)
- Идущая запись — не режим окна, а одна из встреч: `MainView` показывает `RecordingPaneView`
  только когда выбрана записываемая встреча (`AppState.activeRecordingID`). Шапка —
  `RecordingPaneHeader` (заголовок слева, таймер + пауза/стоп справа), слева живой транскрипт
  (`LiveTranscriptColumn`), справа те же заметки, что у готовой встречи.
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
- **A failure belongs to its recording** (`entry.lastFailure`), never to the app — and to the
  *machine*, not to the user. It carries its own recovery plan: `kind`
  (`transient` / `ourFault` / `terminal`), `attempt`, `nextAttemptAt`. Retries are **silent and
  endless**: the ladder walks out to an hour and stays there, because a count of attempts belongs to a
  request somebody is waiting on with a dialogue open, and this is a background obligation. The one
  kind that stops is `.terminal` — the input is gone (audio deleted) or was never there (no speech) —
  and it is **declared by the call site that looked at the input**, never inferred from an error
  string (`PipelineRetry.classify` can no longer return it). Cancellation is not a failure at all.
- **Nothing in the interface reads a failure.** Views ask `AppState.rest(of:)` →
  `MeetingRest` (`waiting` / `done`, and there is deliberately no third branch for "needs a human").
  There is no «Повторить» button, no ⚠ mark and no "Не удалось обработать" anywhere — a meeting is at
  the depth it reached, and says why it stopped if it stopped. Invariant **I13** is a property test
  over random failures. Read `design/no-dead-ends.md` before adding anything that could park a
  meeting.
- **Owed work always has a way back.** `pipelineOutlook` answers what to run *and* when to look
  again; `PipelineDrain.plan` turns every stop into a deadline. Anything that adds a way for the
  pipeline to stop must go through them — "stop and hope something kicks us" is how meetings sat at
  `.saved` for a week (I12). Wake sources are the events that change the answer: heat, sleep, app
  activation, a provider appearing, a finished call.
- **Nothing owed ⇒ no timers, no sidecars, no probes.** The app spends most of its life with a fully
  processed archive; that state must cost one pass over an array.
- **Phases never call each other.** Each ends with `kickPipeline()`; the scheduler derives what is
  next from stages on disk. A phase that returns `.advanced` **must** have moved the stage or parked
  the recording, or the loop asks for the same job forever (caught as `.stalled`, I11).
- **Newest unfinished meeting wins**, except one the user asked for by hand. The meeting that just
  ended is the one someone is waiting to read; the backlog is catch-up. Prioritising transcripts over
  summaries looks equivalent and is not — it drops the fresh meeting to the back of the queue right
  after `.saved`.
- **Catch-up is silent.** Notifications and window activation are for meetings recorded this session
  (`isAwaited`); a launch that owes twenty summaries must not post twenty notifications, steal focus
  twenty times, or open a modal. A modal is worse than noise — awaiting one suspends the worker.
- Do not add `@Published` flags to `AppState` for pipeline state. Seven of them were removed; the
  point was to stop having a second source of truth.
- **Changing what a function *means* means reading every caller first** (`grep` the name). Cheap
  check, expensive miss.

## Audio capture — invariants

Capture runs on **one clock**: a Core Audio process tap and the microphone inside one
private aggregate device, read by a single IOProc (`ProcessTapCapture`). Sample N of the
mic stem and sample N of the system stem are the same instant — that is the whole point,
and it is what makes a live transcript and echo cancellation possible at all.

- **Never guess the channel layout.** Aggregate input channels run subdevices-in-composition-order,
  then taps; the counts come from the system, and the assembled aggregate is rejected if
  its actual channel count disagrees (`CaptureChannelLayout`). A wrong guess is silent:
  the file is the right size and the far side is in the owner's track.
- **The aggregate must contain a real output device.** Mic + tap alone assembles, reports
  the right channel count, starts — and delivers a dead microphone channel (measured).
- **Silence is never a symptom.** Health is "did IOProc callbacks arrive", never "was it loud".
- **Frames are placed by `mSampleTime`, not appended** (`CaptureCursor`). Appending is what
  made the two tracks jitter by milliseconds and coherence collapse to 0.04.
- **Capture never blocks on permission.** The first Core Audio input open waits on a TCC
  decision — measured at 60 s — so it is paid by a warm-up at launch and remembered
  (`Preferences.sharedClockCaptureWorks`). Starting a meeting must cost milliseconds.
- **The ladder always ends somewhere that works** (`CapturePathPolicy`): tap → mic-only. There is
  no second capture path — the ScreenCaptureKit one was deleted with the 14.4 floor, because two
  capture branches mean two truths about how the stems relate, and everything downstream has to
  handle both.
- **Capture never asks for Screen Recording.** That permission is gone from the bundle. Window
  titles still feed meeting detection when the grant happens to exist, but nothing requests it and
  nothing blocks on it.
- Re-measure with `open -a Propeller --args --tap-probe` (report lands in Application Support)
  and `tools/echo-probe/` for coherence. Acceptance: **> 0.7** in the speech band; measured
  0.91–0.97 across runs. Check `maxSys` in the probe report first — a run where the speaker
  was driven into clipping (`maxSys=1.0`) reads 0.67, and that is the acoustic path, not us.

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

## Principles

All of them in one place: [`../design/principles.md`](../design/principles.md) —
product framing, notifications, «no dead ends», the engineering order below, the
studio's form canon (`pgcorpus`) and the grep-checkable typography rules. Read the
relevant section before a decision; run §6 before a commit.

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

## Build & Verify

- ALWAYS build with the project's `./build.sh` (or documented build script), never raw `swift build` / `xcodebuild` directly — raw builds put artifacts in `.build/` and the user sees no updated app.
- After any code change, run the project's test suite and typecheck/lint before reporting done.
- Never claim a fix works without empirical verification (run it, screenshot it, or measure it).

## Scope Discipline

- Implement ONLY what was asked. Do not add extra packages, prototype apps, docs sites, or abstractions that were not requested.
- If you believe extra work is needed, propose it in one sentence and wait for approval before writing code.
- Prefer the smallest diff that satisfies the request.

## Regression Guard (Swift/React refactors)

- Before refactoring shared state (pipeline state machines, markDirty/dirty flags, editor snapshots), list every consumer of that state and confirm each is still correct after the change.
- After each refactor step, re-run the full test suite AND manually exercise the affected UI path (playback, karaoke click, transcript edit) before moving to the next step.
- Never leave a refactor half-applied across a commit boundary.

## Development practices

- Prefer surgical diffs; don’t expand scope beyond the task.
- Keep `docs/` accurate — update ARCHITECTURE / SPEC when decisions change.
- Push back on approaches that fight the local-first / Russian-only constraints.
- Do not change bundle id or Application Support folder names without an explicit migration plan (TCC / models).
