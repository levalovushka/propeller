"""How much of the owner survives the mic stem — and whether cancelling helps.

Runs over Tests/Fixtures/ru-echo-loud-2spk (see
tools/generate-fixture-ru-echo-loud.sh) and answers two questions with the
product's own engine:

  1. Of the owner's words, how many does gigastt return from the mic stem when
     the far side is louder — speaking in the clear, and speaking on top of it.
  2. Does removing the far side from the mic stem (partitioned frequency-domain
     NLMS, the same canceller as aec2.py) give the lost words back, and does it
     damage the words that were never lost.

Recall is a multiset of tokens, not WER: the question is "is the owner in the
transcript at all", and a word recognised in the wrong order still means he is.
The two-token floor is the shared-filler noise level ("я", "про") — the far
side's own reference scores it too.

    python3 tools/echo-probe/owner-loss.py [fixture-dir]

Needs numpy (Xcode's python3 has it) and the gigastt binary from the installed
app; both paths are overridable by env (PYTHON is chosen by the caller, GIGASTT,
GIGASTT_MODELS).
"""
import collections
import json
import os
import re
import subprocess
import sys
import wave

import numpy as np

HOME = os.path.expanduser("~")
GIGASTT = os.environ.get("GIGASTT", "/Applications/Propeller.app/Contents/MacOS/gigastt")
MODELS = os.environ.get(
    "GIGASTT_MODELS", f"{HOME}/Library/Application Support/Meeting Recorder/gigastt-models"
)
FIXTURE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "..", "meeting-recorder", "swift",
    "Tests", "Fixtures", "ru-echo-loud-2spk",
)
RATE = 16000


def read(path):
    with wave.open(path, "rb") as w:
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def write(path, x):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


def transcribe(path):
    """The offline pass, same binary and variant as the app's sidecar."""
    out = subprocess.run(
        [GIGASTT, "--log-level", "error", "transcribe", "--model-dir", MODELS,
         "--model-variant", "e2e_rnnt", "--offline", "-f", "json", path],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(out[out.index("{"):])


def tokens(text):
    return re.findall(r"[\wёЁ]+", text.lower())


def recall(result, reference):
    want = collections.Counter(t for line in reference for t in tokens(line))
    got = collections.Counter(t for w in result["words"] for t in tokens(w["word"]))
    return sum(min(v, got[k]) for k, v in want.items()), sum(want.values())


def mdf(ref, mic, B=512, P=16, mu=0.7):
    """Partitioned frequency-domain NLMS — aec2.py, unchanged."""
    n = min(len(ref), len(mic))
    NF, bins = 2 * B, B + 1
    W = np.zeros((P, bins), np.complex128)
    X = np.zeros((P, bins), np.complex128)
    out = np.zeros(n)
    prev = np.zeros(B)
    pw = np.full(bins, 1e-6)
    for i in range(0, n - B, B):
        xb, db_ = ref[i:i + B], mic[i:i + B]
        Xn = np.fft.rfft(np.concatenate([prev, xb]), NF)
        prev = xb
        X = np.roll(X, 1, axis=0)
        X[0] = Xn
        out[i:i + B] = e = db_ - np.fft.irfft(np.sum(W * X, axis=0), NF)[B:]
        pw = 0.95 * pw + 0.05 * np.abs(Xn) ** 2
        far_e, near_e = xb @ xb, db_ @ db_
        if far_e > 1e-8 and near_e < 16 * far_e:
            E = np.fft.rfft(np.concatenate([np.zeros(B), e]), NF)
            g = np.fft.irfft(mu * np.conj(X) * E / (P * pw + 1e-8), NF, axis=1)
            g[:, B:] = 0
            W += np.fft.rfft(g, NF, axis=1)
    return out.astype(np.float32)


def erle(mic, out, ref):
    hop = int(0.02 * RATE)
    m = min(len(mic), len(out), len(ref)) // hop * hop
    energy = lambda z: np.sqrt((z[:m].reshape(-1, hop) ** 2).mean(1))
    er, em, eo = energy(ref), energy(mic), energy(out)
    loud = er > np.percentile(er, 75)
    return 20 * np.log10((em[loud].mean() + 1e-9) / (eo[loud].mean() + 1e-9))


manifest = json.load(open(os.path.join(FIXTURE, "manifest.json")))
own_ref, far_ref = manifest["owner_reference"], manifest["far_reference"]
print(f"echo over owner: +{manifest['echo_over_owner_db']:.0f} dB\n")
print(f"{'variant':26} {'owner':>9} {'far in mic':>11}   note")

ceiling = transcribe(os.path.join(FIXTURE, "owner-only.wav"))
o, total = recall(ceiling, own_ref)
print(f"{'owner alone (ceiling)':26} {f'{o}/{total}':>9} {'—':>11}")

for kind in ("sequential", "overlap"):
    for path in ("dup", "room"):
        name = f"{kind}-{path}"
        mic_path = os.path.join(FIXTURE, f"{name}.mic.wav")
        sys_path = os.path.join(FIXTURE, f"{name}.sys.wav")
        if not os.path.exists(mic_path):
            # Only the `room` variants are committed — the scaled-duplicate ones
            # are 3.5 MB of wav for a number the level sweep already covers.
            # Regenerate them with generate-fixture-ru-echo-loud.sh to include.
            print(f"{name:26} {'—':>9} {'—':>11}   not in the fixture, skipped")
            continue
        raw = transcribe(mic_path)
        o, _ = recall(raw, own_ref)
        f_, ftotal = recall(raw, far_ref)
        print(f"{name:26} {f'{o}/{total}':>9} {f'{f_}/{ftotal}':>11}   as recorded")
        if path != "room":
            continue                       # cancelling a scaled duplicate proves nothing
        mic, ref = read(mic_path), read(sys_path)
        n = min(len(mic), len(ref))
        cancelled = mdf(ref[:n], mic[:n])
        tmp = os.path.join(FIXTURE, f"{name}.aec.tmp.wav")
        write(tmp, cancelled)
        try:
            after = transcribe(tmp)
        finally:
            os.remove(tmp)
        o2, _ = recall(after, own_ref)
        f2, _ = recall(after, far_ref)
        print(f"{name:26} {f'{o2}/{total}':>9} {f'{f2}/{ftotal}':>11}   "
              f"after cancelling, ERLE {erle(mic[:n], cancelled, ref[:n]):+.1f} dB")
