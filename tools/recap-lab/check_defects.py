"""Три дефекта сборки — кодом, на сохранённых ветках, без единой генерации.

Судейский аудит (`judge/JUDGE.md`) назвал три дефекта, из-за которых `code` проиграл
базе по читаемости (2,17 против 3,38) и по атрибуции задач (44,7 % неверных
исполнителей против 37,5 %):

    (а) «Ход обсуждения» выписан дважды несогласованными наборами таймкодов;
    (б) сырые метки «ДОГОВОРИЛИСЬ: / ЗАДАЧА: / ОТКРЫТО:» стоят буллетами внутри
        «Открытых вопросов»;
    (в) в слоте исполнителя — «Speaker S1», коллективы, выдуманные и составленные
        из двух людей имена.

Пере-суд (`judge/JUDGE-2.md`) назвал четвёртый, которого в первом заходе не было:

    (г) артефакты генерации — иероглифы посреди русской фразы, сросшиеся внутри
        одного слова письменности и дословно вписанная в документ оговорка из
        промпта экстрактора.

Здесь каждый из трёх описан **детектором**, то есть проверяемым кодом, а не глазом
судьи, и посчитан дважды: на сохранённых `recap.md` гейта («до») и на пересборке тех
же ветвей починенным кодом («после»). Пересборка — `replay_asym.replay(code14)`:
ни одного вызова модели, попарно по ячейкам.

Оговорка о точке «до». Пересборка старым кодом невозможна — код починен, — поэтому
«до» это сохранённые файлы гейта. Они не побайтово равны пересборке (жадный отбор
добавок иначе разрешает равные новизны, порядок буллетов отличается), но **счёт
матчера совпадает на всех 24 code-ячейках** — проверено до починки, поэтому пара
«сохранённое ↔ пересобранное» для покрытия честная.

    python3 check_defects.py                 # gate (48 ячеек судейского аудита)
    python3 check_defects.py --batch gate2    # действующая конструкция
    python3 check_defects.py --detail m2/code-1
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path

import bench_ensemble as b
import golden_match as gm
import lint
import owners
import promptlib as p
import replay_asym as r

HERE = Path(__file__).parent
MEETINGS = {"m1": "20260812_144201", "m2": "20260812_153107", "m3": "20260810_094722"}
BUDGET = 14


# ---------------------------------------------------------------------------
# Детектор (а): секция выписана дважды
# ---------------------------------------------------------------------------

def doubled_section(recap: str) -> list[str]:
    """Дубль заголовка секции и второй проход по времени внутри «Хода обсуждения».

    Два признака одного дефекта. Первый — буквальный: `## Ход обсуждения` два раза.
    Второй — то, что судья видел в шести ячейках m2: заголовок один, но таймкоды
    внутри секции **откатываются назад**, потому что после блоков одной ветки идут
    блоки другой со своей нумерацией. Откат назад в протоколе встречи — это и есть
    «выписано дважды»; хронология назад не ходит.
    """
    findings = []
    headings = re.findall(r"^##\s+(.+?)\s*$", recap, re.M)
    for name in sorted(set(headings)):
        if headings.count(name) > 1:
            findings.append(f"заголовок «{name}» × {headings.count(name)}")
    section = b.section_text(recap, b.NARRATIVE)
    if not section:
        return findings
    spans = [b.block_span(block) for block in b.prose_blocks(section.split("\n"))]
    top = -1
    for span in spans:
        if span is None:
            continue
        if span[0] < top:
            findings.append(f"откат таймкода: {span[0] // 60}:{span[0] % 60:02d} "
                            f"после {top // 60}:{top % 60:02d}")
        top = max(top, span[0])
    return findings


# ---------------------------------------------------------------------------
# Детектор (б): сырая метка экстрактора внутри секции
# ---------------------------------------------------------------------------

LABEL_LINE = re.compile(r"(?:^|[-*•]\s*|\*\*)\s*(" + "|".join(b.FACT_LABELS) + r")\s*:", re.M)


def raw_labels(recap: str) -> list[str]:
    """Строки конспекта, несущие метку экстрактора дословно."""
    findings = []
    for number, line in enumerate(recap.split("\n"), 1):
        found = LABEL_LINE.search(line)
        if found:
            findings.append(f"стр.{number}: {found.group(1)}: … {line.strip()[:60]}")
    return findings


# ---------------------------------------------------------------------------
# Детектор (в): исполнитель вне списка участников
# ---------------------------------------------------------------------------

def bad_owners(recap: str, names: owners.Names) -> list[str]:
    """Буллеты «Задач», чей исполнитель не подтверждён словарём имён встречи."""
    findings = []
    for item in b.items_from_recap(recap)["Задачи"]:
        why = owners.unknown_owner(item, names)
        if why:
            findings.append(f"{why}: {item[:70]}")
    return findings


# ---------------------------------------------------------------------------
# Детектор (г): артефакт генерации — иероглиф, сращение письменностей, эхо промпта
# ---------------------------------------------------------------------------

def artifacts(recap: str, transcript: str) -> list[str]:
    """Три класса разом, детектор в `bench_ensemble.artifact_findings`.

    Класс появился в пере-суде (`judge/JUDGE-2.md`) и в первом суде его не было вовсе.
    Латиница целиком не в счёт: «Fast Play», «VK Mix», «Figma» — терминология встреч,
    на ней стоят якоря матчера.
    """
    return b.artifact_findings(recap, transcript)


CLASSES = ("иероглиф", "сращение", "эхо промпта")


def defects(recap: str, names: owners.Names, transcript: str) -> dict[str, list[str]]:
    return {"а·дубль секции": doubled_section(recap),
            "б·сырая метка": raw_labels(recap),
            "в·чужой исполнитель": bad_owners(recap, names),
            "г·артефакт генерации": artifacts(recap, transcript)}


# ---------------------------------------------------------------------------
# Замер
# ---------------------------------------------------------------------------

def rebuild(run: Path, transcript: str, meeting: str, names: owners.Names,
            budget: int = BUDGET, narrative: bool = True) -> str:
    """Пересборка ячейки починенным кодом. Черновик — тот же, что в живом прогоне."""
    stats = run / "stats.json"
    draft_branch = None
    if stats.exists():
        draft_branch = json.loads(stats.read_text(encoding="utf-8")).get("draft_branch")
    return r.replay(run, "code14", transcript, meeting, budget,
                    names=names, draft_branch=draft_branch, narrative=narrative) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", default="gate", help="каталог батча в out/: gate или gate2")
    ap.add_argument("--detail", default=None, help="показать находки одной ячейки, m2/code-1")
    ap.add_argument("--budget", type=int, default=BUDGET, help="бюджет буллетов пересборки")
    ap.add_argument("--no-narrative", action="store_true",
                    help="пересобирать без «Хода обсуждения»: столбец «после» — вариант "
                         "«только буллеты»")
    args = ap.parse_args()

    rows: list[dict] = []
    for short, meeting in MEETINGS.items():
        _, transcript = p.transcript(meeting)
        names = owners.Names.of(transcript)
        for run in sorted((HERE / "out" / args.batch / short).glob("*")):
            recap_file = run / "recap.md"
            if not recap_file.exists():
                continue
            cell = f"{short}/{run.name}"
            before = recap_file.read_text(encoding="utf-8")
            after = None
            if (run / "branch-1-t0.md").exists():
                after = rebuild(run, transcript, meeting, names, args.budget,
                                not args.no_narrative)
            row = {
                "cell": cell, "meeting": meeting, "kind": run.name.split("-")[0],
                "before": defects(before, names, transcript),
                "after": defects(after, names, transcript) if after else None,
                "coverage": (gm.score(before, meeting),
                             gm.score(after, meeting) if after else None),
                "bullets": (r.bullets(before), r.bullets(after) if after else None),
                "fabrications": (r.fabrications(before, transcript),
                                 r.fabrications(after, transcript) if after else None),
                "lint": (len(lint.lint(before, transcript, cell).findings),
                         len(lint.lint(after, transcript, cell).findings) if after else None),
            }
            rows.append(row)
            if args.detail and args.detail == cell:
                for stage in ("before", "after"):
                    print(f"=== {cell} · {'до' if stage == 'before' else 'после'}")
                    if row[stage] is None:
                        print("  пересборки нет: ветки не сохранены")
                        continue
                    for check, items in row[stage].items():
                        print(f"  {check}: {len(items)}")
                        for item in items:
                            print(f"      {item}")
                return 0
    if args.detail:
        print(f"нет такой ячейки: {args.detail}")
        return 1

    checks = ["а·дубль секции", "б·сырая метка", "в·чужой исполнитель",
              "г·артефакт генерации"]
    print(f"ДЕФЕКТЫ СБОРКИ · out/{args.batch} · {len(rows)} ячеек · "
          f"пересобрано {sum(1 for x in rows if x['after'] is not None)}\n")

    for short, meeting in MEETINGS.items():
        for kind in ("base", "code"):
            sub = [x for x in rows if x["cell"].startswith(f"{short}/{kind}")]
            if not sub:
                continue
            cells = []
            for check in checks:
                before = sum(len(x["before"][check]) for x in sub)
                after = ("—" if sub[0]["after"] is None
                         else str(sum(len(x["after"][check]) for x in sub)))
                cells.append(f"{before} → {after}")
            print(f"  {short}/{kind:5} " + "   ".join(f"{c:>12}" for c in cells))
    print(f"\n  {'':11} " + "   ".join(f"{c:>12}" for c in checks) + "   (сумма по 8 ячейкам)")

    def of_class(row: dict, stage: str, name: str) -> int:
        return sum(1 for f in row[stage]["г·артефакт генерации"]
                   if f.split(": ")[1] == name)

    print("\n(г) по классам · на всех ячейках · на пересобранных до → после:\n")
    for name in CLASSES:
        found = [x for x in rows if of_class(x, "before", name)]
        total = sum(of_class(x, "before", name) for x in rows)
        pair = [x for x in rows if x["after"] is not None]
        print(f"  {name:12} {total:3} находок в {len(found):2} ячейках · "
              f"на пересобранных {sum(of_class(x, 'before', name) for x in pair):3} → "
              f"{sum(of_class(x, 'after', name) for x in pair):<3} · "
              f"{', '.join(x['cell'] for x in found) or '—'}")

    print("\nпопарно по метрикам стенда (только пересобранные ячейки):\n")
    print(f"  {'встреча':9} {'покрытие':>16} {'буллетов':>16} {'выдумок':>16} {'находок линта':>18}")
    for short, meeting in MEETINGS.items():
        sub = [x for x in rows if x["cell"].startswith(f"{short}/code") and x["after"]]
        if not sub:
            continue
        line = f"  {short:9}"
        for key in ("coverage", "bullets", "fabrications", "lint"):
            before = statistics.mean(x[key][0] for x in sub)
            after = statistics.mean(x[key][1] for x in sub)
            width = 16 if key != "lint" else 18
            line += f"{f'{before:.2f} → {after:.2f}':>{width}}"
        print(line)

    total_before = sum(len(v) for x in rows for v in x["before"].values())
    total_after = sum(len(v) for x in rows if x["after"] for v in x["after"].values())
    rebuilt_before = sum(len(v) for x in rows if x["after"] for v in x["before"].values())
    print(f"\nдефектов всего: {total_before} на {len(rows)} ячейках; "
          f"на пересобранных {rebuilt_before} → {total_after}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
