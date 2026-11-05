"""Reproduce the app's recap request exactly, outside the app.

Every number this lab reports is worthless if the request differs from the one
`RecapService` sends. So the current prompt is not copied here — it is extracted
from `RecapService.swift` at run time, and the user message is assembled by the
same rules as `buildUserMessage`. When the Swift side changes, the lab follows
without anyone remembering to sync a file.
"""

from __future__ import annotations

import json
import os
import re
import socket
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RECAP_SWIFT = REPO / "meeting-recorder" / "swift" / "Sources" / "RecapService.swift"
MEETINGS = Path.home() / ".meeting-recorder" / "meetings"

# Куда слать запросы. Лабораторный сервер поднимается на 11435+ и никогда на
# 11434: приложение усыновляет любой сервер на своём порту и пишет конспекты
# чужой моделью (2026-10-29, две встречи). Переменная, а не правка файла, —
# чтобы адрес нельзя было забыть вернуть.
OLLAMA_URL = os.environ.get("RECAP_LAB_OLLAMA", "http://127.0.0.1:11434")

# PropellerPure/PropellerPure.swift — OllamaContext. Mirrored, and checked
# against the Swift source by `check_context_constants()`.
CHARACTERS_PER_TOKEN = 2.2
REPLY_TOKENS = 3072
BUCKETS = [16384, 32768]


def _swift_multiline(source: str, declaration: str) -> str:
    """Pull a Swift multiline literal out of the source, undoing its indentation.

    Swift strips the closing delimiter's indentation from every line; we do the
    same, otherwise the prompt would arrive with leading spaces the model never
    sees in production.
    """
    start = source.index(declaration) + len(declaration)
    body = source[start:]
    end = body.index('"""')
    raw = body[:end]
    lines = raw.split("\n")
    # The line carrying the closing delimiter sets the indentation Swift removes.
    closing = lines[-1]
    indent = len(closing) - len(closing.lstrip())
    if lines and lines[0].strip() == "":
        lines = lines[1:]
    return "\n".join(line[indent:] if len(line) >= indent else line.lstrip() for line in lines).rstrip()


def default_prompt() -> str:
    source = RECAP_SWIFT.read_text(encoding="utf-8")
    return _swift_multiline(source, 'static let defaultPrompt = """')


def language_lock() -> str:
    source = RECAP_SWIFT.read_text(encoding="utf-8")
    return "\n" + _swift_multiline(source, 'private static let languageLock = """')


def system_prompt(variant: str | None = None) -> str:
    """`variant` names a file in prompts/; None means whatever ships today."""
    if variant in (None, "current", "v1"):
        body = default_prompt()
    else:
        body = (Path(__file__).parent / "prompts" / f"{variant}.md").read_text(encoding="utf-8").rstrip()
    return body + language_lock()


# Кто был на встрече — по подписям самой ленты. Зеркало
# `RecapDocument.participants(fromTranscript:)`: две формы головы реплики
# (в памяти и на диске) и список плейсхолдеров из `SourceAwareSpeaker`.
HEAD_SHAPES = re.compile(
    r"(?m)^(?:\[(.+?)\]\s*\[\d+:\d+(?::\d+)?\]"
    r"|\*\*([^*\n]{1,60})\*\*\s*·\s*\d{1,3}:\d{2}(?::\d{2})?)\s*$"
)
PLACEHOLDER = re.compile(r"^(?:Speaker|Спикер)(?:\s*S?\d+)?$|^(?:Собеседник|Я)$", re.I)


def participants(transcript_markdown: str) -> list[str]:
    out: list[str] = []
    for whole, disk in HEAD_SHAPES.findall(transcript_markdown):
        label = (whole or disk).strip()
        if not label or PLACEHOLDER.match(label) or label in out:
            continue
        out.append(label)
    return out


