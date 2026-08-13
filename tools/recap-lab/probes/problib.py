"""Shared helpers for the three probes. Read-only over out/ and golden/.

Everything below is COPIED, not imported: golden_match.py / replay_asym.py /
bench_ensemble.py are being edited by a parallel session, and importing them
would both race that work and risk pulling in Ollama-touching code paths.
Each copied block cites its origin. No function here calls a model.
"""

from __future__ import annotations

import math
import re
from pathlib import Path

HERE = Path(__file__).parent          # tools/recap-lab/probes
LAB = HERE.parent                     # tools/recap-lab
MEETINGS_DIR = Path.home() / ".meeting-recorder" / "meetings"   # promptlib.py:19

# Meeting ids per batch directory (verified against out/gate/*/base-1/user.txt).
GATE_MEETING = {"m1": "20260812_144201", "m2": "20260812_153107",
                "m3": "20260810_094722"}
ASYM_MEETING = {"asym1": "20260812_144201", "asym2": "20260812_153107"}


# ---------------------------------------------------------------------------
# Copied from golden_match.py (anchors frozen there; verbatim copy 2026-08-13).
# ---------------------------------------------------------------------------

ANCHORS_144201: dict[str, list[list[str]]] = {
    "D1": [["главн", "прост", "структур"], ["прост", "визуальн", "структур"],
           ["карточк артист"], ["главн", "не перегру"]],
    "D2": [["три", "задач"], ["три", "цел"], ["поиск", "за скобк"], ["три", "функц"]],
    "D3": [["затянуть", "fast play"], ["затянуть во fast play"], ["fast play", "а не"],
           ["фаст", "а не"], ["не", "discovery", "главн"], ["дискавери", "а не"]],
    "D4": [["облегч"], ["одна строка"], ["одну строку"], ["однои строки"],
           ["вместо трех"], ["вместо трёх"]],
    "D5": [["верхн", "треть"], ["первои трети"], ["первую треть"], ["первыи вьюпорт"],
           ["вьюпорт"], ["трети экрана"], ["треть экрана"], ["треть главнои"]],
    "D6": [["vk микс", "одна из"], ["вк микс", "одна из"], ["vk mix", "одна из"],
           ["vk-микс", "одна из"], ["точек входа"], ["точки входа", "fast play"]],
    "D7": [["три уровн"], ["трех уровн"], ["трёх уровн"], ["три сценар"],
           ["уровня взаимодеис"], ["уровнеи взаимодеис"], ["радио", "погружен"]],
    "D8": [["подстрочник", "discovery"], ["подстрочник", "треть"], ["rich", "discovery"],
           ["рич", "дискавери"], ["подстрочник", "дискавери"]],
    "D9": [["длинн", "имен"], ["длинными", "артист"], ["выдержив", "текст"],
           ["имена", "артист", "длин"]],
    "T1": [["итерац"], ["следующ", "макет"]],
    "T2": [["шум", "подчист"], ["убрать", "шум"], ["лишн", "шум"], ["визуальныи шум"]],
    "Q1": [["верхн", "треть"], ["первои трети"], ["первую треть"], ["первыи вьюпорт"],
           ["вьюпорт"], ["трети экрана"], ["треть экрана"], ["треть главнои"]],
    "Q2": [["сильного акцента"], ["один ярк"], ["ярк", "якор"], ["нет", "акцент"],
           ["много вещеи"]],
    "Q3": [["весь кластер"], ["целыи кластер"], ["целого кластера"], ["кластер целиком"],
           ["микро-выбор"], ["микровыбор"], ["не", "выбира", "трек"],
           ["без выбора", "трек"], ["не думать", "выбор"], ["не", "думать", "трек"]],
}

