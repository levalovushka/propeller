"""Два способа спросить у модели больше, чем она отдаёт за один проход.

Оба работают с целым транскриптом — нарезка проверена и не помогает (A1 в
OPTIMIZATION.md), значит вопрос не в том, сколько модель видит, а в том, о чём её
спрашивают.

    --mode completeness   черновик обычным промптом, потом второй проход:
                          «каких договорённостей здесь нет» — и дописать их.
                          Редактура, которая у нас есть, содержания не добавляет
                          ни разу (замер 2026-08-08); этот проход её и просит.

    --mode sections       три вызова по всему транскрипту, каждый об одном:
                          решения · задачи · открытые вопросы. То же лекарство,
                          что дал короткий промпт (длина конкурирует с полнотой),
                          но применённое к задаче, а не к инструкции.

    python3 bench_passes.py --mode completeness --out passes/comp-a
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import promptlib as p

HERE = Path(__file__).parent
MEETING = "20260812_144201"
MODEL = "qwen3.5:4b"

MISSING_PROMPT = """
Ты сверяешь конспект встречи с её транскриптом. Твоя работа — найти то, о чём договорились, но в конспект не попало.

Читай транскрипт подряд. Каждый раз, когда участники о чём-то договорились — кто-то предложил, другой согласился, — проверяй, есть ли это в конспекте. Если нет, выпиши.
На рабочей встрече договорённостей обычно пять и больше, и в конспект попадают не все.

Выпиши только пропущенное, по пункту на строку, начиная с дефиса. Ничего не объясняй и не повторяй то, что в конспекте уже есть.
Не выдумывай: единственный источник — транскрипт.
Если пропущено ничего, ответь одним словом: ПОЛНО.
""".strip()

MERGE_PROMPT = """
Ты дополняешь готовый конспект встречи найденными договорённостями.

Вставь каждую в подходящую секцию: договорённости — в «Решения», кто что делает — в «Задачи», нерешённое — в «Открытые вопросы».
Ничего из того, что уже есть, не удаляй, не сокращай и не переписывай. Секции и их порядок не меняй.
Верни весь конспект целиком, без предисловий и без markdown-ограждений.
""".strip()

SECTION_PROMPTS = {
    "Решения": """
Ты читаешь транскрипт рабочей встречи. Выпиши ТОЛЬКО то, о чём договорились: кто-то предложил, другой согласился.

Собери ВСЕ договорённости, а не первые попавшиеся: они разбросаны по всему разговору, и на рабочей встрече их обычно пять и больше. Пропущенная договорённость — худшая ошибка конспекта.
Каждый пункт с новой строки, начиная с дефиса. Каждый пункт — завершённая договорённость.
Не выдумывай того, чего нет в транскрипте. Ничего, кроме списка, не пиши.
""".strip(),
    "Задачи": """
Ты читаешь транскрипт рабочей встречи. Выпиши ТОЛЬКО то, кто что делает.

Каждый пункт с новой строки: **Кто** — что делает — **к какому сроку**.
Срок и ответственного пиши, только если они прозвучали вслух. Имя не придумывай: если исполнителя не назвали, пиши пункт без него.
Не выдумывай того, чего нет в транскрипте. Ничего, кроме списка, не пиши.
Если никто ничего на себя не брал, ответь одним словом: НЕТ.
""".strip(),
    "Открытые вопросы": """
Ты читаешь транскрипт рабочей встречи. Выпиши ТОЛЬКО то, что обсудили и не решили: что осталось спорным, что заблокировано, чего ждут.

Каждый пункт с новой строки, начиная с дефиса.
Не выдумывай того, чего нет в транскрипте. Ничего, кроме списка, не пиши.
Если нерешённого не осталось, ответь одним словом: НЕТ.
""".strip(),
}


def ask(system: str, user: str, model: str) -> str:
    raw, _ = p.call_ollama(model, system + p.language_lock(), user)
    return p.strip_code_fences(raw).strip()


def completeness(title: str, markdown: str, model: str) -> str:
    draft = ask(p.system_prompt(None), p.build_user_message(title, markdown), model)
    missing = ask(
        MISSING_PROMPT,
        f"КОНСПЕКТ\n{draft}\n\nТРАНСКРИПТ\n{markdown}",
        model,
    )
    if not missing or missing.upper().startswith("ПОЛНО"):
        return draft
    return ask(MERGE_PROMPT, f"КОНСПЕКТ\n{draft}\n\nНАЙДЕННОЕ\n{missing}", model)


def sections(title: str, markdown: str, model: str) -> str:
    user = p.build_user_message(title, markdown)
    parts = []
    for name, prompt in SECTION_PROMPTS.items():
        body = ask(prompt, user, model)
        if not body or body.upper().startswith("НЕТ"):
            continue
        parts.append(f"## {name}\n{body}")
    return "\n\n".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["completeness", "sections"], required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--meeting", default=MEETING)
    ap.add_argument("--model", default=MODEL)
    args = ap.parse_args()

    title, markdown = p.transcript(args.meeting)
    out = HERE / "out" / args.out
    out.mkdir(parents=True, exist_ok=True)
    started = time.time()
    body = (completeness if args.mode == "completeness" else sections)(title, markdown, args.model)
    (out / "recap.md").write_text(body + "\n", encoding="utf-8")
    print(f"{args.out}: {len(body)} симв за {time.time() - started:.0f} с")
    return 0


if __name__ == "__main__":
    sys.exit(main())
