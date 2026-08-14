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
import lint
import owners
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


# Метка ищется в строке, с которой сняты маркер буллета и болд: экстрактор пишет и
# `- ДОГОВОРИЛИСЬ:`, и `**ЗАДАЧА:**`, и двоеточие оказывается то внутри болда, то вне.
FACT_HEAD = re.compile(r"^\s*(?:[-*]\s+)?(?P<label>[А-ЯЁ]{4,})\s*:\s*(?P<body>.*)$")


def items_from_facts(facts: str) -> dict[str, list[str]]:
    """Разбор форм, в которых экстрактор пишет один и тот же размеченный список.

    Он выдаёт то `ДОГОВОРИЛИСЬ: раз; два; три` одной строкой, то `ДОГОВОРИЛИСЬ:`
    и буллеты следом. Первая версия разбора склеивала первую форму в один пункт,
    а вторую теряла целиком: из двенадцати строк подхватывались шесть, и
    механическая сборка выглядела вдвое хуже свободной. Это была цена разбора, а
    не сборки.

    **Четвёртая форма, найденная судейским аудитом:** `- ДОГОВОРИЛИСЬ: раз; два` —
    метка внутри буллета. Разбор проверял буллет раньше метки, поэтому строка целиком,
    вместе с ярлыком, падала в текущую секцию — а текущей к этому моменту стоял
    «ОТКРЫТО», и в шестнадцати ячейках m2 решения и задачи уехали дословными
    буллетами «ДОГОВОРИЛИСЬ:», «ЗАДАЧА:» внутрь «Открытых вопросов» (JUDGE.md,
    раздел «Читаемость»). Отсюда правило: метка ищется **после** снятия маркера
    буллета и болда, и строка с меткой не может попасть в конспект дословно ни при
    какой форме. Формы зафиксированы фикстурами в `test_parse.py` — этот дефект
    возвращался четыре раза, каждый раз новой формой.
    """
    out = {s: [] for s in SECTIONS + [NARRATIVE]}
    current = None
    for raw in facts.split("\n"):
        line = raw.strip()
        if not line or line.upper().startswith("ПУСТО"):
            continue
        head = FACT_HEAD.match(line.replace("**", ""))
        label = head.group("label").upper() if head else None
        if label:
            # Метка вне четырёх (`chunked.EXTRACT_PROMPT` просит ровно ДОГОВОРИЛИСЬ /
            # ЗАДАЧА / ОТКРЫТО / ТЕМА) секцию не переключает, но и дословно в конспект
            # не едет: остаётся тело без ярлыка. Пятая форма ярлыка — вопрос времени,
            # и она не должна снова оказаться в документе.
            target = FACT_LABELS.get(label, current)
            if target:
                current = target
                # «раз; два; три» — три пункта, а не один. Точка с запятой здесь
                # разделитель списка: экстрактору так велено промптом.
                out[current] += [part.strip() for part in head.group("body").split(";")
                                 if len(part.strip()) > 15]
            continue
        bullet = re.match(r"^[-*]\s+(.*)$", line)
        if bullet:
            if current:
                out[current].append(bullet.group(1).strip())
            continue
        if current:
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


TIMECODE = re.compile(r"\b(\d{1,2}):(\d{2})\b")


HEADING_LINE = re.compile(r"^\s*\*\*.+\*\*\s*:?\s*$")
HEADER_TIMECODE_LIMIT = 12   # символов от начала строки, где таймкод — это заголовок


def block_head(line: str) -> bool:
    """Начинает ли строка новый абзац «Хода обсуждения».

    Заголовок абзаца выглядит двояко: `**00:15 – 06:28**: текст` (таймкод в начале) или
    отдельной болд-строкой `**Тема (05:14 – 12:13)**` с телом следующей строкой.
    Таймкод **в глубине** длинной строки заголовком не считается: в теле абзаца стоят
    сроки («до следующей встречи в среду (9:30)»), и по ним абзац отрывался от своего
    заголовка и уезжал в другое место хронологии.
    """
    found = TIMECODE.search(line)
    if not found:
        return False
    return found.start() <= HEADER_TIMECODE_LIMIT or bool(HEADING_LINE.match(line))


