"""Проба C: разделяет ли механический скор заякоренности правду и конфабуляцию.

Скор — доля IDF-веса корней буллета, покрытая лучшей репликой транскрипта
(машинерия Regions из replay_asym, скопирована в problib). Эталоны:
  · конфабуляции — секционные буллеты gate/m3 с «Сафронов» (фамилии в
    транскрипте нет — проверяется кодом);
  · истина — секционные буллеты gate/m1 и gate/m2, на которых сработала
    якорная группа матчера (эти строки и принесли зачёт golden-пункта).

    python3 probes/probe_c.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import problib as pl


def section_bullets(recap: str) -> list[str]:
    items = pl.items_from_recap(recap)
    return [b for s in pl.SECTIONS for b in items[s]]


def main() -> int:
    # Сам факт конфабуляции: фамилии нет в транскрипте m3.
    m3 = "20260810_094722"
    turns_raw, _, _ = pl.parse_transcript(m3)
    assert "сафронов" not in pl.normalize("\n".join(turns_raw)), \
        "«Сафронов» найден в транскрипте — эталон конфабуляции не годится"
    print("проверка: «сафронов» в транскрипте m3 отсутствует — конфабуляция подтверждена")

    regions_m3 = pl.Regions(turns_raw)
    confab: list[tuple[float, str]] = []
    for path in pl.gate_runs("m3"):
        for bullet in section_bullets(path.read_text(encoding="utf-8")):
            if "сафронов" in pl.normalize(bullet):
                confab.append((regions_m3.groundedness(bullet), bullet))

    true_set: list[tuple[float, str]] = []
    for m in ("m1", "m2"):
        meeting = pl.GATE_MEETING[m]
        turns_raw, _, _ = pl.parse_transcript(meeting)
        regions = pl.Regions(turns_raw)
        for path in pl.gate_runs(m):
            for bullet in section_bullets(path.read_text(encoding="utf-8")):
                if pl.line_fires(pl.normalize(bullet), meeting):
                    true_set.append((regions.groundedness(bullet), bullet))

    def describe(name: str, rows: list[tuple[float, str]]) -> list[float]:
        scores = sorted(s for s, _ in rows)
        n = len(scores)
        q = lambda p: scores[min(n - 1, int(p * n))]
        print(f"{name:12} n={n:3}  min={scores[0]:.3f}  p25={q(0.25):.3f}  "
              f"med={q(0.5):.3f}  p75={q(0.75):.3f}  max={scores[-1]:.3f}")
        return scores

    print()
    c_scores = describe("конфабуляции", confab)
    t_scores = describe("истинные", true_set)

    theta = max(c_scores)
    accepted = sum(1 for s in t_scores if s > theta)
    print(f"\nпорог = max(конфабуляции) = {theta:.3f}")
    print(f"истинных строго выше порога: {accepted}/{len(t_scores)} "
          f"({accepted / len(t_scores) * 100:.0f} %), планка ≥80 %")

    # Полная картина разделимости: доля истинных выше каждого дециля конфабуляций.
    print("\nдоля конфабуляций отклонена → доля истинных принята:")
    for keep in (0.5, 0.75, 0.9, 1.0):
        idx = min(len(c_scores) - 1, int(keep * len(c_scores)) - 1)
        th = c_scores[idx]
        acc = sum(1 for s in t_scores if s > th) / len(t_scores)
        print(f"  отклонить {keep * 100:3.0f}% конфабуляций (порог {th:.3f}) → "
              f"принять {acc * 100:3.0f}% истинных")

    print("\nхвосты (для отчёта):")
    for s, b in sorted(confab, reverse=True)[:3]:
        print(f"  конфабуляция {s:.3f}: {b[:100]}…")
    for s, b in sorted(true_set)[:3]:
        print(f"  истина       {s:.3f}: {b[:100]}…")
    return 0


if __name__ == "__main__":
    sys.exit(main())
