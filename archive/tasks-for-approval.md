# Propeller — полный список задач на одобрение

_Составлено из [release-review.md](release-review.md), [plan-v2.md](plan-v2.md), [plan-optimization.md](plan-optimization.md). Код не трогаем, пока не отметишь, чем занимаемся и в каком порядке._

**Как пользоваться:** у каждой задачи статус одобрения — поставь одно из:

- `GO` — делаем  
- `LATER` — в бэклог после текущего окна  
- `SKIP` — не делаем / уже ок / осознанно отложено навсегда  
- `DECIDE` — нужно твоё продуктовое решение до кода  

В конце — открытые решения и предложенные пакеты работ (можно взять пакет целиком или собрать свой порядок из ID).

---

## Легенда

| Колонка | Значение |
|---------|----------|
| **ID** | Стабильный идентификатор |
| **Тип** | `bug` · `ship` · `growth` · `docs` · `content` · `perf` · `debt` |
| **Sev** | `P0` критично для доверия/поставки · `P1` сильно бьёт daily use · `P2` рост/polish |
| **Источник** | Откуда взяли |
| **Одобрение** | пусто → жду твой вердикт |

---

## A. Уже снято / держим как есть (не трогать без запроса)

| ID | Что | Почему |
|----|-----|--------|
| A1 | TEST-онбординг на каждом запуске | Держим открытым намеренно |
| A2 | System audio / SCK на Zoom | Проверено — работает |
| A3 | People / voice library | Вырезано осознанно |
| A4 | Telegram (C2) | R2 |
| A5 | Developer ID + нотаризация (5.4) | Позже по решению |
| A6 | Menu bar chrome (S6–S8) | Закрыто, не трогаем |
| A7 | Шаблоны саммари (4.6) | R2 / контент |
| A8 | Полный RU i18n | Нужно решение DECIDE-1 |
| A9 | Вернуть Process Tap в live path | Нет — SCK-primary канон (2026-07-24); Process Tap dormant |

---

## B. Открытые решения (нужны до части задач)

| ID | Вопрос | Блокирует |
|----|--------|-----------|
| DECIDE-1 | Язык UI: RU целиком / EN UI + RU notifications осознанно / bilingual позже | COPY-* · онбординг |
| DECIDE-2 | Саммари без Ollama: честный empty state + Settings / требовать ключ в онбординге / бандл Ollama (4.5a, тяжёлый) | SHIP-02 · GROW-04 · GROW-05 |
| DECIDE-3 | Definition of Done релиза: N коллег × неделя × ≥1 саммари? | Когда останавливаем ship-пакет |
| DECIDE-4 | Порог size-nudge X ГБ (5 / 10 / настраиваемый); удалять только аудио или всю встречу | GROW-11 |
| DECIDE-5 | Sparkle в R1 или LATER (конфликт plan-v2 vs «не делать за 2 дня») | SHIP-04 |
| DECIDE-6 | Calendar Upcoming «Don't record»: mute только Zoom-сессию / mute по event id на день / join link тоже | BUG-CAL-* |
| DECIDE-7 | Ручная запись + Zoom hangup: не линковать ручную / линковать и стопать (текущее) — задокументировать | BUG-REC-13 |

---

## C. Баги и сценарийные дыры

### C1. Данные и корректность (теряется / портится)

| ID | Sev | Тип | Задача | Источник | Одобрение |
|----|-----|-----|--------|----------|-----------|
| BUG-DATA-01-GO | P0 | bug | Overlay-заметки (⌃⌥N) не затираются `liveNotes` на stop — merge/reload | release-review §5.1 #6 · 4.8 | |
| BUG-DATA-02-GO | P0 | bug | `player.stop()` на start/stop записи; load audio строго для текущего entry | release-review §5.1 #7 | |
| BUG-DATA-03-GO | P0 | bug | Мутекс terminal actions: Stop / Discard / Zoom-end не гоняются | release-review §5.1 #8 · opt R7 | |
| BUG-DATA-04-GO | P1 | bug | Delete meeting чистит md/recap/follow-up (или осознанный leave + docs) | release-review §5.1 #9 | |
| BUG-DATA-05-SKIP | P1 | bug | Во время REC запретить смену meeting через ⌘K / selection (или notes только в live id) | release-review §5.1 #10 | |
| BUG-DATA-06-GO | P1 | bug | Edit transcript mid re-transcribe не затирает новый ASR | release-review §5.2 #24 | |
| BUG-DATA-07-LATER | P1 | bug | Guard regenerate/backfill vs ручной edit summary (no last-write-wins) | release-review §5.2 #25 | |
| BUG-DATA-08-GO | P2 | bug | Rename title → синхронизировать имена файлов md/recap или документировать id-prefix | release-review §5.2 #29 | |

