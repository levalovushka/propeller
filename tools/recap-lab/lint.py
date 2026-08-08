"""Deterministic checks on a finished recap. No model, no network, no opinion.

Everything here is a rule the shipped prompt already states, or a defect found by
reading real recaps out of `~/.meeting-recorder/meetings`. A check earns its place
only if it fired on the archive at least once — a linter that is green on broken
output teaches nothing.

Usage:
    python3 lint.py                 # whole archive, one row per meeting
    python3 lint.py --dir out/v2    # a lab run
    python3 lint.py --detail ID     # every finding for one meeting
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import promptlib as p

# Sections the prompt asks for, in the order it asks for them.
CANON_SECTIONS = ["Итог", "Решения", "Задачи", "Открытые вопросы", "Ход обсуждения", "Прочее"]

# Passive and bureaucratic shapes. The prompt bans them in prose ("активный залог,
# без канцелярита") and the archive is full of them anyway.
PASSIVE = [
    r"\bбыл[оаи]?\s+(?:решен|принят|достигнут|согласован|утверждён|утвержден)\w*",
    r"\b(?:обсуждал|рассматривал|планировал|отмечал|подчёркивал|подчеркивал)\w*с[яь]\b",
    r"\b(?:было|будет)\s+\w+о\b",
    r"\b(?:решено|принято|утверждено|согласовано|достигнуто|отмечено|выявлено|подчёркнуто|подчеркнуто|обозначено|зафиксировано|предложено|определено)\b",
]
CLERICAL = [
    r"\bв рамках\b", r"\bв целях\b", r"\bс целью\b", r"\bпосредством\b", r"\bпутём\b",
    # «данные» и «данных» — это data, обычное слово; канцелярит — «данный вопрос».
    r"\bданн(?:ый|ая|ое|ого|ой|ом|ому)\b", r"\bявляет\w*\b", r"\bосуществля\w+\b",
    r"\bнеобходимо отметить\b", r"\bследует отметить\b", r"\bв части\b",
    r"\bпо итогам обсуждения\b", r"\bв ходе обсуждения\b", r"\bбыла озвучена\b",
    r"\bимеет место\b", r"\bпроизводит\w*\b", r"\bреализац\w+\b",
]
# Words the prompt calls water when they stand as a topic or a bullet's whole point.
FILLER = [
    r"\bэтапы\b", r"\bследующие шаги\b", r"\bприоритеты\b", r"\bрезультаты\b",
    r"\bключев\w+\b", r"\bряд\s+\w+", r"\bсоответствующ\w+\b", r"\bопределённ\w+\b",
]

SENTENCE_WORDS_MAX = 22   # measured median across the archive is 18.4; the tail is the problem

# Deadlines the model likes to hand out. Each is checked against the transcript
# by its stem: «к пятнице» is a lie unless somebody said «пятниц» out loud. Found
# by reading a recap that promised documents «к пятнице» for a meeting where the
# only time ever named was «сегодня к шести».
DEADLINE_STEMS = {
    "понедельник": "понедельник", "вторник": "вторник", "сред[уые]": "сред",
    "четверг": "четверг", "пятниц": "пятниц", "суббот": "суббот", "воскресен": "воскресен",
    "завтра": "завтра", "послезавтра": "послезавтра",
    "до конца недели": "недел", "в течение недели": "недел", "на следующей неделе": "недел",
    "следующей рабочей недел": "недел",
    "до конца дня": "конца дня", "в течение дня": "течение дня", "к концу дня": "конца дня",
    "сегодня вечером": "вечер", "к вечеру": "вечер", "вечернему времени": "вечер",
    "к утру": "утр", "до конца месяца": "месяц",
    "к следующей встрече": "следующей встрече", "к встрече": "к встрече",
}

# Imperative mood. A recap states what happened; it does not give the reader
# orders. Found when the editing pass turned «Левон проводит очистку» into
# «Левон — проведите очистку»: the instructions handed to it were commands, and
# it copied their tone into the document. Checked only at the head of a line or
# right after a dash, where a noun ending in «-йте» cannot stand.
IMPERATIVE = re.compile(
    r"(?:^\s*-\s*|^|—\s+|:\s+)\*{0,2}([А-ЯЁа-яё]{4,}(?:йте|ьте|ите|ните|шите|дите))\b",
    re.M,
)

# Выдуманное действующее лицо: «Сторонники согласились». Породило правило
# «пассив → глагол с действующим лицом» — редактору велели найти подлежащее, и
# он его сочинил. Зеркало RecapLint.inventedActor в Swift.
INVENTED_ACTOR = re.compile(
    r"\b(Сторонник\w*|Сторон[ыа]|Участники|Коллеги|Команда|Стейкхолдер\w*)\s+"
    r"(?:соглас\w+|отказ\w+|реши\w+|договор\w+|подтверд\w+|дообуч\w+|переда\w+|определи\w+)"
)

# Срок, посчитанный в днях. На встрече говорят «сегодня к шести», а «~6 дней» —
# арифметика модели поверх того, чего она не знает.
COMPUTED_DEADLINE = re.compile(
    r"срок:?\s*~?\s*\d+\s*(?:дн|недел|месяц)\w*|в течение\s+\d+\s*(?:дн|недел|месяц)\w*"
)

# Who a task can belong to. A placeholder owner is worse than none: it reads like
# an assignment and names nobody. All three shapes are from real recaps.
FAKE_OWNER = re.compile(
    r"^\s*-\s*\*{0,2}(Система|Команда|Участник|Все|Команда разработки|Разработка)\b"
    r"|неявный ответственн|участник с ответственностью|или участник",
    re.I,
)


@dataclass
class Finding:
    check: str
    line: int
    text: str


@dataclass
class Report:
    meeting: str
    words: int = 0
    findings: list[Finding] = field(default_factory=list)
    stats: dict = field(default_factory=dict)

    def add(self, check: str, line: int, text: str) -> None:
        self.findings.append(Finding(check, line, text.strip()[:110]))

    def count(self, check: str) -> int:
        return sum(1 for f in self.findings if f.check == check)


def model_body(recap: str) -> str:
    """Strip what the app wrapped around the model's answer.

    `wrapRecapDocument` adds the `# Title — рекап` heading and a verbatim
    `## Заметки` section. Linting either would blame the model for the app's text.
    """
    body = re.sub(r"\A#\s+.*\n", "", recap)
    body = re.sub(r"\A---\n.*?\n---\n", "", body, flags=re.S)
    return re.split(r"^##\s+Заметки\s*$", body, maxsplit=1, flags=re.M)[0]


def transcript_facts(transcript: str) -> tuple[set[str], set[str], int]:
    """Word stems, numbers, and the last timecode second, from the transcript.

    Stems come from *every* word regardless of case: the first version collected
    only capitalised ones and then flagged «Оценка» as invented because the
    transcript said «оценка». Three characters, because Russian declension eats
    the tail — at four, «Сашу» and «Лёвы» both read as names nobody had said.
    """
    # ё → е everywhere: the transcript writes «Левон», the recap «Лёвон», and a
    # comparison that treats those as different names reports an invention.
    body = transcript.replace("ё", "е").replace("Ё", "Е")
    stems = {w[:3].lower() for w in re.findall(r"\b[А-Яа-яA-Za-z]{3,}", body)}
    # One token per number. An earlier `[\d\s]*` glued «03:37» and its neighbour
    # into «0337», so every timecode digit read as absent from the transcript.
    numbers = {n.lstrip("0") or "0" for n in re.findall(r"\d+", body)}
    seconds = 0
    for h, m, s in re.findall(r"·\s*(?:(\d{1,2}):)?(\d{1,2}):(\d{2})", body):
        seconds = max(seconds, int(h or 0) * 3600 + int(m) * 60 + int(s))
    return stems, numbers, seconds


def lint(recap: str, transcript: str | None, meeting: str) -> Report:
    rep = Report(meeting=meeting)
    body = model_body(recap)
    lines = body.split("\n")
    rep.words = len(re.findall(r"[А-Яа-яЁёA-Za-z]+", body))

    # --- structure -------------------------------------------------------
    headings = re.findall(r"^##\s+(.+?)\s*$", body, re.M)
    for h in headings:
        if h not in CANON_SECTIONS:
            rep.add("секция вне шаблона", 0, h)
    order = [CANON_SECTIONS.index(h) for h in headings if h in CANON_SECTIONS]
    if order != sorted(order):
        rep.add("секции не по порядку", 0, " → ".join(headings))

    for i, line in enumerate(lines, 1):
        if re.match(r"^#\s+\S", line):
            rep.add("заголовок # вместо ##", i, line)
        if re.match(r"^\s*[*+]\s+\S", line):
            rep.add("буллет * вместо -", i, line)
        if re.match(r"^\s*\d+[.)]\s+\S", line):
            rep.add("нумерованный список", i, line)
        if re.match(r"^\s*\*\*?(Date|Duration|Participants|Дата|Длительность|Участники)\*?\*?\s*:", line):
            rep.add("запрещённая шапка", i, line)
        if re.match(r"^\s*-\s*(—|-|нет|Нет|отсутству)", line):
            rep.add("пустая секция вместо пропуска", i, line)

    # --- timecodes -------------------------------------------------------
    # The prompt shows `[00:04:32]`; transcripts are written `· MM:SS`. Every
    # recap in the archive followed the transcript, so the prompt is the thing
    # that is wrong — but a timecode past the end of the meeting is the model's.
    stems, numbers, last_second = (set(), set(), 0)
    if transcript:
        stems, numbers, last_second = transcript_facts(transcript)

    for i, line in enumerate(lines, 1):
        for tc in re.findall(r"\[?\b((?:\d{1,2}:)?\d{1,2}:\d{2})\b\]?", line):
            parts = [int(x) for x in tc.split(":")]
            sec = parts[0] * 3600 + parts[1] * 60 + parts[2] if len(parts) == 3 else parts[0] * 60 + parts[1]
            if last_second and sec > last_second + 60:
                rep.add("таймкод за пределами встречи", i, f"{tc} > {last_second // 60}:{last_second % 60:02d}")

    # --- invented names and numbers --------------------------------------
    # Cheap grounding: a proper noun or a figure that never occurs in the
    # transcript cannot have been said. Stems, because Russian declines.
    if transcript:
        prose = re.sub(r"\[.*?\]|\(.*?\)", " ", body).replace("ё", "е").replace("Ё", "Е")
        for i, line in enumerate(prose.split("\n"), 1):
            if line.startswith("##"):
                continue
            for m in re.finditer(r"\b[А-ЯЁ][а-яё]{3,}", line):
                # A capital after a bullet, a bold opener or a sentence end is
                # just orthography — only mid-sentence capitals name something.
                before = line[:m.start()].rstrip()
                if not before or before.endswith(("-", "*", ".", "!", "?", ":", "—", "**")):
                    continue
                if m.group(0)[:3].lower() not in stems:
                    rep.add("имя не из транскрипта", i, m.group(0))
            # Latin words are a separate, softer signal: ASR mangles them at the
            # source («Qloud Code», «в гаГ»), and the prompt explicitly asks the
            # model to repair those — so a Latin word absent from the transcript
            # is usually a fix, not an invention. Counted, never summed in.
            for word in re.findall(r"\b[A-Z][A-Za-z]{3,}", line):
                if word[:3].lower() not in stems:
                    rep.add("латиница не из транскрипта", i, word)
            # Timecodes are checked separately; leaving them in made every
            # «03:37» look like two invented figures.
            without_timecodes = re.sub(r"\b(?:\d{1,2}:)?\d{1,2}:\d{2}\b", " ", line)
            for number in re.findall(r"\d+", without_timecodes):
                n = number.lstrip("0") or "0"
                if len(n) > 1 and n not in numbers:
                    rep.add("число не из транскрипта", i, n)

    # --- invented deadlines and owners -----------------------------------
    tasks = re.search(r"^##\s+Задачи\s*$\n(.*?)(?=^##\s|\Z)", body, re.M | re.S)
    if tasks:
        for i, line in enumerate(tasks.group(1).split("\n"), 1):
            if FAKE_OWNER.search(line):
                rep.add("ответственный-призрак", i, line)
    if transcript:
        haystack = transcript.lower().replace("ё", "е")
        for i, line in enumerate(lines, 1):
            low = line.lower().replace("ё", "е")
            for phrase, stem in DEADLINE_STEMS.items():
                if re.search(phrase, low) and stem not in haystack:
                    rep.add("срок не из транскрипта", i, re.search(phrase, low).group(0))

    for m in INVENTED_ACTOR.finditer(body):
        rep.add("выдуманный участник", body[:m.start()].count("\n") + 1, m.group(0))
    for m in COMPUTED_DEADLINE.finditer(body):
        rep.add("посчитанный срок", body[:m.start()].count("\n") + 1, m.group(0))
    for m in IMPERATIVE.finditer(body):
        line_no = body[:m.start()].count("\n") + 1
        rep.add("повелительное наклонение", line_no, m.group(1))

    # --- style -----------------------------------------------------------
    for i, line in enumerate(lines, 1):
        if line.startswith("##"):
            continue
        for pattern in PASSIVE:
            for m in re.finditer(pattern, line, re.I):
                rep.add("пассив", i, m.group(0))
        for pattern in CLERICAL:
            for m in re.finditer(pattern, line, re.I):
                rep.add("канцелярит", i, m.group(0))
        for pattern in FILLER:
            for m in re.finditer(pattern, line, re.I):
                rep.add("вода", i, m.group(0))

    sentences = [s for s in re.split(r"(?<=[.!?])\s+", re.sub(r"^[#\-*\s]+", "", body, flags=re.M)) if len(s.split()) > 2]
    long_sentences = [s for s in sentences if len(s.split()) > SENTENCE_WORDS_MAX]
    for s in long_sentences:
        rep.add("длинное предложение", 0, f"{len(s.split())} слов: {s}")

    # --- proportions -----------------------------------------------------
    sections = dict(re.findall(r"^##\s+(.+?)\s*$\n(.*?)(?=^##\s|\Z)", body, re.M | re.S))
    def words_in(name: str) -> int:
        return len(re.findall(r"[А-Яа-яЁёA-Za-z]+", sections.get(name, "")))

    discussion = words_in("Ход обсуждения")
    rep.stats = {
        "слов": rep.words,
        "ход/всего": round(discussion / rep.words, 2) if rep.words else 0,
        "решений": len(re.findall(r"^\s*-\s", sections.get("Решения", ""), re.M)),
        "задач": len(re.findall(r"^\s*-\s", sections.get("Задачи", ""), re.M)),
        "ср.предл": round(sum(len(s.split()) for s in sentences) / len(sentences), 1) if sentences else 0,
    }
    if transcript:
        tw = len(re.findall(r"[А-Яа-яЁёA-Za-z]+", transcript))
        rep.stats["сжатие"] = f"{rep.words / tw * 100:.1f}%" if tw else "—"
        prompt_chars = len(p.system_prompt()) + len(p.build_user_message("x", transcript))
        rep.stats["обрезан"] = "да" if p.exceeds_largest_window(prompt_chars) else ""
    return rep


CHECKS = [
    "срок не из транскрипта", "посчитанный срок", "выдуманный участник", "повелительное наклонение", "ответственный-призрак", "имя не из транскрипта", "число не из транскрипта", "латиница не из транскрипта", "таймкод за пределами встречи",
    "пассив", "канцелярит", "вода", "длинное предложение",
    "буллет * вместо -", "нумерованный список", "секция вне шаблона",
    "секции не по порядку", "заголовок # вместо ##", "запрещённая шапка",
    "пустая секция вместо пропуска",
]
SHORT = {
    "срок не из транскрипта": "срок!", "посчитанный срок": "срок~",
    "выдуманный участник": "кто!?", "повелительное наклонение": "приказ", "ответственный-призрак": "кто?",
    "имя не из транскрипта": "имена", "число не из транскрипта": "числа",
    "латиница не из транскрипта": "латин",
    "таймкод за пределами встречи": "ТК>", "пассив": "пассив", "канцелярит": "канц",
    "вода": "вода", "длинное предложение": "длин", "буллет * вместо -": "*",
    "нумерованный список": "1.", "секция вне шаблона": "секц?",
    "секции не по порядку": "поряд", "заголовок # вместо ##": "#",
    "запрещённая шапка": "шапка", "пустая секция вместо пропуска": "пусто",
}


def collect(directory: Path | None) -> list[tuple[str, str, str | None]]:
    """Return (meeting id, recap text, transcript text)."""
    out = []
    if directory:
        for path in sorted(directory.glob("*.md")):
            meeting = path.stem
            try:
                _, tr = p.transcript(meeting.split("__")[0])
            except FileNotFoundError:
                tr = None
            out.append((meeting, path.read_text(encoding="utf-8"), tr))
        return out
    for path in sorted(p.MEETINGS.glob("*-recap.md")):
        meeting = path.name.split("-", 1)[0]
        try:
            _, tr = p.transcript(meeting)
        except FileNotFoundError:
            tr = None
        out.append((path.name.replace("-recap.md", ""), path.read_text(encoding="utf-8"), tr))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=Path, default=None, help="каталог с рекапами (по умолчанию — архив)")
    ap.add_argument("--detail", default=None, help="показать все находки одной встречи")
    ap.add_argument("--min-words", type=int, default=200, help="пропускать тестовые огрызки")
    args = ap.parse_args()

    items = collect(args.dir)
    reports = []
    for meeting, recap, tr in items:
        rep = lint(recap, tr, meeting)
        if rep.words < args.min_words and not args.detail:
            continue
        reports.append(rep)

    if args.detail:
        for rep in reports:
            if args.detail not in rep.meeting:
                continue
            print(f"\n=== {rep.meeting} · {rep.stats}")
            for f in rep.findings:
                print(f"  {f.check:32} стр.{f.line:<4} {f.text}")
        return 0

    head = f"{'встреча':30}{'слов':>6}{'сжат':>7}{'обр':>4}{'ход':>5}{'реш':>4}{'зад':>4}"
    head += "".join(f"{SHORT[c]:>6}" for c in CHECKS)
    print(head)
    print("-" * len(head))
    totals = {c: 0 for c in CHECKS}
    for rep in reports:
        row = f"{rep.meeting[:28]:30}{rep.stats['слов']:6}{rep.stats.get('сжатие','—'):>7}"
        row += f"{rep.stats.get('обрезан',''):>4}{rep.stats['ход/всего']:>5}{rep.stats['решений']:>4}{rep.stats['задач']:>4}"
        for c in CHECKS:
            n = rep.count(c)
            totals[c] += n
            row += f"{n if n else '·':>6}"
        print(row)
    print("-" * len(head))
    total_row = f"{'ИТОГО ' + str(len(reports)) + ' встреч':30}{'':6}{'':7}{'':4}{'':5}{'':4}{'':4}"
    total_row += "".join(f"{totals[c]:>6}" for c in CHECKS)
    print(total_row)
    per = f"{'на встречу':30}{'':6}{'':7}{'':4}{'':5}{'':4}{'':4}"
    per += "".join(f"{totals[c]/max(1,len(reports)):>6.1f}" for c in CHECKS)
    print(per)
    return 0


if __name__ == "__main__":
    sys.exit(main())
