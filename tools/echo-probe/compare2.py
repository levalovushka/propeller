"""How much of the far end's speech survives in the mix — and how much of it the
microphone transcribes a second time."""
import json, sys, re
import numpy as np

S = sys.argv[1]

def load(n): return json.load(open(f'{S}/cut/{n}.json'))
def words(t): return re.findall(r'[а-яёa-z0-9]+', t.lower())

def coverage(ref, hyp):
    """Share of ref words matched in hyp, ignoring hyp's extra words.

    Insertions are free on purpose: the mix legitimately contains the owner's
    speech that the system stem cannot have, and counting those as errors would
    measure the wrong thing.
    """
    if not ref: return None
    prev = list(range(len(hyp) + 1))
    prev = [0] * (len(hyp) + 1)          # free insertions: no cost along hyp
    for i in range(1, len(ref) + 1):
        cur = [prev[0] + 1] + [0] * len(hyp)
        for j in range(1, len(hyp) + 1):
            cur[j] = min(prev[j] + 1,                       # deletion
                         cur[j - 1],                        # insertion, free
                         prev[j - 1] + (ref[i-1] != hyp[j-1]))
        prev = cur
    miss = prev[-1]
    return 1 - miss / len(ref)

def text_between(segs, t0, t1):
    return ' '.join(s['text'] for s in segs if s['end'] > t0 and s['start'] < t1)

mix, sysd, mic = load('mix'), load('sys'), load('mic')

pad = 0.7
rows = []
for s in sysd['segments']:
    ref = words(s['text'])
    if len(ref) < 6:
        continue
    a, b = s['start'] - pad, s['end'] + pad
    rows.append((len(ref),
                 coverage(ref, words(text_between(mix['segments'], a, b))),
                 coverage(ref, words(text_between(mic['segments'], a, b)))))

n = sum(r[0] for r in rows)
cov_mix = sum(r[0] * r[1] for r in rows) / n
cov_mic = sum(r[0] * r[2] for r in rows) / n
print(f'реплик дальней стороны в выборке: {len(rows)} ({n} слов)')
print(f'сколько её слов доходит до микса:            {cov_mix:.1%}')
print(f'сколько её слов распознаётся и в микрофоне:  {cov_mic:.1%}   ← это и есть задвоение')

worst = sorted(rows, key=lambda r: r[1])[:1]
print()
for s in sysd['segments']:
    ref = words(s['text'])
    if len(ref) >= 6 and abs(coverage(ref, words(text_between(mix['segments'], s['start']-pad, s['end']+pad))) - worst[0][1]) < 1e-9:
        a, b = s['start'] - pad, s['end'] + pad
        print(f'худший случай [{s["start"]:.0f}–{s["end"]:.0f} c], покрытие {worst[0][1]:.0%}:')
        print('  sys:', s['text'][:260])
        print('  mix:', text_between(mix['segments'], a, b)[:260])
        break