ANCHORS_153107: dict[str, list[list[str]]] = {
    "D1": [["каталог", "едины"], ["единыи каталог"], ["каталог", "остается"],
           ["два", "магазин"], ["одном заказе"], ["докупить"]],
    "D2": [["фильтр", "каталог"], ["навигаци", "каталог"], ["рекомендаци", "корзин"],
           ["похожие", "популярные"], ["апсеил", "рекомендаци"]],
    "D3": [["ритуал"], ["акт заботы"], ["забот", "себе"], ["уход", "дополня"]],
    "D4": [["пресеил"], ["прессеил"], ["готового решения", "не"], ["промежуточн", "иде"]],
    "D5": [["прокладк"], ["отдельн", "саит", "перед"], ["тоггл", "шапке"],
           ["тулбар", "шапке"], ["лишнии клик"]],
    "D6": [["hover"], ["ховер"], ["наведени"], ["превью", "втор"], ["не", "layout"],
           ["переключател", "разворач"]],
    "D7": [["не", "ломать"], ["узнаваем"], ["не редизаин"], ["на коленках"],
           ["привычн", "вид"]],
    "D8": [["figma", "плагин"], ["фигм", "плагин"], ["кэпчер"], ["capture"],
           ["встроенн", "figma"], ["встроенн", "фигм"]],
    "D9": [["50", "100"], ["50-100"], ["50—100"]],
    "D10": [["корзин", "личныи кабинет"], ["только главн"], ["недел", "работы"],
            ["каталог", "корзин", "не"]],
    "D11": [["300", "700"], ["700 тыс"], ["чекаут", "оценить"], ["оформлени", "переписать"]],
    "D12": [["минимум", "максимум"], ["30 %"], ["30%"], ["наценк"], ["два плана"]],
    "T1": [["12:30"], ["10:00"], ["завтра", "черновик"], ["завтра", "встреч"]],
    "T2": [["смет", "посчита"], ["смет", "рассчита"], ["сегодня вечером"], ["итоговую смету"]],
    "Q1": [["акци", "карусел"], ["карусел"], ["акционн"], ["новинк", "акци"]],
    "Q2": [["меикап-каталог"], ["отделить", "каталог"], ["меикап", "уходов", "отдел"]],
}

# m3 anchors: matcher agreement on this meeting is 67 % → numbers derived from
# them are marked unreliable and are NOT used in any probe verdict.
ANCHORS_094722: dict[str, list[list[str]]] = {
    "D1": [["иль", "замен", "влад"], ["иль", "подхват"], ["иль", "музык", "рисован"],
           ["иль", "музык", "13"], ["иль", "музык", "вгруз"]],
    "D2": [["конкретныи план"], ["14", "база знан", "лид"]],
    "D3": [["ротаци", "не принято"], ["ротаци", "отложен"], ["отложен", "решени", "сред"]],
    "D4": [["разгон"], ["промежуточн"], ["параллельн", "база знан"]],
    "D5": [["левон", "стратеги"], ["стратеги", "следующ недел"], ["цд", "убира"],
           ["цд", "снима"], ["хвост", "закр"]],
    "D6": [["турбулентн", "полин"], ["полин", "остает"], ["перенос", "старт", "полин"],
           ["полин", "после 21"], ["24", "отклон"]],
    "D7": [["ротаци", "не принято"], ["ротаци", "отложен"], ["дырочк"],
           ["не тот момент"]],
    "D8": [["шукуров", "продл"], ["шукуров", "21"], ["влад", "камуфляж", "заакт"],
           ["влад", "камуфляж", "четыре час"]],
    "D9": [["10:30"], ["ксюш", "чат"], ["ксюш", "добав"], ["дейлик", "добав"]],
    "T1": [["упакова", "план"], ["составить план"], ["написать план"],
           ["оформить план"], ["подготовить план"]],
    "T2": [["кост"], ["новог человек", "обсуд"], ["вывод", "человек"]],
    "T3": [["ротаци", "не принято"], ["ротаци", "отложен"], ["вернут", "сред"]],
    "T4": [["левон", "камуфляж"], ["камуфляж", "14"], ["передач", "влад"],
           ["отдать", "влад"]],
    "T5": [["заакт", "закрыт"], ["заакт", "поддержк"], ["навалит"]],
    "T6": [["встреч", "гпн"], ["синхрон", "гпн"], ["буфер", "гпн"]],
    "T7": [["ксюш", "добав"], ["подключ", "чат"], ["добав", "звезд"]],
    "Q1": [["другои лид"], ["не решено", "лид"], ["кто", "возглав"]],
    "Q2": [["саит"], ["формат", "база знан"]],
    "Q3": [["варьирова"], ["точное количество час"], ["сколько", "час"]],
    "Q4": [["камуфляж", "термин"], ["официальн", "термин"], ["камуфляж", "офици"]],
    "Q5": [["неясн", "дата"], ["точная дата", "не"], ["дата", "зависит"]],
}

