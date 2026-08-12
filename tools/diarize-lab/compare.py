#!/usr/bin/env python3
"""Диаризация gigastt против FluidAudio на реальных встречах архива.

Вопрос один: если вырезать FluidAudio, встреча станет размечена хуже?

Что берётся за эталон. Полного эталона нет — руками никто не размечал, — поэтому
сравниваются два разбиения одного и того же системного стема:

  FluidAudio  реплики из `mergedSegmentsJSON` архива (там, где `speakerAttribution`
              = diarized, это ровно вывод FluidAudio по системному стему)
  gigastt     `POST /v1/transcribe?diarization=true`, спикер приходит на каждом слове

Меряется три вещи:

  число голосов    сколько кластеров каждый насчитал на дальней стороне
  мелочь           сколько из них меньше `TINY_SECONDS` — на разговоре двоих
                   лишний кластер на пару секунд это выдуманный человек
  согласие         доля времени дальней речи, где системы говорят одно и то же
                   (кластеры сопоставлены жадно по максимальному перекрытию)

Согласие — не точность: если оба ошиблись одинаково, оно будет высоким. Оно
отвечает только на вопрос «различаются ли разбиения», и вместе с числом голосов
этого хватает, чтобы увидеть, что своё делает каждый.

    python3 compare.py 20260812_144201 20260812_110841
    python3 compare.py --all-short          # все встречи архива короче 25 минут
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import wave

ARCHIVE = os.path.expanduser("~/.meeting-recorder/recordings")
INDEX = os.path.join(ARCHIVE, "recordings.json")
OUT = os.path.expanduser("~/diarize-lab-out")

# Сайдкар 2.14 отказывается от файлов длиннее получаса, а `--body-limit-bytes`
# у лабораторного сервера поднят до 64 МиБ. 25 минут 16 кГц моно — 48 МБ, влезает.
MAX_SECONDS = 25 * 60
# Кластер короче этого на встрече двоих — не человек, а осколок.
TINY_SECONDS = 15.0
# Шаг сетки, по которой считается согласие.
FRAME = 0.1


def load_index() -> dict:
    with open(INDEX) as f:
        return {r["id"]: r for r in json.load(f)}


def owner_name(entry: dict) -> str:
    """Имя владельца — метка, которую поставили по микрофонной дорожке."""
    names = {s.get("speaker", "") for s in json.loads(entry["mergedSegmentsJSON"] or "[]")}
    named = [n for n in names if n and not n.startswith("Speaker")]
    return named[0] if len(named) == 1 else ""


def fluid_spans(entry: dict, owner: str) -> list[tuple[float, float, str]]:
    """Реплики дальней стороны так, как их разметил FluidAudio."""
    segs = json.loads(entry["mergedSegmentsJSON"] or "[]")
    return [
        (s["startTime"], s["endTime"], s["speaker"])
        for s in segs
        if s.get("speaker") and s["speaker"] != owner
    ]


def ask_gigastt(path: str, port: int, cache: str) -> tuple[dict, float]:
    """Ответ сайдкара по файлу; повторный прогон читает сохранённый JSON."""
    if os.path.exists(cache):
        with open(cache) as f:
            return json.load(f), float("nan")
    url = f"http://127.0.0.1:{port}/v1/transcribe?segments=true&diarization=true"
    started = time.monotonic()
    raw = subprocess.run(
        ["curl", "-sS", "-X", "POST", url, "-H", "Content-Type: audio/wav",
         "--data-binary", f"@{path}"],
        capture_output=True, check=True,
    ).stdout
    elapsed = time.monotonic() - started
    data = json.loads(raw)
    if "words" not in data:
        raise SystemExit(f"сайдкар не отдал слов: {raw[:300]!r}")
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    with open(cache, "w") as f:
        json.dump(data, f, ensure_ascii=False)
    return data, elapsed


def word_spans(data: dict) -> list[tuple[float, float, str]]:
    """Метки как их отдал диаризатор: по словам."""
    spans: list[tuple[float, float, str]] = []
    for w in data.get("words", []):
        speaker = w.get("speaker")
        if speaker is None:
            continue
        label = f"giga {speaker}"
        if spans and spans[-1][2] == label and w["start"] - spans[-1][1] < 1.0:
            spans[-1] = (spans[-1][0], w["end"], label)
        else:
            spans.append((w["start"], w["end"], label))
    return spans


def voted_spans(data: dict) -> list[tuple[float, float, str]]:
    """Реплика целиком достаётся тому, чьих слов в ней больше.

    Сравнение иначе нечестное: у FluidAudio в архиве лежит уже разложенный по
    репликам результат, а у сайдкара — сырые метки слов. Голосование по реплике
    — ровно то, что сделал бы с ними пайплайн.
    """
    spans: list[tuple[float, float, str]] = []
    for seg in data.get("segments", []):
        votes: dict[int, int] = {}
        for w in seg.get("words", []):
            speaker = w.get("speaker")
            if speaker is not None:
                votes[speaker] = votes.get(speaker, 0) + 1
        if not votes:
            continue
        winner = max(votes.items(), key=lambda kv: kv[1])[0]
        spans.append((seg["start"], seg["end"], f"giga {winner}"))
    return spans


def by_speaker(spans) -> dict[str, float]:
    total: dict[str, float] = {}
    for start, end, label in spans:
        total[label] = total.get(label, 0.0) + max(0.0, end - start)
    return dict(sorted(total.items(), key=lambda kv: -kv[1]))


def frames(spans, duration: float) -> dict[int, str]:
    """Сетка `FRAME`-секундных отсчётов: кто говорит в этот момент."""
    grid: dict[int, str] = {}
    for start, end, label in spans:
        for i in range(int(start / FRAME), int(end / FRAME) + 1):
            grid[i] = label
    return {i: v for i, v in grid.items() if i * FRAME <= duration}


def agreement(a: dict[int, str], b: dict[int, str]) -> tuple[float, int, dict[str, str]]:
    """Доля общего времени, где разбиения совпадают после сопоставления кластеров."""
    shared = a.keys() & b.keys()
    if not shared:
        return 0.0, 0, {}

    overlap: dict[tuple[str, str], int] = {}
    for i in shared:
        key = (b[i], a[i])
        overlap[key] = overlap.get(key, 0) + 1

    mapping: dict[str, str] = {}
    taken: set[str] = set()
    for (src, dst), _ in sorted(overlap.items(), key=lambda kv: -kv[1]):
        if src in mapping or dst in taken:
            continue
        mapping[src] = dst
        taken.add(dst)

    hits = sum(1 for i in shared if mapping.get(b[i]) == a[i])
    return hits / len(shared), len(shared), mapping


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
        raise


def run(rec_id: str, index: dict, port: int) -> None:
    entry = index.get(rec_id)
    if entry is None:
        raise SystemExit(f"{rec_id}: нет в индексе")
    if entry.get("speakerAttribution") != "diarized":
        print(f"{rec_id}: пропуск — спикеры не от диаризатора "
              f"({entry.get('speakerAttribution')})")
        return

    stem = os.path.join(ARCHIVE, f"{rec_id}.sys.wav")
    if not os.path.exists(stem):
        raise SystemExit(f"{rec_id}: нет системного стема")
    seconds = duration_of(stem)
    if seconds > MAX_SECONDS:
        print(f"{rec_id}: пропуск — {seconds/60:.1f} мин, длиннее потолка одного запроса")
        return

    owner = owner_name(entry)
    fluid = fluid_spans(entry, owner)
    data, elapsed = ask_gigastt(stem, port, os.path.join(OUT, f"{rec_id}.gigastt.json"))

    f_by = by_speaker(fluid)
    f_tiny = [k for k, v in f_by.items() if v < TINY_SECONDS]
    f_frames = frames(fluid, seconds)

    print(f"\n=== {rec_id} · {seconds/60:.1f} мин · владелец «{owner or '?'}» ===")
    if elapsed == elapsed:  # не NaN — значит считали сейчас
        print(f"  gigastt: {elapsed:.0f} с на проход (ASR + диаризация), RTF {elapsed/seconds:.3f}")
    print(f"  FluidAudio       голосов {len(f_by)} (мелких {len(f_tiny)}): "
          + ", ".join(f"{k} {v:.0f}с" for k, v in f_by.items()))

    for name, spans in (("gigastt по словам", word_spans(data)),
                        ("gigastt по репликам", voted_spans(data))):
        g_by = by_speaker(spans)
        g_tiny = [k for k, v in g_by.items() if v < TINY_SECONDS]
        share, common, _ = agreement(f_frames, frames(spans, seconds))
        print(f"  {name:16} голосов {len(g_by)} (мелких {len(g_tiny)}): "
              + ", ".join(f"{k} {v:.0f}с" for k, v in g_by.items()))
        print(f"  {'':16} согласие {share*100:.1f} % на {common*FRAME:.0f} с общей речи")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--port", type=int, default=9891)
    ap.add_argument("--all-short", action="store_true",
                    help="все встречи архива, влезающие в один запрос")
    args = ap.parse_args()

    index = load_index()
    ids = args.ids
    if args.all_short:
        ids = [
            r["id"] for r in sorted(index.values(), key=lambda r: r["id"])
            if r.get("speakerAttribution") == "diarized"
            and os.path.exists(os.path.join(ARCHIVE, f"{r['id']}.sys.wav"))
            and duration_of(os.path.join(ARCHIVE, f"{r['id']}.sys.wav")) <= MAX_SECONDS
        ]
    if not ids:
        raise SystemExit("нечего мерить: укажи id или --all-short")

    for rec_id in ids:
        run(rec_id, index, args.port)


if __name__ == "__main__":
    main()
