"""Починка входа — двумя независимыми частями, каждая воспроизводима.

Транскрипт портят три разные вещи, и мерить их одной кучей бессмысленно:
приложение может починить их по отдельности и разной ценой.

    --terms    один термин — одно написание. Это то, что умеет gigastt через
               hotwords и `TermCanon`: словарь, а не модель.
    --speakers `Speaker S1` / `Speaker S2` → имена, которые звучат в обращениях
               внутри реплик. Это шаг 4.x plan-v2 «LLM-именование по обращениям»;
               здесь маппинг проставлен руками, чтобы замер не зависел от того,
               угадала ли модель.

Третья порча — склеенные реплики (в одном блоке говорят двое) — детерминированно
не чинится и здесь не чинится вовсе. Значит всё, что ниже, — нижняя оценка того,
сколько отнимает вход.

    python3 bench_repair.py --terms --speakers --out out/bench/transcript-repaired.md
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import promptlib as p

HERE = Path(__file__).parent
MEETING = "20260812_144201"

# Одно написание на сущность. Слева — то, что реально стоит в транскрипте
# (найдено грепом, не придумано), справа — канон.
TERMS = [
    (r"викс\s+микс|voco\s+микс|века\s+микса|ФК\s+микс|ВК-микс|ВК\s+микс|вк\s+микс|VK\s+микс", "VK Микс"),
    (r"spet\s*Yi|спети\s*фай|с\s+специфай|с\s+спети\s*фай", "Spotify"),
    (r"фаст\s*[Пп]лей|фост\s*плей|пост\s*плей|фастплей|фаст\s*[Пп]ле\b|фост-плеевские", "Fast Play"),
    (r"Resurch\s+discovery|дискавери|Discover\b", "Discovery"),
    (r"рекома|реком\b", "рекомендательная система"),
    (r"дип-дайв|депдайв|подепдайв|депдайвить", "deep dive"),
    (r"рич-\s*рич-текст|рич-текст|лейч-текст", "рич-текст"),
]

# Кто есть кто. Выведено из обращений внутри реплик, не угадано:
#   S1 — Левон обращается к нему «Саш, но ты смешиваешь» (12:47) сразу после его
#        блока 12:09; он же «Лёш/Лёх» в чужих обращениях.
#   S2 — Левон говорит «я глобально согласен с Миленой» (02:11) сразу после её
#        блока 01:27.
# Ровно тот же вывод сделала модель в рекапе, который лежит в архиве, — но там
# он был догадкой в тексте, а не разметкой, и «Задачи» это не спасло.
SPEAKERS = {"Speaker S1": "Саша", "Speaker S2": "Милена"}


def repair(text: str, terms: bool, speakers: bool) -> tuple[str, dict]:
    counts = {}
    head, body = text.split("## Transcript", 1)
    if terms:
        for pattern, canon in TERMS:
            body, n = re.subn(pattern, canon, body)
            if n:
                counts[canon] = n
    if speakers:
        for label, name in SPEAKERS.items():
            body, n = re.subn(rf"^\*\*{label}\*\* ·", f"**{name}** ·", body, flags=re.M)
            counts[name] = n
        head = re.sub(r"^\*\*Participants:\*\*.*$",
                      "**Participants:** Левон, " + ", ".join(SPEAKERS.values()),
                      head, flags=re.M)
    return head + "## Transcript" + body, counts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--terms", action="store_true")
    ap.add_argument("--speakers", action="store_true")
    ap.add_argument("--meeting", default=MEETING)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    _, text = p.transcript(args.meeting)
    fixed, counts = repair(text, args.terms, args.speakers)
    out = args.out if args.out.is_absolute() else HERE / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(fixed, encoding="utf-8")
    print(f"{out} · {len(text)} → {len(fixed)} симв · замен {counts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