def prose_blocks(lines: list[str]) -> list[str]:
    """Абзацы «Хода обсуждения» — блоки, а не строки.

    `items_from_recap` собирает секцию построчно, и это верно для буллетов, но не для
    прозы: у одной ветки блок выглядит как `**00:15 – 06:28**: текст` одной строкой, у
    другой — болд-заголовок и тело отдельной строкой, у третьей за таймкодом идут
    подпункты уровней. Строка, которая не начинает абзац, продолжает предыдущий; иначе
    любая пересортировка рвёт заголовок от тела.
    """
    blocks: list[str] = []
    for line in lines:
        if block_head(line) or not blocks:
            blocks.append(line)
        else:
            blocks[-1] += "\n" + line
    return blocks


def block_span(text: str) -> tuple[int, int] | None:
    """Интервал блока — из его **заголовка**: первая строка, первые два таймкода.

    Не min/max по всему блоку: в теле абзаца стоят сроки («завтра в 12:30», «встреча в
    среду в 9:30»), и по ним блок про 20:46 оказывался в начале встречи. Блок, у
    которого таймкода в заголовке нет вовсе, места в хронологии не занимает — он идёт
    после неё (так уходит в конец ТЕМА-строка экстрактора, у которой заголовок —
    название встречи).
    """
    head = text.split("\n", 1)[0]
    seconds = [int(m.group(1)) * 60 + int(m.group(2)) for m in TIMECODE.finditer(head)]
    if not seconds:
        return None
    start = seconds[0]
    return (start, max(start, seconds[1]) if len(seconds) > 1 else start)


def merge_prose(branches: list[dict[str, list[str]]]) -> list[str]:
    """«Ход обсуждения» всех ветвей — **одна** секция: одна хронология, не две.

    Дефект, найденный судейским аудитом: в шести code-ячейках m2 ход обсуждения выписан
    дважды — сначала пять блоков ветки t=0 (00:15 → 28:51), потом три блока сэмпла
    (05:14 → конец) своими, несогласованными таймкодами; две ячейки за это получили
    читаемость 1 из 5, «пользоваться нельзя» (JUDGE.md). Причина механическая:
    `merge()` сливал прозу тем же порогом пересечения слов, что и буллеты, а он на
    пересказе не срабатывает никогда — и секция получалась конкатенацией ветвей в
    порядке ветвей.

    Что делает это слияние: разбирает прозу на блоки, ставит их в один хронологический
    порядок по таймкоду блока и **ничего не выбрасывает**. Блоки без таймкода идут
    после хронологии в порядке ветвей.

    Почему не выбрасывает. Отбрасывание блока, чей интервал уже занят, убирает второй
    проход целиком — и стоит **0,87 пункта покрытия на m2** (13,12 → 12,25 попарно на
    восьми ячейках): у сэмпла в перекрытых минутах лежит то, чего нет ни в одном
    буллете (Сбербанк как прецедент, «на коленках»). Отбрасывание «пересказов» по
    новизне слов не помогает: на пороге, где оно вообще что-то режет, оно уже стоит
    0,25 пункта на m3, а на m2 убирает 0,2 блока из 10,8 — лексическая новизна не
    отличает «то же другими словами» от «другое», это та же стена, на которой сорвался
    симметричный дедуп (A5.2). Значит выбор такой: одна хронология без потерь — или
    краткость за счёт полноты; здесь взята первая, вторая посчитана и предъявлена.
    """
    kept: list[tuple[tuple[int, int] | None, str]] = []
    for branch in branches:
        for text in prose_blocks(branch.get(NARRATIVE, [])):
            kept.append((block_span(text), text))
    timed = sorted(((span, text) for span, text in kept if span), key=lambda pair: pair[0])
    return [text for _, text in timed] + [text for span, text in kept if span is None]


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


