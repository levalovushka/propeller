"""Regenerate recaps for a fixed corpus with a given prompt version.

Nothing here touches `~/.meeting-recorder` — transcripts are read, recaps are
written to `out/<variant>/`. Comparing prompt versions means comparing two
directories, and the meetings on disk stay the user's.

Usage:
    python3 run.py --variant current            # what ships today
    python3 run.py --variant v2 --only 20260806 # one meeting, new prompt
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import promptlib as p

HERE = Path(__file__).parent
CORPUS = HERE / "corpus.txt"
MODEL = "qwen3.5:4b"   # matches the app's default (`Preferences.recapOllamaModel`)
POLICY_TEMPERATURE = 0.0   # `RecapGenerationPolicy.temperature` — первый вызов детерминированный


def corpus() -> list[str]:
    return [
        line.split("#")[0].strip()
        for line in CORPUS.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="current", help="current | имя файла в prompts/")
    ap.add_argument("--out", default=None, help="каталог прогона (по умолчанию — имя версии)")
    ap.add_argument("--only", default=None, help="подстрока id встречи")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--force", action="store_true", help="перегенерировать уже готовые")
    args = ap.parse_args()

    drift = p.check_context_constants() + p.check_generation_constants()
    if drift:
        print("Лаборатория разошлась с приложением:", *drift, sep="\n  ")
        return 1

    system = p.system_prompt(args.variant)
    out_dir = HERE / "out" / (args.out or args.variant)
    out_dir.mkdir(parents=True, exist_ok=True)

    ids = [m for m in corpus() if not args.only or args.only in m]
    print(f"промпт «{args.variant}» ({len(system)} симв.) · модель {args.model} · встреч {len(ids)}\n")

    for meeting in ids:
        target = out_dir / f"{meeting}.md"
        if target.exists() and not args.force:
            print(f"{meeting}  · уже есть, пропускаю")
            continue
        title, markdown = p.transcript(meeting)
        user = p.build_user_message(title, markdown)
        started = time.time()
        try:
            # Ровно то, что делает `RecapService.callOllamaTracked`: первый вызов
            # детерминированный, ответ короче порога схлопывания
            # (`RecapGenerationPolicy.recapMinReplyTokens`) перегенерируется на
            # t=0,3, из двух берётся длинный. Без этих трёх параметров
            # лаборатория мерила запрос, которого приложение не отправляет —
            # ошибка того же рода, что уже дважды нашлась 2026-08-27 (состав в
            # user-сообщении, промпт редактора).
            raw, stats = p.call_ollama(
                args.model, system, user,
                temperature=POLICY_TEMPERATURE,
                min_reply_tokens=p.REPLY_TOKENS_FLOOR["recap"],
                retry_temperature=p.RETRY_TEMPERATURE,
                requires_discussion=True,
            )
        except Exception as error:                      # noqa: BLE001 — a failed meeting must not stop the batch
            print(f"{meeting}  · ОШИБКА: {error}")
            continue
        body = p.strip_code_fences(raw)
        target.write_text(body + "\n", encoding="utf-8")
        (out_dir / f"{meeting}.json").write_text(
            json.dumps({"title": title, **stats}, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        flag = " ОБРЕЗАН" if stats["truncated"] else ""
        print(
            f"{meeting}  · {len(body):6} симв · ctx {stats['num_ctx']}"
            f" · промпт {stats['prompt_tokens']} ток · {time.time() - started:.0f} с{flag}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
