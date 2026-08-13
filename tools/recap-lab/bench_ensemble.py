"""Ансамбль с объединением: информация в модели есть, она размазана по сэмплам.

Основание — арифметика по уже снятым прогонам (OPTIMIZATION.md, A5):

    один проход                     8,0 / 14
    t=0 ∪ один сэмпл t=0,2         11,0  (2 вызова)
    t=0 ∪ два сэмпла               11,5  (3 вызова)
    ∪ шести facts нарезки          13–14
    t=0 ∪ сэмпл ∪ facts            12,5

Наборы комплементарны: t=0 приносит D5/D6/Q1, которых сэмплы почти не видят, а
Q2 достаёт только пофрагментный экстрактор. Поэтому ветки разные по устройству, а
не просто повторы.

**Модель никогда не пересобирает найденное.** Свободный свод теряет 1,9 пункта в
среднем и 5 в худшем случае при том, что всё уже у него на входе, — поэтому
слияние и рендер здесь код, а не вызов.

И одна поправка к первоначальной конструкции, купленная замером: ветки «целиком»
идут **конспектным** промптом, а не промптом фактов. Плоский размеченный список
на целом транскрипте даёт 5,0 против 8,0 у конспекта (`out/sweep/whole1-*`), то
есть ослабляет самую сильную ветку. Плоский список из неё получается разбором:
секции конспекта — это уже метки.

    python3 bench_ensemble.py --out ens/1
    python3 bench_ensemble.py --out ens/1 --branches t0,sample,sample,chunks
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

import chunked
import promptlib as p

HERE = Path(__file__).parent
MEETING = "20260812_144201"
MODEL = "qwen3.5:4b"
SAMPLE_TEMPERATURE = 0.7

# Секция конспекта → она же метка. Порядок — как в промпте.
SECTIONS = ["Решения", "Задачи", "Открытые вопросы"]
# «Ход обсуждения» сливается наравне с остальными, абзацами. Первая версия брала
# его только из ветки t=0 — и теряла всё, что нашли остальные: замер A3 говорит,
# что там живёт 1,4 пункта из 8, то есть пятая часть содержания.
NARRATIVE = "Ход обсуждения"
FACT_LABELS = {
    "ДОГОВОРИЛИСЬ": "Решения",
    "ЗАДАЧА": "Задачи",
    "ОТКРЫТО": "Открытые вопросы",
    "ТЕМА": NARRATIVE,
}
MAX_DUPLICATE_GROUP = 3
STOP = {"это", "как", "для", "что", "при", "или", "она", "его", "все", "так", "там"}


def items_from_recap(recap: str) -> dict[str, list[str]]:
    """Пункты по секциям. Разбор, а не генерация: секции — готовые метки."""
    out = {s: [] for s in SECTIONS + [NARRATIVE]}
    current = None
    for line in recap.split("\n"):
        heading = re.match(r"^##\s+(.+?)\s*$", line)
        if heading:
            current = heading.group(1).strip()
            continue
        if current == NARRATIVE and line.strip():
            out[NARRATIVE].append(line.strip())
        elif current in out and re.match(r"^\s*[-*]\s+\S", line):
            out[current].append(re.sub(r"^\s*[-*]\s+", "", line).strip())
    return out


def items_from_facts(facts: str) -> dict[str, list[str]]:
    """Разбор двух форм, в которых экстрактор пишет один и тот же список.

    Он выдаёт то `ДОГОВОРИЛИСЬ: раз; два; три` одной строкой, то `ДОГОВОРИЛИСЬ:`
    и буллеты следом. Первая версия разбора склеивала первую форму в один пункт,
    а вторую теряла целиком: из двенадцати строк подхватывались шесть, и
    механическая сборка выглядела вдвое хуже свободной. Это была цена разбора, а
    не сборки.
    """
    out = {s: [] for s in SECTIONS + [NARRATIVE]}
    current = None
    for raw in facts.split("\n"):
        line = raw.strip()
        if not line or line.upper().startswith("ПУСТО"):
            continue
        bullet = re.match(r"^[-*]\s+(.*)$", line)
        if bullet:
            if current:
                out[current].append(bullet.group(1).strip())
            continue
        head = next((l for l in FACT_LABELS if line.upper().startswith(l)), None)
        if head:
            current = FACT_LABELS[head]
            body = line[len(head):].lstrip(":—- ").strip()
            # «раз; два; три» — три пункта, а не один. Точка с запятой здесь
            # разделитель списка: экстрактору так велено промптом.
            out[current] += [part.strip() for part in body.split(";") if len(part.strip()) > 15]
        elif current:
            out[current].append(line)
    return out


def key_words(text: str) -> set[str]:
    words = re.findall(r"[а-яa-z]{4,}", text.lower().replace("ё", "е"))
    return {w for w in words if w not in STOP}


def same(a: str, b: str, threshold: float = 0.55) -> bool:
    wa, wb = key_words(a), key_words(b)
    if not wa or not wb:
        return False
    return len(wa & wb) / min(len(wa), len(wb)) >= threshold


def merge(branches: list[dict[str, list[str]]]) -> dict[str, list[str]]:
    """Слияние без модели: дубль отбрасывается, из двух формулировок остаётся
    длинная — она обычно несёт и срок, и исполнителя."""
    out = {s: [] for s in SECTIONS + [NARRATIVE]}
    for section in SECTIONS + [NARRATIVE]:
        for branch in branches:
            for item in branch.get(section, []):
                for i, kept in enumerate(out[section]):
                    if same(item, kept):
                        if len(item) > len(kept):
                            out[section][i] = item
                        break
                else:
                    out[section].append(item)
    return out


DEDUP_PROMPT = """
Перед тобой пронумерованный список пунктов конспекта встречи. Некоторые говорят об одном и том же разными словами.

