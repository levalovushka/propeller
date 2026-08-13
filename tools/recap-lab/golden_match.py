"""Есть ли договорённость в конспекте — механически, чтобы это можно было мерить.

Полнота — единственная метрика, которая пережила шум (число слов гуляет вдвое,
число найденных решений держится). Но считать её руками — час на ячейку, и
из-за этого замер упирался в разметку, а не в модели.

Здесь каждому пункту golden сопоставлены **якоря**: наборы слов, которые
обязаны встретиться в ОДНОЙ строке конспекта. Строка, а не документ: «Fast Play»
и «Discovery» порознь есть почти в каждом конспекте, и матчер по документу
находил бы всё подряд.

Матчер не заменяет разметку, он её **воспроизводит**: `--calibrate` сверяет его
с 84 оценками, проставленными вручную по шести ячейкам встречи 20260812_144201.
Пока сверка не сходится, числам матчера верить нельзя — и он об этом говорит.

    python3 golden_match.py --calibrate
    python3 golden_match.py out/bench/A/recap.md
    python3 golden_match.py --dir out/sweep-13k
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).parent

# пункт → список групп; группа найдена, если ВСЕ её слова есть в одной строке.
# Слова сравниваются по вхождению подстроки в нормализованную строку (ё→е,
# нижний регистр), поэтому корни пишутся без окончаний.
# Якоря заужены после первой сверки: пять из восьми расхождений были
# срабатываниями на «Итоге» — длинной строке, где нужные слова стоят рядом
# случайно. Поэтому там, где пункт — это *противопоставление* или *спор*,
# в группу входит и слово, которое его несёт.
ANCHORS: dict[str, list[list[str]]] = {
    "D1": [["главн", "прост", "структур"], ["прост", "визуальн", "структур"],
           ["карточк артист"], ["главн", "не перегру"]],
    "D2": [["три", "задач"], ["три", "цел"], ["поиск", "за скобк"], ["три", "функц"]],
    "D3": [["затянуть", "fast play"], ["затянуть во fast play"], ["fast play", "а не"],
           ["фаст", "а не"], ["не", "discovery", "главн"], ["дискавери", "а не"]],
    "D4": [["облегч"], ["одна строка"], ["одну строку"], ["однои строки"],
           ["вместо трех"], ["вместо трёх"]],
    # D5 и Q1 — про одну и ту же первую треть экрана: договорённость и
    # незакрытый вопрос о ней. Различить их механически нельзя, и в ручной
    # разметке они совпадают во всех шести ячейках, поэтому якоря у них общие.
    "D5": [["верхн", "треть"], ["первои трети"], ["первую треть"], ["первыи вьюпорт"],
           ["вьюпорт"], ["трети экрана"], ["треть экрана"], ["треть главнои"]],
    "D6": [["vk микс", "одна из"], ["вк микс", "одна из"], ["vk mix", "одна из"],
           ["vk-микс", "одна из"], ["точек входа"], ["точки входа", "fast play"]],
    "D7": [["три уровн"], ["трех уровн"], ["трёх уровн"], ["три сценар"],
           ["уровня взаимодеис"], ["уровнеи взаимодеис"], ["радио", "погружен"]],
    "D8": [["подстрочник", "discovery"], ["подстрочник", "треть"], ["rich", "discovery"],
           ["рич", "дискавери"], ["подстрочник", "дискавери"]],
    "D9": [["длинн", "имен"], ["длинными", "артист"], ["выдержив", "текст"],
           ["имена", "артист", "длин"]],
    "T1": [["итерац"], ["следующ", "макет"]],
    "T2": [["шум", "подчист"], ["убрать", "шум"], ["лишн", "шум"], ["визуальныи шум"]],
    "Q1": [["верхн", "треть"], ["первои трети"], ["первую треть"], ["первыи вьюпорт"],
           ["вьюпорт"], ["трети экрана"], ["треть экрана"], ["треть главнои"]],
    "Q2": [["сильного акцента"], ["один ярк"], ["ярк", "якор"], ["нет", "акцент"],
           ["много вещеи"]],
    "Q3": [["весь кластер"], ["целыи кластер"], ["целого кластера"], ["кластер целиком"],
           ["микро-выбор"], ["микровыбор"], ["не", "выбира", "трек"],
           ["без выбора", "трек"], ["не думать", "выбор"], ["не", "думать", "трек"]],
}

# «Итог» — пересказ, а не место, где живёт договорённость: это одна длинная
# строка, в которой нужные слова оказываются рядом случайно. Пять ложных
# срабатываний из семи при сверке пришлись именно на неё.
SKIP_SECTIONS = {"итог"}

ITEMS = list(ANCHORS)

# Ручная разметка: 1 — пункт в конспекте есть (в таблице `+` или `~`), 0 — нет.
# Отсюда матчер и проверяется; менять эти числа можно только **перечитав
# конспект**, и три оценки так и были исправлены при первой сверке 2026-08-13:
#
#   d/D6 — стояла 1, но пункт был отмечен по повтору `B-b`, а в самом файле `B`
#          его нет. Ошибка бухгалтерии, не модели.
#   c/Q1 — стояла 1 щедро: открытый вопрос 9b про второй уровень, а не про
#          первую треть экрана.
#   e/D7 — стояла 1 щедро: трёх уровней в этом конспекте нет, есть один
#          «уровень вовлечённости» мимоходом.
#   e/D2 — стояла 1 по «Итогу», а он пересказ. Отсюда общее правило разметки:
#          **пункт засчитывается только вне «Итога»**. Иначе конспект, который
#          ничего не разобрал, но бойко пересказал, получает те же баллы.
HAND: dict[str, dict[str, int]] = {
    #        4b 7b 9b son 4b+ son+
    "D1": dict(zip("abcdef", [0, 0, 1, 1, 0, 1])),
    "D2": dict(zip("abcdef", [1, 1, 1, 1, 0, 1])),
    "D3": dict(zip("abcdef", [1, 1, 1, 1, 0, 1])),
    "D4": dict(zip("abcdef", [1, 1, 1, 1, 1, 1])),
    "D5": dict(zip("abcdef", [0, 0, 0, 1, 0, 1])),
    "D6": dict(zip("abcdef", [0, 0, 0, 0, 0, 1])),
    "D7": dict(zip("abcdef", [1, 1, 1, 1, 0, 1])),
    "D8": dict(zip("abcdef", [1, 1, 1, 1, 1, 1])),
    "D9": dict(zip("abcdef", [1, 0, 1, 1, 1, 1])),
    "T1": dict(zip("abcdef", [1, 1, 1, 1, 1, 1])),
    "T2": dict(zip("abcdef", [0, 0, 0, 1, 0, 1])),
    "Q1": dict(zip("abcdef", [0, 0, 0, 1, 0, 1])),
    "Q2": dict(zip("abcdef", [0, 0, 0, 1, 0, 1])),
    "Q3": dict(zip("abcdef", [0, 1, 1, 1, 1, 1])),
}

HAND_CELLS = {
    "a": ("out/bench/A/recap.md", "qwen3.5:4b"),
    "b": ("out/bench/7b-raw-a/recap.md", "qwen2.5:7b"),
    "c": ("out/bench/9b-raw-a/recap.md", "qwen3.5:9b"),
    "d": ("out/bench/B/recap.md", "sonnet"),
    "e": ("out/bench/C/recap.md", "qwen3.5:4b чинёный"),
    "f": ("out/bench/D/recap.md", "sonnet чинёный"),
}


def normalize(text: str) -> str:
    return text.lower().replace("ё", "е").replace("*", " ").replace("«", " ").replace("»", " ")


def claim_lines(recap: str) -> list[str]:
    """Строки, в которых договорённость может стоять: всё, кроме «Итога»."""
    lines, skipping = [], False
    for line in recap.split("\n"):
        heading = re.match(r"^##\s+(.+?)\s*$", line)
        if heading:
            skipping = heading.group(1).strip().lower() in SKIP_SECTIONS
            continue
        if not skipping and line.strip():
            lines.append(normalize(line))
    return lines


def found(recap: str) -> dict[str, bool]:
    lines = claim_lines(recap)
    result = {}
    for item, groups in ANCHORS.items():
        result[item] = any(
            all(word in line for word in group)
            for group in groups
            for line in lines
        )
    return result


def score(recap: str) -> int:
    return sum(found(recap).values())


def calibrate() -> int:
    print("сверка матчера с ручной разметкой (84 оценки)\n")
    head = f"{'пункт':6}" + "".join(f"{k:>4}" for k in HAND_CELLS)
    print(head + "   расхождения")
    wrong = 0
    per_cell = {k: 0 for k in HAND_CELLS}
    for item in ITEMS:
        row = f"{item:6}"
        notes = []
        for key, (path, _) in HAND_CELLS.items():
            got = int(found((HERE / path).read_text(encoding="utf-8"))[item])
            want = HAND[item][key]
            row += f"{('да' if got else '—'):>4}"
            if got != want:
                wrong += 1
                per_cell[key] += 1
                notes.append(f"{key}: матчер {got}, рука {want}")
        print(row + "   " + "; ".join(notes))
    total = len(ITEMS) * len(HAND_CELLS)
    print(f"\nсовпало {total - wrong} из {total} ({(total - wrong) / total * 100:.0f} %)")
    if wrong:
        print("по ячейкам:", {k: v for k, v in per_cell.items() if v})
    return 0 if wrong <= 4 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("recap", nargs="?", type=Path)
    ap.add_argument("--dir", type=Path, default=None, help="каталог с recap.md внутри подкаталогов")
    ap.add_argument("--calibrate", action="store_true")
    args = ap.parse_args()

    if args.calibrate:
        return calibrate()
    if args.recap:
        hit = found(args.recap.read_text(encoding="utf-8"))
        print(f"{sum(hit.values())}/{len(ITEMS)}: " + " ".join(k for k, v in hit.items() if v))
        return 0
    if args.dir:
        base = args.dir if args.dir.is_absolute() else HERE / args.dir
        for path in sorted(base.glob("*/recap.md")):
            hit = found(path.read_text(encoding="utf-8"))
            print(f"{path.parent.name:24} {sum(hit.values()):2}/{len(ITEMS)}  "
                  + " ".join(k for k, v in hit.items() if v))
        return 0
    ap.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
