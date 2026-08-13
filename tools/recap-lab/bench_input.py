"""Транскрипт против модели: кто из двоих портит саммари.

Лаборатория до сих пор отвечала на вопрос «стал ли промпт лучше». Здесь вопрос
другой: качество конспекта упирается в модель или во вход, который ей дают.
Ответ арифметический — один и тот же промпт прогоняется по решётке
{модель} × {транскрипт}, и разности читаются напрямую:

    B − A   что даёт сильная модель на том же входе
    C − A   что даёт починенный вход той же модели
    D       потолок, когда починено и то и другое

`--transcript` принимает произвольный файл, потому что починенный транскрипт
живёт в лаборатории, а не в `~/.meeting-recorder`: архив пользователя эта
работа не трогает.

    python3 bench_input.py --dump   out/bench/A     # system.txt + user.txt
    python3 bench_input.py --ollama out/bench/A     # прогон qwen
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import promptlib as p

HERE = Path(__file__).parent
MEETING = "20260812_144201"
MODEL = "qwen3.5:4b"


def messages(transcript_path: Path | None, meeting: str) -> tuple[str, str]:
    if transcript_path:
        text = transcript_path.read_text(encoding="utf-8")
        first = text.split("\n", 1)[0]
        title = first.lstrip("# ").strip() if first.startswith("#") else meeting
    else:
        title, text = p.transcript(meeting)
    return p.system_prompt(None), p.build_user_message(title, text)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--transcript", type=Path, default=None, help="файл вместо архивного")
    ap.add_argument("--meeting", default=MEETING)
    ap.add_argument("--dump", action="store_true", help="только записать system.txt/user.txt")
    ap.add_argument("--ollama", action="store_true", help="прогнать через локальную модель")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--temperature", type=float, default=0.2)
    args = ap.parse_args()

    drift = p.check_context_constants()
    if drift:
        print("Лаборатория разошлась с приложением:", *drift, sep="\n  ")
        return 1

    out = HERE / args.out if not args.out.is_absolute() else args.out
    out.mkdir(parents=True, exist_ok=True)
    system, user = messages(args.transcript, args.meeting)
    (out / "system.txt").write_text(system, encoding="utf-8")
    (out / "user.txt").write_text(user, encoding="utf-8")
    chars = len(system) + len(user)
    print(f"{out.name}: система {len(system)} симв · user {len(user)} симв"
          f" · ~{p.estimated_tokens(chars)} ток · num_ctx {p.num_ctx(chars)}"
          f"{' · ОБРЕЗАН' if p.exceeds_largest_window(chars) else ''}")

    if args.ollama:
        started = time.time()
        raw, stats = p.call_ollama(args.model, system, user, temperature=args.temperature,
                                   min_reply_tokens=p.REPLY_TOKENS_FLOOR['recap'])
        body = p.strip_code_fences(raw)
        (out / "recap.md").write_text(body + "\n", encoding="utf-8")
        (out / "stats.json").write_text(
            json.dumps({"model": args.model, **stats}, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"  → {len(body)} симв за {time.time() - started:.0f} с")
    return 0


if __name__ == "__main__":
    sys.exit(main())
