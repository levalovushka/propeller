"""Кому принадлежит текст строки — по словам, а не по времени.

Предыдущая метрика спрашивала «пересекается ли окно строки с речью обеих
дорожек» и давала 96–99 % даже на ленте, где каждая строка по построению
принадлежит одному человеку: куски ASR покрывают почти всё время встречи. Здесь
вопрос другой и честный — **чьи слова стоят в строке**.

Для каждой строки транскрипта микса берётся её текст и сравнивается со словами,
сказанными в то же время на каждой дорожке по отдельности. Строка «смешанная»,
если существенная доля её слов нашлась и там, и там.

Порог намеренно грубый (четверть слов с каждой стороны): вопрос стоит «одна ли
это реплика или две склеенных», а не «сколько именно процентов чужого».

**Микрофон обязан приходить уже без эха.** На колонках две трети микрофонной
дорожки — слова собеседника (замерено на встрече тестировщика: 1382 слова эха
против 698 своих), и если сравнивать с сырым микрофоном, смешанной окажется
каждая строка. Сначала `EchoDedup`, потом этот замер.

Замер 2026-08-12, встреча тестировщика (17 минут, колонки): из 264 строк микса
смешанных 28 — **10.6 %**, в них 9.9 % слов. Та же встреча по прежней, временной
метрике давала 72.7 %; разница в семь раз и есть цена вопроса «по словам или по
секундам».
"""
import json
import pathlib
import re
import sys

SCRATCH = pathlib.Path(sys.argv[1])
PAD = 1.0
SHARE = 0.25


def words(text):
    return re.findall(r"[а-яёa-z0-9]{3,}", text.lower())


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


def said(track, start, end):
    return set(words(" ".join(s["text"] for s in track
                              if s["end"] > start - PAD and s["start"] < end + PAD)))


name = sys.argv[2]
mix = parse_srt(SCRATCH / f"{name}.mix.srt")
mic = parse_srt(SCRATCH / f"{name}.mic.srt")
sysd = parse_srt(SCRATCH / f"{name}.sys.srt")

mixed = only_mic = only_sys = neither = 0
mixed_words = total_words = 0
examples = []

for line in mix:
    tokens = set(words(line["text"]))
    if len(tokens) < 4:
        continue
    from_mic = tokens & said(mic, line["start"], line["end"])
    from_sys = tokens & said(sysd, line["start"], line["end"])
    total_words += len(tokens)
    share_mic = len(from_mic) / len(tokens)
    share_sys = len(from_sys) / len(tokens)
    if share_mic >= SHARE and share_sys >= SHARE:
        mixed += 1
        mixed_words += len(tokens)
        if len(examples) < 3:
            examples.append((line["start"], line["text"]))
    elif share_mic >= SHARE:
        only_mic += 1
    elif share_sys >= SHARE:
        only_sys += 1
    else:
        neither += 1

total = mixed + only_mic + only_sys + neither
print(f"  строк в миксе: {total}")
print(f"  из них смешанных (слова обеих дорожек): {mixed} ({mixed / max(1, total):.1%}), "
      f"слов в них {mixed_words / max(1, total_words):.1%}")
print(f"  чисто владелец: {only_mic}   чисто собеседник: {only_sys}   ни там ни там: {neither}")
for start, text in examples:
    print(f"    {int(start)//60:02d}:{int(start)%60:02d} {text[:110]}")
