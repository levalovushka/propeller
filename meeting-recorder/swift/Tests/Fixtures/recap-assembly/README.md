# Паритет механической сборки со стендом (Г1, archive/RELEASE-1.16.5.md)

`facts-live.md` — живой выход экстрактора со стенда:
`tools/recap-lab/out/gate2-fixed/m3/code-1/branch-3-facts.md` (встреча
20260810_094722, планёрка; `out/` в .gitignore, поэтому вход скопирован сюда).

`expected-live.md` — что из него собирает python-эталон. Снят 2026-08-14 так:

```python
# из tools/recap-lab/
import bench_ensemble as b
facts = open("out/gate2-fixed/m3/code-1/branch-3-facts.md").read()
branch = b.items_from_facts(facts)
merged = b.merge([branch])
merged[b.NARRATIVE] = b.merge_prose([branch])
open("expected-live.md", "w").write(b.render(merged, "", ""))
```

`render(..., "", "")` — без «Итога» и без фильтров `owners`/`strip_artifacts`:
это конструкции ансамбля, в lite они не едут (их роль играют `RecapLint.grounded`
и `TermCanon` дальше по конвейеру). Swift-порт (`RecapAssembly.assemble`) обязан
совпасть **байт в байт**; разъехались — чинить порт, не фикстуру.