def build_user_message(title: str, transcript_markdown: str, notes: str | None = None) -> str:
    """Mirror of `RecapDocument.userMessage`.

    Состав здесь появился 2026-08-27, и это была не мелочь: сама функция
    (`RecapDocument.userMessage`) добавляет строкой в промпт «Участники: …» и
    правило «исполнителем может быть только участник из этого списка» с
    2026-08-20, а лаборатория продолжала слать запрос без них. То есть замер
    ответственного шёл по запросу, которого приложение не отправляет — ровно то,
    от чего этот модуль обещает защищать в первой своей строке.
    """
    parts = [f"Встреча: {title if title else 'без названия'}"]
    people = participants(transcript_markdown)
    if people:
        parts.append("Участники: " + ", ".join(people) + ".")
        parts.append(
            "Исполнителем задачи может быть только участник из этого списка, "
            "и только если поручение прозвучало вслух."
        )
    trimmed_notes = (notes or "").strip()
    if trimmed_notes:
        parts += ["", "Заметки пользователя (якоря — приоритетнее болтовни в транскрипте). Вплетай их по смыслу, а не отдельным списком; раздела «Заметки» не пиши — он собирается из этого текста дословно и без тебя:", trimmed_notes]
    parts += ["", "Транскрипт:", transcript_markdown, "", "Ответь строго на русском языке."]
    return "\n".join(parts)


