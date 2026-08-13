"""Посчитать гейт по правилу, записанному до прогонов (A5.2, 2026-08-13).

Правило здесь не выбирается, а исполняется — оно зафиксировано в доске раньше, чем
появились данные, и параметры теста стоят в константах ниже, а не во флагах:

    единица       один прогон
    страта        встреча (три страты, по 8 + 8 прогонов)
    статистика    невзвешенное среднее по стратам разниц средних (code14 − база),
                  в пунктах покрытия
    перестановка  внутри страты, метки ячеек переставляются независимо в каждой
                  встрече; полное перечисление невозможно (C(16,8)³ ≈ 2 · 10¹²)
    Монте-Карло   100 000 жребиев, seed 20260813
    p             двусторонний (односторонняя доля × 2), как везде на доске

Точка проходит гейт, если: ≤14 буллетов · выдумки ≤ базы пулом · покрытие выше базы
с p < 5 % пулом И средняя разница не отрицательна ни на одной встрече отдельно.

`--old-matcher` считает то же самое матчером **до** починки свёртки `й` → `и`.
Починка поднимает ансамбль сильнее базы, то есть сделана в пользу проверяемой
гипотезы, поэтому вердикт обязан быть предъявлен в обоих видах: если он одинаков,
починка его не решала.

    python3 gate_score.py
    python3 gate_score.py --old-matcher
"""

from __future__ import annotations

import argparse
import random
import statistics
import sys
from pathlib import Path

import bench_ensemble as b
import golden_match as gm
import lint
import promptlib as p
import replay_asym as r

HERE = Path(__file__).parent

DRAWS = 100_000
SEED = 20260813
BUDGET = 14
# Встреча → каталог батча. Порядок фиксирован: он же порядок страт в выводе.
BATCHES = [
    ("20260812_144201", "out/gate2/m1"),
    ("20260812_153107", "out/gate2/m2"),
    ("20260810_094722", "out/gate2/m3"),
]


def old_normalize(text: str) -> str:
    """`normalize` до починки 2026-08-13: без свёртки `й` → `и`."""
    return text.lower().replace("ё", "е").replace("*", " ").replace("«", " ").replace("»", " ")


def cell(directory: Path, prefix: str, meeting: str, transcript: str) -> list[dict]:
    rows = []
    for run in sorted(directory.glob(f"{prefix}-*")):
        recap = (run / "recap.md")
        if not recap.exists():
            continue
        text = recap.read_text(encoding="utf-8")
        stats = {}
        stats_file = run / "stats.json"
        if stats_file.exists():
            import json
            stats = json.loads(stats_file.read_text(encoding="utf-8"))
        # У базы длина ответа одна, у ансамбля — по одной на ветку. В таблицу идёт
        # разброс по всем ветвям ячейки, как везде на доске: ячейка, где половина
        # ответов схлопнулась, — это не результат гипотезы, и без этой колонки
        # такого не видно (методика, правило 3).
        lengths = [stats["reply_tokens"]] if stats.get("reply_tokens") else []
        for branch in stats.get("branches") or []:
            if branch.get("reply_tokens"):
                lengths.append(branch["reply_tokens"])
        rows.append({
            "run": run.name,
            "coverage": gm.score(text, meeting),
            "bullets": r.bullets(text),
            "fabrications": r.fabrications(text, transcript),
            "tokens": lengths,
            "calls": stats.get("calls", 1),
            "seconds": stats.get("seconds", 0),
        })
    return rows


