"""Таблица по решётке {модель} × {транскрипт}.

Заземление считается против ТОГО транскрипта, который модель видела: конспект по
починенному входу нельзя проверять по сырому, иначе каждое исправленное слово
читается как выдумка. `lint.lint` для этого и принимает транскрипт отдельным
аргументом.

    python3 bench_report.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import lint
import promptlib as p

HERE = Path(__file__).parent
BENCH = HERE / "out" / "bench"
MEETING = "20260812_144201"

# ячейка → (каталог, транскрипт, который эта ячейка видела)
CELLS = [
    ("A · qwen + сырой", "A", None),
    ("B · sonnet + сырой", "B", None),
    ("C · qwen + чинёный", "C", "transcript-repaired.md"),
    ("D · sonnet + чинёный", "D", "transcript-repaired.md"),
]

SHOWN = [
    "выдуманный участник", "ответственный-призрак", "срок не из транскрипта",
    "посчитанный срок", "имя не из транскрипта", "число не из транскрипта",
    "пассив", "канцелярит", "вода", "длинное предложение",
    "буллет * вместо -", "секция вне шаблона",
]


def main() -> int:
    _, raw = p.transcript(MEETING)
    rows = []
    for label, folder, transcript_name in CELLS:
        recap_path = BENCH / folder / "recap.md"
        if not recap_path.exists():
            print(f"{label}: нет {recap_path}")
            continue
        transcript = (BENCH / transcript_name).read_text(encoding="utf-8") if transcript_name else raw
        rows.append((label, lint.lint(recap_path.read_text(encoding="utf-8"), transcript, folder)))

    head = f"{'ячейка':24}{'слов':>6}{'реш':>5}{'зад':>5}{'находок':>9}"
    head += "".join(f"{lint.SHORT[c]:>7}" for c in SHOWN)
    print(head)
    print("-" * len(head))
    for label, rep in rows:
        row = f"{label:24}{rep.stats['слов']:6}{rep.stats['решений']:5}{rep.stats['задач']:5}"
        row += f"{len(rep.findings):9}"
        row += "".join(f"{rep.count(c) or '·':>7}" for c in SHOWN)
        print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
