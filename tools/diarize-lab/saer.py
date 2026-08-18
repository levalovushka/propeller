#!/usr/bin/env python3
"""SAER — доля времени дальней речи, ушедшей в ленте не тому человеку.

Зачем не DER. Диаризатор в этом пайплайне не решает, где речь: реплики приходят
от ASR, а `DiarizationMerge.speakerLabel(forMidpoint:)` берёт метку окна, внутрь
которого попала середина реплики, а если такого окна нет — ближайшего по центру
(`PropellerPure/PropellerPure.swift:205`). Значит «пропуск» и «ложная тревога»
из DER пайплайну ничего не стоят: метка находится всегда. Стоит ровно одно —
какая. SAER повторяет это правило буквально и меряет то, что человек видит в
ленте: секунды речи, подписанные чужим именем.

DER тоже считается — им сравнивают себя с опубликованными числами (probe der).

    python3 saer.py --ref ref/X.sys.ref.json --hyp out/X.base.json --utts asr/X.sys.utts.json
"""

from __future__ import annotations

import argparse
import json


def load_spans(path: str) -> list[dict]:
    data = json.load(open(path))
    return data["spans"] if isinstance(data, dict) else data


def label_for(midpoint: float, spans: list[dict]) -> str | None:
    """Метка окна — то же правило, что в `DiarizationMerge.speakerLabel`."""
    for s in spans:
        if s["start"] <= midpoint <= s["end"]:
            return s["speaker"]
    if not spans:
        return None
    return min(spans, key=lambda s: abs((s["start"] + s["end"]) / 2 - midpoint))["speaker"]


def best_mapping(pairs: list[tuple[str, str, float]]) -> dict[str, str]:
    """Жадное соответствие «кластер → человек» по общему времени.

    Жадность, а не венгерский алгоритм: кластеров единицы, а жадный выбор по
    убыванию совпадает с оптимумом всюду, где один кластер явно чей-то. Где не
    совпал бы, SAER только завысится — то есть в пользу «диаризация плоха»,
    а вывод здесь делается в обратную сторону.
    """
    weights: dict[tuple[str, str], float] = {}
    for cluster, person, seconds in pairs:
        weights[(cluster, person)] = weights.get((cluster, person), 0.0) + seconds
    mapping: dict[str, str] = {}
    taken: set[str] = set()
    for (cluster, person), _ in sorted(weights.items(), key=lambda kv: -kv[1]):
        if cluster in mapping or person in taken:
            continue
        mapping[cluster] = person
        taken.add(person)
    # Кластер, которому не досталось человека, всегда неправ — так и оставляем.
    return mapping


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", required=True)
    ap.add_argument("--hyp", required=True)
    ap.add_argument("--utts", required=True)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    ref = load_spans(args.ref)
    hyp = load_spans(args.hyp)
    utts = json.load(open(args.utts))

    scored: list[tuple[str, str, float]] = []
    for u in utts:
        mid = (u["start"] + u["end"]) / 2
        person = None
        for r in ref:
            if r["start"] <= mid <= r["end"]:
                person = r["speaker"]
                break
        if person is None:
            continue  # реплика вне размеченного — не в счёт
        cluster = label_for(mid, hyp) or "—"
        scored.append((cluster, person, u["end"] - u["start"]))

    mapping = best_mapping(scored)
    total = sum(s for _, _, s in scored)
    wrong = sum(s for c, p, s in scored if mapping.get(c) != p)
    people = sorted({p for _, p, _ in scored})
    clusters = sorted({c for c, _, _ in scored})

    print(f"  реплик размечено {len(scored)}, {total:.0f} с")
    print(f"  людей в эталоне {len(people)} {people}, кластеров на них {len(clusters)} {clusters}")
    print(f"  сопоставление: " + " ".join(f"{k}→{v}" for k, v in sorted(mapping.items())))
    print(f"  SAER {wrong / total * 100:.1f} %  ({wrong:.0f} с из {total:.0f})")

    if not args.quiet:
        per: dict[str, list[float]] = {}
        for c, p, s in scored:
            row = per.setdefault(p, [0.0, 0.0])
            row[0] += s
            if mapping.get(c) != p:
                row[1] += s
        for p, (tot, bad) in sorted(per.items(), key=lambda kv: -kv[1][0]):
            print(f"    {p:4} {tot:6.0f} с, не тому {bad:5.0f} с ({bad / tot * 100:.0f} %)")


if __name__ == "__main__":
    main()