ASYM_PROMPT = """
Ниже черновик конспекта встречи: его пункты помечены буквами A, B, C…
После него — список кандидатов, помеченных числами: К1, К2, К3…

Для каждого кандидата реши, есть ли в черновике пункт про то же самое.
Ответ — по строке на каждого кандидата, в том же порядке, строго в форме:

К1 = C
К2 = 0

Справа — буква того пункта черновика, который говорит то же самое, что кандидат,
или 0, если такого пункта в черновике нет. Справа ровно одна буква, не список.
Буква обязана быть из черновика. Ничего, кроме таких строк, не пиши.

То же самое — это тот же факт другими словами, а не соседний факт про ту же тему.
«Договорились переводить сборку на новый раннер» и «Сборку решено собирать на
новом раннере, старый выключаем» — одно и то же, это пара. «Договорились
переводить сборку на новый раннер» и «Тесты гоняем в два потока» — не пара.
""".strip()
# Буквы слева и числа справа — не оформление. С номерами по обе стороны 4B
# отвечает арифметической прогрессией («К4 = 5, К5 = 6, … К17 = 18»): она
# продолжает узор, а не сравнивает тексты. Из 19 кандидатов так нашлось 4 дубля
# при 22 буллетах на выходе. Разнотипные метки этот узор ломают.
LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

# Сколько кандидатов может уйти в один пункт черновика. Ветки-кандидаты дают две
# формулировки одного факта, экстрактор иногда дробит её на две-три строки —
# всё, что шире, это «общая тема», та самая склейка крупными группами, на которой
# сорвался симметричный дедуп (A5.2).
MAX_ABSORB = 3
# Проверки заземления из lint.py — те же, которыми в таблицах считаются выдумки.
# «латиница не из транскрипта» не входит: ASR ломает латиницу на входе, и промпт
# прямо просит её починить, так что расхождение там обычно правка, а не выдумка.
GROUNDING_CHECKS = (
    "срок не из транскрипта", "посчитанный срок", "выдуманный участник",
    "ответственный-призрак", "имя не из транскрипта", "число не из транскрипта",
)


def ungrounded(text: str, section: str, transcript: str) -> bool:
    """Есть ли в добавке имя, число или срок, которых в транскрипте не было.

    Проверка не своя: тот же `lint.lint`, которым считаются выдумки в таблицах, —
    иначе фильтр и метрика разошлись бы, и добавки отбирались бы по одному
    правилу, а вранье считалось по другому.
    """
    report = lint.lint(f"## {section}\n- {text}\n", transcript, "candidate")
    return any(report.count(check) for check in GROUNDING_CHECKS)


def trim_to_budget(kept: dict[str, list[str]], additions: list[tuple[str, str]],
                   draft: dict[str, list[str]], budget: int) -> int:
    """Урезать **добавки** до бюджета буллетов. Черновик неприкосновенен.

    Порядок — по новизне: сколько значимых слов добавка приносит поверх всего, что
    уже сказано черновиком. Дедуп убирает то, что модель назвала повтором; бюджет
    решает, что делать с остатком, когда его всё равно слишком много, — и решает
    кодом, потому что это выбор про длину документа, а не про смысл.
    """
    if sum(len(kept[s]) for s in SECTIONS) <= budget:
        return 0
    known = set()
    for section in SECTIONS:
        for text in draft.get(section, []):
            known |= key_words(text)
    room = max(0, budget - sum(len(draft.get(s, [])) for s in SECTIONS))
    # Жадно и **с пересчётом**: слова взятой добавки сразу становятся известными.
    # Один общий рейтинг новизны против черновика этого не делает — семь добавок,
    # каждая новая для черновика, повторяют друг друга, и место уходит на одно и
    # то же другими словами.
    survivors, pool = [], list(additions)
    while pool and len(survivors) < room:
        best = max(pool, key=lambda pair: len(key_words(pair[1]) - known))
        pool.remove(best)
        survivors.append(best)
        known |= key_words(best[1])
    dropped = 0
    for section, item in additions:
        if (section, item) not in survivors and item in kept[section]:
            kept[section].remove(item)
            dropped += 1
    return dropped


