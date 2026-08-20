#!/usr/bin/env bash
# Regenerate Tests/Fixtures/ru-echo-loud-2spk — the fixture ru-short-2spk's
# README says is owed.
#
# # Why it is owed
#
# Both shipped fixtures put the far side in the mic stem 12 dB *below* the
# owner. Real meetings on speakers have it 4–6 dB *above*
# (docs/ECHO_AND_MIX_EXPERIMENTS.md, 2026-08-11 section). So every rule that
# decides which mic words are the owner's is measured only in the easy
# direction — and the field report we could not reproduce is the hard one:
# "not a single word of mine is in the transcript". The archive says it is not
# one person's machine: 2 of 70 meetings carry zero owner words, six more under
# 6 % (audit 2026-08-20).
#
# # What it contains
#
# Two layouts, because they fail differently, and two echo paths per layout,
# because the difference decides whether a canceller means anything.
#
#   sequential — far side and owner speak in their own slots.
#   overlap    — the owner speaks *inside* the far side's turns: an
#                interjection, which is what actually happens on a call.
#
#   dup  — the mic's copy of the far side is a scaled duplicate. Cheap, and
#          honest only about levels: a canceller removes it perfectly, which
#          makes cancellation numbers on it worthless.
#   room — the copy is delayed, filtered by a small synthetic impulse response
#          and soft-clipped by a speaker. This is the one to cancel against.
#
# `owner-only.wav` is the ceiling: the owner with no far side at all.
#
# ECHO_DB sets how far the far side sits above the owner in the mic stem
# (default 5, the measured real value). The level sweep in
# benchmarks/report-owner-loss.md is this script run at 0, 5, 10, 15, 20.
#
# Needs numpy for the room convolution: on a stock macOS box
#   /Applications/Xcode.app/Contents/Developer/usr/bin/python3
# has it. Override with PYTHON=…
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# DEST is overridable so a level sweep can write somewhere else than the
# shipped fixture: the sweep is a question, not a new baseline.
DEST="${DEST:-$ROOT/swift/Tests/Fixtures/ru-echo-loud-2spk}"
ECHO_DB="${ECHO_DB:-5}"
PYTHON="${PYTHON:-/Applications/Xcode.app/Contents/Developer/usr/bin/python3}"
if ! "$PYTHON" -c "import numpy" 2>/dev/null; then
  echo "no numpy in $PYTHON — set PYTHON to an interpreter that has it" >&2
  exit 1
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# Owner and far side get disjoint content words on purpose: "did the owner
# survive" is then a question about tokens, not about judgement.
say -v Milena -r 190 -o a1.aiff "Я предлагаю начать с бюджета, потому что смета уже посчитана."
say -v Milena -r 190 -o a2.aiff "У меня есть вопрос про сроки поставки макетов."
say -v Milena -r 190 -o a3.aiff "Давайте зафиксируем ответственного за релиз."
say -v Milena -r 190 -o a4.aiff "Мне нужно понять, кто согласует смету во вторник."
say -v Yuri -r 150 -o b1.aiff "Хорошо, я расскажу про интеграцию плагина и его ограничения по шрифтам."
say -v Yuri -r 150 -o b2.aiff "Мы можем показать демо на следующей неделе, если успеем собрать сборку."
say -v Yuri -r 150 -o b3.aiff "Дизайнер выходит двадцать четвёртого, поэтому график сдвигается."
say -v Yuri -r 150 -o b4.aiff "Пришлю ссылку на доску и черновик оценки в чат после встречи."

for f in a1 a2 a3 a4 b1 b2 b3 b4; do
  afconvert -f WAVE -d LEI16@16000 -c 1 "$f.aiff" "$f.wav"
done

ECHO_DB="$ECHO_DB" "$PYTHON" - <<'PY'
import json, os, wave
import numpy as np

RATE = 16000
ECHO_DB = float(os.environ["ECHO_DB"])
OWNER = [
    "Я предлагаю начать с бюджета, потому что смета уже посчитана.",
    "У меня есть вопрос про сроки поставки макетов.",
    "Давайте зафиксируем ответственного за релиз.",
    "Мне нужно понять, кто согласует смету во вторник.",
]
FAR = [
    "Хорошо, я расскажу про интеграцию плагина и его ограничения по шрифтам.",
    "Мы можем показать демо на следующей неделе, если успеем собрать сборку.",
    "Дизайнер выходит двадцать четвёртого, поэтому график сдвигается.",
    "Пришлю ссылку на доску и черновик оценки в чат после встречи.",
]


