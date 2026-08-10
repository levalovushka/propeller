#!/usr/bin/env bash
# Regenerate Tests/Fixtures/ru-short-2spk (plan-testing-metrics F2).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/swift/Tests/Fixtures/ru-short-2spk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

say -v Milena -r 190 -o a.aiff "Привет. Давайте быстро обсудим план на спринт. Нужно закрыть три задачи до пятницы. Также важно не забыть про релиз заметок."
say -v Milena -r 150 -o b.aiff "Хорошо. Я возьму бэклог и риски. К среде пришлю черновик оценки. Если понадобится помощь дизайна — напиши."
say -v Milena -r 190 -o a2.aiff "Отлично. Тогда на стендапе завтра сверим прогресс. Я подготовлю список блокеров заранее."
say -v Milena -r 150 -o b2.aiff "Договорились. После стендапа обновлю доску и пришлю ссылку в чат."

for f in a b a2 b2; do
  afconvert -f WAVE -d LEI16@16000 -c 1 "$f.aiff" "$f.wav"
done

python3 << 'PY'
import wave, struct
def read(p):
    with wave.open(p, "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == 16000
        return w.readframes(w.getnframes())
parts = [read(p) for p in ["a.wav", "b.wav", "a2.wav", "b2.wav"]]
silence = b"\x00\x00" * 8000
def scale(frames, gain):
    outb = bytearray()
    for i in range(0, len(frames), 2):
        s = struct.unpack_from("<h", frames, i)[0]
        s = max(-32768, min(32767, int(s * gain)))
        outb += struct.pack("<h", s)
    return bytes(outb)
# The mic hears the far side too — through the room, quieter (-12 dB here):
# that is the speakers case, and the rule that separates the two tracks
# (`StemDominance`) exists precisely for it.
#
# The system stem, though, is tapped *before* the speaker, straight off the
# app's output — the owner's voice cannot be in it at all. It used to carry A at
# 0.25, and that one number made the fixture lie in the direction that matters:
# the sys session then recognised the owner's speech, the live text came out
# doubled (38 insertions on 58 reference words, measured), and any change that
# fed the engine more selectively would have scored a spectacular saving on
# audio no real meeting contains.
gains_mic = [1.0, 0.25, 1.0, 0.25]
gains_sys = [0.0, 1.0, 0.0, 1.0]
final = silence.join(parts)
mic = silence.join(scale(p, g) for p, g in zip(parts, gains_mic))
sys = silence.join(scale(p, g) for p, g in zip(parts, gains_sys))
def write(name, data):
    with wave.open(name, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(data)
write("final.wav", final)
write("final.mic.wav", mic)
write("final.sys.wav", sys)
print(f"duration_s={len(final)/(16000*2):.2f}")
PY

mkdir -p "$DEST"
cp -f final.wav final.mic.wav final.sys.wav "$DEST/"
echo "Wrote $DEST"