### C2. Пайплайн и очередь

| ID | Sev | Тип | Задача | Источник | Одобрение |
|----|-----|-----|--------|----------|-----------|
| BUG-PIPE-01-GO | P0 | bug | Очередь/реконсилятор: вторая встреча после Stop не остаётся `recorded` навсегда; не держать `isTranscribing` на весь recap | release-review #1 · opt **G1/G2** | |
| BUG-PIPE-02-GO | P1 | bug | Pipeline UI (спиннеры/статусы) только при `busyRecordingID == entry.id` | release-review #3–4 | |
| BUG-PIPE-03-GO | P1 | bug | `beginRecording` не сбрасывает чужой pipeline UI | release-review #2 | |
| BUG-PIPE-04-GO | P1 | bug | Не красть фокус окна при завершении recap чужой/фоновой встречи | release-review #5 · #30 | |
| BUG-PIPE-05-GO | P1 | bug | Auto-resume / CTA для recovered (`recorded` / `transcribed_raw`) на launch | release-review #15–16 · G2 | |
| BUG-PIPE-06-GO | P1 | bug | Menu bar показывает processing и на этапе `recapStep` | release-review #17 | |
| BUG-PIPE-07-GO | P2 | bug | Metadata (title/topics/tags) дотягивать реконсилятором, если recap есть а мета нет | opt **G4** | |
| BUG-PIPE-08-GO | P2 | bug | Тишина / ASR noResults — понятный статус, не «failed» без смысла | release-review #33 | |

### C3. Запись, Zoom, календарь

| ID | Sev | Тип | Задача | Источник | Одобрение |
|----|-----|-----|--------|----------|-----------|
| BUG-REC-01-GO | P0 | bug | Discard («Stop & delete») в Recording UI + живом menu bar (plan 1.3 помечен ☑ — **проверить/вернуть**) | plan-v2 1.3 · release-review #12 | |
| BUG-REC-02-GO | P0 | bug | Upcoming «Don't record» реально глушит Zoom auto-record (не только hide из списка) | release-review #11 · DECIDE-6 | |
| BUG-REC-03-GO | P1 | bug | `ignoredZoomMeeting` липкий на сессию Zoom (не сбрасывать флапом детектора) | opt **G3** / R7 | |
| BUG-REC-04-GO | P1 | bug | Ручная запись не линкуется к Zoom hangup (или DECIDE-7 + docs) | release-review #13 | |
| BUG-REC-05-GO | P1 | bug | Notifications denied → не тихий auto-record: gate или in-app decline | release-review #28 · zoom-notify | |
| BUG-REC-06-GO | P1 | bug | Screen Recording preflight при старте (если captureSystemAudio on) | release-review perm-gate | |
| BUG-REC-07-GO | P1 | bug | Mid-session sys-audio failure → живой баннер, не только post-stop | release-review #27 | |
| BUG-REC-08-GO | P2 | growth | Join / open Zoom link из Upcoming | release-review #14 | |
| BUG-REC-09-GO | P2 | growth | Авто-стоп записи через 8 часов + периодический disk check | opt **G5** | |
| BUG-REC-10-LATER | P2 | bug | Dismiss Upcoming переживает relaunch (если нужно после DECIDE-6) | release-review #36 | |

### C4. UI-состояние и доверие

