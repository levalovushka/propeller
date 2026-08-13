"""Пересобрать слияние на **уже сохранённых** ветках — без единой генерации.

Зачем: ветки (`branch-1-t0.md`, `branch-2-sample.md`, `branch-3-facts.md`) лежат в
каждом прогоне `out/`, а сборка над ними — код. Значит любой вариант отбора
добавок проверяется на сохранённом батче попарно и бесплатно: те же ветки, меняется
только сборка. Живой батч нужен уже потом, чтобы подтвердить эффект на новых
сэмплах.

Варианты отбора (`--variants`):

    draft    только черновик t=0, добавок нет — нижняя граница
    code14   добавки, отбор жадно по новизне слов (действующий `--dedup budget`)
    quota14  то же, но с гарантированными слотами «Задачам» и «Открытым вопросам»
    oracle14 отбор по самой метрике — верхняя граница того, что ветки вмещают
    mech     механическое слияние без бюджета — покрытие при 26–28 буллетах

Вызова дедупа здесь нет ни в одном варианте: он не окупается (A5.2 — код без
вызова даёт 10,8 против 10,0). Поэтому пересчёт детерминирован и повторяем.

    python3 replay_asym.py --dir out/asym1 --runs asym
    python3 replay_asym.py --dir out/asym2 --runs asym --meeting 20260812_153107
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import bench_ensemble as b
import golden_match as gm
import lint
import promptlib as p

HERE = Path(__file__).parent

# Сколько буллетов секция получает гарантированно, если у неё есть кандидаты.
# «Решения» не квотируются: они и так забирают всё, что жадность оставит.
QUOTAS = {"Задачи": 1, "Открытые вопросы": 1}


def load_branches(run: Path) -> tuple[dict, list[dict], str, str]:
    """Ветки прогона в том же виде, в каком их видит `bench_ensemble.main`."""
    t0 = (run / "branch-1-t0.md").read_text(encoding="utf-8")
    draft = b.items_from_recap(t0)
    others = []
    sample = run / "branch-2-sample.md"
    if sample.exists():
        others.append(b.items_from_recap(sample.read_text(encoding="utf-8")))
    facts = run / "branch-3-facts.md"
    if facts.exists():
        others.append(b.items_from_facts(facts.read_text(encoding="utf-8")))
    return draft, others, b.section_text(t0, "Итог"), b.section_text(t0, "Ход обсуждения")


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
    kept[b.NARRATIVE] = b.merge([draft] + others)[b.NARRATIVE]
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


def by_metric(additions: list, kept: dict, draft: dict, summary: str, discussion: str,
              room: int, meeting: str) -> list:
    """Оракул: жадно по самой метрике. Верхняя граница, не конструкция."""
    survivors, pool = [], list(additions)
    while pool and len(survivors) < room:
        best, best_score = None, -1
        for pair in pool:
            trial = build(draft, survivors + [pair], summary, discussion, kept)
            value = gm.score(trial, meeting)
            if value > best_score:
                best, best_score = pair, value
        pool.remove(best)
        survivors.append(best)
    return survivors


def build(draft: dict, survivors: list, summary: str, discussion: str, kept: dict) -> str:
    out = {s: list(draft.get(s, [])) for s in b.SECTIONS}
    for section, item in survivors:
        out[section].append(item)
    out[b.NARRATIVE] = kept[b.NARRATIVE]
    return b.render(out, summary, discussion)


def bullets(recap: str) -> int:
    items = b.items_from_recap(recap)
    return sum(len(items[s]) for s in b.SECTIONS)


def fabrications(recap: str, transcript: str) -> int:
    report = lint.lint(recap, transcript, "replay")
    return sum(report.count(check) for check in b.GROUNDING_CHECKS)


def replay(run: Path, variant: str, transcript: str, meeting: str, budget: int) -> str:
    draft, others, summary, discussion = load_branches(run)
    kept, additions = candidates_of(draft, others, transcript)
    if variant == "draft":
        # «Только черновик» — это «шипнуть одну ветку t=0», поэтому и «Ход
        # обсуждения» тут её собственный, а не слитый по всем веткам. Иначе строка
        # завышена на 1,6 пункта чужой находкой (9,6 против 8,0).
        return build(draft, [], summary, discussion, {b.NARRATIVE: draft[b.NARRATIVE]})
    if variant == "mech":
        return build(draft, additions, summary, discussion, kept)
    room = max(0, budget - sum(len(draft.get(s, [])) for s in b.SECTIONS))
    known: set[str] = set()
    for section in b.SECTIONS:
        for text in draft.get(section, []):
            known |= b.key_words(text)
    if variant == "code14":
        survivors = greedy(additions, known, room)
    elif variant == "quota14":
        survivors = greedy(additions, known, room, QUOTAS)
    elif variant == "oracle14":
        survivors = by_metric(additions, kept, draft, summary, discussion, room, meeting)
    else:
        raise SystemExit(f"неизвестный вариант: {variant}")
    return build(draft, survivors, summary, discussion, kept)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="каталог батча, например out/asym1")
    ap.add_argument("--runs", default="asym", help="префикс подкаталогов с ветками")
    ap.add_argument("--meeting", default=b.MEETING)
    ap.add_argument("--budget", type=int, default=14)
    ap.add_argument("--variants", default="draft,code14,quota14,oracle14")
    ap.add_argument("--write", action="store_true", help="сохранить пересборки рядом с ветками")
    args = ap.parse_args()

    _, transcript = p.transcript(args.meeting)
    base = Path(args.dir) if Path(args.dir).is_absolute() else HERE / args.dir
    runs = sorted(d for d in base.glob(f"{args.runs}*") if (d / "branch-1-t0.md").exists())
    if not runs:
        print(f"нет прогонов с ветками в {base}")
        return 1
    variants = [v.strip() for v in args.variants.split(",")]
    scale = len(gm.MEETINGS[args.meeting][0])

    table: dict[str, list[tuple[int, int, int]]] = {v: [] for v in variants}
    for run in runs:
        for variant in variants:
            recap = replay(run, variant, transcript, args.meeting, args.budget)
            row = (gm.score(recap, args.meeting), bullets(recap),
                   fabrications(recap, transcript))
            table[variant].append(row)
            if args.write:
                (run / f"replay-{variant}.md").write_text(recap + "\n", encoding="utf-8")

    print(f"{base.name} · встреча {args.meeting} · шкала {scale} · n={len(runs)} "
          f"· бюджет {args.budget}\n")
    print(f"{'вариант':10} {'покрытие':22} {'среднее':>8} {'буллетов':>9} {'выдумок':>8}")
    for variant in variants:
        rows = table[variant]
        covers = sorted(r[0] for r in rows)
        print(f"{variant:10} {' '.join(f'{c:2}' for c in covers):22} "
              f"{sum(covers) / len(covers):8.1f} "
              f"{sum(r[1] for r in rows) / len(rows):9.1f} "
              f"{sum(r[2] for r in rows) / len(rows):8.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
