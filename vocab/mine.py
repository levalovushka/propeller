"""Найти в расшифровках слова, которыми распознавание ломает наши термины.

Метод: не буквы, а звук. GigaAM ошибается фонетически — «пайплайн» становится
«майплайном», «онбординг» «анбордингом», — поэтому слова сводятся к грубой
звуковой сигнатуре (оглушение, аканье, иканье, удвоения), и всё, что попало в
одну сигнатуру с термином, но написано иначе, — кандидат.

Два выхода, и они идут в разные места:

* **термин звучит и ломается** → в `vocab/hotwords-core.txt` и `BuiltinHotwords`,
  чинить у источника;
* **термин ломается так, что горячее слово не спасает** (замерено: «онбординг»
  лежит в списке с самого начала, а в архиве всё равно «анбординг») → в
  `PropellerPure/TermCanon.swift`, чинить в готовом конспекте.

Термин, который в архиве **не звучал ни разу**, не нужен нигде: горячее слово,
которому нечего чинить, приносит только ложные срабатывания на похожих обычных
словах (`BuiltinHotwords` — «лид/лит», «шот/шёл»).

    python3 mine.py              # кандидаты по всему архиву
    python3 mine.py --min 2      # включая одиночные упоминания
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import subprocess
import sys
import tempfile

MEETINGS = pathlib.Path.home() / ".meeting-recorder" / "meetings"
HERE = pathlib.Path(__file__).parent

# Пары, которые распознавание путает чаще всего. Порядок важен: сначала снимаем
# мягкость и удвоения, потом сводим гласные и оглушаем согласные.
_VOWELS = str.maketrans({"о": "а", "ё": "е", "я": "а", "э": "е", "и": "е", "ы": "е", "ю": "у"})
_CONSONANTS = str.maketrans({"б": "п", "в": "ф", "г": "к", "д": "т", "ж": "ш", "з": "с"})


def signature(word: str) -> str:
    """Грубая звуковая форма слова: то, что слышит модель, а не то, что пишет."""
    w = word.lower().replace("ъ", "").replace("ь", "")
    w = re.sub(r"(.)\1+", r"\1", w)          # удвоения не слышны
    w = w.translate(_VOWELS).translate(_CONSONANTS)
    w = w.replace("тс", "ц").replace("тьс", "ц")
    return w


def not_russian(words: list[str]) -> set[str]:
    """Слова, которых русская орфография не знает — через `spellcheck.swift`.

    Проверка встроена в macOS, поэтому эталон «что такое русское слово» не надо
    ни скачивать, ни поддерживать. Если собрать утилиту не удалось, майнинг всё
    равно идёт — просто без этого раздела.
    """
    source = HERE / "spellcheck.swift"
    binary = pathlib.Path(tempfile.gettempdir()) / "propeller-spellcheck"
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        build = subprocess.run(["swiftc", "-O", str(source), "-o", str(binary)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print("не собрался spellcheck.swift:", build.stderr.strip()[:200], file=sys.stderr)
            return set()
    done = subprocess.run([str(binary)], input="\n".join(words), capture_output=True, text=True)
    return {w.strip() for w in done.stdout.splitlines() if w.strip()}


def corpus_words(source: str = "transcripts") -> collections.Counter:
    """Слова из расшифровок или из конспектов.

    Источник выбирается не для полноты, а по тому, что чем чинится. Горячие
    слова правят распознавание, значит ищутся по расшифровкам. `TermCanon`
    правит **готовый конспект**, и у модели там свои поломки, которых в
    расшифровке не было: «стрибук» вместо Storybook, «камусфляж» вместо
    «камуфляжа». Искать их по транскриптам бесполезно — их там нет.
    """
    freq: collections.Counter = collections.Counter()
    for path in MEETINGS.glob("*.md"):
        is_recap = path.name.endswith("-recap.md")
        if is_recap != (source == "recaps"):
            continue
        text = path.read_text(encoding="utf-8")
        text = text.split("## Transcript", 1)[-1]
        text = re.sub(r"^\*\*.+?\*\*\s*·.*$", "", text, flags=re.M)
        for word in re.findall(r"\b[а-яёa-z][а-яёa-z-]{2,}\b", text.lower()):
            freq[word] += 1
    return freq


def vocabulary() -> dict[str, str]:
    """Термин → откуда он взят. Ядро, полный список и то, что уже канонизируем."""
    known: dict[str, str] = {}
    for name in ("hotwords-core.txt", "hotwords-full.txt"):
        path = HERE / name
        if not path.exists():
            continue
        for term in path.read_text(encoding="utf-8").replace("\n", ",").split(","):
            term = term.strip()
            if term and term.lower() not in known:
                known[term.lower()] = name.replace("hotwords-", "").replace(".txt", "")

    canon = HERE.parent / "meeting-recorder" / "swift" / "PropellerPure" / "TermCanon.swift"
    if canon.exists():
        for _, right in re.findall(r'\("([^"]+)",\s*"([^"]+)"\)', canon.read_text(encoding="utf-8")):
            known.setdefault(right.lower(), "canon")
    return known


def audit(freq: collections.Counter, known: dict[str, str]) -> int:
    """Какие горячие слова опаснее, чем полезны.

    Смещение работает по всему потоку, поэтому короткий термин, звучащий как
    частое обычное слово, перетягивает на себя чужую речь. Замерено: «Кикс» из
    списка превратил «диплинки» в «диплин Кикс». Термин, который вдобавок не
    звучал ни разу, — чистый вред, и его место в этом отчёте, а не в словаре.
    """
    by_sig: dict[str, list[tuple[int, str]]] = collections.defaultdict(list)
    for word, count in freq.items():
        by_sig[signature(word)].append((count, word))

    risky = []
    for term, origin in known.items():
        if origin != "core" or len(term) > 5:
            continue
        clash = [(n, w) for n, w in by_sig.get(signature(term), []) if w != term and n >= 5]
        if clash:
            risky.append((max(n for n, _ in clash), term, sorted(clash, reverse=True)[:3]))

    ordinary = set()
    flat = [w for _, _, clash in risky for _, w in clash]
    foreign = not_russian(flat)
    ordinary = {w for w in flat if w not in foreign}   # прошло проверку = обычное слово

    print("=== ГОРЯЧИЕ СЛОВА, КОТОРЫЕ ПЕРЕТЯГИВАЮТ ОБЫЧНУЮ РЕЧЬ")
    print(f"{'термин':12}{'звучал':>8}   сталкивается с")
    for _, term, clash in sorted(risky, reverse=True):
        hits = [(n, w) for n, w in clash if w in ordinary]
        if not hits:
            continue
        heard = freq.get(term.lower(), 0)
        verdict = "  ← ни разу не звучал, чистый вред" if heard == 0 else ""
        print(f"  {term:12}{heard:>6}   " + ", ".join(f"{w}×{n}" for n, w in hits) + verdict)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--min", type=int, default=3, help="порог частоты кандидата")
    ap.add_argument("--source", choices=["transcripts", "recaps"], default="transcripts",
                    help="расшифровки (горячие слова) или конспекты (TermCanon)")
    ap.add_argument("--limit", type=int, default=80, help="сколько кандидатов показать")
    ap.add_argument("--audit", action="store_true",
                    help="искать не новые слова, а вредные: термины, которые перетягивают обычную речь")
    args = ap.parse_args()

    freq = corpus_words(args.source)
    known = vocabulary()
    if not freq:
        print(f"нет расшифровок в {MEETINGS}")
        return 1

    if args.audit:
        return audit(freq, known)

    by_signature: dict[str, set[str]] = collections.defaultdict(set)
    for word in freq:
        by_signature[signature(word)].add(word)

    sounds_right: list[tuple[int, str, str]] = []
    sounds_wrong: list[tuple[int, str, str, str]] = []
    never_heard: list[str] = []

    for term, origin in sorted(known.items()):
        variants = by_signature.get(signature(term), set())
        if not variants:
            never_heard.append(term)
            continue
        correct = freq.get(term, 0)
        wrong = {v: freq[v] for v in variants if v != term and freq[v] >= args.min}
        if correct:
            sounds_right.append((correct, term, origin))
        for variant, count in sorted(wrong.items(), key=lambda x: -x[1]):
            # Короткое слово совпадает по звуку со слишком многим: «ток» = «так»,
            # «нид» = «нет», «доп» = «топ». Замена по такой паре испортит обычную
            # фразу ради красивой находки — то же соображение, по которому
            # «инстанция» не попала в TermCanon.
            if len(term) < 5 or len(variant) < 5:
                continue
            # Обе формы в словаре — это два написания одного сленга («чел» и
            # «чилл»), а не поломка распознавания. Чинить тут нечего.
            if variant in known:
                continue
            sounds_wrong.append((count, variant, term, origin))

    print(f"источник: {args.source}, "
          f"слов в корпусе: {len(freq)}, терминов в словарях: {len(known)}\n")

    print("=== ЗВУЧИТ ИСКАЖЁННО — кандидаты в TermCanon (искажение → канон)")
    for count, variant, term, origin in sorted(sounds_wrong, reverse=True):
        right = freq.get(term, 0)
        mark = "  ← правильного написания нет вовсе" if not right else f"  (верно тоже: {right})"
        print(f"  {count:4} × «{variant}»  →  «{term}» [{origin}]{mark}")

    print("\n=== ЗВУЧИТ ВЕРНО — в словаре нужны, чинить нечего")
    print("  " + ", ".join(f"{t}({c})" for c, t, o in sorted(sounds_right, reverse=True)[:40]))

    # Чего нет ни в наших словарях, ни в русском языке. Здесь и термины, и имена,
    # и поломки распознавания — разделять их приходится глазами, но список уже
    # короткий и отсортирован по тому, как часто это звучит.
    candidates = [w for w, c in freq.items() if c >= args.min and w not in known]
    foreign = not_russian(candidates)
    unknown = sorted(((freq[w], w) for w in foreign), reverse=True)
    print(f"\n=== НЕТ НИ В СЛОВАРЯХ, НИ В РУССКОМ ЯЗЫКЕ: {len(unknown)} слов")
    for count, word in unknown[:args.limit]:
        print(f"  {count:4} × {word}")

    only_full = [t for t in never_heard if known[t] == "full"]
    print(f"\n=== НЕ ЗВУЧАЛИ НИ РАЗУ: {len(never_heard)} терминов "
          f"(из них {len(only_full)} — только в полном списке)")
    print("  в ядре, но не звучат:",
          ", ".join(t for t in never_heard if known[t] == "core")[:400] or "—")
    return 0


if __name__ == "__main__":
    sys.exit(main())
