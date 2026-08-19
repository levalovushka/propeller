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

Swift Package Manager (`Package.swift`). GigaAM ASR weights (~247 MB, INT8 set) ship **inside the .app** and are copied to Application Support on first use — no download, transcription works offline.

The bundled Ollama engine is **slimmed** (`tools/slim-ollama.sh`, 139 → 34 MB): the MLX
runtime and the Intel CPU backends are dropped, since the engine logs `using llama-server
for model` for `qwen3.5:4b` and the app is arm64-only. Installation is unchanged — same
tarball in the bundle, same unpack, no network — and `build.sh` refuses to ship an archive
missing `ollama` or `llama-server`. **Raising `OllamaSidecar.releaseTag` means re-slimming
and re-checking that log line**; MLX already handles Q4_K_M in preview, so this trade
expires the day it claims our model. Only the summary model (`qwen3.5:4b`, ~3.4 GB) is fetched over the network — automatically, on first
launch and whenever it goes missing (`AppState.ensureSummaryModel`, decision in
`PropellerPure/ModelProvisioning`). «Саммари нет» is a legal depth for one meeting; «нет LLM» is not a
legal state for the app, so there is no consent gate and no «Скачать» button to press.

## Architecture (short)

### Dependencies (SPM)

- **FluidAudio** — on-device speaker diarization + WeSpeaker embeddings
- ASR is **not** an SPM package: bundled `gigastt` binary (HTTP sidecar)

**Never call `OfflineDiarizerManager.prepareModels()`.** It is `load` + `initialize`
+ a prewarm, and the prewarm kills the process on macOS 14: it feeds CoreML a
degenerate input (`samplesPerWindow` zeros and a 1×1×1 segmentation tensor), which
on 14.8.4 goes down the BNNS CPU path and writes past a page. Twenty-five identical
crash reports from one tester, one per launch that had a meeting waiting; nobody on
macOS 26 can reproduce it. Use `TranscriptionService.loadDiarizerModels`, which does
the two public halves itself. A signal is not catchable, so there is no defensive
way to keep calling it — and raising the FluidAudio pin means re-checking that
`prepareModels` is still the only thing that prewarms.

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
- Идущая запись — не режим окна, а одна из встреч: `MainView` показывает `RecordingPaneView`
  только когда выбрана записываемая встреча (`AppState.activeRecordingID`). Шапка —
  `RecordingPaneHeader` (заголовок слева, таймер + пауза/стоп справа), слева живой транскрипт
  (`LiveTranscriptColumn`), и в той же ленте — заметки на своих секундах
  (`PropellerPure/NotePlacement`). Пишутся они в поле внизу колонки (`NoteBar`),
  и оно есть только пока идёт запись: у готовой встречи заметка — раздел саммари.
- `NotchController` — чёлка на время записи: чёрная плита у выреза, слева лопасть
  (`PropellerUI/NotchSurface.swift`), которую крутит уровень записываемого звука, справа заметка.
  ⌃⌥N и клик по правому уху опускают её в поле ввода на три строки с воздухом (вниз, не вширь —
  `NotchGeometry.composeDrop`, число выведено, не выбрано); Enter сохраняет с
  таймкодом, Esc выходит без сохранения. Геометрия и привод лопасти — чистые (`PropellerPure/NotchGeometry`,
  `PropellerPure/BladeDrive`), потому что проверить их можно только на четырёх геометриях сразу.
  **Лопасть питается огибающей, а не уровнем** (`BladeDrive.envelope`): из захвата приходит пик за
  буфер, раз в несколько десятков миллисекунд, и подать его в привод напрямую — значит получить
  храповик на слогах, потому что `timeConstant` тянет вверх втрое быстрее, чем отпускает. Частоту
  отсчётов пишет `AudioRecorder.noteLevelTick` — замер, а не оценка по коду.
  Паузы и стопа там нет намеренно; нижний оверлей заметки (`NoteOverlayController`) удалён.
  **Нет выреза — нет фичи целиком, вместе с ⌃⌥N** (`NotchGeometry.screen(...)` → `nil`): заметки
  тогда пишутся в поле внизу окна. Вырез может появиться и исчезнуть посреди записи (крышка, монитор,
  разрешение) — за этим следит `NotchController`, и наблюдатель живёт всю запись, а не пока стоит
  панель
- `MenuBarPanelView` — record/stop, recent, quit
- Настройки — не окно, а состояние панели (`AppState.paneRoute`): столбец групп шириной с колонку саммари. Вёрстка — `PropellerUI/SettingsKit.swift`, содержимое — `Sources/SettingsPane.swift`. Сцены `Settings` и `SettingsLink` в проекте больше нет; ⌘, и меню-бар идут через `SettingsOpener`

