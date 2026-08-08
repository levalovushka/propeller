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


def call_ollama(model: str, system: str, user: str, timeout: int = 1800) -> tuple[str, dict]:
    """Same payload shape as `RecapService.callOllama` — think off, temp 0.2, sized window."""
    ctx = num_ctx(len(system) + len(user))
    payload = {
        "model": model,
        "stream": False,
        "keep_alive": 90,
        "think": False,
        "options": {"num_ctx": ctx, "temperature": 0.2},
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = json.loads(response.read().decode("utf-8"))
    content = (body.get("message") or {}).get("content", "")
    stats = {
        "num_ctx": ctx,
        "prompt_tokens": body.get("prompt_eval_count"),
        "reply_tokens": body.get("eval_count"),
        "seconds": round((body.get("total_duration") or 0) / 1e9, 1),
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