def read(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == RATE
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def write(path, x):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


def rms(x):
    voiced = x[np.abs(x) > 1e-4]
    return float(np.sqrt(np.mean((voiced if voiced.size else x) ** 2) + 1e-12))


def room(x):
    """Direct path, four reflections, a short decay tail, then the speaker.

    Fixed seed: a fixture that changes under you is not a fixture.
    """
    rng = np.random.default_rng(7)
    h = np.zeros(int(0.045 * RATE), np.float32)
    h[int(0.004 * RATE)] = 1.0
    for t, g in ((0.011, 0.5), (0.017, -0.34), (0.026, 0.22), (0.038, -0.12)):
        h[int(t * RATE)] = g
    h += rng.standard_normal(len(h)).astype(np.float32) * 0.05 \
        * np.exp(-np.arange(len(h)) / (0.012 * RATE))
    return np.tanh(np.convolve(x, h)[: len(x)] * 1.6) / 1.6


owner = [read(f"a{i}.wav") for i in (1, 2, 3, 4)]
far = [read(f"b{i}.wav") for i in (1, 2, 3, 4)]
air = RATE // 2

def layout(kind):
    """Returns (owner track, far track, turn plan) on one timeline."""
    plan, at = [], air
    own_t, far_t = np.zeros(0, np.float32), np.zeros(0, np.float32)

    def place(track, samples, start):
        if start + len(samples) > len(track):
            track = np.concatenate([track, np.zeros(start + len(samples) - len(track), np.float32)])
        track[start : start + len(samples)] += samples
        return track

    for i in range(4):
        if kind == "sequential":
            own_t = place(own_t, owner[i], at)
            plan.append(("owner", i, at / RATE))
            at += len(owner[i]) + air
            far_t = place(far_t, far[i], at)
            plan.append(("far", i, at / RATE))
            at += len(far[i]) + air
        else:
            far_t = place(far_t, far[i], at)
            plan.append(("far", i, at / RATE))
            own_t = place(own_t, owner[i], at + RATE)
            plan.append(("owner", i, (at + RATE) / RATE))
            at += max(len(far[i]), RATE + len(owner[i])) + air
    n = max(len(own_t), len(far_t))
    own_t = np.concatenate([own_t, np.zeros(n - len(own_t), np.float32)])
    far_t = np.concatenate([far_t, np.zeros(n - len(far_t), np.float32)])
    return own_t, far_t, plan


manifest = {
    "echo_over_owner_db": ECHO_DB,
    "owner_reference": OWNER,
    "far_reference": FAR,
    "variants": {},
}
for kind in ("sequential", "overlap"):
    own_t, far_t, plan = layout(kind)
    for path in ("dup", "room"):
        echo = far_t * 1.0 if path == "dup" else room(far_t)
        # The owner sits ECHO_DB below the far side's copy *in the mic*.
        own = own_t * (rms(echo) / (10 ** (ECHO_DB / 20)) / rms(own_t))
        mic = own + echo
        peak = float(np.max(np.abs(mic)))
        if peak > 0.95:                    # keep the ratio, never clip
            mic, own = mic * (0.95 / peak), own * (0.95 / peak)
        name = f"{kind}-{path}"
        write(f"{name}.mic.wav", mic)
        write(f"{name}.sys.wav", far_t)
        manifest["variants"][name] = {
            "duration_s": round(len(mic) / RATE, 2),
            "owner_over_echo_db": round(20 * np.log10(rms(own) / rms(echo)), 1),
            "turns": [{"who": w, "index": i, "start": round(s, 2)} for w, i, s in plan],
        }
    if kind == "overlap":
        # The ceiling: the same owner audio with no far side at all. Any
        # measurement of "how much of the owner survived" is against this.
        own = own_t * (rms(room(far_t)) / (10 ** (ECHO_DB / 20)) / rms(own_t))
        write("owner-only.wav", own)

with open("manifest.json", "w") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
for name, meta in manifest["variants"].items():
    print(f"{name}: {meta['duration_s']} s, owner {meta['owner_over_echo_db']:+} dB vs echo")
PY

mkdir -p "$DEST"
rm -f "$DEST"/*.wav "$DEST"/manifest.json
cp -f *.mic.wav *.sys.wav owner-only.wav manifest.json "$DEST/"
echo "Wrote $DEST (ECHO_DB=$ECHO_DB)"
