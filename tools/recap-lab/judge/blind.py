#!/usr/bin/env python3
"""Blind the gate corpus for independent semantic judging.

Copies out/gate/<meeting>/<construction>-<run>/recap.md to
judge/blind/<meeting>/cell-NN.md under a random permutation drawn
separately for each meeting, and records the correspondence in
judge/mapping.json.

The meeting stays visible (the judge needs its transcript and its golden
markup); the construction does not. Run once, then do not read
mapping.json until every verdict is written.
"""
from __future__ import annotations

import json
import os
import random
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
GATE = LAB / "out" / "gate"
BLIND = HERE / "blind"
MAPPING = HERE / "mapping.json"

MEETINGS = {
    "m1": "20260812_144201",
    "m2": "20260812_153107",
    "m3": "20260810_094722",
}


def main() -> int:
    if MAPPING.exists():
        print(f"refusing to reshuffle: {MAPPING} already exists", file=sys.stderr)
        return 1

    # Seeded from the OS, not from a constant: a constant seed plus this
    # source file would let the judge reconstruct the mapping by hand.
    seed = int.from_bytes(os.urandom(8), "big")
    rng = random.Random(seed)

    mapping: dict[str, dict[str, str]] = {}
    for meeting in sorted(MEETINGS):
        src_dir = GATE / meeting
        cells = sorted(p.name for p in src_dir.iterdir()
                       if p.is_dir() and (p / "recap.md").is_file())
        if len(cells) != 16:
            print(f"{meeting}: expected 16 cells, found {len(cells)}", file=sys.stderr)
            return 1

        order = cells[:]
        rng.shuffle(order)

        out_dir = BLIND / meeting
        out_dir.mkdir(parents=True, exist_ok=True)
        mapping[meeting] = {}
        for i, cell in enumerate(order, start=1):
            blind_name = f"cell-{i:02d}"
            shutil.copyfile(src_dir / cell / "recap.md", out_dir / f"{blind_name}.md")
            mapping[meeting][blind_name] = cell
        print(f"{meeting}: 16 cells blinded -> {out_dir}")

    MAPPING.write_text(
        json.dumps({"seed": seed, "meetings": MEETINGS, "cells": mapping},
                   ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"mapping -> {MAPPING} (do not open until judging is done)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