ONE_PROMPT = """
Ниже черновик конспекта встречи: его пункты помечены буквами A, B, C…
После него — один кандидат.

Говорит ли какой-нибудь пункт черновика то же самое, что кандидат?
Ответь одной буквой этого пункта — или 0, если такого пункта нет.
Ничего, кроме буквы или нуля, не пиши.

То же самое — это тот же факт другими словами, а не соседний факт про ту же тему.
«Договорились переводить сборку на новый раннер» и «Сборку решено собирать на
новом раннере, старый выключаем» — одно и то же. «Договорились переводить сборку
на новый раннер» и «Тесты гоняем в два потока» — нет.
""".strip()


def match_one(draft: list[tuple[str, str]], candidate: tuple[str, str],
              model: str) -> tuple[int, int, str]:
    """Один кандидат за вызов: буква пункта черновика или 0.

    Дороже списка ровно во столько раз, сколько кандидатов, и куплено это тем,
    что на списке 4B отвечает **позиционной диагональю**: на реальном прогоне она
    вернула К1=A, К2=B, К3=D, К4=F, К5=E… — перестановку, а не сопоставление, и
    среди «дублей» оказались «три уровня взаимодействия» против «Deep Dive» и
    «структура главной простая» против «облегчённого Rich-text». Ни секционное
    вето, ни предел на группу такую подделку отличить не могут: она выглядит
    ровно как аккуратный ответ. Одному кандидату продолжать нечего.
    """
    listing = "Черновик:\n" + "\n".join(
        f"{LETTERS[n]}. [{s}] {text}" for n, (s, text) in enumerate(draft))
    listing += f"\n\nКандидат: [{candidate[0]}] {candidate[1]}"
    raw, stats = p.call_ollama(model, ONE_PROMPT, listing, temperature=0.0)
    answer = p.strip_code_fences(raw).strip()
    letter = re.match(r"^\W*([A-Za-z]|0)", answer)
    target = -1
    if letter and letter.group(1).upper() in LETTERS:
        target = LETTERS.index(letter.group(1).upper())
    return target, stats["calls"], answer.split("\n")[0][:40]


def dedup_pass(kept: dict[str, list[str]], branch: dict[str, list[str]], model: str,
               transcript: str | None, diagnostics: dict,
               additions: list[tuple[str, str]], per_candidate: bool,
               use_model: bool = True) -> tuple[int, str]:
    """Кандидаты одной ветки против текущего черновика: один вызов, по вызову на
    кандидата или ни одного (`use_model=False`).

    Черновик здесь — не только ветка t=0, но и то, что уже дописано предыдущей
    веткой. Иначе две ветки, нашедшие один и тот же **новый** факт, дают два
    буллета: каждая по отдельности не совпала ни с чем в t=0.
    """
    # Кандидаты: всё из ветки, кроме того, что и так дословно похоже на пункт
    # черновика. Порог 0,55 ловит мало (A5.2), но то, что ловит, — настоящие
    # дубли, и на них не нужно тратить место в промпте.
    candidates = [(s, item) for s in SECTIONS for item in branch.get(s, [])
                  if not any(same(item, other) for other in kept[s])]
    diagnostics["candidates"] += len(candidates)
    draft = [(s, text) for s in SECTIONS for text in kept[s]][:len(LETTERS)]
    if not candidates or not draft:
        for section, item in candidates:
            kept[section].append(item)
            additions.append((section, item))
            diagnostics["added"] += 1
        return 0, ""

    listing = "Черновик:\n" + "\n".join(
        f"{LETTERS[n]}. [{s}] {text}" for n, (s, text) in enumerate(draft))
    listing += "\n\nКандидаты:\n" + "\n".join(
        f"К{n + 1}. [{s}] {text}" for n, (s, text) in enumerate(candidates))

    answers: list[tuple[int, int]] = []   # (номер кандидата, номер пункта черновика)
    calls, reply = 0, ""
    if not use_model:
        # Контроль: дедупа нет вовсе, лишнее срезает только бюджет. Он оказался
        # точнее вызова, и это и есть вывод A5.2 — см. таблицу в OPTIMIZATION.md.
        reply = "без вызова"
    elif per_candidate:
        for index, candidate in enumerate(candidates):
            target, one_call, answer = match_one(draft, candidate, model)
            answers.append((index, target))
            calls += one_call
            reply += f"К{index + 1} = {answer}\n"
    else:
        raw, stats = p.call_ollama(model, ASYM_PROMPT, listing, temperature=0.0)
        calls, reply = stats["calls"], raw.strip()
        for line in p.strip_code_fences(raw).strip().split("\n"):
            pair = re.match(r"^\s*К?\s*(\d+)\s*[=:—-]+\s*([A-Za-z]|0)", line.strip())
            if not pair:
                continue
            letter = pair.group(2).upper()
            answers.append((int(pair.group(1)) - 1,
                            LETTERS.index(letter) if letter in LETTERS else -1))

    duplicate: set[int] = set()
    absorbed: dict[int, int] = {}
    for candidate, target in answers:
        if not 0 <= candidate < len(candidates):
            continue
        diagnostics["answered"] += 1
        # Ноль и любая буква вне черновика — «пары нет», то есть кандидат
        # остаётся. Молчание о кандидате читается так же: удалить пункт можно
        # только по прямому указанию.
        if not 0 <= target < len(draft):
            continue
        if draft[target][0] != candidates[candidate][0]:
            diagnostics["vetoed_section"] += 1
            continue
        if absorbed.get(target, 0) >= MAX_ABSORB:
            diagnostics["vetoed_absorb"] += 1
            continue
        absorbed[target] = absorbed.get(target, 0) + 1
        duplicate.add(candidate)
    diagnostics["duplicates"] += len(duplicate)

    for index, (section, item) in enumerate(candidates):
        if index in duplicate:
            continue
        if transcript and ungrounded(item, section, transcript):
            diagnostics["ungrounded"] += 1
            continue
        kept[section].append(item)
        additions.append((section, item))
        diagnostics["added"] += 1
    return calls, listing + "\n\nОТВЕТ:\n" + reply.strip()


