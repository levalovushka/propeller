"""Сколько слов каждой стороны доходит до готовой расшифровки.

Метрика принадлежности (ownership.py) отвечает «чьи слова стоят в строке».
Здесь другой вопрос, и для конспекта он не менее важный: **не потерялось ли
сказанное вовсе**. Эталон — чистая дорожка (её слова заведомо произнесены),
гипотеза — та лента, из которой потом собирается конспект.

Вставки бесплатны намеренно: в ленте законно стоит речь другой стороны, и
считать её ошибкой значило бы мерить не то.

Запуск: coverage.py <каталог> <кандидат.srt> <эталон.srt>
"""
import pathlib
import re
import sys

PAD = 0.7


def words(text):
    return re.findall(r"[а-яёa-z0-9]+", text.lower().replace("ё", "е"))


def parse_srt(path):
    out = []
    for block in path.read_text(encoding="utf-8").strip().split("\n\n"):
        lines = [l for l in block.splitlines() if l.strip()]
        if len(lines) < 2 or "-->" not in lines[1]:
            continue
        def clock(v):
            h, m, rest = v.split(":")
            s, ms = rest.replace(",", ".").split(".")
            return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000
        a, b = (p.strip() for p in lines[1].split("-->"))
        body = " ".join(lines[2:]).strip()
        if body:
            out.append({"start": clock(a), "end": clock(b), "text": body})
    return out


def coverage(ref, hyp):
    """Доля слов эталона, нашедшихся в гипотезе; вставки не штрафуются."""
    if not ref:
        return None
    prev = [0] * (len(hyp) + 1)
    for i in range(1, len(ref) + 1):
        cur = [prev[0] + 1] + [0] * len(hyp)
        for j in range(1, len(hyp) + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1], prev[j - 1] + (ref[i - 1] != hyp[j - 1]))
        prev = cur
    return 1 - prev[-1] / len(ref)


def between(track, t0, t1):
    return " ".join(s["text"] for s in track if s["end"] > t0 and s["start"] < t1)


W = pathlib.Path(sys.argv[1])
hyp = parse_srt(W / sys.argv[2])
ref = parse_srt(W / sys.argv[3])

rows = []
for cue in ref:
    r = words(cue["text"])
    if len(r) < 6:
        continue
    h = words(between(hyp, cue["start"] - PAD, cue["end"] + PAD))
    rows.append((len(r), coverage(r, h)))

n = sum(r[0] for r in rows)
cov = sum(r[0] * r[1] for r in rows) / n
print(f"{sys.argv[3]} → {sys.argv[2]}: реплик {len(rows)} ({n} слов), покрытие {cov:.1%}")
