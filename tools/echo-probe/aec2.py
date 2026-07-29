"""Partitioned frequency-domain NLMS, with a synthetic self-test first.

If the canceller cannot remove an echo we made ourselves, any number it reports
on the real recording means nothing.
"""
import sys, wave, numpy as np

def read(p):
    with wave.open(p, 'rb') as w:
        sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float32)
    return x / 32768.0, sr

def write(p, x, sr):
    with wave.open(p, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype('<i2').tobytes())

def mdf(ref, mic, B=512, P=16, mu=0.7):
    """ref: far-end signal already aligned to the mic timeline."""
    n = min(len(ref), len(mic))
    NF = 2 * B
    bins = NF // 2 + 1
    W = np.zeros((P, bins), np.complex128)
    X = np.zeros((P, bins), np.complex128)
    out = np.zeros(n, np.float64)
    prev = np.zeros(B)
    pw = np.full(bins, 1e-6)
    for i in range(0, n - B, B):
        xb, db_ = ref[i:i+B], mic[i:i+B]
        Xn = np.fft.rfft(np.concatenate([prev, xb]), NF)
        prev = xb
        X = np.roll(X, 1, axis=0)
        X[0] = Xn
        y = np.fft.irfft(np.sum(W * X, axis=0), NF)[B:]
        e = db_ - y
        out[i:i+B] = e
        pw = 0.95 * pw + 0.05 * np.abs(Xn) ** 2
        far = xb @ xb
        near = db_ @ db_
        if far > 1e-8 and near < 16 * far:
            E = np.fft.rfft(np.concatenate([np.zeros(B), e]), NF)
            G = mu * np.conj(X) * E / (P * pw + 1e-8)
            g = np.fft.irfft(G, NF, axis=1)
            g[:, B:] = 0
            W += np.fft.rfft(g, NF, axis=1)
    return out.astype(np.float32)

def erle(mic, out, ref, sr):
    hop = int(0.02 * sr)
    m = min(len(mic), len(out), len(ref)) // hop * hop
    e = lambda z: np.sqrt((z[:m].reshape(-1, hop) ** 2).mean(1))
    er, em, eo = e(ref), e(mic), e(out)
    loud = er > np.percentile(er, 75)
    return 20 * np.log10((em[loud].mean() + 1e-9) / (eo[loud].mean() + 1e-9))

# ---------- self-test ----------
rng = np.random.default_rng(0)
sr = 16000
far = rng.standard_normal(sr * 20).astype(np.float32) * 0.1
h = np.zeros(2000, np.float32); h[300] = 0.6; h[420] = -0.3; h[900] = 0.15
echo = np.convolve(far, h)[:len(far)]
near = np.zeros_like(far); near[sr*10:sr*11] = rng.standard_normal(sr) * 0.05
mic_t = echo + near
out_t = mdf(far, mic_t)
print(f'самотест (синтетическое эхо): ERLE = {erle(mic_t, out_t, far, sr):+.1f} dB   '
      f'(ожидаем сильно больше нуля)')

# ---------- real recording ----------
S = sys.argv[1]
LAG = int(sys.argv[2])
mic, sr = read(f'{S}/cut/mic.wav')
sysx, _ = read(f'{S}/cut/sys.wav')
n = min(len(mic), len(sysx))
mic, sysx = mic[:n], sysx[:n]
ref = np.concatenate([np.zeros(LAG, np.float32), sysx])[:n]

out = mdf(ref, mic)
print(f'реальная запись: ERLE = {erle(mic, out, ref, sr):+.1f} dB')
write(f'{S}/cut/aec_mic.wav', out, sr)
write(f'{S}/cut/aec.wav', out + ref, sr)
write(f'{S}/cut/aligned.wav', mic + ref, sr)
print('written: aligned.wav, aec_mic.wav, aec.wav')