def lint_density(items: dict[str, list[str]], transcript: str) -> float:
    """Находок заземления на буллет ветки."""
    bullets = [(s, t) for s in SECTIONS for t in items.get(s, [])]
    if not bullets:
        return float("inf")
    return sum(1 for s, t in bullets if ungrounded(t, s, transcript)) / len(bullets)


def choose_draft_index(branches: list[dict], names: list[str], transcript: str) -> int:
    """Какая ветка «целиком» становится неприкосновенным черновиком.

    Политика `clean`, принятая 2026-08-13 после гейта №1: берётся ветка с **меньшей
    плотностью выдумок на буллет** среди `t0` и `sample`. Черновик не редактируется
    никем, поэтому его выдумки доезжают до пользователя целиком — значит выбирать
    надо по чистоте, а не по жребию.

    Почему не по длине и не по флагу схлопывания: на первой встрече `t0` короткий
    (519 токенов, ниже порога) и при этом **хороший**, а на третьей короткий и
    конфабулирующий — «Ильяс» превращается в «Илью Сафронова» и получает задачи.
    Длина их не различает, плотность выдумок различает: 0,000 против 0,191 на второй
    встрече (черновик остаётся `t0` во всех восьми прогонах), 0,636 против 0,291 на
    третьей (во всех восьми меняется на сэмпл), поровну на первой — где выбор и не
    важен.

    Замер на сохранённых ветках (пять батчей, попарно против политики «всегда t0»):
    выдумки на третьей встрече 14,9 → 7,2 при том же покрытии, покрытие первой
    встречи 10,12 → 10,50, вторая встреча без изменений. Ноль новых вызовов: обе
    ветки и так генерируются.
    """
    pool = [i for i, n in enumerate(names) if n in ("t0", "sample")]
    if not pool:
        return names.index("t0")
    return min(pool, key=lambda i: lint_density(branches[i], transcript))


