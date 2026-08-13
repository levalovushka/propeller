#!/usr/bin/env python3
"""Decode the blinding and compare the semantic judge with the mechanical matcher.

Reads judge/mapping.json and judge/verdicts/**, re-runs the matcher read-only
(`python3 golden_match.py <recap> --meeting <id>`) on all 48 originals, and
prints every number quoted in JUDGE.md.
"""
from __future__ import annotations

import json
import re
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
MEETING_ID = {"m1": "20260812_144201", "m2": "20260812_153107", "m3": "20260810_094722"}


def matcher_hits(recap: Path, meeting_id: str) -> set[str]:
    out = subprocess.run(
        [sys.executable, "golden_match.py", str(recap), "--meeting", meeting_id],
        cwd=LAB, capture_output=True, text=True, check=True,
    ).stdout.strip()
    # "8/14: D2 D4 D6 D7 D8 T1 T2 Q3"
    head, _, tail = out.partition(":")
    got, _, total = head.partition("/")
    return set(tail.split()), int(got), int(total)


def main() -> int:
    mapping = json.loads((HERE / "mapping.json").read_text(encoding="utf-8"))["cells"]

    rows = []           # one per cell
    for meeting in ("m1", "m2", "m3"):
        for blind, cell in sorted(mapping[meeting].items()):
            v = json.loads((HERE / "verdicts" / meeting / f"{blind}.json").read_text(encoding="utf-8"))
            recap = LAB / "out" / "gate" / meeting / cell / "recap.md"
            hits, got, total = matcher_hits(recap, MEETING_ID[meeting])
            construction = cell.split("-")[0]
            rows.append({
                "meeting": meeting, "blind": blind, "cell": cell,
                "construction": construction,
                "items": v["items"], "hits": hits, "n_items": total,
                "readability": v["readability"],
                "contradictions": v.get("contradictions", []),
                "missing": v.get("missing_from_golden", []),
            })
            assert set(v["items"]) >= hits, f"{meeting}/{cell}: matcher item outside rubric"

    # ---------- 1. per-item agreement judge vs matcher ----------
    print("== Попунктное согласие судья↔матчер ==")
    print(f"{'':4} {'ячеек':>6} {'пунктов':>8} {'совпало':>8} {'согласие':>9}  "
          f"{'матчер да / судья не-ok':>24} {'матчер нет / судья ok':>22}")
    agreement = {}
    for meeting in ("m1", "m2", "m3"):
        sub = [r for r in rows if r["meeting"] == meeting]
        tot = same = fp = fn = 0
        for r in sub:
            for key, val in r["items"].items():
                judge_yes = val["v"] == "ok"
                match_yes = key in r["hits"]
                tot += 1
                if judge_yes == match_yes:
                    same += 1
                elif match_yes:
                    fp += 1
                else:
                    fn += 1
        agreement[meeting] = same / tot
        print(f"{meeting:4} {len(sub):6} {tot:8} {same:8} {same/tot:8.1%}  {fp:24} {fn:22}")

    # ---------- 2. base vs code ----------
    print("\n== base ↔ code ==")
    print(f"{'':4} {'судья: ok/ячейку':>28} {'матчер: пунктов/ячейку':>30} {'знак':>10}")
    signs = {}
    for meeting in ("m1", "m2", "m3"):
        line = [meeting]
        stats = {}
        for who in ("judge", "matcher"):
            vals = {}
            for c in ("base", "code"):
                sub = [r for r in rows if r["meeting"] == meeting and r["construction"] == c]
                if who == "judge":
                    vals[c] = statistics.mean(
                        sum(1 for v in r["items"].values() if v["v"] == "ok") for r in sub)
                else:
                    vals[c] = statistics.mean(len(r["hits"]) for r in sub)
            stats[who] = vals
        dj = stats["judge"]["code"] - stats["judge"]["base"]
        dm = stats["matcher"]["code"] - stats["matcher"]["base"]
        signs[meeting] = (dj, dm)
        agree = "совпал" if (dj > 0) == (dm > 0) else "РАЗОШЁЛСЯ"
        print(f"{meeting:4} base {stats['judge']['base']:5.2f} → code {stats['judge']['code']:5.2f} "
              f"({dj:+5.2f})   base {stats['matcher']['base']:5.2f} → code {stats['matcher']['code']:5.2f} "
              f"({dm:+5.2f})   {agree}")

    # ---------- 3. matcher counted it, judge says distorted ----------
    print("\n== Слепые пятна якорей: матчер зачёл, судья говорит «искажено» ==")
    blind_spots = defaultdict(list)
    for r in rows:
        for key, val in r["items"].items():
            if val["v"] == "distorted" and key in r["hits"]:
                blind_spots[val.get("class", "?")].append(
                    (r["meeting"], r["cell"], key, val.get("why", "")))
    for cls, items in sorted(blind_spots.items()):
        print(f"\n-- {cls} ({len(items)}) --")
        for meeting, cell, key, why in items:
            print(f"   {meeting}/{cell:8} {key:4} {why}")
    n_dist = sum(1 for r in rows for v in r["items"].values() if v["v"] == "distorted")
    print(f"\nвсего искажений: {n_dist}; из них матчер зачёл: "
          f"{sum(len(v) for v in blind_spots.values())}")

    # ---------- 4. task attribution ----------
    print("\n== Атрибуция задач (T-пункты, не absent) ==")
    print(f"{'':4} {'констр':>7} {'T-пунктов':>10} {'owner ok':>9} {'wrong':>7} {'absent':>7} {'wrong %':>8}")
    for meeting in ("m1", "m2", "m3"):
        for c in ("base", "code"):
            sub = [r for r in rows if r["meeting"] == meeting and r["construction"] == c]
            tally = defaultdict(int)
            for r in sub:
                for key, val in r["items"].items():
                    if key.startswith("T") and val["v"] != "absent":
                        tally[val.get("owner", "absent")] += 1
            n = sum(tally.values())
            print(f"{meeting:4} {c:>7} {n:10} {tally['ok']:9} {tally['wrong']:7} "
                  f"{tally['absent']:7} {(tally['wrong']/n if n else 0):7.0%}")
    print("\n-- то же по срокам (due) --")
    for meeting in ("m1", "m2", "m3"):
        for c in ("base", "code"):
            sub = [r for r in rows if r["meeting"] == meeting and r["construction"] == c]
            tally = defaultdict(int)
            for r in sub:
                for key, val in r["items"].items():
                    if key.startswith("T") and val["v"] != "absent":
                        tally[val.get("due", "absent")] += 1
            n = sum(v for k, v in tally.items() if k != "n/a")
            print(f"{meeting:4} {c:>7} due ok {tally['ok']:3} wrong {tally['wrong']:3} "
                  f"absent {tally['absent']:3} n/a {tally['n/a']:3}"
                  + (f"   wrong {tally['wrong']/n:.0%}" if n else ""))

    # ---------- 5. readability ----------
    print("\n== Читаемость (1–5) ==")
    for meeting in ("m1", "m2", "m3"):
        line = [meeting]
        for c in ("base", "code"):
            sub = [r for r in rows if r["meeting"] == meeting and r["construction"] == c]
            vals = [r["readability"] for r in sub]
            line.append(f"{c} {statistics.mean(vals):.2f} {sorted(vals)}")
        print("  ".join(line))
    for c in ("base", "code"):
        vals = [r["readability"] for r in rows if r["construction"] == c]
        print(f"весь корпус {c}: {statistics.mean(vals):.2f}")

    # ---------- 6. contradictions volume ----------
    print("\n== Противоречий транскрипту на ячейку ==")
    for meeting in ("m1", "m2", "m3"):
        for c in ("base", "code"):
            sub = [r for r in rows if r["meeting"] == meeting and r["construction"] == c]
            print(f"{meeting} {c:>5}: {statistics.mean(len(r['contradictions']) for r in sub):.2f}")

    # ---------- 7. per-item hit rates, judge vs matcher ----------
    print("\n== Попунктно: судья ok / матчер да (из 16 ячеек) ==")
    for meeting in ("m1", "m2", "m3"):
        sub = [r for r in rows if r["meeting"] == meeting]
        keys = list(sub[0]["items"])
        print(f"\n{meeting}: {'пункт':6} {'судья ok':>9} {'матчер':>7} {'расх.':>6}")
        for key in keys:
            j = sum(1 for r in sub if r["items"][key]["v"] == "ok")
            m = sum(1 for r in sub if key in r["hits"])
            flag = "  <<<" if abs(j - m) >= 6 else ""
            print(f"   {key:6} {j:9} {m:7} {j-m:+6}{flag}")

    # ---------- 8. raw table ----------
    print("\n== Ячейки ==")
    print(f"{'blind':10} {'cell':8} {'судья ok':>9} {'матчер':>7} {'читаем.':>8}")
    for r in rows:
        j = sum(1 for v in r["items"].values() if v["v"] == "ok")
        print(f"{r['meeting']}/{r['blind']:8} {r['cell']:8} {j:9} {len(r['hits']):7} {r['readability']:8}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
