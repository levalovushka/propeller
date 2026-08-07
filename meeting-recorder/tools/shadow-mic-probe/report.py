#!/usr/bin/env python3
"""Отчёт по журналу теневого замера (`probe.swift`).

Отвечает ровно на два вопроса:
  1. сколько времени пробник действительно наблюдал (иначе «ноль срабатываний»
     неотличимо от «пробник умер во вторник»);
  2. сколько баннеров «Кажется, вы на встрече» человек увидел бы за это время.

Баннером считается эпизод, у которого непрерывный дуплекс (микрофон и звук
одновременно) продержался дольше порога. Порог — та самая задержка, ради
которой старт записи и уведомление разведены во времени.

  ./report.py [журнал] [--threshold 60]
"""

import json
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

DEFAULT_JOURNAL = Path.home() / ".meeting-recorder" / "shadow-mic.jsonl"
# Промежуток больше этого считается перерывом в наблюдении: heartbeat ходит
# раз в 15 минут, всё что дольше — сон машины или остановленный пробник.
GAP = timedelta(minutes=20)


def parse(path):
    events = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
            record["at"] = datetime.fromisoformat(record["at"])
        except (json.JSONDecodeError, KeyError, ValueError):
            continue
        events.append(record)
    return sorted(events, key=lambda r: r["at"])


def observed(events):
    """Сумма промежутков между событиями, не превышающих GAP."""
    total = timedelta()
    for earlier, later in zip(events, events[1:]):
        step = later["at"] - earlier["at"]
        if step <= GAP:
            total += step
    return total


def human(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds} с"
    if seconds < 3600:
        return f"{seconds // 60} мин {seconds % 60:02d} с"
    return f"{seconds // 3600} ч {(seconds % 3600) // 60:02d} мин"


def main():
    args = [a for a in sys.argv[1:]]
    threshold = 60
    if "--threshold" in args:
        i = args.index("--threshold")
        threshold = int(args[i + 1])
        del args[i:i + 2]
    path = Path(args[0]) if args else DEFAULT_JOURNAL

    if not path.exists():
        sys.exit(f"журнала нет: {path}")

    events = parse(path)
    if not events:
        sys.exit(f"журнал пуст: {path}")

    window = observed(events)
    days = window.total_seconds() / 86400
    # Идущий эпизод отчитывается раз в минуту и закрывается один раз. Без
    # `episode-progress` отчёт молчал бы ровно про ту встречу, которая идёт
    # прямо сейчас, — а её и проверяют первой.
    episodes, live = [], {}
    for e in events:
        kind = e.get("event")
        key = e.get("key") or e.get("bundleID") or e.get("name")
        if kind == "episode-progress":
            live[key] = e
        elif kind == "episode":
            live.pop(key, None)
            episodes.append(e)
    for e in live.values():
        e = dict(e)
        e["ongoing"] = True
        episodes.append(e)
    episodes.sort(key=lambda e: e.get("startedAt", ""))

    print(f"Журнал: {path}")
    print(f"Наблюдение: {events[0]['at']:%d.%m %H:%M} — {events[-1]['at']:%d.%m %H:%M}, "
          f"из них под наблюдением {human(window.total_seconds())} ({days:.1f} сут)")
    print(f"Порог баннера: непрерывный дуплекс ≥ {threshold} с")
    print()

    if not episodes:
        print("Эпизодов с микрофоном не было вовсе.")
        return

    print(f"{'начало':<14}{'длительность':>14}{'дуплекс':>13}{'подряд':>13}  {'баннер':<7} приложение")
    banners = 0
    by_app = defaultdict(lambda: [0, 0])
    for e in episodes:
        started = datetime.fromisoformat(e["startedAt"])
        run = e.get("longestDuplexSeconds", 0)
        is_banner = run >= threshold
        banners += is_banner
        app = e.get("bundleID") or e.get("name") or "?"
        by_app[app][0] += 1
        by_app[app][1] += is_banner
        print(f"{started:%d.%m %H:%M}  "
              f"{human(e.get('durationSeconds', 0)):>12}  "
              f"{human(e.get('duplexSeconds', 0)):>11}  "
              f"{human(run):>11}  "
              f"{'да' if is_banner else '—':<7} {app}"
              f"{'  ← идёт сейчас' if e.get('ongoing') else ''}")

    print()
    print(f"Эпизодов с микрофоном: {len(episodes)}; из них дожили бы до баннера: {banners}")
    if days >= 0.5:
        print(f"В пересчёте на неделю: {banners / days * 7:.1f} баннеров")
    else:
        print("Наблюдения меньше половины суток — на неделю пересчитывать рано")
    print()
    print("По приложениям (баннеров / эпизодов):")
    for app, (total, shown) in sorted(by_app.items(), key=lambda kv: -kv[1][1]):
        print(f"  {shown:>3} / {total:<3}  {app}")
    print()
    print("Дальше — руками: пометьте, какие из баннеров были ложными.")
    print("Критерий приёмки: не больше 2 ложных за неделю.")


if __name__ == "__main__":
    main()