def merge_asymmetric(draft: dict[str, list[str]], others: list[dict[str, list[str]]],
                     model: str, transcript: str | None,
                     budget: int = 0, per_candidate: bool = False,
                     use_model: bool = True) -> tuple[dict[str, list[str]], dict]:
    """«База + добавки»: ветка t=0 — конспект, остальные ветки — только кандидаты.

    Симметричное слияние не сходится (A5.2): при пороге пересечения слов дубли не
    ловятся, а модель, которой дан общий список, кластеризует по теме и один раз
    вернула группу из 21 номера. Здесь у неё нет такой возможности **по форме
    ответа**: черновик она не видит как редактируемый текст, а про каждого
    кандидата отвечает одной буквой — пунктом черновика или нулём. Схлопнуть
    черновик она не может, потерять пункт — тоже: удаляются только кандидаты, и
    только те, на которые она показала пальцем.
    """
    kept = {s: list(draft.get(s, [])) for s in SECTIONS + [NARRATIVE]}
    diagnostics = {"candidates": 0, "answered": 0, "duplicates": 0, "vetoed_section": 0,
                   "vetoed_absorb": 0, "ungrounded": 0, "added": 0, "over_budget": 0}
    calls, exchanges, additions = 0, [], []
    for index, branch in enumerate(others, 1):
        branch_calls, exchange = dedup_pass(kept, branch, model, transcript,
                                            diagnostics, additions, per_candidate,
                                            use_model)
        calls += branch_calls
        if exchange:
            exchanges.append(f"=== ветка {index}\n{exchange}")
    if budget:
        diagnostics["over_budget"] = trim_to_budget(kept, additions, draft, budget)
    return kept, {"calls": calls, "exchange": "\n\n".join(exchanges), **diagnostics}


def render(merged: dict[str, list[str]], summary: str, discussion: str,
           names: "owners.Names | None" = None) -> str:
    """Собрать документ. `names` включает фильтр слота исполнителя (`owners.py`).

    Фильтр стоит здесь, а не в разборе ветвей, потому что рендер — единственная точка,
    через которую проходят и живой прогон, и пересборка `replay_asym`: иначе замер и
    продукт разошлись бы. `names=None` — старое поведение, для фикстур разбора.
    """
    parts = []
    if summary.strip():
        parts.append("## Итог\n" + summary.strip())
    for section in SECTIONS:
        items = merged[section]
        if names is not None and section == "Задачи":
            items = [owners.scrub(item, names) for item in items]
        if items:
            parts.append(f"## {section}\n" + "\n".join(f"- {i}" for i in items))
    if merged[NARRATIVE]:
        parts.append(f"## {NARRATIVE}\n" + "\n\n".join(merged[NARRATIVE]))
    elif discussion.strip():
        parts.append(f"## {NARRATIVE}\n" + discussion.strip())
    return "\n\n".join(parts)


def section_text(recap: str, name: str) -> str:
    match = re.search(rf"^##\s+{name}\s*$\n(.*?)(?=^##\s|\Z)", recap, re.M | re.S)
    return match.group(1).strip() if match else ""


