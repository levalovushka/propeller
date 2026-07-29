# System Audio Capture Experiments

> **Это история охоты за пропавшим собеседником (апрель — июль 2026).** Живой
> канон захвата — [AUDIO-CAPTURE-CASES.md](AUDIO-CAPTURE-CASES.md): обещания,
> полный список сценариев и что делаем в каждом. Замер задвоения — в
> [ECHO_AND_MIX_EXPERIMENTS.md](ECHO_AND_MIX_EXPERIMENTS.md). Ниже — эксперименты
> и выводы, которые к этому канону привели; часть из них уже неверна, и это
> помечено.

## Что изменилось после написания этого файла (обновлено 2026-07-29)

- **ScreenCaptureKit — единственный путь.** `ProcessTapAudioCapture` удалён:
  ноль ссылок, признан нерабочим (пустые стемы), а сценарий, ради которого его
  держали, закрыт основным путём.
- **Область захвата решается по идущему звонку**, а не по запущенному приложению
  и не по громкости (`CaptureScopePolicy`). Отката «тихо четыре секунды →
  пишем весь экран» больше нет: на живом звонке видно, что app-scoped фильтр
  отдаёт звук приложения вместе с его хелперами (`CptHost` у Zoom).
- **Тишина в стеме — нормальное состояние**, а не симптом. Ниже по тексту она
  местами трактуется как отказ — это устарело: собеседники просто могли молчать,
  и порогов громкости в решениях у нас больше нет.
- **Стемы больше не складываются с нуля**: системный кладётся на свой сдвиг
  (`StemTimeline`), иначе дальняя сторона попадала в запись дважды.
- **Появился пробник** `--capture-probe` (см. ниже) — он заменяет ручные
  «Эксперименты 2 и 3» там, где вопрос про область захвата.

## Проба захвата (2026-07-29)

Сравнивает на живом звонке три области — только приложения с окнами, они же плюс
процессы без окон, и весь экран, — сама ждёт появления звука и пишет отчёт:

```bash
osascript -e 'quit app "Propeller"'
open -a Propeller --args --capture-probe
cat ~/Library/Application\ Support/Meeting\ Recorder/capture-probe.txt
```

Живёт в релизном бинарнике сознательно: разрешение «Запись экрана» выдано
бандлу, отдельная утилита просила бы его у Терминала и мерила бы другую систему.

## Канон на 2026-07-24 (историческое)

**ScreenCaptureKit is the live path.** Mic-only is judged at **stop** via the real `.sys.wav` stem (`AudioRecorder.lastStopWasMicOnly`). Mid-recording UI banners fire only if system capture **fails to start**, not on speculative silence watchdogs. Live health = System level meter.

See also [STATE.md](../../STATE.md) Part 0.

## Working Hypotheses

When the other person is missing from a recording, the failure is usually one of:

- ScreenCaptureKit permission is denied or stale after rebuilding/signing the app.
- Audio buffers arrive, but the buffer format is not decoded correctly.
- The capture filter is tied to the wrong display in a multi-display setup.
- The system stem is present but too quiet relative to the microphone in the final mix.
- The meeting app routes call audio through a device or mode ScreenCaptureKit does not expose.

## Implemented Changes

- The capture filter now prefers the display containing the mouse, then the main display, instead of blindly using the first display returned by ScreenCaptureKit.
- System audio decoding now handles non-interleaved and interleaved float/16-bit PCM buffers explicitly.
- Each recording logs a system-audio capture report with callback count, decoded PCM buffers, conversion failures, frames written, audible buffers, peak level, and file size.
- Mixing now checks whether the system stem is actually audible and applies a bounded automatic gain to system audio before combining it with the mic.
- The app keeps the `.mic.wav` and `.sys.wav` stems while audio is retained, so failures can be audited after the fact.

## Experiment 1: Offline Capture Audit

Audit recent recordings:

```bash
cd swift
swift run Experiments capture-audit
```

Audit one recording:

```bash
cd swift
swift run Experiments capture-audit ~/.meeting-recorder/recordings/RECORDING_ID.wav
```

The report is also saved under:

```text
~/.meeting-recorder/test/results/capture-audit-*.txt
```

Interpretation:

- `missing system stem`: ScreenCaptureKit failed before writing audio.
- `system stem is silent`: **чаще всего собеседники просто молчали.** В 2026-04 это
  читалось как отказ, потому что тогда пустыми оказались все 25 записей подряд;
  сегодня тишина сама по себе ни о чём не говорит.
- `system stem is audible but much quieter than mic`: mixing gain is the likely fix.
- `system stem looks audible`: capture worked; issues are probably downstream transcription/diarization.

Initial local audit on April 15, 2026:

- 25 recent recordings audited.
- 15 had no system stem.
- 10 had a tiny/silent system stem.
- 0 had an audible system stem.

That baseline points to capture-layer failure rather than Whisper/diarization failure for the missing remote speaker cases.

## Experiment 2: Live Meeting Probe

Before a real meeting, play any short sound from the same app/device where the call audio will come from, then start a 10-second recording.

Expected result:

- The in-progress view should show a moving system waveform.
- The capture audit should show an audible `.sys.wav` stem.

If the waveform is flat:

- Confirm Screen Recording permission for `Meeting Recorder`.
- Toggle Screen Recording off/on after rebuilding the app.
- Move the mouse to the display where the meeting app is visible before starting recording.
- Check the meeting app's output device. If it is a special virtual or headset call device, test the system output speaker/headphones route.

## Experiment 3: Known-Sound Test

Play a locally generated tone or a short video while recording. Then run:

```bash
cd swift
swift run Experiments capture-audit ~/.meeting-recorder/recordings/RECORDING_ID.wav
```

This separates ScreenCaptureKit capture problems from meeting-app-specific routing problems. If the tone records but the call does not, the meeting app or audio route is the likely culprit.

## Bigger Options

1. Add an in-app "System audio test" button that records 5 seconds and immediately reports whether system audio is audible.
2. ~~Offer a meeting-app/window picker~~ — не понадобилось: фильтр строится
   автоматически по платформе, чей звонок идёт (`CaptureScopePolicy`).
3. Add a virtual audio-device fallback for users who need maximum reliability across call apps. This is more invasive and less native, but it can be more predictable than display-based ScreenCaptureKit capture.