| ID | Sev | Тип | Задача | Источник | Одобрение |
|----|-----|-----|--------|----------|-----------|
| BUG-UI-01-GO | P1 | bug | «Mic only» badge per-entry, не глобальный latch | release-review #20 | |
| BUG-UI-02-GO | P1 | bug | Empty Summary: CTA Generate + «нужен Ollama/ключ» → Settings | release-review #18 · SHIP-02 | |
| BUG-UI-03-GO | P1 | bug | Empty library + Record CTA на home | release-review empty-home | |
| BUG-UI-04-LATER | P1 | bug | Follow-up empty: inline CTA или скрыть таб; честный copy про compress≠LLM | release-review #26 · #41–42 | |
| BUG-UI-05-GO | P1 | bug | `preferredDetailTab` не залипает на чужой митинг после Back | release-review #23 | |
| BUG-UI-06-GO | P1 | bug | Убрать/починить мёртвый Retention UI (time-based) до size-nudge | release-review retention-dead · 6.1 | |
| BUG-UI-07-GO | P2 | bug | Короткие &lt;5s: не «исчезать» из списка без объяснения / единый stub policy | release-review #22 | |
| BUG-UI-08-GO | P2 | debt | Удалить мёртвый код: Delete Audio alert, `preferredSidebarSection`, orphan `MenuBarPanelView` UI после переноса Discard | opt H1 · release-review #31 #34 | |
| BUG-UI-09-GO | P2 | bug | Provider Off — явный empty state «выключено», не «ещё не готово» | release-review #35 | |
| BUG-UI-10-GO | P2 | bug | Rename speaker не обязан всегда перегенеривать recap (или confirm) | release-review #19 | |

### C5. Копирайт / онбординг (флоу можно оставить всегда открытым)

| ID | Sev | Тип | Задача | Источник | Одобрение |
|----|-----|-----|--------|----------|-----------|
| COPY-01-LATER | P1 | bug | Убрать ложное «Screenshots» из Welcome | release-review onboard-lie | |
| COPY-02-GO | P1 | bug | Calendar: один честный чип EventKit / «включая Google в Internet Accounts» | onboard-lie · Settings уже ближе | |
| COPY-03-LATER | P1 | bug | Permissions: Screen Recording wording; Next disabled с пояснением; Accessibility ≠ «Notes over any app» | onboard-lie | |
| COPY-04-GO | P1 | bug | Выровнять `recap`/`summary`, `Downloading model…`, stop notifications с языком UI | release-review ru-en · DECIDE-1 | |
| COPY-05-LATER | P1 | bug | Cloud Auto: явный copy «транскрипт уйдёт к провайдеру» + безопасный дефолт | cloud-default · DECIDE-2 | |

---

## D. Поставка (ship)

| ID | Sev | Тип | Задача | Источник | Одобрение |
|----|-----|-----|--------|----------|-----------|
| SHIP-01-GO | P0 | ship | `build.sh`: fail hard без `gigastt`; не глотать codesign errors | release-review build-soft | |
| SHIP-02-GO | P0 | ship | Честный путь к саммари без провайдера (empty state; не silent skip) | DECIDE-2 · recap-silent | |
| SHIP-03-GO | P0 | ship | DMG (`hdiutil`) поверх build.sh + версия из Bundle | plan-v2 **5.2** | |
| SHIP-04-GO | P1 | ship | Sparkle + appcast + «Проверить обновления» | plan-v2 **5.3** · S2 · DECIDE-5 | |
| SHIP-05-GO | P0 | ship | `COLLEAGUES.md` / README: ПКМ→Открыть, Mic, Screen Recording, Notifications, Accessibility, Ollama/ключ | plan-v2 **5.5** | |
| SHIP-06-GO | P1 | ship | Стабильный Dev codesign identity в инструкции билдера (TCC survival) | adhoc-tcc | |
| SHIP-07-GO | P2 | ship | CI: прогон бандла / наличие gigastt в артефакте | release-review | |
| SHIP-08-GO | P1 | ship | Dogfood 15 прогонов из release-review §7 перед раздачей | release-review §7 | |

---

## E. Точки роста продукта (plan-v2 / growth)