def estimated_tokens(prompt_characters: int) -> int:
    return -(-max(0, prompt_characters) * 10 // int(CHARACTERS_PER_TOKEN * 10))


def num_ctx(prompt_characters: int) -> int:
    needed = estimated_tokens(prompt_characters) + REPLY_TOKENS
    return next((b for b in BUCKETS if b >= needed), BUCKETS[-1])


def exceeds_largest_window(prompt_characters: int) -> bool:
    return estimated_tokens(prompt_characters) + REPLY_TOKENS > BUCKETS[-1]


def check_generation_constants() -> list[str]:
    """Fail loudly if the generation policy drifted from Swift.

    Заведено 2026-08-28, после того как одна и та же ошибка нашлась третий раз за
    сутки: лаборатория шлёт запрос, которого приложение не отправляет. Первые два
    раза это были состав в user-сообщении и промпт редактора; третий — сама
    генерация: `run.py` гонял t=0,2 без повтора при схлопнувшемся ответе, а
    приложение гоняет t=0 и перегенерирует всё короче 800 токенов. Числа,
    снятые так, отвечали на вопрос, которого никто не задавал.
    """
    pol = (REPO / "meeting-recorder" / "swift" / "PropellerPure"
           / "RecapGenerationPolicy.swift").read_text(encoding="utf-8")
    import run as runner   # локальный импорт: run.py импортирует promptlib
    problems = []
    checks = [
        ("temperature", r"public static let temperature = ([\d.]+)", runner.POLICY_TEMPERATURE),
        ("retryTemperature", r"public static let retryTemperature = ([\d.]+)", RETRY_TEMPERATURE),
        ("recapMinReplyTokens", r"public static let recapMinReplyTokens = (\d+)",
         REPLY_TOKENS_FLOOR["recap"]),
        ("loopLineRepeats", r"public static let loopLineRepeats = (\d+)", LOOP_LINE_REPEATS),
        ("loopLineMinCharacters", r"public static let loopLineMinCharacters = (\d+)",
         LOOP_LINE_MIN_CHARACTERS),
    ]
    for name, pattern, mine in checks:
        m = re.search(pattern, pol)
        if not m or float(m.group(1)) != float(mine):
            problems.append(f"RecapGenerationPolicy.{name} = {m.group(1) if m else '?'}, у лаборатории {mine}")
    # Потолок в Swift выражен через окно, а не числом — и ровно это сверяется:
    # если кто-то впишет туда своё число, лаборатория должна об этом узнать.
    if "public static let maxReplyTokens = OllamaContext.replyTokens" not in pol \
            or MAX_REPLY_TOKENS != REPLY_TOKENS:
        problems.append(f"RecapGenerationPolicy.maxReplyTokens разошёлся с окном, у лаборатории {MAX_REPLY_TOKENS}")
    return problems


def check_context_constants() -> list[str]:
    """Fail loudly if the mirrored OllamaContext numbers drifted from Swift."""
    pure = (REPO / "meeting-recorder" / "swift" / "PropellerPure" / "PropellerPure.swift").read_text(encoding="utf-8")
    problems = []
    for name, want in [("charactersPerToken", CHARACTERS_PER_TOKEN), ("replyTokens", REPLY_TOKENS)]:
        m = re.search(rf"public static let {name} = ([\d.]+)", pure)
        if not m or float(m.group(1)) != float(want):
            problems.append(f"OllamaContext.{name} = {m.group(1) if m else '?'}, у лаборатории {want}")
    m = re.search(r"public static let buckets = \[([\d, ]+)\]", pure)
    if not m or [int(x) for x in m.group(1).split(",")] != BUCKETS:
        problems.append(f"OllamaContext.buckets = {m.group(1) if m else '?'}, у лаборатории {BUCKETS}")
    return problems


def transcript(meeting_id: str) -> tuple[str, str]:
    """Return (title, whole markdown file) — the app passes the file verbatim."""
    matches = sorted(p for p in MEETINGS.glob(f"{meeting_id}*.md") if not p.name.endswith("-recap.md"))
    if not matches:
        raise FileNotFoundError(f"нет транскрипта для {meeting_id} в {MEETINGS}")
    text = matches[0].read_text(encoding="utf-8")
    first = text.split("\n", 1)[0]
    title = first.lstrip("# ").strip() if first.startswith("#") else meeting_id
    return title, text


def shipped_recap(meeting_id: str) -> str | None:
    matches = sorted(MEETINGS.glob(f"{meeting_id}*-recap.md"))
    return matches[0].read_text(encoding="utf-8") if matches else None


# Порог «ответ схлопнулся». Найден разбором 2026-08-13: счёт по golden оказался
# почти функцией длины ответа (r = 0,78 на десяти прогонах «целиком», r = 0,90 на
# одиннадцати прогонах нарезки), а сами длины двумодальны — при побайтово
# одинаковом промпте модель отдаёт то ~700–1400 токенов, то 266–465. Короткий
# ответ — это не «модель так решила», это сорвавшаяся генерация, и она тянет счёт
# вниз независимо от проверяемой гипотезы.
REPLY_TOKENS_FLOOR = {"recap": 800, "facts": 600}


RETRY_TEMPERATURE = 0.3   # на ней перегенерируется схлопнувшийся ответ пути t=0

# Потолок ответа (`num_predict`) — зеркало `RecapGenerationPolicy.maxReplyTokens`,
# то есть запас окна под ответ. Без него 2026-10-29 приложение генерировало 12
# тысяч токенов до тайм-аута; на 997 ответах стенда длиннее 2154 не было ни одного.
MAX_REPLY_TOKENS = REPLY_TOKENS
# Петля — одна содержательная строка три раза (`RecapGenerationPolicy.looped`).
# На 1611 документах стенда и архива строка от 16 символов повторялась максимум дважды.
LOOP_LINE_REPEATS = 3
LOOP_LINE_MIN_CHARACTERS = 24


class Runaway(RuntimeError):
    """Оба вызова ушли в разнос — зеркало `RecapError.runaway`."""


def looped(text: str) -> bool:
    seen: dict[str, int] = {}
    for raw in text.splitlines():
        line = " ".join(raw.split())
        if len(line) < LOOP_LINE_MIN_CHARACTERS:
            continue
        seen[line] = seen.get(line, 0) + 1
        if seen[line] >= LOOP_LINE_REPEATS:
            return True
    return False

# Последняя секция шаблона. Ответ без неё дописан не до конца, и длиной это не
# ловится: замер 2026-08-28 — секция есть у каждого ответа от 941 токена и ни у
# одного до 945, при пороге схлопывания 800.
#
# Повтор по этому признаку **пробовали и сняли**: правило сработало на 9 первых
# ответах из 12, а секции после повтора не было у 6 из 12 против 4–5 без правила.
# Длина ответа определяется входом, и повтор пересэмплирует то же решение модели
# остановиться. Функция остаётся — ею считают дефект в таблицах (`requires_discussion`
# у `call_ollama` по умолчанию выключен, как и в проде).
DISCUSSION_HEADING = re.compile(r"(?mi)^##+\s*\**\s*Ход обсуждения\s*\**\s*:?\s*$")


def missing_discussion(text: str) -> bool:
    return DISCUSSION_HEADING.search(text) is None


def call_ollama(model: str, system: str, user: str, timeout: int = 1800,
                temperature: float = 0.2,
                min_reply_tokens: int | None = None,
                retry_temperature: float | None = None,
                requires_discussion: bool = False,
                fmt: dict | None = None,
                max_reply_tokens: int | None = MAX_REPLY_TOKENS) -> tuple[str, dict]:
    """Same payload shape as `RecapService.callOllama` — think off, temp 0.2, sized window.

    `min_reply_tokens` перегенерирует ответ **один раз**, если он схлопнулся.
    Один, а не до победного: цикл превратил бы замер в отбор счастливых прогонов.
    Длина обоих попыток уходит в `stats`, чтобы схлопывание было видно в таблице,
    а не пряталось в среднем.

    `retry_temperature` нужен пути t=0, где повтор на той же температуре бессмысленен:
    он задаёт температуру **только повтора**, первый вызов остаётся детерминированным.

    `fmt` — JSON-схема в поле `format` (structured outputs Ollama ≥ 0.5). Приложение
    её сегодня не шлёт; путь v3 (`bench_extract.py`) стоит на ней целиком, поэтому
    схема идёт параметром, а не вторым клиентом: ретрай схлопнувшегося ответа и
    `stats` должны быть одни и те же на обоих путях.

    `max_reply_tokens` — потолок ответа и правило разноса, зеркало
    `RecapGenerationPolicy` (2026-11-03): ответ до потолка, петля или тайм-аут
    просят повтора даже без порога, разнос никогда не выигрывает выбор, два
    разноса подряд — `Runaway`. `None` — поведение до 2026-11-03: без потолка,
    тайм-аут — исключение, разнос не распознаётся. Нужен только как база замера.
    """
    guarded = max_reply_tokens is not None
    ctx = num_ctx(len(system) + len(user))
    options = {"num_ctx": ctx, "temperature": temperature}
    if guarded:
        options["num_predict"] = max_reply_tokens
    payload = {
        "model": model,
        "stream": False,
        "keep_alive": 90,
        "think": False,
        "options": options,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    if fmt is not None:
        payload["format"] = fmt

    def once(at_temperature: float | None = None) -> dict:
        body_payload = payload
        if at_temperature is not None and at_temperature != temperature:
            body_payload = {**payload,
                            "options": {**payload["options"], "temperature": at_temperature}}
        req = urllib.request.Request(
            f"{OLLAMA_URL}/api/chat",
            data=json.dumps(body_payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                body = json.loads(response.read().decode("utf-8"))
        except (TimeoutError, socket.timeout, urllib.error.URLError) as error:
            # Тайм-аут — разнос, а не отказ (`ModelReply.timedOut`). Остальные
            # сетевые ошибки остаются ошибками, как в приложении.
            timed_out = isinstance(error, (TimeoutError, socket.timeout)) or \
                isinstance(getattr(error, "reason", None), (TimeoutError, socket.timeout))
            if not (guarded and timed_out):
                raise
            return {"content": "", "tokens": 0, "seconds": float(timeout), "prompt": 0,
                    "unfinished": True}
        return {
            "content": (body.get("message") or {}).get("content", ""),
            "tokens": body.get("eval_count") or 0,
            "seconds": round((body.get("total_duration") or 0) / 1e9, 1),
            "prompt": body.get("prompt_eval_count") or 0,
            "unfinished": guarded and body.get("done_reason") == "length",
        }

    def ran_away(reply: dict) -> bool:
        return guarded and (reply["unfinished"] or looped(reply["content"]))

    first = once()
    content, reply_tokens, seconds, prompt_tokens = (
        first["content"], first["tokens"], first["seconds"], first["prompt"])
    first_reply_tokens, retried = reply_tokens, False
    # При t=0 повтор детерминированно возвращает тот же текст — вызов сгорает
    # впустую. Ансамбль платил его в каждом прогоне (ens-5: ветка t0 с
    # `retried=true` и совпавшим sha).
    #
    # Но «повтора нет» — неверное следствие (замер 2026-08-13, третья встреча):
    # на `20260810_094722` ветка t=0 схлопнулась детерминированно во всех восьми
    # прогонах (684 токена против порога 800) и дала черновик **хуже худшего** из
    # восьми сэмплов базы. Детерминизм там не защищал, а закреплял плохой ответ.
    # Поэтому вызывающий может задать `retry_temperature`: при t=0 повтор идёт на
    # ней. Воспроизводимость сохраняется, пока ответ здоров, и приносится в жертву
    # ровно в том случае, когда она вредна.
    collapsed = bool(min_reply_tokens and reply_tokens < min_reply_tokens)
    ran_away_first = ran_away(first)
    winner_ran_away = ran_away_first
    # Второй признак недописанности, и он структурный: нет «Хода обсуждения».
    # Длина была прокси, и прокси разошёлся с предметом — документ на 814–945
    # токенов проходит порог 800 и приезжает без самой большой своей секции.
    cut = requires_discussion and missing_discussion(content)
    retry_at = temperature if temperature > 0 else (retry_temperature or 0.0)
    if (collapsed or cut or ran_away_first) and retry_at > 0:
        retried = True
        second = once(retry_at)
        second_tokens = second["tokens"]
        seconds += second["seconds"]
        second_ran_away = ran_away(second)
        # Разнос не выигрывает никогда: «длинный из двух» отдал бы победу петле.
        if ran_away_first != second_ran_away:
            if ran_away_first:
                content, reply_tokens, winner_ran_away = second["content"], second_tokens, False
        else:
            # Дописанность важнее длины: ответ с секцией побеждает более длинный без
            # неё. Когда по секции ничья — правило прежнее, длинный из двух.
            second_cut = requires_discussion and missing_discussion(second["content"])
            if requires_discussion and cut != second_cut:
                if cut:
                    content, reply_tokens = second["content"], second_tokens
            elif second_tokens > reply_tokens:
                content, reply_tokens = second["content"], second_tokens

    stats = {
        "num_ctx": ctx,
        "num_predict": max_reply_tokens,
        "prompt_tokens": prompt_tokens,
        "reply_tokens": reply_tokens,
        "first_reply_tokens": first_reply_tokens,
        "retried": retried,
        "retry_temperature": retry_at if retried else None,
        # Схлопнулся ли **итоговый** ответ: после удачного повтора флаг снимается,
        # иначе таблица говорила бы «схлопнулось», когда починка уже сработала.
        "collapsed": bool(min_reply_tokens and reply_tokens < min_reply_tokens),
        "collapsed_first": collapsed,
        "ran_away_first": ran_away_first,
        "ran_away": winner_ran_away,
        "cut_first": cut,
        "cut": requires_discussion and missing_discussion(content),
        "calls": 2 if retried else 1,
        "seconds": seconds,
        "truncated": exceeds_largest_window(len(system) + len(user)),
    }
    if winner_ran_away:
        raise Runaway(f"оба ответа в разносе: {stats}")
    return content, stats


def strip_code_fences(text: str) -> str:
    """Mirror of `RecapMetadataParser.stripCodeFences` for the markdown path."""
    t = text.strip()
    if t.startswith("```"):
        t = re.sub(r"^```[a-zA-Z]*\n", "", t)
        t = re.sub(r"\n```$", "", t)
    return t.strip()
