"""Проба C-2: по-сущностная верификация имён с поправкой на ASR.

Гипотеза: имя из конспекта отделяется от выдуманного нормализованным
редакционным расстоянием до ближайшего кандидата из объединения
{токены транскрипта + участники из шапки транскрипта}.

Способ извлечения имён (зафиксирован ДО разметки, см. PROBES.md):
  1) болд-паттерн «Кто —»: `**Имя [Фамилия]** —` в начале буллета;
  2) капитализированные кириллические токены вне начала предложения,
     подряд идущие склеиваются в составное имя (макс. 2 токена);
  3) из результата разметкой исключаются не-люди (продукты, разделы) —
     список исключённого печатается целиком, правило: слово обозначает
     продукт/проект/компанию, а не человека.

Разметка классов — руками по транскрипту и шапке, до вычисления расстояний:
  verbatim   токен (или оба токена) дословно есть в транскрипте/шапке
  asr        реальный участник, форма — вариант распознавания/склонения
  fabricated имени/фамилии в транскрипте и шапке нет — выдумка модели
  wrongname  фамилия настоящая, имя чужое (класс вне планки, отдельный отчёт)

    python3 probes/probe_c2.py            # расстояния, порог, матрица, телеметрия
    python3 probes/probe_c2.py --extract  # только извлечение (для разметки)
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import problib as pl

CAP = r"[А-ЯЁ][а-яё]+(?:[ёа-я]*)"
BOLD_WHO = re.compile(r"^\s*[-*]\s+\*\*([А-ЯЁA-Z][^*]{1,40}?)\*\*\s*[—–-]")
CAP_TOKEN = re.compile(r"[А-ЯЁ][а-яё]{2,}")
SENT_START = re.compile(r"(?:^|[.!?:;•]\s*|\*\*|[-*]\s+|«|\()\s*$")


def extract_entities(recap: str) -> list[str]:
    """Имена-кандидаты из конспекта: болд «Кто —» + капитализация вне начала
    предложения; подряд идущие капитализированные токены склеиваются (≤2)."""
    entities: list[str] = []
    for line in recap.split("\n"):
        if not line.strip() or line.startswith("##"):
            continue
        m = BOLD_WHO.match(line)
        if m:
            inner = m.group(1).strip()
            caps = CAP_TOKEN.findall(inner)
            if caps and len(caps) <= 3 and not re.search(r"[a-zA-Z0-9]", inner):
                entities.append(" ".join(caps))
        plain = line.replace("**", "")
        for m in re.finditer(rf"({CAP}(?:\s+{CAP})?)", plain):
            start = m.start()
            if SENT_START.search(plain[:start]):
                continue  # начало предложения/буллета — капитализация не сигнал
            entities.append(m.group(1))
    return entities


# ---------------------------------------------------------------------------
# Разметка. Ключ — нормализованная форма сущности (см. pl.normalize).
# Классы: verbatim / asr / fabricated / wrongname / notperson (исключено).
# Обоснования не-дословных — цитатами в PROBES.md.
# ---------------------------------------------------------------------------

LABELS: dict[str, str] = {}      # заполняется в labels.py после извлечения

try:
    from labels_c2 import LABELS  # type: ignore  # noqa: F401
except ImportError:
    pass


def norm(s: str) -> str:
    return pl.normalize(s).strip()


def levenshtein(a: str, b: str) -> int:
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


# {2,}, не {3,}: транскрипт m3 содержит обрубок «са» («выводить илья са на базу
# знании»), и кандидат из двух букв обязан быть находимым — иначе дословная
# форма конспекта получает ненулевое расстояние на ровном месте.
WORD = re.compile(r"[а-яёa-z]{2,}")


def candidate_tokens(meeting: str) -> set[str]:
    """Токены транскрипта + участники/адреса из шапки (список из календаря)."""
    matches = sorted(p for p in pl.MEETINGS_DIR.glob(f"{meeting}*.md")
                     if not p.name.endswith("-recap.md"))
    text = matches[0].read_text(encoding="utf-8")
    header, _, body = text.partition("## Transcript")
    tokens = set(WORD.findall(pl.normalize(body)))
    for line in header.split("\n"):
        if re.match(r"\*\*(Participants|Invited|Organizer|Calendar):", line):
            for email in re.findall(r"([\w.+-]+)@", line):
                tokens |= set(WORD.findall(email.lower().replace(".", " ")))
            tokens |= set(WORD.findall(pl.normalize(line)))
    return tokens


def entity_distance(entity: str, tokens: set[str]) -> float:
    """min(целиком, потокенно-max): каждый токен имени ищет своего ближайшего
    кандидата, составное имя живо, только если живы все его части."""
    parts = norm(entity).split()
    per_token = max(min(ndist(part, c) for c in tokens) for part in parts)
    whole = min(ndist(norm(entity).replace(" ", ""), c) for c in tokens)
    return min(per_token, whole)


def token_report(entity: str, tokens: set[str]) -> str:
    out = []
    for part in norm(entity).split():
        best = min(tokens, key=lambda c: ndist(part, c))
        out.append(f"{part}→{best} {ndist(part, best):.2f}")
    return ", ".join(out)


def gate_entities() -> list[tuple[str, str, str, str]]:
    """(ячейка, встреча, сущность, класс) по всем ячейкам gate."""
    rows = []
    for m in ("m1", "m2", "m3"):
        meeting = pl.GATE_MEETING[m]
        for path in pl.gate_runs(m):
            cell = f"{m}/{path.parent.name}"
            for ent in extract_entities(path.read_text(encoding="utf-8")):
                label = LABELS.get(norm(ent), "UNLABELLED")
                rows.append((cell, meeting, ent, label))
    return rows


def cmd_extract() -> int:
    """Список уникальных сущностей для разметки: встреча → форма → частота."""
    from collections import Counter
    for m in ("m1", "m2", "m3"):
        counter: Counter[str] = Counter()
        for path in pl.gate_runs(m):
            for ent in extract_entities(path.read_text(encoding="utf-8")):
                counter[norm(ent)] += 1
        print(f"== gate/{m} ({pl.GATE_MEETING[m]}) ==")
        for ent, n in counter.most_common():
            print(f"  {n:3}  {ent}   [{LABELS.get(ent, '?')}]")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--extract", action="store_true")
    args = ap.parse_args()
    if args.extract:
        return cmd_extract()

    rows = gate_entities()
    unlabelled = sorted({norm(e) for _, _, e, l in rows if l == "UNLABELLED"})
    if unlabelled:
        print("НЕРАЗМЕЧЕНО:", ", ".join(unlabelled))
        return 1

    tokens = {m: candidate_tokens(m) for m in pl.GATE_MEETING.values()}
    dist_cache: dict[tuple[str, str], float] = {}
    scored = []
    for cell, meeting, ent, label in rows:
        if label == "notperson":
            continue
        key = (meeting, norm(ent))
        if key not in dist_cache:
            dist_cache[key] = entity_distance(ent, tokens[meeting])
        scored.append((cell, meeting, ent, label, dist_cache[key]))

    # 1. Распределения по классам (по уникальным формам и по вхождениям).
    print("расстояние до ближайшего кандидата по классам:")
    print(f"{'класс':11} {'форм':>5} {'вхожд.':>7}  распределение по уникальным формам")
    uniq: dict[str, dict[str, float]] = {}
    for _, meeting, ent, label, d in scored:
        uniq.setdefault(label, {})[f"{meeting}:{norm(ent)}"] = d
    for label in ("verbatim", "asr", "fabricated", "wrongname"):
        forms = sorted(uniq.get(label, {}).values())
        count = sum(1 for r in scored if r[3] == label)
        if not forms:
            continue
        shown = " ".join(f"{v:.2f}" for v in forms)
        print(f"{label:11} {len(forms):5} {count:7}  {shown}")

    # 2. Порог: планка — 100 % fabricated флагуются, ≥90 % verbatim+asr проходят.
    ok = sorted(d for k, v in uniq.items() if k in ("verbatim", "asr")
                for d in v.values())
    bad = sorted(d for d in uniq.get("fabricated", {}).values())
    theta_lo = max(ok[: int(len(ok) * 0.9 + 0.999)][-1] if ok else 0, 0)
    print(f"\nfabricated: min={bad[0]:.3f}; verbatim+asr: p90={theta_lo:.3f}")
    viable = [t for t in sorted(set(ok + bad))
              if all(b > t for b in bad)
              and sum(1 for o in ok if o <= t) >= 0.9 * len(ok)]
    if viable:
        theta = viable[0]
        print(f"порог существует: θ = {theta:.3f} "
              f"(зазор до min(fabricated) = {bad[0] - theta:.3f})")
    else:
        theta = (bad[0] + theta_lo) / 2 if bad else theta_lo
        print("порога, дающего 100 %/90 % по уникальным формам, НЕТ")

    # Матрица ошибок при θ (по вхождениям и по формам).
    print(f"\nматрица при θ = {theta:.3f} (вхождения):")
    print(f"{'класс':11} {'прошло':>7} {'зафлагано':>10}")
    for label in ("verbatim", "asr", "fabricated", "wrongname"):
        sub = [r for r in scored if r[3] == label]
        if not sub:
            continue
        passed = sum(1 for r in sub if r[4] <= theta)
        print(f"{label:11} {passed:7} {len(sub) - passed:10}")

    # 3. Потокенная проверка класса wrongname — ловится ли он порознь.
    wn = [(m, e) for _, m, e, l, _ in scored if l == "wrongname"]
    if wn:
        print("\nwrongname потокенно (имя и фамилия порознь):")
        for meeting, ent in sorted(set(wn)):
            print(f"  {ent:22} {token_report(ent, tokens[meeting])}")

    # 4. Кандидат в прод-телеметрию: доля имён без кандидата ближе θ,
    #    base против code по каждой встрече (все вхождения, вкл. wrongname).
    print(f"\nтелеметрия «доля имён конспекта без кандидата ближе θ={theta:.3f}»:")
    print(f"{'встреча':6} {'ячейки':6} {'имён':>6} {'зафлагано':>10} {'доля':>7}")
    for m in ("m1", "m2", "m3"):
        for kind in ("base", "code"):
            sub = [r for r in scored
                   if r[0].startswith(f"{m}/{kind}")]
            flagged = sum(1 for r in sub if r[4] > theta)
            share = flagged / len(sub) * 100 if sub else 0.0
            print(f"{m:6} {kind:6} {len(sub):6} {flagged:10} {share:6.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
