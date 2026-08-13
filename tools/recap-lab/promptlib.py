"""Reproduce the app's recap request exactly, outside the app.

Every number this lab reports is worthless if the request differs from the one
`RecapService` sends. So the current prompt is not copied here — it is extracted
from `RecapService.swift` at run time, and the user message is assembled by the
same rules as `buildUserMessage`. When the Swift side changes, the lab follows
without anyone remembering to sync a file.
"""

from __future__ import annotations

import json
import re
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RECAP_SWIFT = REPO / "meeting-recorder" / "swift" / "Sources" / "RecapService.swift"
MEETINGS = Path.home() / ".meeting-recorder" / "meetings"

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


def build_user_message(title: str, transcript_markdown: str, notes: str | None = None) -> str:
    """Mirror of `RecapService.buildUserMessage` (speakers/duration are unused there too)."""
    parts = [f"Встреча: {title if title else 'без названия'}"]
    trimmed_notes = (notes or "").strip()
    if trimmed_notes:
        parts += ["", "Заметки пользователя (якоря — приоритетнее болтовни в транскрипте):", trimmed_notes]
    parts += ["", "Транскрипт:", transcript_markdown, "", "Ответь строго на русском языке."]
    return "\n".join(parts)


def estimated_tokens(prompt_characters: int) -> int:
    return -(-max(0, prompt_characters) * 10 // int(CHARACTERS_PER_TOKEN * 10))


def num_ctx(prompt_characters: int) -> int:
    needed = estimated_tokens(prompt_characters) + REPLY_TOKENS
    return next((b for b in BUCKETS if b >= needed), BUCKETS[-1])


def exceeds_largest_window(prompt_characters: int) -> bool:
    return estimated_tokens(prompt_characters) + REPLY_TOKENS > BUCKETS[-1]


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


def call_ollama(model: str, system: str, user: str, timeout: int = 1800,
                temperature: float = 0.2,
                min_reply_tokens: int | None = None,
                retry_temperature: float | None = None) -> tuple[str, dict]:
    """Same payload shape as `RecapService.callOllama` — think off, temp 0.2, sized window.

    `min_reply_tokens` перегенерирует ответ **один раз**, если он схлопнулся.
    Один, а не до победного: цикл превратил бы замер в отбор счастливых прогонов.
    Длина обоих попыток уходит в `stats`, чтобы схлопывание было видно в таблице,
    а не пряталось в среднем.

    `retry_temperature` нужен пути t=0, где повтор на той же температуре бессмысленен:
    он задаёт температуру **только повтора**, первый вызов остаётся детерминированным.
    """
    ctx = num_ctx(len(system) + len(user))
    payload = {
        "model": model,
        "stream": False,
        "keep_alive": 90,
        "think": False,
        "options": {"num_ctx": ctx, "temperature": temperature},
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    def once(at_temperature: float | None = None) -> tuple[str, int, float, int]:
        body_payload = payload
        if at_temperature is not None and at_temperature != temperature:
            body_payload = {**payload,
                            "options": {**payload["options"], "temperature": at_temperature}}
        req = urllib.request.Request(
            "http://127.0.0.1:11434/api/chat",
            data=json.dumps(body_payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as response:
            body = json.loads(response.read().decode("utf-8"))
        return (
            (body.get("message") or {}).get("content", ""),
            body.get("eval_count") or 0,
            round((body.get("total_duration") or 0) / 1e9, 1),
            body.get("prompt_eval_count") or 0,
        )

    content, reply_tokens, seconds, prompt_tokens = once()
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
    retry_at = temperature if temperature > 0 else (retry_temperature or 0.0)
    if collapsed and retry_at > 0:
        retried = True
        second, second_tokens, second_seconds, _ = once(retry_at)
        seconds += second_seconds
        # Берётся длинный из двух, а не второй: вторая попытка тоже может
        # сорваться, и тогда менять один огрызок на другой — потеря без выигрыша.
        if second_tokens > reply_tokens:
            content, reply_tokens = second, second_tokens

    stats = {
        "num_ctx": ctx,
        "prompt_tokens": prompt_tokens,
        "reply_tokens": reply_tokens,
        "first_reply_tokens": first_reply_tokens,
        "retried": retried,
        "retry_temperature": retry_at if retried else None,
        # Схлопнулся ли **итоговый** ответ: после удачного повтора флаг снимается,
        # иначе таблица говорила бы «схлопнулось», когда починка уже сработала.
        "collapsed": bool(min_reply_tokens and reply_tokens < min_reply_tokens),
        "collapsed_first": collapsed,
        "calls": 2 if retried else 1,
        "seconds": seconds,
        "truncated": exceeds_largest_window(len(system) + len(user)),
    }
    return content, stats


def strip_code_fences(text: str) -> str:
    """Mirror of `RecapMetadataParser.stripCodeFences` for the markdown path."""
    t = text.strip()
    if t.startswith("```"):
        t = re.sub(r"^```[a-zA-Z]*\n", "", t)
        t = re.sub(r"\n```$", "", t)
    return t.strip()
