"""Слот исполнителя: сверка с закрытым словарём имён встречи.

Зачем именно здесь, а не в модели. Судейский аудит (`judge/JUDGE.md`) посчитал то,
чего стенд не мерил: **44,7 % задач ансамбля адресованы не тому** (37,5 % у базы).
Исполнителями становятся обломки расшифровки («Саболь», «Агась»), сырой ярлык
«Speaker S1», коллективы («Команда VK Музыка (дизайн)» — в 13 ячейках m1 из 16) и
люди-кентавры: «Саша Шукуров» (Саша + Влад Шукуров), «Полина Кузнецова» (Полина +
Настя Кузнецова), «Илья Сафронов» (фамилии в транскрипте нет вовсе).

Почему это **не** провалившаяся проба C-2. Там кандидатами были все токены
транскрипта, и у выдуманной фамилии всегда находился случайный сосед: «Поняева» →
«поняла» (0,29), «Рикипа» → «рикап» (0,33) — ближе, чем честный ASR-мангл до своего
человека («акушина» → «маркетинга» 0,50). Классы пересекались на всём интервале, и
порога не было (PROBES.md, C-2). Здесь кандидатов не вся лексика, а **имена
встречи** — 16–45 форм, — и у «поняла» с «рикапом» нет права голоса. Это ровно тот
адрес, который проба C-2 оставила в наследство своим вердиктом. Словарь получается
не крошечным (89–125 форм на встречу: ASR пишет с большой буквы и начало фразы, так
что в него попадают «Ага», «Блин», «Даже»), но он **закрытый и из этой встречи** — а
именно это и решает: ни одна выдуманная фамилия корпуса ближе 0,58 ни к одной его
форме не подходит.

Словарь имён (порядок источников — порядок надёжности):

    1) имена спикеров из шапок реплик (`**Левон** · 00:15`) — не «Speaker SN»;
    2) капитализированные кириллические токены тела транскрипта: так в него попадают
       обращения («Оля, привет», «Саш», «Аринчик»), которых нет ни в одном другом
       месте файла;
    3) капитализированные токены строк шапки Participants / Organizer / Invited.

Оговорка, которую надо знать при чтении: `**Participants:**` во всех трёх встречах
корпуса содержит **одно** имя («Левон»), а `Invited:` — адреса из инициалов
(`as@`, `nk@`, `pkr@`). То есть шапка сама по себе словаря не даёт: настоящие
исполнители m2 (Оля, Саша) живут только в теле транскрипта. Поэтому источник (2)
обязателен, и «список участников» здесь — имена, **произнесённые на встрече**, а не
календарный список.

Составное имя сверяется **парой**: рядом стоящие капитализированные токены
транскрипта дают словарь пар, и «Саша Шукуров» не проходит, хотя порознь оба токена
честные (`саш` есть, `шукуров` есть) — пары такой на встрече не было. Это единственный
способ поймать класс `wrongname`: расстоянию тут мерить нечего (PROBES.md, C-2).

Порог θ = 0,34 — тот же, что у телеметрии C-2, чтобы в лаборатории было одно число,
а не два. Он лежит внутри широкого плато: на размеченных слотах гейта максимум
сохранённой честной формы — 0,25, минимум срезанной выдумки — 0,58, так что любой
θ ∈ [0,25; 0,58) даёт ту же матрицу (замер — `python3 owners.py`).

    python3 owners.py            # словари трёх встреч, матрица по слотам гейта
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).parent

# Порог нормализованного редакционного расстояния. См. шапку: плато [0,25; 0,58).
THETA = 0.34

CAP = r"[А-ЯЁ][а-яё]+"
# Коллективы вместо человека. Тот же класс, что ловит `lint.FAKE_OWNER`, но здесь он
# нужен раньше: «Команда» как токен встречается в транскрипте с большой буквы в
# начале фразы, то есть по расстоянию прошла бы.
COLLECTIVE = re.compile(
    r"^(команда|системa|система|участник\w*|все|сторон\w*|коллеги|стеикхолдер\w*|"
    r"разработка|дизаин\w*|обе|обои)\b", re.I)
SPEAKER_LABEL = re.compile(r"\bSpeaker\s*S?\d+\b", re.I)


def normalize(text: str) -> str:
    """ё→е, й→и, нижний регистр — как в `golden_match.normalize`.

    Копия, а не импорт: `gate_score.py --old-matcher` подменяет функцию матчера
    целиком, и фильтр исполнителя не должен от этой подмены зависеть.
    """
    return (text.lower().replace("ё", "е").replace("й", "и")
            .replace("*", " ").replace("«", " ").replace("»", " ").strip())


def levenshtein(a: str, b: str) -> int:
    """probe_c2.py:81 — та же реализация, чтобы числа фильтра и пробы сходились."""
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[-1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def ndist(a: str, b: str) -> float:
    if not a or not b:
        return 1.0
    return levenshtein(a, b) / max(len(a), len(b))


class Names:
    """Закрытый словарь имён одной встречи: одиночные формы и пары «имя фамилия»."""

    def __init__(self, tokens: set[str], pairs: set[tuple[str, str]]) -> None:
        self.tokens = tokens
        self.pairs = pairs

    @classmethod
    def of(cls, transcript: str) -> "Names":
        header, _, body = transcript.partition("## Transcript")
        tokens: set[str] = set()
        pairs: set[tuple[str, str]] = set()
        for line in body.split("\n"):
            head = re.match(r"^\*\*([^*]+)\*\*\s*·", line)
            if head and not SPEAKER_LABEL.search(head.group(1)):
                tokens.add(normalize(head.group(1)))
        for line in header.split("\n"):
            if re.match(r"\*\*(Participants|Organizer|Invited)\s*:", line):
                tokens |= {normalize(t) for t in re.findall(CAP, line)}
        # Шапки реплик выброшены: имя спикера уже взято выше, а как «сосед» оно
        # склеивалось бы в пару с первым словом реплики.
        plain = re.sub(r"^\*\*[^*]+\*\*\s*·.*$", "", body, flags=re.M)
        for pair in re.finditer(rf"({CAP})(?:\s+({CAP}))?", plain):
            first, second = normalize(pair.group(1)), normalize(pair.group(2) or "")
            tokens.add(first)
            if second:
                tokens.add(second)
                pairs.add((first, second))
        return cls({t for t in tokens if len(t) >= 2}, pairs)

    def token_distance(self, token: str) -> float:
        return min((ndist(token, name) for name in self.tokens), default=1.0)

    def pair_distance(self, first: str, second: str) -> float:
        """Пара живёт, только если жива целиком: max по двум токенам, min по парам."""
        return min((max(ndist(first, a), ndist(second, b)) for a, b in self.pairs),
                   default=1.0)


# Слот исполнителя в буллете «Задач». Три формы, все из настоящих конспектов:
# `**Левон** — доработать…`, `Левон — согласовать…`, `Speaker S1 посчитает…`.
BOLD_SLOT = re.compile(r"^\s*\*\*(?P<slot>[^*\n]{1,60}?)\*\*\s*[—–]\s*(?P<rest>.+)$", re.S)
PLAIN_SLOT = re.compile(r"^\s*(?P<slot>[А-ЯЁ][^—–\n]{0,58}?)\s+[—–]\s+(?P<rest>.+)$", re.S)
SPEAKER_PREFIX = re.compile(r"^\s*\*{0,2}\s*Speaker\s*S?\d+\s*\*{0,2}\s*[—–:,]?\s*", re.I)
# «Саболь (Speaker S1) должна…» — имя подтверждено, а рядом с ним висит ярлык
# диаризации. Ярлык не содержание ни при какой формулировке, поэтому снимается.
SPEAKER_PAREN = re.compile(r"\s*[(\[]\s*\*{0,2}Speaker\s*S?\d+\*{0,2}\s*[)\]]", re.I)
# Из слота выбрасывается пояснение в скобках: «Саболь (Оля)» проверяется как «Саболь».
PARENTHETICAL = re.compile(r"\([^)]*\)")
# Слот «имя-образный», только если каждый его токен — капитализированное слово или
# соединитель. Иначе `PLAIN_SLOT` съел бы обычную фразу с тире.
JOINER = {"и", "+", "/", ",", "&"}


def slot_tokens(slot: str) -> list[str] | None:
    """Токены имени из слота или None, если слот на имя не похож вовсе."""
    core = PARENTHETICAL.sub(" ", slot).strip(" .:,;·")
    if not core:
        return None
    words = [w for w in re.split(r"[\s]+", core) if w]
    names = []
    for word in words:
        bare = word.strip("«».,:;()[]")
        if not bare or bare.lower() in JOINER:
            continue
        if not re.fullmatch(CAP, bare):
            return None
        names.append(bare)
    return names or None


def verdict(slot: str, names: Names, theta: float = THETA) -> tuple[bool | None, str]:
    """Оставить ли исполнителя. Второе значение — причина, для отчётов и детектора.

    Три исхода, а не два: `None` значит «в этом месте слота исполнителя нет вовсе» —
    болд или тире внутри обычной фразы («Обсуждено использование макетов — как
    референсов»). Такой пункт не трогается: фильтр снимает исполнителя, а не режет
    прозу по первому тире.
    """
    if SPEAKER_LABEL.search(slot):
        return False, "ярлык Speaker"
    core = PARENTHETICAL.sub(" ", slot)
    if COLLECTIVE.match(normalize(core)):
        return False, "коллектив"
    if re.search(r"[A-Za-z0-9]", core) and len(core.split()) <= 4:
        # «Команда VK Музыка (дизайн)», «XPage»: короткий слот с латиницей — это не
        # участник встречи. Длинная фраза с латиницей — это не слот вовсе, и она
        # уходит в ветку «слота нет» ниже.
        return False, "латиница или цифра"
    tokens = slot_tokens(slot)
    if not tokens:
        return None, "слота нет"
    if len(tokens) > 2:
        return False, f"{len(tokens)} токенов"
    if len(tokens) == 1:
        distance = names.token_distance(normalize(tokens[0]))
        return distance <= theta, f"{distance:.2f}"
    distance = names.pair_distance(normalize(tokens[0]), normalize(tokens[1]))
    return distance <= theta, f"пара {distance:.2f}"


def scrub(item: str, names: Names, theta: float = THETA) -> str:
    """Снять неподтверждённого исполнителя, сохранив текст пункта.

    Пункт без исполнителя честнее пункта с чужим: «назначить работу живому человеку
    хуже, чем никому» (README, замер 2026-08-12). Поэтому текст не теряется никогда —
    уходит только слот.
    """
    item = SPEAKER_PAREN.sub("", item)
    stripped = SPEAKER_PREFIX.sub("", item, count=1)
    if stripped != item:
        # «Speaker S1 посчитает цифры» → «посчитает цифры»; дальше сверяется остаток:
        # за ярлыком иногда идёт настоящее имя («Speaker S1 — Левон — посчитает»).
        return scrub(stripped.strip(), names, theta)
    match = BOLD_SLOT.match(item) or PLAIN_SLOT.match(item)
    if not match:
        return item
    keep, _ = verdict(match.group("slot"), names, theta)
    return item if keep is not False else match.group("rest").strip()


def unknown_owner(item: str, names: Names, theta: float = THETA) -> str | None:
    """Причина, по которой исполнитель пункта не подтверждён; None — подтверждён
    или его нет вовсе. Это и есть детектор дефекта (в) из `check_defects.py`."""
    if SPEAKER_LABEL.search(item.split("—")[0]):
        return "ярлык Speaker"
    match = BOLD_SLOT.match(item) or PLAIN_SLOT.match(item)
    if not match:
        return None
    keep, why = verdict(match.group("slot"), names, theta)
    return why if keep is False else None


# ---------------------------------------------------------------------------
# Замер порога на размеченном сете пробы C-2: слоты исполнителя всех ячеек гейта.
# ---------------------------------------------------------------------------

def _labelled_slots() -> list[tuple[str, str, str, str]]:
    """(батч/встреча/ячейка, слот, класс C-2, встреча) по gate и gate2."""
    sys.path.insert(0, str(HERE / "probes"))
    import problib as pl                     # noqa: E402
    from labels_c2 import LABELS             # noqa: E402

    rows = []
    for batch in ("gate", "gate2"):
        for short, meeting in pl.GATE_MEETING.items():
            for path in sorted((HERE / "out" / batch / short).glob("*/recap.md")):
                recap = path.read_text(encoding="utf-8")
                tasks = re.search(r"^##\s+Задачи\s*$\n(.*?)(?=^##\s|\Z)", recap, re.M | re.S)
                if not tasks:
                    continue
                for line in tasks.group(1).split("\n"):
                    if not re.match(r"^\s*[-*]\s+\S", line):
                        continue
                    item = re.sub(r"^\s*[-*]\s+", "", line).strip()
                    match = BOLD_SLOT.match(item) or PLAIN_SLOT.match(item)
                    if not match:
                        continue
                    slot = match.group("slot").strip()
                    key = normalize(PARENTHETICAL.sub("", slot))
                    rows.append((f"{batch}/{short}/{path.parent.name}", slot,
                                 LABELS.get(key, "неразмечено"), meeting))
    return rows


def main() -> int:
    import promptlib as p                    # noqa: E402

    sys.path.insert(0, str(HERE / "probes"))
    import problib as pl                     # noqa: E402

    dictionaries = {}
    for short, meeting in pl.GATE_MEETING.items():
        _, text = p.transcript(meeting)
        names = Names.of(text)
        dictionaries[meeting] = names
        print(f"{short} · {meeting}: {len(names.tokens)} имён, {len(names.pairs)} пар")
        print("   ", ", ".join(sorted(names.tokens)))
    rows = _labelled_slots()
    print(f"\nслотов исполнителя в gate+gate2: {len(rows)}")

    print(f"\nсвип порога (вхождения):")
    print(f"{'θ':>6}  " + "  ".join(f"{c:>12}" for c in
                                    ("verbatim", "asr", "fabricated", "wrongname")))
    for theta in (0.20, 0.25, 0.30, THETA, 0.40, 0.50, 0.58, 0.60):
        cells = []
        for cls in ("verbatim", "asr", "fabricated", "wrongname"):
            sub = [r for r in rows if r[2] == cls]
            kept = sum(1 for r in sub if verdict(r[1], dictionaries[r[3]], theta)[0])
            cells.append(f"{kept}/{len(sub)}")
        print(f"{theta:6.2f}  " + "  ".join(f"{c:>12}" for c in cells))
    print("в клетках — сколько слотов класса ПРОШЛО фильтр")

    print(f"\nуникальные слоты при θ = {THETA}:")
    seen = set()
    for _, slot, cls, meeting in rows:
        if (slot, meeting) in seen:
            continue
        seen.add((slot, meeting))
        keep, why = verdict(slot, dictionaries[meeting], THETA)
        print(f"  {meeting[-6:]}  {slot[:40]:42} [{cls:12}] "
              f"{'оставлен' if keep else 'срезан  '}  {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
