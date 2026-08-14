"""Пересобрать слияние на **уже сохранённых** ветках — без единой генерации.

Зачем: ветки (`branch-1-t0.md`, `branch-2-sample.md`, `branch-3-facts.md`) лежат в
каждом прогоне `out/`, а сборка над ними — код. Значит любой вариант отбора
добавок проверяется на сохранённом батче попарно и бесплатно: те же ветки, меняется
только сборка. Живой батч нужен уже потом, чтобы подтвердить эффект на новых
сэмплах.

Варианты отбора (`--variants`):

    draft        только черновик t=0, добавок нет — нижняя граница
    code14       добавки, отбор жадно по новизне слов (действующий `--dedup budget`)
    quota14      то же, с гарантированными слотами «Задачам» и «Открытым вопросам»
    idf          новизна взвешена редкостью слова и поделена на длину кандидата
    region       дедуп и приоритет по месту пункта в транскрипте
    canon        сравнение по каноничным формам (один вызов на прогон)
    oracle14     отбор по самой метрике — верхняя граница того, что ветки вмещают
    mech         механическое слияние без бюджета — покрытие при 26–28 буллетах

Признаки складываются: `region+idf`, `canon+idf`, `all`. Итог замера (A5.2): попарно
**все** сигналы в шуме (p = 50–100 % по десяти прогонам), а критерий гейта на второй
встрече не проходит и оракул — там связывает мощность замера, не отбор.

Вызова дедупа здесь нет ни в одном варианте: он не окупается (A5.2 — код без
вызова даёт 10,8 против 10,0). Кроме `canon`, где один детерминированный вызов
кэшируется в `canon.json`, пересчёт вообще не обращается к модели.

    python3 replay_asym.py --dir out/asym1 --runs asym
    python3 replay_asym.py --dir out/asym2 --runs asym --meeting 20260812_153107
    python3 replay_asym.py --dir out/asym1 --runs asym --variants code14,idf,canon,oracle14
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

import bench_ensemble as b
import golden_match as gm
import lint
import owners
import promptlib as p

HERE = Path(__file__).parent

# Сколько буллетов секция получает гарантированно, если у неё есть кандидаты.
# «Решения» не квотируются: они и так забирают всё, что жадность оставит.
# Отвергнуто замером (A5.2): ноль на второй встрече при любой форме квоты.
QUOTAS = {"Задачи": 1, "Открытые вопросы": 1}

STEM = 5           # длина корня: «уровня»/«уровни» → «урове», «взаимодействие» → «взаим»
REGION_KEEP = 0.5  # турн входит в регион пункта, если его вес ≥ половины лучшего
REGION_SAME = 0.6  # доля пересечения регионов, при которой кандидат считается дублем


def stems(text: str) -> set[str]:
    return {w[:STEM] for w in b.key_words(text)}


class Regions:
    """Где в транскрипте заякорен пункт — набор реплик, а не набор слов.

    Зачем: два пункта могут говорить об одном и не делить ни одного слова —
    «три уровня взаимодействия» и «Radio / Fast Play / Deep Dive» стоят в одной
    реплике. Лексическое пересечение таких не видит вовсе (A5.2: подбор порога не
    работает, ветки называют одно слишком разными словами), а место в транскрипте
    видит. Машинерия та же, что у заземляющего линта: корни слов транскрипта.

    Редкость слова считается по репликам (IDF): слово, которое есть в половине
    встречи, регион не задаёт, а размывает.
    """

    def __init__(self, transcript: str) -> None:
        header, _, body = transcript.partition("## Transcript")
        raw = [t for t in re.split(r"(?=^\*\*[^*]+\*\*\s*·\s*\d)", body, flags=re.M)
               if t.strip()]
        self.turns = [stems(t) for t in raw]
        self.count = max(1, len(self.turns))
        self.where: dict[str, set[int]] = {}
        for index, turn in enumerate(self.turns):
            for stem in turn:
                self.where.setdefault(stem, set()).add(index)
        self.idf = {stem: math.log(self.count / len(turns))
                    for stem, turns in self.where.items()}

    def weight(self, stem: str) -> float:
        """Слова, которого в транскрипте нет, — вес максимальный: оно либо термин
        ветки, либо выдумка, и заземление выдумки отсекает раньше отбора."""
        return self.idf.get(stem, math.log(self.count))

    def of(self, text: str) -> frozenset[int]:
        scores: dict[int, float] = {}
        for stem in stems(text):
            for turn in self.where.get(stem, ()):
                scores[turn] = scores.get(turn, 0.0) + self.idf[stem]
        if not scores:
            return frozenset()
        top = max(scores.values())
        return frozenset(t for t, s in scores.items() if s >= top * REGION_KEEP)

    def novelty(self, text: str, known: set[str]) -> float:
        """Новизна с IDF и нормировкой на длину: сколько **редкого** приносит
        кандидат на слово своей длины.

        Без нормировки длинный расплывчатый кандидат обыгрывает короткий
        конкретный — он приносит больше новых слов просто потому, что слов в нём
        больше, и внутри секции выбирается не тот (A5.2, диагностика промахов).
        """
        own = stems(text)
        if not own:
            return 0.0
        return sum(self.weight(s) for s in own - known) / len(own)


def region_same(a: frozenset[int], b_: frozenset[int]) -> bool:
    if not a or not b_:
        return False
    return len(a & b_) / min(len(a), len(b_)) >= REGION_SAME


def load_branches(run: Path, draft_from: Path | None = None,
                  draft_branch: str | None = None) -> tuple[dict, list[dict], str, str]:
    """Ветки прогона в том же виде, в каком их видит `bench_ensemble.main`.

    `draft_from` подменяет **только черновик**, оставляя ветки кандидатов теми же.
    Так проверяется починка схлопнувшегося черновика без единой генерации: черновик
    берётся из здорового прогона базы, кандидаты — из сохранённых ветвей своего
    прогона, попарно. Это превью, а не замер: живой ретрай при t=0,3 даст свой
    черновик, а не чужой.

    `draft_branch="sample"` воспроизводит политику `clean` живого прогона: с гейта №2
    черновиком становится ветка с меньшей плотностью выдумок, и её имя записано в
    `stats.json`. Без этого пересборка ячейки гейта №2 считала бы другую конструкцию,
    чем та, которую прогоняли.
    """
    t0_text = (draft_from or (run / "branch-1-t0.md")).read_text(encoding="utf-8")
    sample_file = run / "branch-2-sample.md"
    sample_text = sample_file.read_text(encoding="utf-8") if sample_file.exists() else None
    prose_from = t0_text
    if draft_branch == "sample" and sample_text is not None:
        draft, prose_from = b.items_from_recap(sample_text), sample_text
        others = [b.items_from_recap(t0_text)]
    else:
        draft = b.items_from_recap(t0_text)
        others = [b.items_from_recap(sample_text)] if sample_text is not None else []
    facts = run / "branch-3-facts.md"
    if facts.exists():
        others.append(b.items_from_facts(facts.read_text(encoding="utf-8")))
    return (draft, others, b.section_text(prose_from, "Итог"),
            b.section_text(prose_from, "Ход обсуждения"))


def candidates_of(draft: dict, others: list[dict], transcript: str) -> tuple[dict, list]:
    """Черновик плюс все заземлённые добавки, без отбора: вход для любого варианта.

    Повторяет `dedup_pass(use_model=False)` — включая сверку второй ветки с уже
    выросшим черновиком: иначе один новый факт, найденный двумя ветками, даёт два
    буллета.
    """
    kept = {s: list(draft.get(s, [])) for s in b.SECTIONS + [b.NARRATIVE]}
    # «Ход обсуждения» — как в `bench_ensemble.main`: сливается по всем веткам, а не
    # берётся из черновика. Бюджет буллетов он не тратит, но в счёт покрытия входит
    # (матчер пропускает только «Итог»), и брать его из одной ветки стоило 12/14 → 9/14.
    # Слияние — хронологией блоков (`merge_prose`), а не конкатенацией ветвей.
    kept[b.NARRATIVE] = b.merge_prose([draft] + others)
    additions: list[tuple[str, str]] = []
    for branch in others:
        # Отбор кандидатов — против **снимка** черновика, как в `dedup_pass`: внутри
        # одной ветки пункты друг с другом не сверяются, сверка идёт только с тем,
        # что уже стояло к началу ветки. Если сверять по ходу, ветка съедает сама
        # себя, и пересборка расходится с живым прогоном.
        candidates = [(s, item) for s in b.SECTIONS for item in branch.get(s, [])
                      if not any(b.same(item, other) for other in kept[s])]
        for section, item in candidates:
            if b.ungrounded(item, section, transcript):
                continue
            kept[section].append(item)
            additions.append((section, item))
    return kept, additions


def greedy(additions: list, known: set, room: int, quotas: dict | None = None) -> list:
    """Жадно по предельной новизне слов, с пересчётом после каждого взятого.

    С квотами: сначала каждая секция из `quotas` получает свои слоты (тем же
    правилом новизны внутри секции), остаток разыгрывается общим пулом. Смысл
    квоты — по пяти прогонам `asym1` терялись одни и те же короткие пункты
    «Задач» и «Открытых вопросов»: жадность по новизне слов систематически
    предпочитает длинные «Решения».
    """
    survivors: list[tuple[str, str]] = []
    pool = list(additions)

    def take(subset: list) -> None:
        best = max(subset, key=lambda pair: len(b.key_words(pair[1]) - known))
        pool.remove(best)
        survivors.append(best)
        known.update(b.key_words(best[1]))

    for section, slots in (quotas or {}).items():
        for _ in range(slots):
            subset = [pair for pair in pool if pair[0] == section]
            if not subset or len(survivors) >= room:
                break
            take(subset)
    while pool and len(survivors) < room:
        take(pool)
    return survivors


def lint_density(items: dict, transcript: str) -> float:
    """Находок заземления на буллет. Сигнал выбора черновика, купленный m3.

    Длина для выбора не годится: на первой встрече ветка t=0 короткая (519 токенов,
    ниже порога) и при этом хорошая, а на третьей короткая и конфабулирующая —
    «Ильяс» превращается в «Илью Сафронова» и получает задачи. Разделяет их не
    длина, а плотность выдумок: черновик m3 несёт «Сафронова» пять раз, черновик
    m1 чист.
    """
    bullets = [(s, t) for s in b.SECTIONS for t in items.get(s, [])]
    if not bullets:
        return float("inf")
    found = sum(1 for s, t in bullets if b.ungrounded(t, s, transcript))
    return found / len(bullets)


def choose_draft(branches: dict[str, dict], policy: str, transcript: str) -> tuple[str, dict]:
    """Какая ветка становится неприкосновенным черновиком.

    `t0`       всегда ветка t=0 — конструкция гейта №1
    `swap`     при схлопывании t=0 роли меняются: черновиком становится сэмпл,
               буллеты t=0 уходят в кандидаты. Ноль новых вызовов
    `clean`    черновик — ветка с наименьшей плотностью находок линта на буллет
    `longest`  черновик — самая длинная ветка (для сравнения)
    """
    t0, sample = branches.get("t0"), branches.get("sample")
    if policy == "t0" or sample is None:
        return "t0", t0
    if policy == "swap":
        return ("sample", sample) if t0.get("collapsed") else ("t0", t0)
    if policy == "clean":
        best = min(("t0", "sample"),
                   key=lambda n: lint_density(branches[n], transcript))
        return best, branches[best]
    if policy == "longest":
        best = max(("t0", "sample"),
                   key=lambda n: sum(len(t) for s in b.SECTIONS for t in branches[n].get(s, [])))
        return best, branches[best]
    raise SystemExit(f"неизвестная политика черновика: {policy}")


def signalled(additions: list, draft: dict, regions: Regions, room: int,
              features: set[str], canon: dict[str, str] | None = None) -> list:
    """Отбор добавок с сигналами: те же кандидаты, другое ранжирование.

    Признаки складываются, каждый проверяется отдельно и в комбинации:

    `idf`          новизна взвешена редкостью слова в транскрипте и поделена на
                   длину кандидата — «сколько редкого на слово»
    `region-dedup` кандидат, чей регион транскрипта сильно перекрыт регионом пункта
                   черновика **той же секции**, слот не тратит вовсе
    `region-first` кандидат, чей регион не пересекается ни с одним уже взятым,
                   идёт первым: это гарантированно другой кусок встречи
    `canon`        сравнение и ранжирование идут по каноничной форме пункта,
                   в конспект вставляется исходная формулировка

    Промахи отбора **разные в каждом прогоне** (диагностика A5.2), то есть это шум
    ранжирования, а не слепое пятно ветвей, — поэтому лечится сигналом, а не квотой.
    """
    def form(text: str) -> str:
        return (canon or {}).get(text) or text

    pool = list(additions)
    if "region-dedup" in features:
        pool = [(section, item) for section, item in pool
                if not any(region_same(regions.of(form(item)), regions.of(form(other)))
                           for other in draft.get(section, []))]

    # Два счётчика «уже сказанного»: слова — для лексического ранга (он и есть
    # действующая точка `code14`, и его надо воспроизводить побайтово), корни — для
    # IDF-ранга. Держать один общий значило бы менять сразу два признака.
    known_words: set[str] = set()
    known_stems: set[str] = set()
    taken_regions: set[int] = set()
    for section in b.SECTIONS:
        for text in draft.get(section, []):
            known_words |= b.key_words(form(text))
            known_stems |= stems(form(text))
            taken_regions |= regions.of(form(text))

    def rank(pair: tuple[str, str]) -> float:
        text = form(pair[1])
        if "idf" in features:
            return regions.novelty(text, known_stems)
        return float(len(b.key_words(text) - known_words))

    survivors: list[tuple[str, str]] = []
    while pool and len(survivors) < room:
        subset = pool
        if "region-first" in features:
            fresh = [pair for pair in pool
                     if regions.of(form(pair[1]))
                     and not (regions.of(form(pair[1])) & taken_regions)]
            subset = fresh or pool
        best = max(subset, key=rank)
        pool.remove(best)
        survivors.append(best)
        known_words |= b.key_words(form(best[1]))
        known_stems |= stems(form(best[1]))
        taken_regions |= regions.of(form(best[1]))
    return survivors


def by_metric(additions: list, kept: dict, draft: dict, summary: str, discussion: str,
              room: int, meeting: str, names: "owners.Names | None" = None,
              transcript: str | None = None, narrative: bool = True) -> list:
    """Оракул: жадно по самой метрике. Верхняя граница, не конструкция."""
    survivors, pool = [], list(additions)
    while pool and len(survivors) < room:
        best, best_score = None, -1
        for pair in pool:
            trial = build(draft, survivors + [pair], summary, discussion, kept, names,
                          transcript, narrative)
            value = gm.score(trial, meeting)
            if value > best_score:
                best, best_score = pair, value
        pool.remove(best)
        survivors.append(best)
    return survivors


def build(draft: dict, survivors: list, summary: str, discussion: str, kept: dict,
          names: "owners.Names | None" = None, transcript: str | None = None,
          narrative: bool = True) -> str:
    out = {s: list(draft.get(s, [])) for s in b.SECTIONS}
    for section, item in survivors:
        out[section].append(item)
    out[b.NARRATIVE] = kept[b.NARRATIVE]
    return b.render(out, summary, discussion, names, transcript, narrative)


CANON_PROMPT = """
Ниже пронумерованные пункты конспекта встречи.