### Assistant connections (MCP)

A second executable ships in the bundle: `PropellerMCP` (target `MCPServer/`), a
stdio MCP server that **only reads** `~/.meeting-recorder`. It does not need the app
running, and it is the one process besides the app that Developer ID signs.

- **What differs between clients is data, not code** — `PropellerPure/MCPClient.swift`
  holds each client's config path, config format, marker filename and row title.
  Adding a client is a case there, not a branch in the connector.
- **The button writes into somebody else's config**, so both merges are pure and
  tested: `ClaudeConfigMerge` (JSON, parse-and-rebuild) and `CodexConfigMerge`
  (TOML, **append the section, never parse the file** — people hand-edit
  `~/.codex/config.toml` and their comments live in it).
- **The row's state is derived, never stored** (`MCPCellMachine`): the config is
  someone else's file and can be rewritten without telling us. A stored "connected"
  would go false silently, which is the one thing a checkmark must not do.
- **Each client gets its own marker file.** The server learns who launched it from
  a token we wrote into the `env` of our own config entry, falling back to
  `clientInfo`. Matching client names on the substring "claude" alone made Claude
  Code stamp Claude Desktop's marker — check `claude-code` first.
- **The tool list is a function of the client**: ChatGPT additionally gets `search`
  and `fetch` (OpenAI's contract, both a text and a `structuredContent` copy),
  because its deep research path calls only those two names. Claude keeps five —
  near-duplicates would dilute the descriptions the feature rests on.

Plan and decisions: [`../plan-claude-mcp.md`](../plan-claude-mcp.md); component
status: [`../STATE.md`](../STATE.md) §13.

### Data storage

```
~/.meeting-recorder/{recordings,meetings}   # people/ is legacy: no longer read/written
~/Library/Application Support/Meeting Recorder/{gigastt-models/,hotwords.txt,ollama/}
# plus, from the MCP server: <client>-mcp-seen markers and the usage log. Those are
# the only files that process writes — it never touches ~/.meeting-recorder.
# ollama/ — the summary engine unpacked from the bundle (~97 MB) plus models/ (~3.4 GB,
# fetched over the network). By far the largest thing the app puts on a person's disk.
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
  **That 0.91–0.97 describes the tap, not a meeting.** On real audio, coherence between the
  mic and the system stem in the speech band is ~0.5, because the probe plays a test signal
  at a convenient level while a room adds a non-linear speaker and a reverb tail. Quoting the
  probe's figure as "we can cancel echo" is the mistake that measurement exists to prevent.

## Live echo — invariants

On speakers the microphone hears the far side and 95–97 % of her words are recognisable
from the mic stem alone, so the live column will show every remark twice unless something
stops it. Two things do, and **neither of them compares the two tracks' loudness**.

- **Never decide who spoke by which track is louder.** Measured 2026-08-11 across the
  archive: the owner's own voice in his own microphone is **4–6 dB below** the far side's
  echo. Output level belongs to the call app, input level to the mic gain; the two are not
  one scale. A rule built on that premise (`StemDominance`) shipped, looked right in the
  harness for four days, and was inert on every real meeting. Numbers:
  `benchmarks/report-gate.md`, `docs/ECHO_AND_MIX_EXPERIMENTS.md` (2026-08-11 section).
- **The audio may only be asked gain-free questions.** Two are legal: "did the system stem
  carry anything at all" (digital silence, `FeedGate.silenceFloor`) and "is the microphone
  predictable from the reference" (`EchoCoherence`). Anything of the form `mic > system` is
  the refuted rule coming back.
- **What reaches the screen is decided on the text** (`EchoDedup`): a mic line the far side
  has already said cannot be the owner's, at any level. Matching is fuzzy per token, and
  **only for tokens of four characters or more** — at two, one edit turns "ни" into "они",
  which cost a whole owner turn in the harness (coverage 0.964 → 0.916).
- **A duplicate is dropped at once; "this looks new" may wait.** Similarity only grows as
  more of the far side arrives, and `LiveTranscript` promises that shown text is never
  rewritten. Waiting is capped at `EchoDedup.holdSeconds` and only applies to lines that
  overlap audible far-side speech — own speech into silence is never delayed.
- **Suppression is not the answer, and this is measured.** A coherent post-filter gives
  8.8–10.3 dB and the engine does not care: 95.4 % of the far side's words still come
  through against 97.5 % raw. An ASR needs 20–30 dB; linearly that is not available here.
  Before proposing AEC, read the numbers — the cheap version is already refuted.
- **The gate is about electricity, the dedup is about truth.** If a change makes the gate
  stricter, it can only cost CPU; if it makes the dedup stricter, it can cost a word. Watch
  `live.coverage`, never `live.wer` alone: a rule that hides a badly recognised real turn
  *improves* WER.

## Meeting detection

Which apps count as a call, and which window titles mean "in one", is **data** in
[`PropellerPure/MeetingPlatform.swift`](swift/PropellerPure/MeetingPlatform.swift), covered by
`MeetingPlatformTests`. Adding a service is a row in `MeetingPlatform.all`, not new code in the detector.

- Auto-record starts a recording *without asking*, so a wrong title in `meetingTitleMarkers` records
  something nobody wanted. Idle titles always win over markers — that regression already shipped once
  (RU panels «Настройки»/«Чат» triggered auto-record).
- Store every identifier lowercased; matching lowercases the input, not the table.
- **A signal must mean "a call is on", not "this app is busy".** The display-sleep assertion is the
  weakest one and only counts for a platform whose row says `sleepAssertionMeansCall` — Контур.Толк
  holds it while *someone shares a screen*, so trusting it started a recording at the start of a share
  and stopped it when the share ended (1.15). Talk therefore has no call signal at all and is started
  by hand; before adding one, check it is absent while the app merely sits open.
- **Read the assertion's name, not just its type** (`sleepAssertionNameMarkers`). Apps name what they
  hold: VK writes «VK video call in progress» and holds nothing else, so the row narrows the signal to
  that name and «VK keeps the display awake» stops meaning anything on its own. Empty list = the
  shipped Zoom behaviour, any assertion counts. Measure the name on a live call before writing one in.
- **What counts is who holds the assertion, not how many conferencing apps are open.** The detector
  used to skip the whole branch unless exactly one was running (`live.count == 1`); one idle Zoom left
  open all day was enough to make a live VK call invisible for its whole length (measured 2026-08-11,
  76 s, assertion held throughout). The rule is now `MeetingPlatform.callFromAssertion`, in
  `PropellerPure` with tests: one holder is the call, two are nobody's — there is one recording and
  nothing to choose with.
- **Polling stops only when no conferencing app is left at all.** The timer is raised by a *launch*
  notification and used to be dropped by any *termination* — so quitting VK Звонки killed detection
  for a Zoom that had been running since the day before, and auto-record was silent until the app
  restarted (measured 2026-08-12: `sample` caught 11993 of 11993 main-thread samples idle, and a live
  Zoom call went unrecorded). Who is left is `MeetingPlatform.live(in:excludingPID:)`, with tests —
  and the pid that just quit must be excluded, because `runningApplications` keeps reporting it for a
  moment. One platform in the table hid this: "a conferencing app quit" and "none are left" were the
  same event.
- **A platform whose bundle id ends in something meaningless needs `ownsProcess` checked.** VK's is
  `com.vk.calls.native.1`, and the "last component is the process name" rule handed the platform every
  process with a `1` in its name until it started requiring three characters and a non-digit.

- **Заголовки окон как сигнал мертвы, и в браузере детекта сейчас нет вовсе.** Без «Записи экрана»
  `CGWindowListCopyWindowInfo` отдаёт пустые имена у всех окон (замерено 2026-08-07), значит
  `browserTitleMeansCall` не срабатывает никогда. Кандидат на замену — аудио-дуплекс процесса
  (`kAudioProcessPropertyIsRunningInput` + `IsRunningOutput`), который читается без единого
  TCC-разрешения. Идёт теневой замер: `tools/shadow-mic-probe/` (`./run.sh report`), критерий
  приёмки — не больше 2 ложных баннеров за неделю, подробности и снятые факты в
  [`../STATE.md`](../STATE.md) §8.

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

### When a tester says it crashes

**Crash reports are named `MeetingRecorder-*.ips`, not `Propeller-*`.** The bundle is
Propeller, the executable inside it is still `MeetingRecorder`, and macOS names the
report after the executable — so does Activity Monitor and so does the force-quit
dialogue. Asking a tester for `Propeller*.ips` returns nothing and reads as "there
are no crash reports", which is the opposite of the truth. This cost a round trip
once; the whole ask is one line, and `zsh` aborts the command if a glob matches
nothing, so it must not be a bare glob:

```bash
mkdir -p ~/Desktop/propeller-logs && find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports \( -iname "*meetingrecorder*" -o -iname "*propeller*" -o -iname "*llama*" -o -iname "*ollama*" \) -exec cp {} ~/Desktop/propeller-logs/ \; 2>/dev/null; cp "$HOME/Library/Application Support/Meeting Recorder/"*.log ~/Desktop/propeller-logs/ 2>/dev/null; open ~/Desktop/propeller-logs
```

Read the first two lines of an `.ips` before theorising: `os_version` and the
exception. `EXC_BAD_ACCESS` at an address ending in `ffc` is four bytes past a page
boundary — a buffer overrun in whatever library owns the faulting thread, not
memory pressure. `EXC_RESOURCE` would be the system killing us. And read
`os_version` every time: the one crash this project has had was a macOS 14-only
path that nobody on 26 could reproduce, and every hypothesis formed before that
line was read turned out to be wrong.

## Performance — measure first, and measure what it costs the person

Three harnesses, all writing `swift/benchmarks/`, all diffed by `tools/bench-diff`
against a per-fixture baseline:

```bash
tools/measure-batch.sh                        # offline pass: asr.rtf, asr.cpu_cores, diarize, RSS
tools/measure-live.sh                         # the live layer, in real time
FIXTURE=ru-pauses-2spk K=3 tools/measure-live.sh
cd swift && swift run -c release Bench -- --search   # ui.search_ms on a synthetic archive
```

A fourth number has no harness and does not need one: **what a person waits for**.
Stream the app's own log during a real meeting and read the phase transitions —
17 minutes of audio measured 42 s of transcript plus 39 s of summary, with
fractions of a second in the seams. Signposts do not reach the persistent store
and `debugLog` writes at `.debug`, so it has to be captured live, and `log` may be
shadowed by a shell builtin:

```bash
/usr/bin/log stream --level debug --style compact --predicate 'subsystem == "app.propeller"'
```

- **The live harness defaults to the shipped configuration** (echo feed gate on).
  `--no-gate`, `--gate=silence`, `--gate=both`, `--pool-size N` exist to re-answer
  hypotheses, not for daily use. A harness whose default is not the product
  measures a product that does not exist.
- **A green harness is not a working feature.** Both fixtures carry the far side in
  the mic stem 12 dB *below* the owner; real meetings on speakers have it 4–6 dB
  *above*. The echo rule was green here for four days while being inert on every
  actual meeting. When a rule depends on a level relationship, ask what the fixture
  assumes about it before trusting the diff — and a fixture with the echo above the
  reference is owed (`Tests/Fixtures/ru-short-2spk/README.md`).
- **Cost metrics never travel alone.** Every `live.*` cost sits beside `live.wer`,
  `live.coverage` and `live.attribution_accuracy`, because the cheap way to save
  CPU is to stop recognising speech. `coverage` is the one that catches it — a gate
  that goes quiet mid-phrase *improves* WER while deleting the meeting. Metrics
  carry a `direction`; `bench-diff` used to read every drop as an improvement.
- **Cores, not just RTF.** `asr.cpu_cores` says whether the machine is usable while
  the pass runs (measured: 3.2 of 10), which is what a person actually feels;
  RTF only ever said how long it takes.
- **Where the money is:** the live layer costs 0.35 cores for the *whole meeting*
  (of which the coherence estimator is 0.0013), and the feed gate is worth
  **−15 % of that on continuous speech, −18 % on a fixture with pauses**, measured
  against a `--no-gate` run of the same commit in the same hour — never against a
  number from another day. The offline pass is 3.2 cores for
  ~110 s of an hour-long one, the summary under one core but 4.6 GB. Numbers and
  every rejected idea (with its cost) live in `benchmarks/report-gate.md` and
  `benchmarks/report-pipeline-cpu.md`. Read them before proposing a knob — five
  plausible ones are already refuted there, echo suppression among them.
- **A promoted baseline needs its argument in `benchmarks/`, not in a commit body
  alone.** `live.wer` is currently 0.048 above the old tolerance on `ru-pauses-2spk`
  by decision: the increase is seven insertions from one badly recognised owner turn
  that the previous rule hid entirely, and `coverage` improved in the same run.
  **Three of those seven are the turn, four are the gate** — a `--no-gate` run of the
  same commit scores 0.181 with three insertions and identical coverage, so feeding
  the mic session speech torn by skipped portions costs the other four. The lesson is
  the method: attributing a delta to a rule means measuring the rule alone. If a
  guardrail goes red, the choice is to fix it or to write down why the red is the
  better product — never to widen the tolerance quietly. And a guardrail whose
  tolerance is inside its own scatter is not a guardrail: `live.app_cpu_cores` reads
  ±45 % between identical runs against a `+20 %` gate, so its red says nothing.

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
