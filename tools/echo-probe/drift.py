"""Does the delay between the two stems stay put over the whole meeting?

Mic and system audio come from two independent clocks (input device vs
ScreenCaptureKit). If those clocks drift, the echo delay walks, and any echo
canceller is chasing a moving target.
"""
import sys, wave, numpy as np

S = sys.argv[1]

def read(p):
    with wave.open(p, 'rb') as w:
        sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float32)
    return x / 32768.0, sr

def lag_env(a, b, sr, max_ms=1500, hop_ms=2):
    """Delay via envelope correlation — robust to reverb and to distortion."""
    hop = int(sr * hop_ms / 1000)
    m = min(len(a), len(b)) // hop * hop
    ea = np.sqrt((a[:m].reshape(-1, hop) ** 2).mean(1) + 1e-12)
    eb = np.sqrt((b[:m].reshape(-1, hop) ** 2).mean(1) + 1e-12)
    ea -= ea.mean(); eb -= eb.mean()
    n = 1 << int(np.ceil(np.log2(len(ea) * 2)))
    cc = np.fft.irfft(np.fft.rfft(ea, n) * np.conj(np.fft.rfft(eb, n)), n)
    k = int(max_ms / hop_ms)
    pos, neg = cc[:k], cc[-k:]
    if pos.max() >= neg.max():
        idx, peak = int(np.argmax(pos)), pos.max()
    else:
        idx, peak = int(np.argmax(neg)) - k, neg.max()
    norm = np.sqrt((ea ** 2).sum() * (eb ** 2).sum()) + 1e-12
    return idx * hop_ms, float(peak / norm)

mic, sr = read(f'{S}/full/mic.wav')
sysx, _ = read(f'{S}/full/sys.wav')
n = min(len(mic), len(sysx))
print(f'{n/sr/60:.1f} мин')

win = 120 * sr
print('окно (мин)   задержка mic−sys   уверенность')
xs, ys = [], []
for i in range(0, n - win, win):
    d, c = lag_env(mic[i:i+win], sysx[i:i+win], sr)
    flag = '' if c > 0.25 else '   (мало речи, ненадёжно)'
    print(f'  {i/sr/60:5.1f}        {d:+7.0f} мс         {c:.2f}{flag}')
    if c > 0.25:
        xs.append(i / sr); ys.append(d)

if len(xs) > 2:
    k, b = np.polyfit(xs, ys, 1)
    print(f'\nтренд: {k*60:+.1f} мс на минуту записи  '
          f'(за час это {k*3600:+.0f} мс)')
    print(f'разброс вокруг тренда: {np.std(np.array(ys) - (k*np.array(xs)+b)):.0f} мс')
