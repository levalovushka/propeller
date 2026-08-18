#!/usr/bin/env python3
"""Отложить стемы встреч, пока retention их не съел.

Зачем. Корпус для замеров диаризации скоропортящийся: retention включён по
умолчанию, и на 2026-08-18 из 59 встреч архива звук остался у трёх. Встреча
`20260812_144201`, на которой прошлые замеры видели двоих в одном кластере,
существует только текстом — переспросить её уже нечем.

Что делает. Копирует системный и микрофонный стемы в каталог вне репозитория и
ведёт рядом манифест: что отложено, когда, какой длины. Архив только читается —
ни одного вызова, который пишет или удаляет.

Чего не делает. Не трогает retention в приложении и не спорит с ним: человек
попросил удалять аудио, и это его решение. Снимок — копия для инструмента
разработчика, а не отмена политики хранения.

    python3 snapshot.py            # отложить всё, у чего ещё есть звук
    python3 snapshot.py --list     # что уже отложено и что вот-вот пропадёт
    python3 snapshot.py 20260817_165425 20260818_103818

Приватность: снимок — живые встречи. Он лежит вне репозитория и в git не уезжает
никогда; в лабораторию попадают только эталоны и таймкоды (DIARIZATION.md).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import wave

ARCHIVE = os.path.expanduser("~/.meeting-recorder/recordings")
INDEX = os.path.join(ARCHIVE, "recordings.json")
CORPUS = os.path.expanduser("~/diarize-lab-corpus")
MANIFEST = os.path.join(CORPUS, "manifest.json")
STEMS = ("sys", "mic")


def load_index() -> list[dict]:
    with open(INDEX) as f:
        return json.load(f)


def duration_of(path: str) -> float:
    """Длительность. Часть архива записана float32-WAV, который `wave` не читает."""
    try:
        with wave.open(path) as w:
            return w.getnframes() / w.getframerate()
    except wave.Error:
        out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "estimated duration" in line:
                return float(line.split(":")[1].split()[0])
        return 0.0


def load_manifest() -> dict:
    if os.path.exists(MANIFEST):
        with open(MANIFEST) as f:
            return json.load(f)
    return {}


def save_manifest(manifest: dict) -> None:
    os.makedirs(CORPUS, exist_ok=True)
    with open(MANIFEST, "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1, sort_keys=True)


def stem_paths(rec_id: str) -> dict[str, str]:
    """Стемы, которые ещё лежат в архиве."""
    found = {}
    for stem in STEMS:
        path = os.path.join(ARCHIVE, f"{rec_id}.{stem}.wav")
        if os.path.exists(path):
            found[stem] = path
    return found


def snapshot(rec: dict, manifest: dict) -> str:
    rec_id = rec["id"]
    if rec_id in manifest:
        return "уже отложена"
    available = stem_paths(rec_id)
    if "sys" not in available:
        # Без системного стема мерить дальнюю сторону нечем — это и есть предмет.
        return "нет системного стема"

    os.makedirs(CORPUS, exist_ok=True)
    copied = {}
    for stem, source in available.items():
        target = os.path.join(CORPUS, f"{rec_id}.{stem}.wav")
        shutil.copy2(source, target)
        copied[stem] = os.path.getsize(target)

    manifest[rec_id] = {
        "date": rec.get("date"),
        "title": rec.get("title"),
        "seconds": round(duration_of(available["sys"]), 1),
        "attribution": rec.get("speakerAttribution"),
        "stems": copied,
        # Сколько кластеров насчитала дальняя сторона на момент снимка — по нему
        # видно, стоит ли эта встреча разметки: один кластер значит слипание.
        "farClusters": len({
            s.get("speaker", "")
            for s in json.loads(rec.get("mergedSegmentsJSON") or "[]")
            if s.get("speaker", "").startswith("Speaker")
        }),
    }
    return "отложена " + ", ".join(f"{k} {v/1e6:.0f} МБ" for k, v in copied.items())


def show(index: list[dict], manifest: dict) -> None:
    print(f"снимок: {CORPUS}")
    total = sum(
        os.path.getsize(os.path.join(CORPUS, f))
        for f in os.listdir(CORPUS)
        if f.endswith(".wav")
    ) if os.path.isdir(CORPUS) else 0
    print(f"отложено встреч {len(manifest)}, {total/1e9:.2f} ГБ\n")
    for rec_id, meta in sorted(manifest.items()):
        gone = "" if stem_paths(rec_id) else "  (в архиве уже нет)"
        print(f"  {rec_id} {meta['seconds']/60:5.1f} мин  кластеров {meta['farClusters']}{gone}")

    pending = [
        r["id"] for r in index
        if r["id"] not in manifest and "sys" in stem_paths(r["id"])
    ]
    if pending:
        print(f"\nещё в архиве, но не отложено — {len(pending)}: {', '.join(sorted(pending))}")
        print("  это то, что исчезнет со следующим проходом retention")
    else:
        print("\nвсё, у чего есть звук, отложено")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*", help="встречи; пусто = все, у кого есть звук")
    ap.add_argument("--list", action="store_true", help="только показать состояние")
    args = ap.parse_args()

    index = load_index()
    manifest = load_manifest()

    if args.list:
        show(index, manifest)
        return

    by_id = {r["id"]: r for r in index}
    ids = args.ids or [r["id"] for r in index if "sys" in stem_paths(r["id"])]
    if not ids:
        print("нечего откладывать: в архиве не осталось системных стемов")
        return

    for rec_id in sorted(ids):
        rec = by_id.get(rec_id)
        if rec is None:
            print(f"  {rec_id}: нет в индексе")
            continue
        print(f"  {rec_id}: {snapshot(rec, manifest)}")

    save_manifest(manifest)
    print()
    show(index, manifest)


if __name__ == "__main__":
    main()