| ID | Sev | Тип | Задача | Источник | Одобрение |
|----|-----|-----|--------|----------|-----------|
| GROW-01-LATER | P1 | growth | Календарь → уведомление «Записать?» для не-Zoom (Meet/Телемост) | plan-v2 **1.4** | |
| GROW-02-GO | P2 | docs | Docs drift: Process Tap → SCK-only; статус E4/1.2 поправить | plan-v2 1.2 · opt E4 note | |
| GROW-03-GO | P2 | content | Стартовый словарь терминов (hotwords pack) | plan-v2 **2.2** | |
| GROW-04-GO | P1 | growth | Дефолт модели — проверить/закрепить qwen2.5:7b везде (prefs уже default) | plan-v2 **4.5** | |
| GROW-05-GO | P1 | growth | Бандл Ollama + pull модели в онбординге (~4.5 ГБ) | plan-v2 **4.5a** · DECIDE-2 | |
| GROW-06-GO | P2 | growth | UI статус загрузки LLM-модели + backfill по «модель готова» | plan-v2 **4.5b** | |
| GROW-07-GO | P2 | growth | LLM-именование спикеров (Speaker N → имена) | plan-v2 **4.7** / 3.4 | |
| GROW-08-LATER | P2 | growth | Предупреждение при re-summarize поверх ручных правок | plan-v2 4.1 остаток | |
| GROW-09-GO | P2 | growth | Авто-заголовок: живая проверка UI + календарный приоритет названия | plan-v2 4.2 | |
| GROW-10-GO | P2 | growth | Живая проверка topics/tags на реальных встречах | plan-v2 4.3–4.4 | |
| GROW-11-GO | P1 | growth | Size-based retention nudge (вместо time-based) | plan-v2 **6.1** · DECIDE-4 | |
| GROW-12-GO | P1 | growth | Саммари в полнотекстовый ⌘K поиск | plan-v2 **6.2** | |
| GROW-13-GO | P2 | growth | Фильтр списка встреч по тегам | plan-v2 **6.3** | |
| GROW-14-GO | P2 | growth | Settings: донастройка recap prompt понятна (S4) | plan-v2 S4 | |
| GROW-15-LATER | P2 | growth | WaveformScrubber в detail | design / release-review | |
| GROW-16-GO | P2 | growth | Structured notes `{timestamp,text}` + LLM-связь (4.8 остаток) | plan-v2 4.8 | |

---

## F. Надёжность / perf / tech debt (plan-optimization)

| ID | Sev | Тип | Задача | Источник | Одобрение |
|----|-----|-----|--------|----------|-----------|
| OPT-G1G2-GO | P0 | bug | = BUG-PIPE-01 (реконсилятор) — не дублировать работу | G1/G2 | _(alias)_ |
| OPT-M1-GO | P2 | perf | Стриминговый offline mix (не грузить час в RAM) | M1 | |
| OPT-M2-GO | P2 | bug | Выравнивание старта mic/sys стемов | M2 | |
| OPT-M3-GO | P2 | bug | Смена output device mid-call не роняет sys audio | M3 | |
| OPT-M4-GO | P2 | bug | Soft-clamp микса вместо hard-clip | M4 | |
| OPT-M5-GO | P2 | bug | VoiceProcessed: I/O не под lock в аудио-колбэке | M5 | |
| OPT-R1-GO | P2 | bug | gigastt `restart()` vs `stop()` → portOccupied | R1 | |
| OPT-R2-GO | P2 | bug | Ollama timeouts + `num_ctx` | R2 | |
| OPT-R3-GO | P2 | bug | ASR HTTP timeout масштабируется с длительностью | R3 | |
| OPT-P1-GO | P2 | perf | SearchPalette: не пересканировать всё на каждый keystroke | P1 | |
| OPT-P2-GO | P2 | perf | Кэш parsed transcript segments | P2/P7 | |
| OPT-P4-GO | P2 | perf | Сузить наблюдение AppState во views | P4 | |
| OPT-P6-GO | P2 | perf | RecordingStore.save off MainActor / без prettyPrinted hot path | P6 | |
| OPT-H4-GO | P2 | debt | PipelineCoordinator (вынос стейт-машины) — вместе с реконсилятором или после | A2/H4 | |
| OPT-AUTO-GO | P2 | bug | Auto provider: не уходить на cloud через 5s cold Ollama без явного согласия | release-review #21 · COPY-05 | |

