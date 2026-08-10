#!/usr/bin/env bash
# Regenerate Tests/Fixtures/ru-pauses-2spk — the fixture that can falsify a
# feeding gate.
#
# `ru-short-2spk` cannot: it is 27 s of near-continuous speech with 1.5 s of
# silence in it, so "stop sending the engine silence" moves its cost by 5 %,
# which is inside the noise of the measurement. A real call is mostly one person
# listening — the owner's own track is silent about two thirds of the time.
#
# Two properties are therefore deliberate:
#
#   * ~65 % silence on the mic track, ~70 % on the system track, in pauses of
#     1.5–4.5 s — long enough that a gate with hysteresis can actually close.
#   * one interruption, where the owner starts talking 1.2 s before the far side
#     stops. That is the only stretch where a dominance gate can steal the
#     owner's words, and a fixture without it would let a broken gate pass.
#
# Stem asymmetry matches the real capture, as in ru-short-2spk: the tap is taken
# before the speaker, so the owner cannot be in the system stem, while the mic
# hears the far side back out of the room at -12 dB.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/swift/Tests/Fixtures/ru-pauses-2spk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# Voice A — the owner (mic), faster; voice B — the far side (system), slower.
say -v Milena -r 190 -o a1.aiff "Привет. Давай сверим, что осталось по спринту."
say -v Milena -r 150 -o b1.aiff "Привет. Я закрыла две задачи из четырёх, остальные в ревью."
say -v Milena -r 190 -o a2.aiff "Хорошо. Тогда я беру на себя миграцию базы и отчёт по метрикам."
say -v Milena -r 150 -o b2.aiff "Только учти, что миграция задевает биллинг, там нужен отдельный прогон тестов."
say -v Milena -r 190 -o a3.aiff "Да, я помню про биллинг. Прогоню отдельно и пришлю лог."
say -v Milena -r 150 -o b3.aiff "И ещё одно. Дизайн просил не менять форму оплаты до пятницы, иначе они не успеют."
say -v Milena -r 190 -o a4.aiff "Понял, до пятницы не трогаю."
say -v Milena -r 150 -o b4.aiff "Тогда всё. Я напишу в чат, когда ревью закроется."
say -v Milena -r 190 -o a5.aiff "Отлично. Спасибо, до связи."

for f in a1 b1 a2 b2 a3 b3 a4 b4 a5; do
  afconvert -f WAVE -d LEI16@16000 -c 1 "$f.aiff" "$f.wav"
done

python3 << 'PY'
import json, struct, wave

RATE = 16000

def read(path):
    with wave.open(path, "rb") as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, RATE), path
        return list(struct.unpack(f"<{w.getnframes()}h", w.readframes(w.getnframes())))

clips = {name: read(f"{name}.wav") for name in
         ["a1", "b1", "a2", "b2", "a3", "b3", "a4", "b4", "a5"]}

def seconds(name):
    return len(clips[name]) / RATE

# Speaking order with explicit gaps. The gap before a4 is negative: the owner
# cuts in 1.2 s before the far side finishes — that is the interruption.
GAPS = {"a1": 2.0, "b1": 1.5, "a2": 3.0, "b2": 2.0,
        "a3": 4.5, "b3": 1.5, "a4": -1.2, "b4": 2.5, "a5": 1.5}
OWNER = {"a1", "a2", "a3", "a4", "a5"}
TEXTS = {
    "a1": "Привет. Давай сверим, что осталось по спринту.",
    "b1": "Привет. Я закрыла две задачи из четырёх, остальные в ревью.",
    "a2": "Хорошо. Тогда я беру на себя миграцию базы и отчёт по метрикам.",
    "b2": "Только учти, что миграция задевает биллинг, там нужен отдельный прогон тестов.",
    "a3": "Да, я помню про биллинг. Прогоню отдельно и пришлю лог.",
    "b3": "И ещё одно. Дизайн просил не менять форму оплаты до пятницы, иначе они не успеют.",
    "a4": "Понял, до пятницы не трогаю.",
    "b4": "Тогда всё. Я напишу в чат, когда ревью закроется.",
    "a5": "Отлично. Спасибо, до связи.",
}

placed = []          # (name, start_sample)
cursor = 0.0
for name in ["a1", "b1", "a2", "b2", "a3", "b3", "a4", "b4", "a5"]:
    cursor += GAPS[name]
    placed.append((name, int(round(cursor * RATE))))
    cursor += seconds(name)
total = int(round((cursor + 2.0) * RATE))   # 2 s of tail

def mix(gain_owner, gain_remote):
    """Sum the clips into one track at their placed offsets."""
    track = [0] * total
    for name, start in placed:
        gain = gain_owner if name in OWNER else gain_remote
        if gain == 0.0:
            continue
        for i, sample in enumerate(clips[name]):
            j = start + i
            if j >= total:
                break
            track[j] = max(-32768, min(32767, track[j] + int(sample * gain)))
    return track

def write(path, track):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(struct.pack(f"<{len(track)}h", *track))

# final: both voices at full level, as the meeting sounded.
# mic:   owner direct, far side back out of the room (-12 dB).
# sys:   the tap — far side only, at full digital level.
write("final.wav", mix(1.0, 1.0))
write("final.mic.wav", mix(1.0, 0.25))
write("final.sys.wav", mix(0.0, 1.0))

# Reference in speaking order, i.e. sorted by start — the same order
# LiveTranscript.turns comes out in, so WER is not paying for a reordering.
order = sorted(placed, key=lambda item: item[1])
with open("reference-transcript.txt", "w", encoding="utf-8") as f:
    for name, _ in order:
        f.write(TEXTS[name] + "\n")

speakers = {
    "audio": "final.wav",
    "duration_s": round(total / RATE, 2),
    "speakers": [
        {"id": "A", "role": "local", "stem_hint": "mic",
         "turns": [{"text": TEXTS[n]} for n, _ in order if n in OWNER]},
        {"id": "B", "role": "remote", "stem_hint": "sys",
         "turns": [{"text": TEXTS[n]} for n, _ in order if n not in OWNER]},
    ],
    "notes": ("Synthetic TTS (macOS say -v Milena). Pauses 1.5-4.5 s; one "
              "interruption where A starts 1.2 s before B ends. Stems: mic = A + "
              "B at -12 dB, sys = B only."),
}
with open("reference-speakers.json", "w", encoding="utf-8") as f:
    json.dump(speakers, f, ensure_ascii=False, indent=2)
    f.write("\n")

# What the fixture is worth is how much of it is silence — print it, so a change
# to the script that quietly removes the pauses is visible immediately.
def silent_share(track):
    window = int(0.05 * RATE)
    quiet = sum(
        1 for start in range(0, len(track) - window, window)
        if (sum(s * s for s in track[start:start + window]) / window) ** 0.5 < 0.003 * 32767
    )
    return quiet / max(1, len(track) // window)

print(f"duration_s={total / RATE:.2f}")
print(f"mic silence={silent_share(read('final.mic.wav')):.0%}  "
      f"sys silence={silent_share(read('final.sys.wav')):.0%}")
PY

mkdir -p "$DEST"
cp -f final.wav final.mic.wav final.sys.wav \
      reference-transcript.txt reference-speakers.json "$DEST/"
echo "Wrote $DEST"
