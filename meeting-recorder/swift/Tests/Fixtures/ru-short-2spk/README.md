# Fixture: `ru-short-2spk`

Short synthetic Russian dialogue (~27 s, 16 kHz mono WAV) for batch metrics / golden E2E.

| File | Role |
|------|------|
| `final.wav` | Mixed meeting audio |
| `final.mic.wav` | Mic stem: A at full level, B at −12 dB |
| `final.sys.wav` | System stem: B only |
| `reference-transcript.txt` | Ground-truth text (WER/CER, Q1) |
| `reference-speakers.json` | Speaker turns / stem hints (DER, Q1) |

## Why the stems are asymmetric

Because the real ones are. The system stem is a process tap on the app's
output — taken *before* the speaker, so the owner's voice cannot appear in it at
all. The mic hears both: the owner directly, and the far side back out of the
room, quieter (`docs/ECHO_AND_MIX_EXPERIMENTS.md` §1 measures +27 dB over the
noise floor, and 95.2 % of the far side's words recognisable from the mic alone).
That asymmetry is the only thing that lets the two tracks be told apart
(`StemDominance`), so a fixture that blurs it makes the rule untestable.

It did blur it until 2026-08-10: the sys stem also carried A at 0.25. The live
harness read the result immediately — the far-side session transcribed the
owner's speech too, so the live text came out doubled (38 insertions on 58
reference words, WER 0.83, attribution 0.44) and the sidecar held 859 MB instead
of the 546 MB a real stream costs. Numbers on the corrected stems: WER 0.28,
attribution 1.00.

The room is still not simulated — the mic's copy of the far side is a scaled
duplicate, not a filtered and delayed one. Good enough for cost and for the
dominance rule; not a fixture for echo cancellation.

Regenerate (needs macOS `say` + `afconvert`):

```bash
../../../../tools/generate-fixture-ru-short.sh
```
