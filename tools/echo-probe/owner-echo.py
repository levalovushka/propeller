"""Сколько чужих слов стоит в репликах владельца — без круга в рассуждении.

ownership.py сравнивает строку с обеими дорожками, и «дорожка владельца» там
сама получена снятием эха: то есть эталон зависит от правила, которое мы
проверяем. Здесь эталон один и чистый — системный стем. Владельца в нём нет по
построению (он снят до колонки), значит любое его слово, найденное в реплике
владельца в то же время, — это эхо, не совпадение метрики.

Обратную сторону проверять нечем и не надо: реплики дальней стороны в ленте
скопированы из ASR системного стема дословно, слов владельца в них быть не может.

Запуск: owner-echo.py <каталог> <имя> [имя владельца]
"""
import json
import pathlib
import re
import sys

W = pathlib.Path(sys.argv[1])
NAME = sys.argv[2]
OWNER = sys.argv[3] if len(sys.argv) > 3 else "Левон"
PAD = 1.0
SHARE = 0.25


def words(text):
    return re.findall(r"[а-яёa-z0-9]{3,}", text.lower().replace("ё", "е"))


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


assembled = json.loads((W / f"{NAME}.assembled.json").read_text())
sysd = parse_srt(W / f"{NAME}.sys.srt")


def said(start, end):
    return set(words(" ".join(s["text"] for s in sysd
                              if s["end"] > start - PAD and s["start"] < end + PAD)))


lines = tainted = 0
own_words = tainted_words = 0
worst = []
for line in assembled:
    if line["speaker"] != OWNER:
        continue
    tokens = words(line["text"])
    if len(tokens) < 4:
        continue
    lines += 1
    own_words += len(tokens)
    from_sys = set(tokens) & said(line["start"], line["end"])
    hit = sum(1 for t in tokens if t in from_sys)
    tainted_words += hit
    if len(from_sys) / len(set(tokens)) >= SHARE:
        tainted += 1
        worst.append((len(from_sys) / len(set(tokens)), line, sorted(from_sys)))

# короткие реплики: их прежний порог «4+ слова» не видел, а именно там жило
# целиком-эхо вроде «Вот.» и «Сейчас скажу.»
short = short_echo = 0
for line in assembled:
    if line["speaker"] != OWNER:
        continue
    tokens = words(line["text"])
    if not tokens or len(tokens) >= 4:
        continue
    short += 1
    heard = said(line["start"], line["end"])
    if all(t in heard for t in tokens):
        short_echo += 1
print(f"  коротких реплик владельца (1–3 слова): {short}, из них целиком чужие слова: {short_echo}")
print(f"  реплик владельца (4+ слов): {lines}, слов {own_words}")
print(f"  из них с чужими словами (доля ≥ {SHARE:.0%}): {tainted} ({tainted / max(1, lines):.1%})")
print(f"  чужих слов внутри реплик владельца: {tainted_words} ({tainted_words / max(1, own_words):.1%})")
for share, line, hits in sorted(worst, key=lambda r: -r[0])[:5]:
    t = int(line["start"])
    print(f"    {t//60:02d}:{t%60:02d} [{share:.0%}] {line['text'][:100]}")
    print(f"        чужие: {hits}")
