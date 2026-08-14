"""Пакет П0 плана v3: модель ищет утверждения по схеме, а не пишет конспект.

Идея пробы (`plan-recap-v3.md`): пространство дефектов свободного текста
бесконечно, детекторы перечислимы — значит дефекты надо делать непорождаемыми, а
не чинить фильтрами. Здесь это проверяется в самом дешёвом виде: извлечение идёт
окнами по транскрипту в **JSON по схеме** (structured outputs Ollama), каждое
утверждение несёт дословную цитату-спан и исполнителя из закрытого списка имён
встречи. Выдуманное имя не проходит enum, эхо промпта не влезает в схему, метка
экстрактора не существует — парсить нечего.

Что здесь есть и чего нет. Есть: окна, две температуры, схема, спан- и
enum-проверки кодом, дедуп, минимальный рендер списка — ровно столько, сколько
нужно, чтобы посчитать покрытие `golden_match.py` и прогнать четыре детектора
`check_defects.py`. Нет: карты тем, прозы, верификатора, бюджета буллетов — это
П1–П3, и они существуют, только если П0 зелёный.

    python3 bench_extract.py --out v3/m1-1 --meeting 20260812_144201
    python3 bench_extract.py --out v3/m1-free-1 --meeting 20260812_144201 --free
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

import bench_ensemble as b
import chunked
import golden_match as gm
import owners
import promptlib as p

HERE = Path(__file__).parent
MODEL = "qwen3.5:4b"

# 13k — проверенная точка A1/chunk-facts (README, «нарезка по 13 000 символов»):
# 13 решений против 6 при 26k. Перекрытие 20 % — страховка от утверждения,
# разорванного границей окна: без него договорённость, которую начали в конце
# одного окна и закрыли в начале другого, не видна ни одному из двух.
WINDOW = 13_000
OVERLAP = 0.20
SAMPLE_TEMPERATURE = 0.7

# Тип утверждения → секция конспекта. Секции — те же, что у `bench_ensemble`,
# иначе матчер и детекторы считали бы другой документ.
TYPE_SECTION = {"agreement": "Решения", "task": "Задачи", "question": "Открытые вопросы"}

# Короткое имя встречи — как в `check_defects.py`; батч раскладывается по ним.
MEETINGS = {"m1": "20260812_144201", "m2": "20260812_153107", "m3": "20260810_094722"}

EXTRACT_PROMPT = """
Ты выписываешь из фрагмента транскрипта рабочей встречи то, о чём договорились, кто что делает и что осталось нерешённым.

Поля каждого пункта:
- type: agreement — договорённость; task — кто что делает; question — обсудили и не решили.
- text: формулировка пункта по-русски, одной фразой.
- quote: одно-два предложения подряд из фрагмента, по которым пункт виден. Копируй символ в символ, подряд, с одного места. Нельзя: сокращать, ставить многоточие, склеивать два куска, брать слова из разных реплик, заключать в кавычки.
- t: таймкод реплики, из которой взята цитата, в виде ММ:СС.
- owner: имя исполнителя — только из списка допустимых имён. Не уверен — null. Пункт без исполнителя честнее пункта с чужим исполнителем.
- deadline: срок, если он прозвучал вслух. Не прозвучал — null.

Фрагмент — единственный источник, ничего не додумывай. Не о чем писать — верни пустой список.
""".strip()

LEAN_PROMPT = """
Ты выписываешь из фрагмента транскрипта рабочей встречи то, о чём договорились, кто что делает и что осталось нерешённым. Не пересказывай реплики: пиши только то, что участники проговорили как решение, задачу или нерешённый вопрос.

Поля каждого пункта:
- type: agreement — договорённость; task — кто что делает; question — обсудили и не решили.
- text: формулировка пункта по-русски, одной фразой.
- quote: одно-два предложения подряд из фрагмента, по которым пункт виден. Копируй символ в символ, подряд, с одного места. Нельзя: сокращать, ставить многоточие, склеивать два куска.