---

## G. Документация и гигиена планов

| ID | Sev | Тип | Задача | Источник | Одобрение |
|----|-----|-----|--------|----------|-----------|
| DOCS-01-GO | P1 | docs | Scope freeze в plan-v2: R1 ship list vs deferred; снять конфликт Sparkle | release-review · DECIDE-5 | |
| DOCS-02-GO | P1 | docs | Поправить 1.2/E4: runtime = SCK; Process Tap = optional/deferred | GROW-02 | |
| DOCS-03-GO | P2 | docs | Сверить 1.3 Discard: статус ☑ vs отсутствие в live UI | BUG-REC-01 | |
| DOCS-04-GO | P2 | docs | Обновить ARCHITECTURE.md (Sparkle/SCK/retention) под факт | sparkle-conflict | |
| DOCS-05-GO | P2 | docs | Зафиксировать DECIDE-* ответы в plan-v2 / release-review | — | |

---

## Предложенные пакеты (выбери один или собери свой)

Отметь пакет `GO` или перечисли ID.

### Пакет **S** — Ship-минимум (поставка коллегам)
`SHIP-01` `SHIP-02` `SHIP-03` `SHIP-05` `SHIP-08`  
`COPY-01` `COPY-02` `COPY-03` `COPY-05`  
`BUG-UI-02` `BUG-UI-03` `BUG-UI-06`  
+ DECIDE-1, DECIDE-2, DECIDE-3

**Статус (2026-07-27): DONE** — `./build.sh` fail-hard + DMG в `dist/`, COLLEAGUES.md, dogfood-checklist, empty Summary/library, Retention UI снят, Calendar chip честный. LATER в пакете не трогали: `COPY-01/03/05`. `SHIP-04` Sparkle → пакет G. `SHIP-06/07` закрыты вместе с инструкцией + CI sanity. Дальше пакет G.

### Пакет **D** — Data & day-scenarios (доверие при реальном дне)
`BUG-DATA-01` `BUG-DATA-02` `BUG-DATA-03`  
`BUG-PIPE-01` `BUG-PIPE-02` `BUG-PIPE-05`  
`BUG-REC-01` `BUG-REC-02` `BUG-REC-03` `BUG-REC-05`  
`BUG-UI-01`

**Статус (2026-07-27): DONE** — собрано в `/Applications/Propeller.app`. Дальше пакет S.

### Пакет **G** — Growth R1 из plan-v2 (после S+D)
`GROW-12` `GROW-11` `GROW-01` `GROW-04`  
`SHIP-04` только если DECIDE-5 = GO  
`GROW-05` только если DECIDE-2 = бандл Ollama

**Статус (2026-07-27): DONE** — Sparkle (`SHIP-04`) + appcast tooling; size-nudge 5 ГБ (`GROW-11`); саммари в ⌘K (`GROW-12`); qwen2.5:7b подтверждён (`GROW-04`). Пропущены: `GROW-01` (LATER), `GROW-05` (не бандл). Docs Sparkle/SCK/retention подтянуты.

### Пакет **P** — Perf/audio deep (после живых недель)
`OPT-M*` `OPT-R*` `OPT-P*` `OPT-H4`

### Явно не предлагаю в ближайшее окно
`GROW-05` (если не выбрал бандл) · `GROW-07` · `GROW-15` · `SHIP-04` (если DECIDE-5 = LATER) · полный `OPT-P4` · `A9` Process Tap

---

## Твой ответ (шаблон)

Скопируй и заполни:

```
DECIDE-1: RU
DECIDE-2: Надо запускать скачивание после онборда, класть это в статус. Без олламы давать тост с ошибкой. 
DECIDE-3: 1 неделя, пять коллег.
DECIDE-4: 5 гб.
DECIDE-5: Да уже как будто можно и в первый релиз.
DECIDE-6: Мьют сессии.
DECIDE-7: Линк и стоп. 



После этого начинаем кодить строго по одобренному списку и порядку.
