"""Recap a meeting that does not fit the window, in two stages.

Measured on the archive: 8 of 54 transcripts exceed the largest `num_ctx`
bucket, and they are the eight most substantial meetings. Ollama then drops the
*beginning* of the conversation and the model writes a confident recap of a
meeting it saw half of.

So: cut the transcript on speaker turns, pull facts out of each piece, then
build the recap from the pieces. Nothing is dropped silently — a piece that
fails says so.

Usage:
    python3 chunked.py --variant v4            # only meetings that overflow
    python3 chunked.py --variant v4 --all      # every meeting in the corpus
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

import promptlib as p
import run as runner

HERE = Path(__file__).parent

# A piece is far below the window on purpose. The window is what the model can
# *hold*; extraction quality falls off long before that, and two 12k pieces beat
# one 24k piece at finding the fifth agreement.
CHUNK_CHARACTERS = 26_000

EXTRACT_PROMPT = """
Ты читаешь фрагмент транскрипта рабочей встречи. Выпиши из него факты — без предисловий и без выводов.

- ДОГОВОРИЛИСЬ: то, что участники проговорили как решение (кто-то предложил, другой согласился).
- ЗАДАЧА: кто что делает. Срок — только если прозвучал вслух.
- ОТКРЫТО: что обсудили и не решили.
- ТЕМА: о чём говорили, с таймкодом начала в том виде, как он стоит в транскрипте.

Каждый пункт с новой строки, начиная с метки. Ничего не выдумывай: фрагмент — единственный источник.
Если в фрагменте нет ничего, кроме приветствий и болтовни, ответь одним словом: ПУСТО.
Отвечай только на русском.
""".strip()


def split_on_turns(transcript: str, limit: int = CHUNK_CHARACTERS) -> list[str]:
    """Cut between speaker turns, never inside one.

    Splitting mid-turn costs the piece its speaker and its timecode, and the
    extraction then attributes the sentence to whoever spoke next.
    """
    header, _, body = transcript.partition("## Transcript")
    turns = re.split(r"(?=^\*\*[^*]+\*\*\s*·\s*\d)", body, flags=re.M)
    turns = [t for t in turns if t.strip()]

    pieces: list[str] = []
    current = ""
    for turn in turns:
        if current and len(current) + len(turn) > limit:
            pieces.append(current)
            current = turn
        else:
            current += turn
    if current.strip():
        pieces.append(current)
    # The header carries the date and the participant list; the first piece keeps
    # it so the model knows whose meeting this is.
    if pieces:
        pieces[0] = header + "## Transcript" + pieces[0]
    return pieces


def extract(model: str, piece: str, index: int, total: int) -> str | None:
    user = f"Фрагмент {index} из {total}.\n\n{piece}"
    raw, _ = p.call_ollama(model, EXTRACT_PROMPT + p.language_lock(), user,
                           min_reply_tokens=p.REPLY_TOKENS_FLOOR['facts'])
    text = p.strip_code_fences(raw).strip()
    return None if not text or text.upper().startswith("ПУСТО") else text


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="v4", help="промпт для сборки конспекта")
    ap.add_argument("--out", default=None)
    ap.add_argument("--only", default=None)
    ap.add_argument("--all", action="store_true", help="не только переполняющие окно")
    ap.add_argument("--model", default=runner.MODEL)
    ap.add_argument("--chunk", type=int, default=CHUNK_CHARACTERS,
                    help="символов на фрагмент")
    ap.add_argument("--meeting", default=None,
                    help="встреча вне corpus.txt — свип нарезки меряется на размеченной встрече")
    args = ap.parse_args()

    system = p.system_prompt(args.variant)
    out_dir = HERE / "out" / (args.out or f"{args.variant}-chunked")
    out_dir.mkdir(parents=True, exist_ok=True)

    for meeting in ([args.meeting] if args.meeting else runner.corpus()):
        if args.only and args.only not in meeting:
            continue
        title, markdown = p.transcript(meeting)
        whole = len(system) + len(p.build_user_message(title, markdown))
        if not args.all and not p.exceeds_largest_window(whole):
            continue

        pieces = split_on_turns(markdown, args.chunk)
        started = time.time()
        facts: list[str] = []
        for i, piece in enumerate(pieces, 1):
            try:
                found = extract(args.model, piece, i, len(pieces))
            except Exception as error:                  # noqa: BLE001
                print(f"{meeting}  · фрагмент {i}/{len(pieces)} ОШИБКА: {error}")
                continue
            if found:
                facts.append(found)
            print(f"{meeting}  · фрагмент {i}/{len(pieces)}"
                  f" ({len(piece)} симв) → {len(found) if found else 0} симв")

        if not facts:
            print(f"{meeting}  · из {len(pieces)} фрагментов не извлечено ничего — пропускаю")
            continue

        digest = "\n\n".join(facts)
        # Промежуточное извлечение — то, что читаешь, когда свод вышел бедным:
        # виноват экстрактор или сборщик, видно только здесь.
        (out_dir / f"{meeting}.facts.md").write_text(digest + "\n", encoding="utf-8")
        user = "\n".join([
            f"Встреча: {title}",
            "",
            "Ниже — факты, выписанные из транскрипта по частям, по порядку встречи.",
            "Это единственный источник: транскрипт целиком в контекст не помещается.",
            "",
            digest,
            "",
            "Ответь строго на русском языке.",
        ])
        raw, stats = p.call_ollama(args.model, system, user,
                                   min_reply_tokens=p.REPLY_TOKENS_FLOOR['recap'])
        body = p.strip_code_fences(raw)
        (out_dir / f"{meeting}.md").write_text(body + "\n", encoding="utf-8")
        (out_dir / f"{meeting}.json").write_text(json.dumps({
            "title": title, "pieces": len(pieces), "facts_characters": len(digest),
            "seconds": round(time.time() - started, 1), **stats,
        }, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{meeting}  · свод из {len(facts)}/{len(pieces)} фрагментов"
              f" · {len(body)} симв · {time.time() - started:.0f} с\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
