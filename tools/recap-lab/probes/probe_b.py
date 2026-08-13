"""Проба B: маркеры фиксации договорённости как ретривер решений/задач.

Словарь записан в PROBES.md ДО замера. Без модели и без матчера: только
golden-таймкоды и транскрипт. Время маркера = таймкод реплики.

    python3 probes/probe_b.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import problib as pl

# Зафиксировано в PROBES.md до замера. Подстроки по нормализованному тексту
# реплики (lower, ё→е, й→и) — той же нормализацией, что у матчера.
MARKERS = [
    "договорил", "договорим", "зафиксир", "фиксиру", "по рукам",
    "решили", "решено", "принято", "принимаем", "утвердил",
    "соидемся", "остановимся на", "сошлись на",
    "да, даваи", "да даваи", "даваи так", "так и сделаем", "так и оставим",
    "океи, тогда", "океи тогда", "ок, тогда", "хорошо, тогда", "ладно, тогда",
    "пусть будет", "тогда так", "значит так и",
    "согласен", "согласна", "поддержива", "договоренность",
]

WINDOW = 60          # окно покрытия вокруг маркера, ±сек
DELTAS = (30, 60)    # допуски recall


def marker_times(turns_raw: list[str], times: list[int | None]) -> list[tuple[int, str]]:
    hits: list[tuple[int, str]] = []
    for turn, t in zip(turns_raw, times):
        if t is None:
            continue
        norm = pl.normalize(turn)
        for marker in MARKERS:
            if marker in norm:
                hits.append((t, marker))
    return hits


def union_len(points: list[int], duration: int) -> int:
    spans = sorted((max(0, t - WINDOW), min(duration, t + WINDOW)) for t in points)
    total, cur_s, cur_e = 0, None, None
    for s, e in spans:
        if cur_e is None or s > cur_e:
            if cur_e is not None:
                total += cur_e - cur_s
            cur_s, cur_e = s, e
        else:
            cur_e = max(cur_e, e)
    if cur_e is not None:
        total += cur_e - cur_s
    return total


def main() -> int:
    grand = {d: [0, 0] for d in DELTAS}
    print(f"{'встреча':16} {'D+T':>4} " +
          " ".join(f"{'recall±' + str(d):>10}" for d in DELTAS) +
          f" {'маркеров':>9} {'окна ±60':>9}")
    for meeting in ("20260812_144201", "20260812_153107", "20260810_094722"):
        turns_raw, times, duration = pl.parse_transcript(meeting)
        hits = marker_times(turns_raw, times)
        points = [t for t, _ in hits]
        spans = pl.golden_spans(meeting)
        dt_items = {k: v for k, v in spans.items()
                    if k[0] in "DT" and v}
        rec = {}
        for d in DELTAS:
            got = sum(1 for intervals in dt_items.values()
                      if any(a - d <= t <= b + d for t in points
                             for a, b in intervals))
            rec[d] = (got, len(dt_items))
            grand[d][0] += got
            grand[d][1] += len(dt_items)
        cover = union_len(points, duration) / duration
        print(f"{meeting:16} {len(dt_items):4} " +
              " ".join(f"{rec[d][0]:>3}/{rec[d][1]:<3} {rec[d][0] / rec[d][1] * 100:3.0f}%"
                       for d in DELTAS) +
              f" {len(points):9} {cover * 100:8.1f}%")
    print(f"{'ИТОГО':16} {grand[DELTAS[0]][1]:4} " +
          " ".join(f"{g:>3}/{n:<3} {g / n * 100:3.0f}%" for g, n in
                   (grand[d] for d in DELTAS)))

    # Какие маркеры вообще стреляют — для отчёта.
    print("\nчастоты маркеров по трём встречам:")
    freq: dict[str, int] = {}
    for meeting in ("20260812_144201", "20260812_153107", "20260810_094722"):
        turns_raw, times, _ = pl.parse_transcript(meeting)
        for _, marker in marker_times(turns_raw, times):
            freq[marker] = freq.get(marker, 0) + 1
    for marker, n in sorted(freq.items(), key=lambda x: -x[1]):
        print(f"  {marker:20} {n}")
    dead = [m for m in MARKERS if m not in freq]
    print("  без срабатываний:", ", ".join(dead) if dead else "—")
    return 0


if __name__ == "__main__":
    sys.exit(main())
