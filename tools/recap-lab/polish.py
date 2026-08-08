"""Second pass: fix the form of a finished recap without touching its content.

Measured: a short extraction prompt (v4, 1164 characters) finds 36 agreements
across the corpus against 28 and 25 for the shipped one — and writes 17 passives
and 21 bureaucratic turns, because it says nothing about style. A long prompt
does the reverse. The two jobs compete for a 4B model's attention, so they are
split: extract with the short prompt, then edit what came out.

The editor sees ~4 000 characters instead of a whole meeting, which is why it
can be told a great deal about style and still be fast.

Usage:
    python3 polish.py --dir out/v4          # → out/v4-polished
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

import lint
import promptlib as p
import run as runner

HERE = Path(__file__).parent

POLISH_PROMPT = """
Ты — редактор. Перед тобой готовый конспект встречи. Перепиши его по правилам ниже, ничего не добавляя и ничего не выбрасывая.

НАКЛОНЕНИЕ
Конспект рассказывает, что было, а не раздаёт указания. Изъявительное наклонение, третье лицо: «Левон чистит код», «Договорились отказаться от диплинков». Не «проведите очистку», не «используйте компоненты», не «реализуйте» — читатель конспекта не исполнитель.

ЧТО НЕЛЬЗЯ ТРОГАТЬ
- Состав: сколько пунктов пришло — столько и уходит. Ни одного нового, ни одного убранного, ни одного слитого с соседним.
- Факты, имена, числа, таймкоды, названия секций и их порядок.
- Термины и англицизмы участников: «дейлик», «флоу», «инстанс», «пайплайн», «джоба», «прод», «фича». Не переводи их и не расшифровывай.

ЧТО ИСПРАВИТЬ
- Пассив — в активный залог. «Было решено перейти» → «Решили перейти». «Обсуждалась смета» → «Обсудили смету». Слова «утверждено», «согласовано», «отмечено», «выявлено», «зафиксировано», «принято решение» замени на глагол с действующим лицом; если лица нет — «Договорились…».
- Канцелярит выкинь: «в рамках», «в целях», «с целью», «посредством», «путём», «данный», «является», «осуществляет», «реализация», «в части», «по итогам обсуждения», «в ходе обсуждения».
- Предложения длиннее 20 слов разбей на два. Смысл при этом сохрани целиком.
- Вводные обороты и общие слова («ключевой», «соответствующий», «ряд вопросов», «этапы», «следующие шаги») убери, если без них понятно.
- Ответственный-призрак: если пункт задачи начинается с «**Система**», «**Команда**», «**Участник**», «неявный ответственный» — убери этот псевдо-ответственный, оставив саму задачу. Имя не придумывай.
- Разметка: заголовки через ##, списки через дефис, жирное через **.

Верни только переписанный конспект — без предисловий, без пояснений и без markdown-ограждений.
""".strip()

# What to say about each kind of finding. The linter knows the address; the model
# is only asked to rewrite that spot — a rule with a quote attached gets obeyed,
# the same rule in a list of nine does not.
GUIDANCE = {
    "срок не из транскрипта":
        "срок «{}» на встрече не звучал — в исправленном тексте его нет, задача осталась",
    "ответственный-призрак":
        "«{}» — не ответственный: в исправленном тексте пункт стоит без имени",
    "пассив":
        "пассив «{}» — в исправленном тексте здесь глагол с действующим лицом",
    "канцелярит":
        "канцелярит «{}» — в исправленном тексте его нет",
    "вода":
        "общее слово «{}» — в исправленном тексте его нет, если без него понятно",
    "длинное предложение":
        "предложение из {} — в исправленном тексте на его месте два",
}
MAX_GUIDED = 20     # a 4B model stops reading a list somewhere around here


def guidance_block(report) -> str:
    """Turn linter findings into addressed instructions, most damaging first."""
    lines: list[str] = []
    for check in GUIDANCE:
        for finding in report.findings:
            if finding.check != check:
                continue
            text = finding.text
            if check == "длинное предложение":
                text = text.split(":")[0]           # «31 слов»
            elif check == "ответственный-призрак":
                # Цитировать весь пункт незачем — модель ищет по имени.
                text = re.sub(r"^\s*-\s*", "", text).split("—")[0].strip()
            lines.append("- " + GUIDANCE[check].format(text))
            if len(lines) >= MAX_GUIDED:
                break
        if len(lines) >= MAX_GUIDED:
            break
    if not lines:
        return ""
    return ("\n\nНАЙДЕННЫЕ МЕСТА — проверено по транскрипту, каждое должно уйти:\n"
            + "\n".join(lines))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=Path, required=True, help="каталог с рекапами первого прохода")
    ap.add_argument("--out", default=None)
    ap.add_argument("--only", default=None)
    ap.add_argument("--model", default=runner.MODEL)
    ap.add_argument("--plain", action="store_true",
                    help="без адресных находок линтера — только общие правила")
    args = ap.parse_args()

    source = args.dir if args.dir.is_absolute() else HERE / args.dir
    out_dir = HERE / "out" / (args.out or f"{source.name}-polished")
    out_dir.mkdir(parents=True, exist_ok=True)
    system = POLISH_PROMPT + p.language_lock()

    for path in sorted(source.glob("*.md")):
        if args.only and args.only not in path.stem:
            continue
        draft = path.read_text(encoding="utf-8")
        guided = ""
        if not args.plain:
            try:
                _, transcript = p.transcript(path.stem)
            except FileNotFoundError:
                transcript = None
            guided = guidance_block(lint.lint(draft, transcript, path.stem))
        started = time.time()
        try:
            raw, stats = p.call_ollama(args.model, system, draft + guided)
        except Exception as error:                      # noqa: BLE001
            print(f"{path.stem}  · ОШИБКА: {error}")
            continue
        body = p.strip_code_fences(raw)

        # A polish that loses bullets is a polish that lost content. Report it
        # rather than let a silent shrink pass for a style improvement.
        before = len(re.findall(r"^\s*-\s", draft, re.M))
        after = len(re.findall(r"^\s*-\s", body, re.M))
        flag = f"  ПУНКТОВ {before} → {after}" if after < before else ""
        (out_dir / path.name).write_text(body + "\n", encoding="utf-8")
        (out_dir / f"{path.stem}.json").write_text(json.dumps({
            "bullets_before": before, "bullets_after": after,
            "seconds": round(time.time() - started, 1), **stats,
        }, ensure_ascii=False, indent=2), encoding="utf-8")
        addressed = guided.count("\n- ")
        print(f"{path.stem}  · {len(draft)} → {len(body)} симв"
              f" · {addressed} адресов · {time.time() - started:.0f} с{flag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