Перепиши каждый в 5–7 слов: субъект — действие — объект. Без прилагательных, без
пояснений в скобках, без кавычек. Термин, если он в пункте есть, сохрани.

Верни ровно столько строк, сколько пунктов, в том же порядке, в формате
`номер. краткая форма`. Ничего, кроме этих строк, не пиши.
""".strip()


def canonize(run: Path, texts: list[str], model: str) -> dict[str, str]:
    """Каноничная форма каждого пункта — один детерминированный вызов на прогон.

    Это **не модель-судья**: судьёй 4B мертва измеренно (диагональ на списке,
    yes-bias по одному кандидату). Здесь у неё нет решения — только перефраз каждой
    строки по отдельности, режим, в котором она надёжна. Решают по-прежнему код и
    сигналы, а в конспект вставляется **исходная** формулировка: канон живёт только
    внутри сравнения.

    Ответ кладётся рядом с ветками (`canon.json`): пересборка после этого снова
    детерминирована и повторяется без вызовов.
    """
    cache = run / "canon.json"
    if cache.exists():
        stored = json.loads(cache.read_text(encoding="utf-8"))
        if all(text in stored for text in texts):
            return stored
    listing = "\n".join(f"{n + 1}. {text}" for n, text in enumerate(texts))
    raw, _ = p.call_ollama(model, CANON_PROMPT, listing, temperature=0.0)
    lines = [l.strip() for l in p.strip_code_fences(raw).strip().split("\n") if l.strip()]
    canon: dict[str, str] = {}
    for line in lines:
        pair = re.match(r"^(\d+)\s*[.)]\s*(.+)$", line)
        if pair and 0 <= int(pair.group(1)) - 1 < len(texts):
            canon[texts[int(pair.group(1)) - 1]] = pair.group(2).strip()
    # Номера модель просит, но не пишет: на реальном прогоне вернулись 13 строк
    # канона **без** нумерации, и разбор «только по номеру» дал пустой словарь —
    # вариант измерялся бы как «канона нет». Позиционная склейка разрешена **только**
    # при точном совпадении числа строк: строк меньше — сдвиг спарил бы чужие формы,
    # и это была бы подделка, которая выглядит как аккуратный ответ (та же ловушка,
    # что у модели-судьи на списке).
    if not canon and len(lines) == len(texts):
        canon = dict(zip(texts, lines))
    # Пункт, на который модель не ответила, сравнивается по своей исходной форме:
    # молчание не должно стирать кандидата.
    cache.write_text(json.dumps(canon, ensure_ascii=False, indent=2), encoding="utf-8")
    return canon


def bullets(recap: str) -> int:
    items = b.items_from_recap(recap)
    return sum(len(items[s]) for s in b.SECTIONS)


def fabrications(recap: str, transcript: str) -> int:
    report = lint.lint(recap, transcript, "replay")
    return sum(report.count(check) for check in b.GROUNDING_CHECKS)


# Вариант → признаки отбора. `code14` — действующая точка, пустой набор.
VARIANTS = {
    "code14": set(),
    "idf": {"idf"},
    "region": {"region-dedup", "region-first"},
    "region-dedup": {"region-dedup"},
    "region-first": {"region-first"},
    "region+idf": {"region-dedup", "region-first", "idf"},
    "idf+first": {"idf", "region-first"},
    "canon+idf": {"canon", "idf"},
    "canon": {"canon"},
    "canon+region+idf": {"canon", "region-dedup", "region-first", "idf"},
    "all": {"canon", "region-dedup", "region-first", "idf"},
}


def replay(run: Path, variant: str, transcript: str, meeting: str, budget: int,
           regions: Regions | None = None, model: str = b.MODEL,
           draft_from: Path | None = None, names: "owners.Names | None" = None,
           draft_branch: str | None = None, narrative: bool = True) -> str:
    draft, others, summary, discussion = load_branches(run, draft_from, draft_branch)
    kept, additions = candidates_of(draft, others, transcript)
    # Фильтр слота исполнителя и фильтр артефактов генерации — часть сборки, значит и
    # часть пересборки: иначе пересборка мерила бы не то, что уедет в продукт. Словарь
    # имён и словарь форм считаются из того же транскрипта; точка «до» для сравнения —
    # сохранённые `recap.md` гейта, их пересборкой не восстановить (код починен).
    if names is None:
        names = owners.Names.of(transcript)
    if variant == "draft":
        # «Только черновик» — это «шипнуть одну ветку t=0», поэтому и «Ход
        # обсуждения» тут её собственный, а не слитый по всем веткам. Иначе строка
        # завышена на 1,6 пункта чужой находкой (9,6 против 8,0).
        return build(draft, [], summary, discussion, {b.NARRATIVE: draft[b.NARRATIVE]},
                     names, transcript, narrative)
    if variant == "mech":
        return build(draft, additions, summary, discussion, kept, names, transcript,
                     narrative)
    room = max(0, budget - sum(len(draft.get(s, [])) for s in b.SECTIONS))
    if variant == "quota14":
        known: set[str] = set()
        for section in b.SECTIONS:
            for text in draft.get(section, []):
                known |= b.key_words(text)
        survivors = greedy(additions, known, room, QUOTAS)
    elif variant == "oracle14":
        survivors = by_metric(additions, kept, draft, summary, discussion, room, meeting,
                              names, transcript, narrative)
    elif variant in VARIANTS:
        features = VARIANTS[variant]
        canon = None
        if "canon" in features:
            texts = [t for s in b.SECTIONS for t in draft.get(s, [])]
            texts += [item for _, item in additions]
            canon = canonize(run, texts, model)
        survivors = signalled(additions, draft, regions or Regions(transcript), room,
                              features, canon)
    else:
        raise SystemExit(f"неизвестный вариант: {variant}")
    return build(draft, survivors, summary, discussion, kept, names, transcript, narrative)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="каталог батча, например out/asym1")
    ap.add_argument("--runs", default="asym", help="префикс подкаталогов с ветками")
    ap.add_argument("--meeting", default=b.MEETING)
    ap.add_argument("--budget", type=int, default=14)
    ap.add_argument("--variants", default="draft,code14,quota14,oracle14")
    ap.add_argument("--model", default=b.MODEL, help="только для варианта canon")
    ap.add_argument("--write", action="store_true", help="сохранить пересборки рядом с ветками")
    ap.add_argument("--no-narrative", action="store_true",
                    help="собрать без «Хода обсуждения»: «Итог» плюс буллеты")
    ap.add_argument("--draft-from-stats", action="store_true",
                    help="черновик брать из `draft_branch` в stats.json прогона — "
                         "иначе им всегда становится ветка t=0 и пересборка ячейки "
                         "гейта №2 считает не ту конструкцию, что живой прогон")
    args = ap.parse_args()

    _, transcript = p.transcript(args.meeting)
    base = Path(args.dir) if Path(args.dir).is_absolute() else HERE / args.dir
    runs = sorted(d for d in base.glob(f"{args.runs}*") if (d / "branch-1-t0.md").exists())
    if not runs:
        print(f"нет прогонов с ветками в {base}")
        return 1
    variants = [v.strip() for v in args.variants.split(",")]
    scale = len(gm.MEETINGS[args.meeting][0])
    regions = Regions(transcript)

    table: dict[str, list[tuple[int, int, int]]] = {v: [] for v in variants}
    for run in runs:
        draft_branch = None
        stats = run / "stats.json"
        if args.draft_from_stats and stats.exists():
            draft_branch = json.loads(stats.read_text(encoding="utf-8")).get("draft_branch")
        for variant in variants:
            recap = replay(run, variant, transcript, args.meeting, args.budget,
                           regions, args.model, draft_branch=draft_branch,
                           narrative=not args.no_narrative)
            row = (gm.score(recap, args.meeting), bullets(recap),
                   fabrications(recap, transcript))
            table[variant].append(row)
            if args.write:
                (run / f"replay-{variant}.md").write_text(recap + "\n", encoding="utf-8")

    print(f"{base.name} · встреча {args.meeting} · шкала {scale} · n={len(runs)} "
          f"· бюджет {args.budget}"
          + (" · без «Хода обсуждения»" if args.no_narrative else "") + "\n")
    width = max(len(v) for v in variants) + 1
    print(f"{'вариант':{width}} {'покрытие':22} {'среднее':>8} {'буллетов':>9} {'выдумок':>8}")
    for variant in variants:
        rows = table[variant]
        covers = sorted(r[0] for r in rows)
        print(f"{variant:{width}} {' '.join(f'{c:2}' for c in covers):22} "
              f"{sum(covers) / len(covers):8.1f} "
              f"{sum(r[1] for r in rows) / len(rows):9.1f} "
              f"{sum(r[2] for r in rows) / len(rows):8.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