ANCHORS = {"20260812_144201": ANCHORS_144201,
           "20260812_153107": ANCHORS_153107,
           "20260810_094722": ANCHORS_094722}

SKIP_SECTIONS = {"итог"}  # golden_match.py:79 — «Итог» пересказ, пункты в нём не считаются


def normalize(text: str) -> str:
    """golden_match.py:318 — ё→е, й→и, нижний регистр, чистка разметки."""
    return (text.lower().replace("ё", "е").replace("й", "и")
            .replace("*", " ").replace("«", " ").replace("»", " "))


def claim_lines(recap: str) -> list[str]:
    """golden_match.py:339 — все строки конспекта вне «Итога»."""
    lines, skipping = [], False
    for line in recap.split("\n"):
        heading = re.match(r"^##\s+(.+?)\s*$", line)
        if heading:
            skipping = heading.group(1).strip().lower() in SKIP_SECTIONS
            continue
        if not skipping and line.strip():
            lines.append(normalize(line))
    return lines


def found(recap: str, meeting: str) -> dict[str, bool]:
    """golden_match.py:352 — какие golden-пункты матчер видит в конспекте."""
    lines = claim_lines(recap)
    return {item: any(all(word in line for word in group)
                      for group in groups for line in lines)
            for item, groups in ANCHORS[meeting].items()}


def line_fires(line_norm: str, meeting: str) -> str | None:
    """Какой golden-пункт срабатывает на ЭТОЙ строке (для пробы C).

    То же правило групп, что в found(), но по одной строке: возвращает id
    первого сработавшего пункта или None.
    """
    for item, groups in ANCHORS[meeting].items():
        if any(all(word in line_norm for word in group) for group in groups):
            return item
    return None


# ---------------------------------------------------------------------------
# Copied from bench_ensemble.py (sections, bullet parsing, key words).
# ---------------------------------------------------------------------------

SECTIONS = ["Решения", "Задачи", "Открытые вопросы"]   # bench_ensemble.py:48
NARRATIVE = "Ход обсуждения"                            # bench_ensemble.py:52
STOP = {"это", "как", "для", "что", "при", "или", "она",
        "его", "все", "так", "там"}                     # bench_ensemble.py:60


def key_words(text: str) -> set[str]:
    """bench_ensemble.py:111"""
    words = re.findall(r"[а-яa-z]{4,}", text.lower().replace("ё", "е"))
    return {w for w in words if w not in STOP}


def items_from_recap(recap: str) -> dict[str, list[str]]:
    """bench_ensemble.py:63 — буллеты по секциям, разбор без генерации."""
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


# ---------------------------------------------------------------------------
# Copied from replay_asym.py (stems + Regions), extended with turn times.
# ---------------------------------------------------------------------------

STEM = 5   # replay_asym.py:54


def stems(text: str) -> set[str]:
    """replay_asym.py:59"""
    return {w[:STEM] for w in key_words(text)}


TURN_SPLIT = r"(?=^\*\*[^*]+\*\*\s*·\s*\d)"   # replay_asym.py:78
TURN_HEAD = re.compile(r"^\*\*[^*]+\*\*\s*·\s*(\d{1,2}):(\d{2})")


def parse_transcript(meeting: str) -> tuple[list[str], list[int | None], int]:
    """Реплики транскрипта + время начала каждой (сек) + длительность встречи.

    Нарезка на реплики — побайтово та же, что в replay_asym.Regions.__init__,
    чтобы индексы реплик совпадали с регионной машинерией. Время — из шапки
    реплики `**Speaker** · MM:SS`; длительность — из `**Duration:** N min`.
    """
    matches = sorted(p for p in MEETINGS_DIR.glob(f"{meeting}*.md")
                     if not p.name.endswith("-recap.md"))
    if not matches:
        raise FileNotFoundError(f"нет транскрипта для {meeting} в {MEETINGS_DIR}")
    text = matches[0].read_text(encoding="utf-8")
    dur = re.search(r"\*\*Duration:\*\*\s*(\d+)\s*min", text)
    duration = int(dur.group(1)) * 60 if dur else 0
    header, _, body = text.partition("## Transcript")
    raw = [t for t in re.split(TURN_SPLIT, body, flags=re.M) if t.strip()]
    times: list[int | None] = []
    for turn in raw:
        head = TURN_HEAD.match(turn.strip())
        times.append(int(head.group(1)) * 60 + int(head.group(2)) if head else None)
    last = max((t for t in times if t is not None), default=0)
    return raw, times, max(duration, last + 30)


