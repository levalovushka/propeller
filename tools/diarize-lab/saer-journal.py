#!/usr/bin/env python3
"""SAER журнала наблюдателя — против того же эталона и в тех же терминах,
что и диаризация (`saer.py`), плюс два числа из plan-speaker-tags.md §9,
которых у диаризации нет: покрытие и честность.

Отличие от `saer.py` — намеренное и одно. Для диаризации метка находится
всегда (нет накрывающего окна — берётся ближайшее), потому что так делает
прод. Журнал наблюдателя устроен иначе: молчание — законный ответ, и в
проде промолчанные секунды уходят диаризации, а не ближайшему пролёту
журнала. Поэтому здесь реплика получает имя только от НАКРЫВАЮЩЕГО пролёта;
непокрытая реплика — не ошибка, а «наблюдатель промолчал», и она считается
отдельно. С `--fallback` (out/<id>.base.json диаризации) промолчанные
реплики получают метку диаризации по её обычному правилу — это сквозное
число, которое сравнивается с сегодняшними 2,7 % (ГПН) и 7,8 % (160113).

Журнал получается из трассы шипованным решением, а не копией его логики:

    cd meeting-recorder/swift
    swift run -c release CallWindowJournalLab трасса.jsonl > /tmp/journal.json
    python3 tools/diarize-lab/saer-journal.py \
        --journal /tmp/journal.json \
        --ref ref/<id>.sys.ref.json --utts utts/<id>.sys.utts.json \
        [--fallback out/<id>.base.json]

Ограничение, названное вслух (§11.1 шаг 3): считать можно только по встрече,
на которую сняты И трасса, И эталон. На 2026-08-19 такой пары не существует —
эталоны есть у двух встреч без трасс, трасс с живых встреч нет ни одной.
Скрипт написан до данных, чтобы данные было куда положить.
"""

from __future__ import annotations

import argparse
import json

from saer import best_mapping, label_for, load_spans


def covering_label(midpoint: float, spans: list[dict]) -> str | None:
    """Только накрывающий пролёт — без отката к ближайшему."""
    for s in spans:
        if s["start"] <= midpoint <= s["end"]:
            return s["speaker"]
    return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--journal", required=True, help="spans из CallWindowJournalLab")
    ap.add_argument("--ref", required=True)
    ap.add_argument("--utts", required=True)
    ap.add_argument("--fallback", help="out/<id>.base.json — диаризация для промолчанных секунд")
    args = ap.parse_args()

    journal = load_spans(args.journal)
    ref = load_spans(args.ref)
    utts = json.load(open(args.utts))
    fallback = load_spans(args.fallback) if args.fallback else None

    named: list[tuple[str, str, float]] = []      # (имя из журнала, человек, секунды)
    silent: list[tuple[str, float]] = []          # (человек, секунды) — журнал промолчал
    for u in utts:
        mid = (u["start"] + u["end"]) / 2
        person = next((r["speaker"] for r in ref if r["start"] <= mid <= r["end"]), None)
        if person is None:
            continue  # реплика вне размеченного — не в счёт, как в saer.py
        seconds = u["end"] - u["start"]
        name = covering_label(mid, journal)
        if name is None:
            silent.append((person, seconds))
        else:
            named.append((name, person, seconds))

    total = sum(s for _, _, s in named) + sum(s for _, s in silent)
    if total == 0:
        print("  в эталоне не нашлось ни одной реплики — считать нечего")
        return

    covered = sum(s for _, _, s in named)
    print(f"  реплик размечено {len(named) + len(silent)}, {total:.0f} с")
    print(f"  покрытие: журнал назвал {covered / total * 100:.1f} % секунд ({covered:.0f} с)")
    print(f"  честность: промолчал {100 - covered / total * 100:.1f} % ({total - covered:.0f} с)")

    if named:
        mapping = best_mapping(named)
        wrong = sum(s for n, p, s in named if mapping.get(n) != p)
        print(f"  сопоставление: " + " ".join(f"{k}→{v}" for k, v in sorted(mapping.items())))
        print(f"  SAER по названным секундам {wrong / covered * 100:.1f} % ({wrong:.0f} с из {covered:.0f})")
    else:
        print("  журнал не назвал ни секунды — SAER по названным не определён")

    if fallback is not None:
        # Сквозной счёт: названные секунды — журналом, промолчанные — диаризацией
        # по её правилу (с откатом к ближайшему окну, как в проде).
        fb_scored = list(named)
        for u in utts:
            mid = (u["start"] + u["end"]) / 2
            person = next((r["speaker"] for r in ref if r["start"] <= mid <= r["end"]), None)
            if person is None or covering_label(mid, journal) is not None:
                continue
            fb_scored.append((label_for(mid, fallback) or "—", person, u["end"] - u["start"]))
        fb_mapping = best_mapping(fb_scored)
        fb_wrong = sum(s for c, p, s in fb_scored if fb_mapping.get(c) != p)
        print(f"  СКВОЗНОЙ SAER (журнал + диаризация на промолчанном) "
              f"{fb_wrong / total * 100:.1f} % ({fb_wrong:.0f} с из {total:.0f}) — "
              f"сравнивать с 2,7 % (ГПН) и 7,8 % (160113)")


if __name__ == "__main__":
    main()