def stratified_p(strata: list[tuple[list[int], list[int]]]) -> tuple[float, float]:
    """Перестановка внутри страты, статистика — невзвешенное среднее разниц.

    Монте-Карло с фиксированным seed: полное перечисление невозможно, а без
    фиксации числа жребиев и seed тест был бы невоспроизводим.
    """
    observed = statistics.mean(statistics.mean(c) - statistics.mean(a) for a, c in strata)
    rng = random.Random(SEED)
    hits = 0
    pools = [(a + c, len(a)) for a, c in strata]
    for _ in range(DRAWS):
        total = 0.0
        for pool, n in pools:
            shuffled = pool[:]
            rng.shuffle(shuffled)
            total += statistics.mean(shuffled[n:]) - statistics.mean(shuffled[:n])
        if total / len(pools) >= observed - 1e-9:
            hits += 1
    return observed, min(1.0, 2 * hits / DRAWS)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--old-matcher", action="store_true",
                    help="считать матчером до починки свёртки й → и")
    args = ap.parse_args()

    if args.old_matcher:
        gm.normalize = old_normalize

    strata, report = [], []
    for meeting, directory in BATCHES:
        _, transcript = p.transcript(meeting)
        base = cell(HERE / directory, "base", meeting, transcript)
        code = cell(HERE / directory, "code", meeting, transcript)
        if not base or not code:
            print(f"нет ячеек в {directory}")
            return 1
        if len(base) != len(code):
            print(f"{directory}: ячейки разной длины — {len(base)} и {len(code)}, "
                  f"чередование нарушено")
            return 1
        strata.append(([x["coverage"] for x in base], [x["coverage"] for x in code]))
        report.append((meeting, len(gm.MEETINGS[meeting][0]), base, code))

    matcher = "матчер до починки" if args.old_matcher else "матчер починен"
    print(f"ГЕЙТ Г0 · правило записано 2026-08-13 до прогонов · {matcher}\n")
    for meeting, scale, base, code in report:
        print(f"встреча {meeting} · шкала {scale} · n={len(base)}")
        print(f"  {'ячейка':8} {'покрытие':26} {'среднее':>8} {'буллетов':>9} "
              f"{'выдумок':>8} {'вызовов':>8} {'reply_tokens':>14} {'сек':>6}")
        for name, rows in (("база", base), ("code14", code)):
            covers = sorted(x["coverage"] for x in rows)
            tokens = [t for x in rows for t in x["tokens"]]
            print(f"  {name:8} {' '.join(f'{c:2}' for c in covers):26} "
                  f"{statistics.mean(covers):8.1f} "
                  f"{statistics.mean(x['bullets'] for x in rows):9.1f} "
                  f"{statistics.mean(x['fabrications'] for x in rows):8.1f} "
                  f"{statistics.mean(x['calls'] for x in rows):8.1f} "
                  f"{min(tokens) if tokens else 0:6}–{max(tokens) if tokens else 0:<7} "
                  f"{statistics.mean(x['seconds'] for x in rows):6.0f}")
        diff = statistics.mean(x["coverage"] for x in code) - statistics.mean(
            x["coverage"] for x in base)
        print(f"  разница {diff:+.2f}\n")

    observed, pv = stratified_p(strata)
    per_meeting = [statistics.mean(c) - statistics.mean(a) for a, c in strata]

    pooled_base_fab = statistics.mean(x["fabrications"] for _, _, base, _ in report
                                      for x in base)
    pooled_code_fab = statistics.mean(x["fabrications"] for _, _, _, code in report
                                      for x in code)
    max_bullets = max(x["bullets"] for _, _, _, code in report for x in code)

    brevity = max_bullets <= BUDGET
    honesty = pooled_code_fab <= pooled_base_fab
    coverage = pv < 0.05 and all(d >= 0 for d in per_meeting)

    print("итог по трём условиям правила:\n")
    print(f"  1 краткость   ≤14 буллетов          макс {max_bullets}            "
          f"{'ДА' if brevity else 'НЕТ'}")
    print(f"  2 выдумки     ≤ базы пулом          {pooled_code_fab:.2f} против "
          f"{pooled_base_fab:.2f}   {'ДА' if honesty else 'НЕТ'}")
    print(f"  3 покрытие    p < 5 % пулом и ни одной отрицательной встречи")
    print(f"                среднее по стратам {observed:+.2f} · p = {pv * 100:.2f} % · "
          f"по встречам " + " ".join(f"{d:+.2f}" for d in per_meeting) +
          f"   {'ДА' if coverage else 'НЕТ'}")
    passed = brevity and honesty and coverage
    print(f"\nГЕЙТ {'ПРОЙДЕН' if passed else 'НЕ ПРОЙДЕН'}"
          f" ({DRAWS} жребиев, seed {SEED})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