class Regions:
    """replay_asym.py:63 — где в транскрипте заякорен текст: реплики, не слова.

    Скопировано без изменений логики; конструктор принимает готовый список
    реплик (тот же split), чтобы индексы совпадали с parse_transcript.
    """

    def __init__(self, turns_raw: list[str]) -> None:
        self.turns = [stems(t) for t in turns_raw]
        self.count = max(1, len(self.turns))
        self.where: dict[str, set[int]] = {}
        for index, turn in enumerate(self.turns):
            for stem in turn:
                self.where.setdefault(stem, set()).add(index)
        self.idf = {stem: math.log(self.count / len(turns))
                    for stem, turns in self.where.items()}

    def weight(self, stem: str) -> float:
        return self.idf.get(stem, math.log(self.count))

    def of(self, text: str) -> frozenset[int]:
        scores: dict[int, float] = {}
        for stem in stems(text):
            for turn in self.where.get(stem, ()):
                scores[turn] = scores.get(turn, 0.0) + self.idf[stem]
        if not scores:
            return frozenset()
        top = max(scores.values())
        return frozenset(t for t, s in scores.items() if s >= top * 0.5)

    # Новое (для пробы C): доля веса корней буллета, покрытая лучшей репликой.
    def groundedness(self, text: str) -> float:
        own = stems(text)
        if not own:
            return 0.0
        denom = sum(self.weight(s) for s in own)
        if denom <= 0:
            return 1.0
        best = 0.0
        for turn in self.turns:
            got = sum(self.idf[s] for s in own & turn)
            best = max(best, got)
        return best / denom


# ---------------------------------------------------------------------------
# New: golden timecode parsing and run enumeration.
# ---------------------------------------------------------------------------

TIME_TOKEN = re.compile(r"(\d{1,2}):(\d{2}|xx)")


def _token_sec(m: re.Match, end: bool) -> int:
    minute = int(m.group(1))
    sec = m.group(2)
    return minute * 60 + (59 if sec == "xx" and end else 0 if sec == "xx" else int(sec))


def golden_spans(meeting: str) -> dict[str, list[tuple[int, int]]]:
    """id пункта → список интервалов (сек) из golden-файла; без таймкода — пусто.

    Формы в golden: `00:17–00:40`, `08:35`, `14:06 / 16:57`, `24:xx`,
    `21:29–24:xx`. Поле таймкода — между первым и вторым ` · ` строки пункта.
    """
    path = LAB / "golden" / f"{meeting}.md"
    spans: dict[str, list[tuple[int, int]]] = {}
    for line in path.read_text(encoding="utf-8").split("\n"):
        m = re.match(r"^- \*\*([DTQ]\d+)\*\* · ([^·]*)(·|$)", line)
        if not m:
            continue
        item, field = m.group(1), m.group(2)
        intervals: list[tuple[int, int]] = []
        for part in field.split("/"):
            tokens = list(TIME_TOKEN.finditer(part))
            if len(tokens) >= 2:
                intervals.append((_token_sec(tokens[0], False), _token_sec(tokens[1], True)))
            elif len(tokens) == 1:
                t = tokens[0]
                intervals.append((_token_sec(t, False), _token_sec(t, True)))
        spans[item] = intervals
    return spans


def gate_runs(m: str) -> list[Path]:
    return sorted((LAB / "out" / "gate" / m).glob("*/recap.md"))


def asym_runs(batch: str) -> list[Path]:
    return sorted((LAB / "out" / batch).glob("*/recap.md"))


def all_cells_a() -> list[tuple[str, str, Path]]:
    """(метка ячейки, встреча, путь recap.md) для пробы A: gate m1/m2 + asym1/2."""
    cells = []
    for m in ("m1", "m2"):
        for path in gate_runs(m):
            cells.append((f"gate/{m}/{path.parent.name}", GATE_MEETING[m], path))
    for batch in ("asym1", "asym2"):
        for path in asym_runs(batch):
            cells.append((f"{batch}/{path.parent.name}", ASYM_MEETING[batch], path))
    return cells
