"""Проба A: концентрируются ли промахи golden в непокрытых сегментах транскрипта.

Планка записана в PROBES.md ДО запуска. Без модели: сегменты по таймкодам
реплик (вариант — лексический TextTiling), покрытие — регионная машинерия
replay_asym (скопирована в problib), промахи — матчер golden_match (скопирован).

    python3 probes/probe_a.py
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import problib as pl

SPAN = 210          # сек на сегмент по таймкодам (~3,5 мин)
TT_WINDOW = 6       # реплик с каждой стороны границы (TextTiling)
TT_MIN_GAP = 4      # минимум реплик между границами


def time_segments(times: list[int | None], duration: int) -> list[tuple[int, int, set[int]]]:
    """Окна ~SPAN секунд, выровненные по началам реплик."""
    segs: list[tuple[int, int, set[int]]] = []
    start, members = None, set()
    for i, t in enumerate(times):
        if t is None:
            continue
        if start is None:
            start, members = t, {i}
            continue
        if t - start >= SPAN:
            segs.append((start, t, members))
            start, members = t, {i}
        else:
            members.add(i)
    if start is not None:
        segs.append((start, duration, members))
    return segs


def texttiling_segments(turns_raw: list[str], times: list[int | None],
                        duration: int) -> list[tuple[int, int, set[int]]]:
    """Лексический TextTiling по корням: границы в глубоких минимумах сходства."""
    stem_sets = [pl.stems(t) for t in turns_raw]
    n = len(stem_sets)
    sims: list[float] = []
    for gap in range(1, n):
        left = set().union(*stem_sets[max(0, gap - TT_WINDOW):gap])
        right = set().union(*stem_sets[gap:gap + TT_WINDOW])
        union = left | right
        sims.append(len(left & right) / len(union) if union else 0.0)

    def peak(idx: int, step: int) -> float:
        best = sims[idx]
        j = idx + step
        while 0 <= j < len(sims) and sims[j] >= best:
            best = sims[j]
            j += step
        return best

    depths = [(peak(i, -1) - s) + (peak(i, +1) - s) for i, s in enumerate(sims)]
    mean = sum(depths) / len(depths)
    sd = math.sqrt(sum((d - mean) ** 2 for d in depths) / len(depths))
    cut = mean + sd / 2
    bounds: list[int] = []
    for i, d in sorted(enumerate(depths), key=lambda x: -x[1]):
        if d < cut:
            break
        gap = i + 1
        if all(abs(gap - b) >= TT_MIN_GAP for b in bounds):
            bounds.append(gap)
    bounds.sort()
    segs: list[tuple[int, int, set[int]]] = []
    prev = 0
    for b in bounds + [n]:
        members = set(range(prev, b))
        start = min((times[i] for i in members if times[i] is not None), default=0)
        ends = [times[i] for i in range(b, n) if times[i] is not None]
        end = ends[0] if ends else duration
        segs.append((start, end, members))
        prev = b
    return segs


def covered_segments(recap: str, regions: pl.Regions,
                     segs: list[tuple[int, int, set[int]]]) -> list[bool]:
    anchored: set[int] = set()
    for line in pl.claim_lines(recap):
        anchored |= regions.of(line)
    return [bool(members & anchored) for _, _, members in segs]


def item_uncovered(intervals: list[tuple[int, int]],
                   segs: list[tuple[int, int, set[int]]],
                   covered: list[bool]) -> bool | None:
    """Пункт «в дыре», если больше половины задетых сегментов непокрыты."""
    touched = [k for k, (s, e, _) in enumerate(segs)
               if any(a < e and b >= s for a, b in intervals)]
    if not touched:
        return None
    unc = sum(1 for k in touched if not covered[k])
    return unc * 2 > len(touched)


def run(seg_fn_name: str) -> None:
    print(f"\n=== сегментация: {seg_fn_name} ===")
    pooled = {True: [0, 0], False: [0, 0]}   # uncovered? -> [промахи, всего]
    unc_shares: list[float] = []
    batches: dict[str, dict] = {}

    cache: dict[str, tuple] = {}
    for label, meeting, path in pl.all_cells_a():
        if meeting not in cache:
            turns_raw, times, duration = pl.parse_transcript(meeting)
            regions = pl.Regions(turns_raw)
            segs = (time_segments(times, duration) if seg_fn_name == "time"
                    else texttiling_segments(turns_raw, times, duration))
            cache[meeting] = (regions, segs, pl.golden_spans(meeting))
        regions, segs, spans = cache[meeting]

        recap = path.read_text(encoding="utf-8")
        covered = covered_segments(recap, regions, segs)
        unc_share = covered.count(False) / len(covered)
        unc_shares.append(unc_share)

        hits = pl.found(recap, meeting)
        batch = label.split("/")[0] if label.startswith("asym") else "/".join(label.split("/")[:2])
        b = batches.setdefault(batch, {"cells": 0, "unc": 0.0,
                                       True: [0, 0], False: [0, 0], "skipped": 0})
        b["cells"] += 1
        b["unc"] += unc_share
        for item, intervals in spans.items():
            if not intervals:
                b["skipped"] += 1
                continue
            where = item_uncovered(intervals, segs, covered)
            if where is None:
                b["skipped"] += 1
                continue
            missed = not hits[item]
            b[where][0] += int(missed)
            b[where][1] += 1
            pooled[where][0] += int(missed)
            pooled[where][1] += 1

    print(f"{'батч':14} {'ячеек':>5} {'непокр.%':>9} {'в дырах: промах/всего':>22} "
          f"{'вне дыр: промах/всего':>22} {'обогащение':>11}")
    rows = list(batches.items()) + [("ИТОГО", {
        "cells": sum(b["cells"] for b in batches.values()),
        "unc": sum(b["unc"] for b in batches.values()),
        True: pooled[True], False: pooled[False]})]
    for name, b in rows:
        mu, nu = b[True]
        mc, nc = b[False]
        rate_u = mu / nu if nu else float("nan")
        rate_c = mc / nc if nc else float("nan")
        enrich = (rate_u / rate_c) if nc and nu and rate_c > 0 else float("inf") if nu and rate_u > 0 else float("nan")
        print(f"{name:14} {b['cells']:5} {b['unc'] / b['cells'] * 100:8.1f}% "
              f"{f'{mu}/{nu}':>16} ({rate_u * 100 if nu else 0:4.0f}%) "
              f"{f'{mc}/{nc}':>16} ({rate_c * 100 if nc else 0:4.0f}%) "
              f"{enrich:11.2f}")
    mu, nu = pooled[True]
    mc, nc = pooled[False]
    print(f"\nсредняя доля непокрытых сегментов: {sum(unc_shares) / len(unc_shares) * 100:.1f} % "
          f"(планка ≤40 %)")
    if nu == 0:
        print("в дырах не оказалось ни одного пункта — предиктор ничего не предсказывает")


def main() -> int:
    run("time")
    run("texttiling")
    return 0


if __name__ == "__main__":
    sys.exit(main())
