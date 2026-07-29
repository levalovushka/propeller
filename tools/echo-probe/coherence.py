"""Can a linear filter explain the echo at all?

Magnitude-squared coherence between the aligned system stem and the microphone,
measured only where the far end is loud. Near 1 means «a filter can subtract
this» — that is what an echo canceller needs. Low coherence means the path is
not linear (speaker distortion, or the microphone is doing its own processing),
and no canceller will help much.
"""
import sys, wave, numpy as np

S, LAG = sys.argv[1], int(sys.argv[2])

def read(p):
    with wave.open(p, 'rb') as w:
        sr = w.getframerate()
        return np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float64) / 32768, sr

mic, sr = read(f'{S}/full/mic.wav')
sysx, _ = read(f'{S}/full/sys.wav')
n = min(len(mic), len(sysx))
mic, sysx = mic[:n], sysx[:n]
ref = np.concatenate([np.zeros(LAG), sysx])[:n]

N = 2048
hop = N // 2
win = np.hanning(N)
frames = (n - N) // hop

Pxx = np.zeros(N // 2 + 1); Pyy = np.zeros(N // 2 + 1)
Pxy = np.zeros(N // 2 + 1, complex)
used = 0
ref_rms_all = np.sqrt((ref ** 2).mean())

for i in range(frames):
    a = ref[i*hop:i*hop+N]
    b = mic[i*hop:i*hop+N]
    if np.sqrt((a ** 2).mean()) < ref_rms_all:      # only loud far-end frames
        continue
    A = np.fft.rfft(a * win); B = np.fft.rfft(b * win)
    Pxx += np.abs(A) ** 2; Pyy += np.abs(B) ** 2; Pxy += A * np.conj(B)
    used += 1

coh = np.abs(Pxy) ** 2 / (Pxx * Pyy + 1e-20)
freqs = np.fft.rfftfreq(N, 1 / sr)
band = (freqs > 200) & (freqs < 3500)
print(f'кадров в расчёте: {used}')
print(f'когерентность в речевой полосе 200–3500 Гц: среднее {coh[band].mean():.2f}, '
      f'медиана {np.median(coh[band]):.2f}, максимум {coh[band].max():.2f}')
for lo, hi in ((100, 300), (300, 800), (800, 1500), (1500, 3000), (3000, 6000)):
    m = (freqs >= lo) & (freqs < hi)
    print(f'  {lo:5d}–{hi:5d} Гц: {coh[m].mean():.2f}')
print()
print('ориентир: > 0.7 — путь линейный, эхоподавитель снимет 15–25 dB;')
print('          0.3–0.7 — частично; < 0.3 — линейной модели там нет.')