Найди такие группы и верни только номера: по группе на строку, номера через запятую.
В группе два-три номера, не больше. Группа — это один и тот же факт разными словами, а не общая тема.
Пункт, у которого нет пары, не упоминай вовсе. Ничего, кроме номеров и запятых, не пиши.
Если повторов нет, ответь одним словом: НЕТ.
""".strip()


def dedup_by_model(merged: dict[str, list[str]], model: str) -> tuple[dict[str, list[str]], int]:
    """Модель показывает пальцем, схлопывает код.

    Она возвращает **номера**, а не текст: так она не может ни потерять пункт,
    ни дописать свой. Это то же правило, что и везде в этой конструкции —
    свободная пересборка теряет 1,9 пункта, — но применённое к списку из ~30
    строк, где 4B надёжна, а не к целой встрече.

    Механический дедуп по пересечению слов до цели не доводит: подбор порога от
    0,55 до 0,25 даёт 28,0 → 22,8 пункта при цели ≤14, потому что разные ветки
    называют одну договорённость разными словами.
    """
    flat = [(s, i, text) for s in SECTIONS for i, text in enumerate(merged[s])]
    if len(flat) < 2:
        return merged, 0
    listing = "\n".join(f"{n + 1}. {text}" for n, (_, _, text) in enumerate(flat))
    raw, stats = p.call_ollama(model, DEDUP_PROMPT, listing, temperature=0.0)
    answer = p.strip_code_fences(raw).strip()
    drop: set[int] = set()
    for line in answer.split("\n"):
        numbers = [int(x) - 1 for x in re.findall(r"\d+", line)]
        numbers = [n for n in numbers if 0 <= n < len(flat)]
        if len(numbers) < 2:
            continue
        # Право вето у кода, а не у модели. Без этих двух проверок 4B вернула
        # **одну группу из 21 номера** через обе секции и схлопнула конспект в
        # один пункт: покрытие 12,0 → 9,4 (p = 0,004). Настоящий дубль — это два-три
        # пункта в одной секции; всё, что шире, — «общая тема», а не повтор.
        if len(numbers) > MAX_DUPLICATE_GROUP:
            continue
        if len({flat[n][0] for n in numbers}) > 1:
            continue
        # Остаётся длинный: он обычно несёт и срок, и исполнителя.
        keep = max(numbers, key=lambda n: len(flat[n][2]))
        drop |= {n for n in numbers if n != keep}
    if not drop:
        return merged, stats["calls"]
    out = {s: list(v) for s, v in merged.items()}
    for section in SECTIONS:
        out[section] = [text for i, text in enumerate(merged[section])
                        if (section, i) not in {(s, i) for n, (s, i, _) in enumerate(flat) if n in drop}]
    return out, stats["calls"]


def render(merged: dict[str, list[str]], summary: str, discussion: str) -> str:
    parts = []
    if summary.strip():
        parts.append("## Итог\n" + summary.strip())
    for section in SECTIONS:
        if merged[section]:
            parts.append(f"## {section}\n" + "\n".join(f"- {i}" for i in merged[section]))
    if merged[NARRATIVE]:
        parts.append(f"## {NARRATIVE}\n" + "\n\n".join(merged[NARRATIVE]))
    elif discussion.strip():
        parts.append(f"## {NARRATIVE}\n" + discussion.strip())
    return "\n\n".join(parts)


def section_text(recap: str, name: str) -> str:
    match = re.search(rf"^##\s+{name}\s*$\n(.*?)(?=^##\s|\Z)", recap, re.M | re.S)
    return match.group(1).strip() if match else ""


def whole_pass(title: str, markdown: str, model: str, temperature: float) -> str:
    raw, stats = p.call_ollama(
        model, p.system_prompt(None), p.build_user_message(title, markdown),
        temperature=temperature, min_reply_tokens=p.REPLY_TOKENS_FLOOR["recap"],
    )
    return p.strip_code_fences(raw), stats


def chunk_facts(markdown: str, model: str, limit: int = 13_000) -> tuple[str, int, int]:
    """Возвращает и число **фактических** вызовов: ретраи тоже стоят денег, а
    в первой версии `calls` их не считал — цена ансамбля в таблицах была занижена
    (до шести вызовов при записанных четырёх)."""
    pieces = chunked.split_on_turns(markdown, limit)
    facts, calls = [], 0
    for index, piece in enumerate(pieces, 1):
        raw, stats = p.call_ollama(
            model, chunked.EXTRACT_PROMPT + p.language_lock(),
            f"Фрагмент {index} из {len(pieces)}.\n\n{piece}",
            min_reply_tokens=p.REPLY_TOKENS_FLOOR["facts"],
        )
        calls += stats["calls"]
        text = p.strip_code_fences(raw).strip()
        if text and not text.upper().startswith("ПУСТО"):
            facts.append(text)
    return "\n".join(facts), len(pieces), calls


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--meeting", default=MEETING)
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--branches", default="t0,sample,chunks",
                    help="через запятую: t0 · sample · chunks")
    ap.add_argument("--dedup", choices=["mech", "model"], default="mech",
                    help="mech — только пересечение слов; model — плюс вызов «покажи дубли»")
    args = ap.parse_args()

    title, markdown = p.transcript(args.meeting)
    out = HERE / "out" / args.out
    out.mkdir(parents=True, exist_ok=True)

    started = time.time()
    branches, log, summary, discussion = [], [], "", ""
    for name in args.branches.split(","):
        name = name.strip()
        if name in ("t0", "sample"):
            temperature = 0.0 if name == "t0" else SAMPLE_TEMPERATURE
            recap, stats = whole_pass(title, markdown, args.model, temperature)
            branches.append(items_from_recap(recap))
            # «Итог» и «Ход обсуждения» — проза, механически не сливаются.
            # Берутся из детерминированной ветки, чтобы не зависеть от жребия.
            if name == "t0" or not summary:
                summary = section_text(recap, "Итог")
                discussion = section_text(recap, "Ход обсуждения")
            log.append({"branch": name, "temperature": temperature, **stats})
            (out / f"branch-{len(branches)}-{name}.md").write_text(recap + "\n", encoding="utf-8")
        elif name == "chunks":
            facts, pieces, chunk_calls = chunk_facts(markdown, args.model)
            branches.append(items_from_facts(facts))
            log.append({"branch": "chunks", "pieces": pieces, "characters": len(facts),
                        "calls": chunk_calls})
            (out / f"branch-{len(branches)}-facts.md").write_text(facts + "\n", encoding="utf-8")
        else:
            print(f"неизвестная ветка: {name}")
            return 1

    merged = merge(branches)
    dedup_calls = 0
    if args.dedup == "model":
        merged, dedup_calls = dedup_by_model(merged, args.model)
    body = render(merged, summary, discussion)
    (out / "recap.md").write_text(body + "\n", encoding="utf-8")
    calls = sum(b.get("calls", 1) for b in log) + dedup_calls
    (out / "stats.json").write_text(json.dumps({
        "branches": log,
        "calls": calls,
        "items": {s: len(v) for s, v in merged.items()},
        "seconds": round(time.time() - started, 1),
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{args.out}: {calls} вызовов · "
          + " ".join(f"{s} {len(v)}" for s, v in merged.items())
          + f" · {time.time() - started:.0f} с")
    return 0


if __name__ == "__main__":
    sys.exit(main())
