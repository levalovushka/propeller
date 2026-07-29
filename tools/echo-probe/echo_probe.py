"""Does the mic stem contain a copy of the system stem?

Reads both stems, finds the delay by cross-correlation on a loud window, then
reports how much of the mic energy that delayed copy explains.
"""
import sys, wave, numpy as np

def read_wav(path, limit_s=None):
    with wave.open(path, 'rb') as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        n = w.getnframes()
        if limit_s:
            n = min(n, int(limit_s * sr))
        raw = w.readframes(n)
    assert sw == 2, f"{path}: expected int16, got {sw*8}-bit"
    x = np.frombuffer(raw, dtype='<i2').astype(np.float32) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr

def best_lag(a, b, sr, max_lag_s=1.0):
    """Lag (in samples) that best aligns b to a, via FFT cross-correlation."""
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    A = np.fft.rfft(a - a.mean(), n)
    B = np.fft.rfft(b - b.mean(), n)
    cc = np.fft.irfft(A * np.conj(B), n)
    m = int(max_lag_s * sr)
    pos = cc[:m]
    neg = cc[-m:]
    if pos.max() >= neg.max():
        lag = int(np.argmax(pos))
        peak = pos.max()
    else:
        lag = int(np.argmax(neg)) - m
        peak = neg.max()
    denom = np.sqrt(np.sum((a - a.mean())**2) * np.sum((b - b.mean())**2)) + 1e-12
    return lag, float(peak / denom)

def envelope(x, sr, hop_ms=20):
    hop = int(sr * hop_ms / 1000)
    n = len(x) // hop * hop
    return np.sqrt((x[:n].reshape(-1, hop)**2).mean(axis=1) + 1e-12)

def main(mic_path, sys_path):
    mic, sr = read_wav(mic_path)
    sysx, sr2 = read_wav(sys_path)
    assert sr == sr2, f"sample rate mismatch {sr} vs {sr2}"
    n = min(len(mic), len(sysx))
    mic, sysx = mic[:n], sysx[:n]
    dur = n / sr
    print(f"duration {dur/60:.1f} min @ {sr} Hz")
    print(f"rms  mic={np.sqrt((mic**2).mean()):.5f}  sys={np.sqrt((sysx**2).mean()):.5f}")

    # Pick the loudest 60 s of system audio — that is where echo would show.
    env_s = envelope(sysx, sr)
    win = int(60 * sr / (0.02 * sr))          # 60 s worth of 20 ms hops
    if len(env_s) > win:
        block = np.convolve(env_s, np.ones(win) / win, mode='valid')
        start = int(np.argmax(block) * 0.02 * sr)
    else:
        start = 0
    seg = slice(start, start + 60 * sr)
    print(f"probe window: {start/sr/60:.1f}–{(start/sr+60)/60:.1f} min")

    lag, corr = best_lag(mic[seg], sysx[seg], sr)
    print(f"best lag = {lag} samples ({lag/sr*1000:+.0f} ms), correlation = {corr:.3f}")

    # Envelope correlation is the robust "is the same audio in there" signal:
    # room reverb destroys waveform correlation but keeps the loudness shape.
    e_mic = envelope(mic[seg], sr)
    e_sys = envelope(sysx[seg], sr)
    k = int(round(lag / (0.02 * sr)))
    if k > 0:
        e_mic_a, e_sys_a = e_mic[k:], e_sys[:len(e_sys) - k]
    elif k < 0:
        e_mic_a, e_sys_a = e_mic[:len(e_mic) + k], e_sys[-k:]
    else:
        e_mic_a, e_sys_a = e_mic, e_sys
    m = min(len(e_mic_a), len(e_sys_a))
    env_corr = float(np.corrcoef(e_mic_a[:m], e_sys_a[:m])[0, 1])
    print(f"envelope correlation = {env_corr:.3f}")

    # How loud is the mic while only the far end is talking? With headphones this
    # is near the noise floor; over speakers it carries the echo.
    thr_s = np.percentile(e_sys_a[:m], 75)
    thr_m_quiet = np.percentile(e_mic_a[:m], 20)
    far_only = (e_sys_a[:m] > thr_s) & (e_mic_a[:m] < np.percentile(e_mic_a[:m], 95))
    if far_only.sum() > 10:
        ratio = 20 * np.log10(e_mic_a[:m][far_only].mean() / (thr_m_quiet + 1e-9))
        print(f"mic level while far end speaks: {ratio:+.1f} dB above mic's own quiet floor "
              f"({far_only.sum()} frames)")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
