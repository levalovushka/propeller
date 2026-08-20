# Fixture: `ru-echo-loud-2spk`

The fixture `ru-short-2spk/README.md` says is owed: the mic stem carries the far
side **above** the owner, which is what real meetings on speakers do (+4…+6 dB,
`docs/ECHO_AND_MIX_EXPERIMENTS.md`, 2026-08-11) and what neither shipped fixture
does (both put it 12 dB below).

Synthetic Russian, `say` voices Milena (owner) and Yuri (far side), 16 kHz mono.
Regenerate with `../../../../tools/generate-fixture-ru-echo-loud.sh`; `ECHO_DB`
sets the level relationship (default 5), `DEST` writes elsewhere for a sweep.

| File | Role |
|------|------|
| `sequential-room.mic.wav` | Mic stem, owner and far side in their own slots |
| `sequential-room.sys.wav` | System stem — the tap: far side only, clean |
| `overlap-room.mic.wav` | Mic stem, owner speaking **inside** the far side's turns |
| `overlap-room.sys.wav` | Same, system stem |
| `owner-only.wav` | The ceiling: the owner's audio with no far side at all |
| `manifest.json` | Levels, per-variant owner/echo ratio, turn plan, both references |

Two layouts because they fail differently, and two echo paths because the
difference decides whether any cancellation number means anything:

* **dup** — the mic's copy of the far side is a scaled duplicate. Honest about
  levels only: a canceller removes it perfectly, so ERLE on it is a lie. **Not
  committed** (3.5 MB of wav for a number the level sweep covers); the generator
  writes it and the driver picks it up if present.
* **room** — the copy is delayed, filtered by a fixed synthetic impulse
  response (direct path, four reflections, short tail) and soft-clipped by a
  speaker. This is the one to cancel against.

The owner's and the far side's content words are disjoint on purpose: "did the
owner survive" is then a question about tokens, not about judgement. Two tokens
of recall is the floor — shared function words that both references contain.

## What it caught

Measured 2026-08-20, `tools/echo-probe/owner-loss.py`, numbers and method in
[`benchmarks/report-owner-loss.md`](../../benchmarks/report-owner-loss.md):
speech in the clear survives at any level (31/31 up to echo +20 dB), speech on
top of the far side does not survive at all (2/31 from +5 dB, 14/31 even at
equal loudness). The loss is in ASR, before any echo rule runs. Cancelling the
system stem out of the mic gives all 31 words back and leaves the clear case
untouched.

## What it still lies about

The room is fixed and linear-plus-`tanh`; a real speaker is neither, so ERLE
here is optimistic. The overlap is total — the owner's whole turn sits inside
the far side's — while a real interjection is partly in the clear. Input AGC and
clock drift are not modelled (drift cannot happen in the product: one IOProc).
And it is four turns of one synthetic voice per side: good enough to show a rule
is broken, not to claim a rate.
