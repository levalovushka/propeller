"""Материализовать пересборку гейта №2: файлы, а не память.

Зачем это отдельный шаг. `check_defects.py` пересобирал ячейку **в памяти** и тут же
её мерил — на диске не оставалось ничего. Пере-суд (`judge/JUDGE-2.md`), не получив
пути к починенным ячейкам, взял единственную папку прогонов, `out/gate2`, то есть
живые прогоны **до** починки, и измерил старую сборку второй раз. Отчёт при этом
верный; неверен был корпус, который ему достался.

Здесь пересборка кладётся на диск в той же раскладке, что и гейт:

    out/gate2-fixed/{m1,m2,m3}/{base,code}-{1..8}/recap.md

`code`-ячейки пересобираются `replay_asym.replay(code14)` — ноль вызовов модели, тот
же черновик, что в живом прогоне (`draft_branch` из `stats.json`). `base`-ячейки —
один ответ модели, они не проходят через `bench_ensemble.render` вообще, поэтому
чинить в них нечего и они копируются дословно; об этом сказано в README папки, чтобы
следующий судья не принял копию за пересборку.

Ветки и `stats.json` копируются рядом: без них по новой папке нельзя прогнать
`check_defects` с пересборкой, то есть нельзя проверить, что рендер — неподвижная
точка (пересборка починенного даёт его же).

    python3 materialize.py                     # out/gate2 → out/gate2-fixed
    python3 materialize.py --batch gate --out gate-fixed
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

import check_defects as cd
import owners
import promptlib as p

HERE = Path(__file__).parent

README = """# Пересборка гейта №2 починенным кодом

Раскладка один в один с `out/gate2`. Собрано `materialize.py`, **ноль вызовов
модели**: `code`-ячейки прогнаны через `replay_asym.replay(code14)` с тем же
черновиком, что в живом прогоне, `base`-ячейки скопированы дословно.

| что | ячеек | recap.md |
|---|---|---|
| `code-*` | {code} | **пересобран** починенным кодом |
| `base-*` | {base} | **копия** `out/gate2`, байт в байт |

**Почему база копируется, а не пересобирается.** Ячейка `base` — это один ответ
модели на один промпт. Она не проходит через `bench_ensemble.render`, а все четыре
починки (слияние прозы, разбор меток экстрактора, фильтр слота исполнителя, фильтр
артефактов генерации) живут в сборке ансамбля и в рендере. Пересобирать нечего: у
базы нет ни ветвей, ни сборки. Поэтому её дефекты остаются на месте — и именно в
таком виде она и есть точка сравнения.

`branch-*.md`, `stats.json`, `system.txt`, `user.txt` скопированы рядом, чтобы по
этой папке можно было прогнать пересборку ещё раз:

    python3 check_defects.py --batch {out}

Столбец «до» здесь — уже починенные файлы, столбец «после» — их повторная
пересборка. Они обязаны совпасть: рендер — неподвижная точка.
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", default="gate2", help="каталог-источник в out/")
    ap.add_argument("--out", default=None, help="каталог-приёмник, по умолчанию <batch>-fixed")
    args = ap.parse_args()

    source = HERE / "out" / args.batch
    target = HERE / "out" / (args.out or f"{args.batch}-fixed")
    if not source.is_dir():
        print(f"нет такого батча: {source}")
        return 1
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target)

    rebuilt, copied = 0, 0
    for short, meeting in cd.MEETINGS.items():
        _, transcript = p.transcript(meeting)
        names = owners.Names.of(transcript)
        for run in sorted((target / short).glob("*")):
            if not (run / "recap.md").exists():
                continue
            if not (run / "branch-1-t0.md").exists():
                copied += 1
                continue
            recap = cd.rebuild(run, transcript, meeting, names)
            (run / "recap.md").write_text(recap, encoding="utf-8")
            rebuilt += 1

    (target / "README.md").write_text(
        README.format(code=rebuilt, base=copied, out=target.name), encoding="utf-8")
    print(f"out/{target.name}: пересобрано {rebuilt}, скопировано {copied}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