Фрагмент — единственный источник, ничего не додумывай. Не о чем писать — верни пустой список.
""".strip()


# ---------------------------------------------------------------------------
# Окна
# ---------------------------------------------------------------------------

def windows(markdown: str, limit: int = WINDOW, overlap: float = OVERLAP) -> list[str]:
    """Окна по границам реплик с перекрытием.

    Резка — та же, что у `chunked.split_on_turns` (общая функция `chunked.turns`):
    делить внутри реплики значит отнять у куска говорящего и таймкод. Перекрытие
    набирается хвостовыми репликами предыдущего окна, а не символами, по той же
    причине.
    """
    header, turn_list = chunked.turns(markdown)
    want_tail = int(limit * overlap)

    pieces: list[list[str]] = []
    current: list[str] = []
    size = 0
    for turn in turn_list:
        if current and size + len(turn) > limit:
            pieces.append(current)
            tail: list[str] = []
            tail_size = 0
            for previous in reversed(current):
                if tail_size >= want_tail:
                    break
                tail.insert(0, previous)
                tail_size += len(previous)
            current, size = list(tail), tail_size
        current.append(turn)
        size += len(turn)
    if current and any(t.strip() for t in current):
        pieces.append(current)
    out = ["".join(piece) for piece in pieces]
    # Шапка несёт дату и список участников — первое окно её сохраняет, как в нарезке.
    if out:
        out[0] = header + "## Transcript" + out[0]
    return out


# ---------------------------------------------------------------------------
# Закрытый список имён
# ---------------------------------------------------------------------------

SENTENCE_START = re.compile(r"(?:^|[.!?…]\s+|[\"«]\s*)$")


def meeting_names(markdown: str, min_mentions: int = 2) -> list[str]:
    """Имена, которыми enum схемы закрывает поле `owner`.

    Три источника, как в плане: шапка встречи, шапки реплик (кроме ярлыков
    диаризации) и словарь имён транскрипта. Последний — механический: слово с
    заглавной **не в начале предложения**, встреченное хотя бы дважды. Правило
    грубое и пропускает мусор («Ну», «Европа», «Фигмы»), и это осознанная цена:
    точный список имён строился бы подгонкой под конкретную встречу, а enum нужен
    не для красоты, а чтобы **выдуманного** имени не существовало как варианта.
    Кто из списка настоящий исполнитель — вопрос П1, не П0.
    """
    header, _, body = markdown.partition("## Transcript")
    found: dict[str, int] = {}

    def add(token: str, weight: int = 10) -> None:
        token = token.strip()
        if len(token) >= 3 and not owners.SPEAKER_LABEL.search(token):
            found[token] = found.get(token, 0) + weight

    for line in header.split("\n"):
        if re.match(r"\*\*(Participants|Organizer|Invited)\s*:", line):
            for token in re.findall(owners.CAP, line):
                add(token)
    for line in body.split("\n"):
        head = re.match(r"^\*\*([^*]+)\*\*\s*·", line)
        if head:
            add(head.group(1))

    plain = re.sub(r"^\*\*[^*]+\*\*\s*·.*$", "", body, flags=re.M)
    for match in re.finditer(owners.CAP, plain):
        if not SENTENCE_START.search(plain[max(0, match.start() - 3):match.start()]):
            add(match.group(0), 1)

    seen: dict[str, str] = {}
    for token, weight in sorted(found.items(), key=lambda kv: -kv[1]):
        if weight >= min_mentions and token.lower() not in seen:
            seen[token.lower()] = token
    return list(seen.values())


def schema(names: list[str], lean: bool = False) -> dict:
    """JSON-схема контракта утверждения. `owner` — enum по именам встречи.

    `lean` — заход на упрощение, предусмотренный стоп-условием П0: в схеме
    остаются `type`, `text`, `quote`, и ничего больше. Каждое снятое поле снято по
    числу, а не по вкусу: `t` модель ставит неверно в 4–14 случаях на ячейку (код
    считает его по спану точно), `deadline` снимался спан-проверкой до шести раз на
    ячейку, а `owner` в 10 выборах из 15 оказался междометием из механического
    словаря имён. Поля, которые нечем заполнить, — это токены, потраченные не на
    поиск договорённостей.
    """
    fields: dict[str, dict] = {
        "type": {"type": "string", "enum": list(TYPE_SECTION)},
        "text": {"type": "string"},
        "quote": {"type": "string"},
    }
    if not lean:
        fields |= {
            "t": {"type": "string"},
            "owner": {"type": ["string", "null"], "enum": [*names, None]},
            "deadline": {"type": ["string", "null"]},
        }
    return {
        "type": "object",
        "properties": {
            "claims": {
                "type": "array",
                "items": {"type": "object", "properties": fields,
                          "required": list(fields)},
            }
        },
        "required": ["claims"],
    }


# ---------------------------------------------------------------------------
# Проверки кодом
# ---------------------------------------------------------------------------

def squeeze(text: str) -> str:
    """Нормализация пробелов — единственный допуск спан-проверки по контракту."""
    return re.sub(r"\s+", " ", text).strip()


def unwrap(quote: str) -> str:
    """Снять оформление поля, не трогая сам спан: кавычки вокруг и край многоточия."""
    return squeeze(quote).strip("\"'«»").strip().strip("…").strip(". ").strip()


def fold(text: str) -> str:
    """Свёртка регистра и `ё` для спан-проверки.

    Куплена той же пробой: из шестнадцати отбросов два — цитата, отличающаяся от
    транскрипта **только заглавной буквой** первого слова (модель начинает спан с
    середины фразы и пишет его с большой). Это не выдумка, а оформление, и матчер
    `golden_match.normalize` сворачивает регистр по той же причине.
    """
    return text.lower().replace("ё", "е")


ELLIPSIS = re.compile(r"\.{2,}|…")
FRAGMENT_MINIMUM = 20


def span_check(quote: str, window: str) -> tuple[int | None, bool]:
    """(позиция первого фрагмента, была ли цитата непрерывной) или (None, …).

    **Почему проверка пофрагментная.** Контракт требует, чтобы `quote` была
    подстрокой окна. 4B под схемой в 11 случаях из 16 отдаёт вместо подстроки
    склейку двух мест через многоточие — при промпте, который многоточие прямо
    запрещает. Строгое чтение выбрасывало бы такое утверждение целиком, а вместе с
    ним и договорённость, которая в нём записана верно.

    Поэтому цитата режется по многоточию и **каждый** фрагмент длиннее 20 символов
    обязан найтись в окне дословно. Гарантия заземления от этого не слабеет:
    выдуманного текста по-прежнему не существует, ни одного фрагмента «на веру» не
    берётся. Слабеет ровно одно — уверенность, что фрагменты стояли рядом.

    Доля непрерывных цитат считается отдельно (`contiguous` в stats): критерий П0
    записан по контракту, и число, по которому он читается, не должно зависеть от
    этого послабления.
    """
    haystack = fold(squeeze(window))
    whole = fold(quote)
    if whole in haystack:
        return haystack.find(whole), True
    fragments = [f.strip() for f in ELLIPSIS.split(quote)]
    fragments = [f for f in fragments if len(f) >= FRAGMENT_MINIMUM]
    if not fragments:
        return None, False
    positions = [haystack.find(fold(f)) for f in fragments]
    if any(position < 0 for position in positions):
        return None, False
    return positions[0], False


TIMECODE_HEAD = re.compile(r"^\*\*[^*]+\*\*\s*·\s*(\d{1,2}:\d{2}(?::\d{2})?)\s*$", re.M)


def timecode_before(window: str, position: int) -> str | None:
    """Ближайший таймкод не позже начала спана — считается кодом, а не моделью.

    Модель ошибается в этом поле грубо и молча (в первой же пробе схемы вместо
    `00:10` пришло `Leyvon`), а позиция спана в окне известна точно. Своё значение
    модели сохраняется в `t_model`, расхождения считаются: это цена поля, которое
    можно было бы из схемы убрать.
    """
    last = None
    for match in TIMECODE_HEAD.finditer(window):
        if match.start() > position:
            break
        last = match.group(1)
    return last


def verify(claim: dict, window: str, names: list[str]) -> tuple[dict | None, str]:
    """Проверенное утверждение или причина отброса.

    Отбрасывает **только** спан-проверка: чужое имя и невыговоренный срок стоят
    полю, а не пункту. Обратное правило убивало бы верную договорённость за
    неверную подпись — ровно то, что «дубль лучше пропуска» запрещает.
    """
    if claim.get("type") not in TYPE_SECTION:
        return None, "тип вне enum"
    text = squeeze(str(claim.get("text") or ""))
    quote = unwrap(str(claim.get("quote") or ""))
    if len(text) < 10:
        return None, "пустой text"
    if len(quote) < 10:
        return None, "пустой quote"
    position, contiguous = span_check(quote, window)
    if position is None:
        return None, "спан не найден"

    owner = claim.get("owner")
    owner_dropped = bool(owner) and owner not in names
    if owner_dropped:
        owner = None
    deadline = claim.get("deadline")
    # Срок проверяется тем же спаном: «к пятнице», которого в цитате нет, — это
    # выдумка, и она снимается молча только с поля.
    deadline_dropped = bool(deadline) and squeeze(str(deadline)).lower() not in quote.lower()
    if deadline_dropped:
        deadline = None

    # Позиция в сжатом тексте ≠ позиция в исходном; для таймкода нужна исходная.
    # Сжатие только схлопывает пробелы, поэтому доля пути по тексту сохраняется —
    # этого хватает, чтобы попасть в нужную реплику, а таймкод берётся её.
    haystack = fold(squeeze(window))
    head = fold(quote[:40])
    raw_position = fold(window).find(head)
    if raw_position < 0:
        raw_position = min(len(window) - 1,
                           int(position * len(window) / max(1, len(haystack))))
    t_code = timecode_before(window, raw_position)
    return {
        "type": claim["type"],
        "text": text,
        "quote": quote,
        "contiguous": contiguous,
        "t": t_code or squeeze(str(claim.get("t") or "")),
        "t_model": squeeze(str(claim.get("t") or "")),
        "t_repaired": bool(t_code) and t_code != squeeze(str(claim.get("t") or "")),
        "owner": owner,
        "owner_dropped": owner_dropped,
        "deadline": deadline,
        "deadline_dropped": deadline_dropped,
    }, ""


# ---------------------------------------------------------------------------
# Дедуп и рендер
# ---------------------------------------------------------------------------

NEAR = 0.80


def dedup(claims: list[dict]) -> tuple[list[dict], int]:
    """Только точный и почти-точный дубль.

    Порог 0,80 по пересечению значимых слов, а не 0,55 как в слиянии ансамбля:
    принцип «дубль лучше пропуска» действует и здесь, а окна перекрываются
    нарочно — схлопывать надо повтор одного и того же спана, а не два разных
    решения об одном предмете.
    """
    kept: list[dict] = []
    dropped = 0
    for claim in claims:
        twin = next((k for k in kept
                     if k["type"] == claim["type"]
                     and (squeeze(k["text"]).lower() == squeeze(claim["text"]).lower()
                          or b.same(k["text"], claim["text"], NEAR))), None)
        if twin is None:
            kept.append(claim)
            continue
        dropped += 1
        # Из двух формулировок остаётся длинная, как в механической сборке A5.1;
        # исполнитель и срок подбираются, если у выжившего их нет.
        if len(claim["text"]) > len(twin["text"]):
            twin["text"] = claim["text"]
        twin["owner"] = twin["owner"] or claim["owner"]
        twin["deadline"] = twin["deadline"] or claim["deadline"]
    return kept, dropped


def sort_key(claim: dict) -> tuple[int, int]:
    match = re.match(r"(\d{1,2}):(\d{2})", claim.get("t") or "")
    return (int(match.group(1)) * 60 + int(match.group(2)) if match else 10 ** 6, 0)


def render(claims: list[dict]) -> str:
    """Минимальный документ: секции, буллеты, хронология. Ни одного вызова модели.

    Полный рендер — П3 (бюджет буллетов, «Ход обсуждения», заметки пользователя).
    Здесь нужен ровно тот документ, который умеют читать `golden_match.py` и
    `check_defects.py`.
    """
    parts = []
    for section in b.SECTIONS:
        items = [c for c in sorted(claims, key=sort_key) if TYPE_SECTION[c["type"]] == section]
        if not items:
            continue
        lines = []
        for claim in items:
            text = claim["text"]
            if section == "Задачи" and claim["owner"]:
                text = f"**{claim['owner']}** — {text}"
            if claim["deadline"]:
                text = f"{text} (срок: {claim['deadline']})"
            lines.append(f"- {text}")
        parts.append(f"## {section}\n" + "\n".join(lines))
    return "\n\n".join(parts)


# ---------------------------------------------------------------------------
# Прогон
# ---------------------------------------------------------------------------

def extract_window(model: str, window: str, index: int, total: int, names: list[str],
                   temperature: float, floor: int | None,
                   lean: bool = False) -> tuple[list[dict], dict, str]:
    user = "\n".join([
        f"Окно {index} из {total}.",
        *([] if lean else ["Допустимые имена: " + ", ".join(names) + "."]),
        "",
        window,
    ])
    raw, stats = p.call_ollama(
        model, (LEAN_PROMPT if lean else EXTRACT_PROMPT) + p.language_lock(), user,
        temperature=temperature, fmt=schema(names, lean),
        min_reply_tokens=floor,
        retry_temperature=p.RETRY_TEMPERATURE if temperature == 0 else None,
    )
    try:
        parsed = json.loads(p.strip_code_fences(raw) or "{}")
        claims = parsed.get("claims") or []
    except json.JSONDecodeError as error:
        stats["json_error"] = str(error)
        claims = []
    return claims, stats, raw


def free_window(model: str, window: str, index: int, total: int,
                temperature: float) -> tuple[str, dict]:
    """Контроль формы (шаг 5): та же нарезка старым свободным EXTRACT_PROMPT."""
    raw, stats = p.call_ollama(
        model, chunked.EXTRACT_PROMPT + p.language_lock(),
        f"Фрагмент {index} из {total}.\n\n{window}",
        temperature=temperature,
        min_reply_tokens=p.REPLY_TOKENS_FLOOR["facts"],
        retry_temperature=p.RETRY_TEMPERATURE if temperature == 0 else None,
    )
    text = p.strip_code_fences(raw).strip()
    return ("" if text.upper().startswith("ПУСТО") else text), stats


def report(batch: str) -> int:
    """Таблица батча: покрытие, буллеты, четыре детектора `check_defects.py`.

    Считается по тем же функциям, что и все прежние замеры доски, — иначе числа
    v3 нельзя ставить рядом с числами ансамбля.
    """
    import check_defects as cd
    import replay_asym as r

    base = HERE / "out" / batch
    print(f"{'ячейка':22} {'встр':6} {'покр':>5} {'булл':>5} {'выдум':>6} "
          f"{'пул':>4} {'непр':>5} {'отбр':>5} {'дефекты':>8} {'сек':>5}")
    rows = []
    for cell in sorted(base.glob("*/stats.json")):
        stats = json.loads(cell.read_text(encoding="utf-8"))
        # Ячейки ансамбля пишет `bench_ensemble.py`, и встречи в его stats нет —
        # она берётся из имени ячейки: батч раскладывается по m1/m2 нарочно.
        meeting = stats.get("meeting") or MEETINGS[cell.parent.name.split("-")[0]]
        _, markdown = p.transcript(meeting)
        recap = (cell.parent / "recap.md").read_text(encoding="utf-8")
        found = cd.defects(recap, owners.Names.of(markdown), markdown)
        total = sum(len(v) for v in found.values())
        row = {
            "cell": cell.parent.name, "meeting": meeting, "mode": stats.get("mode"),
            "coverage": gm.score(recap, meeting), "bullets": r.bullets(recap),
            "fabrications": r.fabrications(recap, markdown),
            "pool": stats.get("pool"), "contiguous": stats.get("contiguous"),
            "span_drop_share": stats.get("span_drop_share"),
            "strict_drop_share": stats.get("strict_drop_share"),
            "defects": {k: len(v) for k, v in found.items() if v},
            "seconds": stats.get("seconds"),
            "reply_tokens": [x.get("reply_tokens") for x in stats.get("branches", [])],
        }
        rows.append(row)
        print(f"{row['cell']:22} {meeting[-6:]:6} {row['coverage']:5} {row['bullets']:5} "
              f"{row['fabrications']:6} {str(row['pool'] or '—'):>4} "
              f"{str(row['contiguous'] or '—'):>5} "
              f"{(f'{row['span_drop_share'] * 100:.0f}%' if row['span_drop_share'] is not None else '—'):>5} "
              f"{total:8} {row['seconds']:5.0f}")
    (base / "report.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")

    import gate_score
    import statistics
    # Виды ячеек берутся из имён, а не из списка: батчи П0 разные (v3, lean, free),
    # и забытый вид тихо выпал бы из сводки.
    kinds = sorted({row["cell"].split("-")[1] for row in rows if "-" in row["cell"]})
    print()
    print(f"{'встреча':8} {'ячейка':8} {'n':>2} {'покрытие':>22} {'сред':>6} "
          f"{'булл':>5} {'выдум':>6} {'токены':>8}")
    means: dict[tuple[str, str], list[int]] = {}
    for short in sorted({row["cell"].split("-")[0] for row in rows}):
        for kind in kinds:
            cells = [row for row in rows if row["cell"].startswith(f"{short}-{kind}-")]
            if not cells:
                continue
            coverage = sorted(row["coverage"] for row in cells)
            means[(short, kind)] = coverage
            tokens = [t for row in cells for t in row["reply_tokens"] if t]
            print(f"{short:8} {kind:8} {len(cells):2} "
                  f"{' '.join(str(c) for c in coverage):>22} "
                  f"{statistics.mean(coverage):6.1f} "
                  f"{statistics.mean(row['bullets'] for row in cells):5.1f} "
                  f"{statistics.mean(row['fabrications'] for row in cells):6.1f} "
                  f"{(f'{min(tokens)}–{max(tokens)}' if tokens else '—'):>8}")
    for kind in kinds:
        for against in ("base", "ens"):
            if kind in ("base", against):
                continue
            strata = [(means[(short, against)], means[(short, kind)])
                      for short in sorted({s for s, k in means if k == kind})
                      if (short, against) in means]
            if strata:
                observed, probability = gate_score.stratified_p(strata)
                print(f"{kind} − {against}: {observed:+.2f} пункта, перестановочный тест "
                      f"{probability * 100:.1f} %")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("--report", default=None, help="таблица батча в out/: v3")
    ap.add_argument("--meeting", default="20260812_144201")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--window", type=int, default=WINDOW)
    ap.add_argument("--overlap", type=float, default=OVERLAP)
    ap.add_argument("--floor", type=int, default=0,
                    help="порог схлопывания ответа в токенах; 0 — без ретрая")
    ap.add_argument("--free", action="store_true",
                    help="контроль формы: те же окна старым свободным промптом")
    ap.add_argument("--lean", action="store_true",
                    help="упрощённая схема: только type/text/quote (заход по стоп-условию П0)")
    args = ap.parse_args()

    if args.report:
        return report(args.report)
    if not args.out:
        ap.error("нужен --out или --report")

    title, markdown = p.transcript(args.meeting)
    pieces = windows(markdown, args.window, args.overlap)
    names = meeting_names(markdown)
    out = HERE / "out" / args.out
    out.mkdir(parents=True, exist_ok=True)

    started = time.time()
    log: list[dict] = []

    if args.free:
        facts = []
        for index, window in enumerate(pieces, 1):
            for temperature in (0.0, SAMPLE_TEMPERATURE):
                text, stats = free_window(args.model, window, index, len(pieces), temperature)
                log.append({"window": index, "temperature": temperature, **stats})
                if text:
                    facts.append(text)
        digest = "\n".join(facts)
        (out / "facts.md").write_text(digest + "\n", encoding="utf-8")
        merged = b.items_from_facts(digest)
        body = b.render(merged, "", "", owners.Names.of(markdown), markdown)
        (out / "recap.md").write_text(body + "\n", encoding="utf-8")
        (out / "stats.json").write_text(json.dumps({
            "mode": "free", "meeting": args.meeting, "title": title,
            "windows": len(pieces), "branches": log,
            "coverage": gm.score(body, args.meeting),
            "seconds": round(time.time() - started, 1),
        }, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{args.out}: свободный контроль · {len(pieces)} окон · "
              f"{gm.score(body, args.meeting)} покрытие · {time.time() - started:.0f} с")
        return 0

    raw_claims: list[dict] = []
    verified: list[dict] = []
    drops: dict[str, int] = {}
    for index, window in enumerate(pieces, 1):
        for temperature in (0.0, SAMPLE_TEMPERATURE):
            claims, stats, raw = extract_window(
                args.model, window, index, len(pieces), names, temperature,
                args.floor or None, args.lean)
            (out / f"window-{index}-t{temperature}.json").write_text(raw + "\n", encoding="utf-8")
            passed = 0
            for claim in claims:
                raw_claims.append(claim)
                checked, why = verify(claim, window, names)
                if checked is None:
                    drops[why] = drops.get(why, 0) + 1
                    continue
                verified.append(checked)
                passed += 1
            log.append({"window": index, "temperature": temperature,
                        "claims": len(claims), "passed": passed, **stats})
            print(f"  окно {index}/{len(pieces)} t={temperature}: "
                  f"{len(claims)} утв, {passed} прошли, {stats['reply_tokens']} токенов")

    pool, duplicates = dedup(verified)
    body = render(pool)
    (out / "recap.md").write_text(body + "\n", encoding="utf-8")
    (out / "claims.json").write_text(
        json.dumps(pool, ensure_ascii=False, indent=2), encoding="utf-8")

    span_drops = drops.get("спан не найден", 0)
    stats = {
        "mode": "lean" if args.lean else "schema", "meeting": args.meeting, "title": title,
        "model": args.model, "ollama": p_version(),
        "windows": [len(x) for x in pieces], "names": names,
        "branches": log,
        "raw_claims": len(raw_claims),
        "drops": drops,
        "span_drop_share": round(span_drops / max(1, len(raw_claims)), 3),
        # Контрактное чтение спан-проверки: цитата непрерывна. Пул стоит на
        # пофрагментном (см. `span_check`), критерий читается по этому числу.
        "contiguous": sum(c["contiguous"] for c in pool),
        "strict_drop_share": round(
            (span_drops + sum(not c["contiguous"] for c in verified)) / max(1, len(raw_claims)), 3),
        "duplicates": duplicates,
        "pool": len(pool),
        "owner_dropped": sum(c["owner_dropped"] for c in pool),
        "with_owner": sum(bool(c["owner"]) for c in pool),
        "deadline_dropped": sum(c["deadline_dropped"] for c in pool),
        "t_repaired": sum(c["t_repaired"] for c in pool),
        "coverage": gm.score(body, args.meeting),
        "calls": sum(x.get("calls", 1) for x in log),
        "seconds": round(time.time() - started, 1),
    }
    (out / "stats.json").write_text(
        json.dumps(stats, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{args.out}: пул {len(pool)} из {len(raw_claims)} · "
          f"отброс спаном {span_drops} ({stats['span_drop_share'] * 100:.0f} %) · "
          f"покрытие {stats['coverage']} · {stats['calls']} вызовов · "
          f"{time.time() - started:.0f} с")
    return 0


def p_version() -> str:
    """Версия Ollama — часть условий воспроизводимости: structured outputs есть
    только с 0.5, и число в таблице должно говорить, на чём оно снято."""
    import urllib.request
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/version", timeout=10) as response:
            return json.loads(response.read().decode("utf-8")).get("version", "?")
    except Exception:                                    # noqa: BLE001
        return "?"


if __name__ == "__main__":
    sys.exit(main())