def whole_pass(title: str, markdown: str, model: str, temperature: float) -> str:
    """Ветка «целиком». Путь t=0 — это черновик, и он **страхуется ретраем**.

    Изменение конструкции 2026-08-13, купленное третьей встречей: на
    `20260810_094722` ветка t=0 схлопнулась детерминированно во всех восьми
    прогонах (684 токена против порога 800), потеряла «Ход обсуждения» целиком и
    дала черновик 6/21 — хуже худшего из восьми сэмплов базы (10–16). Черновик по
    построению неприкосновенен, поэтому один плохой детерминированный ответ
    закреплялся навсегда, да ещё съедал 11 буллетов бюджета из 14.

    Материализовалось предупреждение A4: детерминизм t=0 доказан, а среднее — нет,
    и на встрече такого жанра детерминированная точка оказалась хуже всего
    распределения. Ретрай при t=0,3 — страховка ровно на этот случай.
    """
    raw, stats = p.call_ollama(
        model, p.system_prompt(None), p.build_user_message(title, markdown),
        temperature=temperature, min_reply_tokens=p.REPLY_TOKENS_FLOOR["recap"],
        retry_temperature=p.RETRY_TEMPERATURE if temperature == 0 else None,
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
    ap.add_argument("--budget", type=int, default=0,
                    help="asym: максимум буллетов, добавки сверх бюджета режет код (0 — без предела)")
    ap.add_argument("--dedup", choices=["mech", "model", "asym", "asym-one", "budget"],
                    default="mech",
                    help="mech — только пересечение слов; model — плюс вызов «покажи дубли»; "
                         "asym — ветка t0 как черновик, остальные только кандидатами; "
                         "asym-one — то же, но по вызову на кандидата; "
                         "budget — черновик плюс добавки, отбирает только код")
    args = ap.parse_args()

    title, markdown = p.transcript(args.meeting)
    out = HERE / "out" / args.out
    out.mkdir(parents=True, exist_ok=True)

    started = time.time()
    branches, names, log, summary, discussion = [], [], [], "", ""
    prose: dict[str, tuple[str, str]] = {}
    draft_branch = None
    for name in args.branches.split(","):
        name = name.strip()
        if name in ("t0", "sample"):
            temperature = 0.0 if name == "t0" else SAMPLE_TEMPERATURE
            recap, stats = whole_pass(title, markdown, args.model, temperature)
            branches.append(items_from_recap(recap))
            names.append(name)
            # «Итог» и «Ход обсуждения» — проза, механически не сливаются, поэтому
            # берутся целиком из одной ветки. Из **той же, что стала черновиком**:
            # иначе в документ поедет проза ветки, которую политика забраковала как
            # грязную, — а «Итог» пользователь читает первым. На метрику это не
            # влияет (матчер «Итог» пропускает), на продукт влияет.
            prose[name] = (section_text(recap, "Итог"), section_text(recap, "Ход обсуждения"))
            log.append({"branch": name, "temperature": temperature, **stats})
            (out / f"branch-{len(branches)}-{name}.md").write_text(recap + "\n", encoding="utf-8")
        elif name == "chunks":
            facts, pieces, chunk_calls = chunk_facts(markdown, args.model)
            branches.append(items_from_facts(facts))
            names.append(name)
            log.append({"branch": "chunks", "pieces": pieces, "characters": len(facts),
                        "calls": chunk_calls})
            (out / f"branch-{len(branches)}-facts.md").write_text(facts + "\n", encoding="utf-8")
        else:
            print(f"неизвестная ветка: {name}")
            return 1

    merged = merge(branches)
    # Проза сливается своим правилом при любом варианте дедупа: `merge()` мерит
    # пересечение слов, а на пересказе оно не срабатывает никогда.
    merged[NARRATIVE] = merge_prose(branches)
    dedup_calls, asym = 0, None
    if args.dedup == "model":
        merged, dedup_calls = dedup_by_model(merged, args.model)
    elif args.dedup.startswith(("asym", "budget")):
        if "t0" not in names:
            print("asym требует ветку t0: она и есть черновик")
            return 1
        draft_index = choose_draft_index(branches, names, markdown)
        draft = branches[draft_index]
        draft_branch = names[draft_index]
        summary, discussion = prose.get(draft_branch, (summary, discussion))
        others = [b for i, b in enumerate(branches) if i != draft_index]
        merged, asym = merge_asymmetric(draft, others, args.model, markdown, args.budget,
                                        per_candidate=args.dedup == "asym-one",
                                        use_model=args.dedup != "budget")
        dedup_calls = asym.pop("calls")
        if "exchange" in asym:
            (out / "dedup-asym.txt").write_text(asym.pop("exchange") + "\n", encoding="utf-8")
        # «Ход обсуждения» — абзацы, а не буллеты: он не тратит бюджет краткости,
        # ради которого всё это делается, а брать его из одной ветки стоило
        # 12/14 → 9/14 (A5, поправка 2). Поэтому он сливается по всем ветвям — но
        # хронологией, а не конкатенацией: см. `merge_prose`.
        merged[NARRATIVE] = merge_prose([branches[draft_index]] + others)
    body = render(merged, summary, discussion, owners.Names.of(markdown))
    (out / "recap.md").write_text(body + "\n", encoding="utf-8")
    calls = sum(b.get("calls", 1) for b in log) + dedup_calls
    (out / "stats.json").write_text(json.dumps({
        "branches": log,
        "asym": asym,
        "dedup": args.dedup,
        # Какая ветка стала черновиком: без этого не видно, срабатывала ли политика
        # выбора и на каких прогонах.
        "draft_branch": draft_branch,
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
