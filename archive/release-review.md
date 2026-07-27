# Propeller — релизное ревью и сценарийные дыры

_Снимок: июл 2026. Цель окна: отдать внутренний R1 команде за пару дней._  
_Связанные доки: [plan-v2.md](plan-v2.md) · [plan-optimization.md](plan-optimization.md) · [product-ideas.md](../product-ideas.md) · [meeting-recorder/docs/SPEC.md](../meeting-recorder/docs/SPEC.md)._

### Актуализация статуса (после ревью)

| Тема | Статус |
|------|--------|
| TEST-онбординг на каждом запуске (`showOnboarding = true`) | **Держим открытым намеренно** — не блокер сейчас |
| System audio (SCK / Zoom) | **Проверено на живом Zoom — работает** |
| Остальные находки ниже | Актуальны |

---

## 1. Вердикт

Продукт близко к «красивому рабочему внутреннему инструменту», но ещё не к **поставке**.

- **Happy path** (один Zoom → дождаться пайплайна → Summary → Copy) относительно крепок.
- **Релиз ломают** отсутствие канала раздачи (DMG/инструкция), молчаливый skip саммари без LLM, soft-сборка без `gigastt`, плюс рассинхрон docs/UI с реальностью.
- **Доверие коллег сломают** не «нехватка serif», а сценарии дня: 2 встречи подряд, notes из оверлея, quit mid-pipeline, Calendar «Don't record», Discard, плеер чужого аудио.

**Калибровка:** ~45–55% реалистичных daily-use путей (всё, что отклоняется от одного чистого митинга) имеют хотя бы одну дыру уровня will-hurt или annoying. Это не «всё сломано» — это недооценённый scenario coverage.

---

## 2. Обещание vs факт (ядро JTBD)

| Обещание | Факт | Статус |
|----------|------|--------|
| Install & forget → саммари | Нужны Mic + Screen Recording; рекап только если Ollama / API key | gap |
| Both sides of the call | SCK-only path; **живой Zoom подтверждён** | ok (на момент ревью) |
| Отдать команде | Нет DMG / Release / коллегского README | gap |
| Local-first privacy | Данные локально; Auto может услать транскрипт в cloud LLM | risk |
| Zoom auto, забыли | Работает; без notifications нет «Не записывать»; Discard слабо доступен | risk |
| Имена спикеров | Speaker N + owner-by-mic; LLM-rename отложен | ok для R1 |
| Upcoming «Don't record» | Прячет строку из списка, **не** глушит Zoom auto-record | gap |

---

## 3. Мультиоптика — что упускаешь

### Продукт
ICP узкий и правильный: RU Zoom менеджеры, саммари-first. Риск — расползание scope (Follow-up polish, Sparkle, Ollama-бандл, Process Tap) в окно, где нужна поставка.  
**Заморозить R1:** Zoom + mic/sys + транскрипт + саммари (если LLM есть) + copy + DMG + честные empty states. Остальное — backlog с датой.

### Бизнес
Нет монетизации и не нужна. Метрика успеха — не DAU, а «сколько коллег получили саммари без пинга тебе». Ad-hoc + инструкция допустимы. Developer ID / нотаризация — после первой недели фидбека. Telegram — канал привычки, не канал установки.

### Дизайн / Frontend
Visual language уже «продукт». Убивают доверие мёртвые контролы и пустой home, не отсутствие serif. Удалить или починить: retention UI, ложные чипы Google/Screenshots, disabled Follow-up без объяснения. WaveformScrubber не подключён — polish, не ship-blocker.

### Копирайт
Главный дефект — не тон, а ложь. Каждое обещание в онбординге должно мапиться на TCC или фичу 1:1. Язык: UI ≈ EN, Zoom notifications RU, теги/LLM RU — решить до раздачи.

### Системы / Backend
Сильные стороны: ASR checkpoint, durable index, quit flush, mic/SCK watchdogs, lazy gigastt, Keychain.  
Слабые: один глобальный `isTranscribing` на весь pipeline (включая recap), soft build, mix в RAM на длинных звонках, cloud Auto без явного consent. Process Tap в репо есть, runtime — SCK-only (docs drift с plan-v2 1.2).

### QA / Аналитик
Golden path checklist важнее новых фич. Docs drift (Tap / Sparkle / дефолт модели) создаёт ложное ощущение готовности. Scenario coverage дня менеджера важнее ещё одного дизайн-пасса.

---

## 4. Находки релиз-ревью (defect-first)

Severity: **P0** ship/доверие · **P1** сильно бьёт при использовании · **P2** позже.

### P0

| ID | Оптика | Проблема | Где |
|----|--------|----------|-----|
| dmg | Бизнес | Нет канала раздачи (.app в Applications ≠ поставка) | plan-v2 5.2 · archive Фаза 7 |
| recap-silent | Продукт | Без Ollama/ключа саммари молча не генерится — ломает JTBD | RecapService · plan-v2 4.5a |
| build-soft-gigastt | Системы | Сборка может «успеть» без ASR sidecar | build.sh · CI |

~~sys-audio-live~~ — снято: проверено на живом Zoom.  
~~c4-onboarding~~ — снято с блокеров: держим открытым намеренно.

### P1

| ID | Оптика | Проблема | Где |
|----|--------|----------|-----|
| onboard-lie | Копирайт | Screenshots / Google-чип / recordingGranted = только mic | Onboarding* · OnboardingContainer |
| perm-gate | Системы | Нет gate Screen Recording при старте записи | AppState.startRecording |
| docs-drift-tap | Аналитик | plan-v2: Process Tap primary; runtime: SCK-only | plan-v2 · AudioRecorder |
| retention-dead | Frontend | Auto-delete в Settings не исполняется | SettingsSheet · AppState.bootstrap |
| zoom-notify | Продукт | Автозапись без notifications = нет отказа | NotificationManager · startRecordingFromZoom |
| cloud-default | Бизнес | Auto → cloud LLM без явного consent | RecapService · Settings |
| ru-en | Копирайт | Языковой раскол EN UI / RU notifications | MainView · NotificationManager |
| empty-home | Дизайн | Нет Record CTA и empty state библиотеки | MainView |
| adhoc-tcc | QA | Ad-hoc подпись сбрасывает TCC между билдами | build.sh codesign |

### P2

| ID | Оптика | Проблема | Где |
|----|--------|----------|-----|
| waveform-dead | Дизайн | WaveformScrubber не встроен в detail | WaveformScrubber.swift |
| mix-ram | Системы | Offline mix грузит весь митинг в RAM | AudioRecorder.produceFinalMix |
| tests-thin | QA | Нет integration на record/mix/SCK/sidecar | Tests/ · Bench/ |
| followup-deadend | Frontend | Follow-up tab тупик без summary | RecordingDetailView |
| sparkle-conflict | Аналитик | plan-v2 vs ARCHITECTURE/product-ideas про Sparkle | docs |
| calendar-1-4 | Продукт | Нет «Записать?» для не-Zoom | plan-v2 1.4 |

### Сильные стороны (не потерять)

Pipeline с ASR checkpoint и resume diarization; durable index; quit path; mic/SCK watchdogs; lazy gigastt; Keychain; Zoom detector idle-friendly; notes-as-anchors в промпте; брендовый dark-glass UI.

---

## 5. Сценарийные дыры (daily use)

Интуиция «мы упускаем много багов на экранах и в сценариях» — **верная**. Ниже — то, что всплывёт у коллег при реальном дне, не на демо одного звонка.

### 5.1 Кластеры will-hurt (чинить раньше polish)

#### Очередь пайплайна
1. **Вторая встреча не транскрибируется**, пока первая в ASR→save→recap. `isTranscribing` держится на весь chain; `runTranscribe` → `"Transcription already in progress"`.  
   `AppState.runTranscribe` · `stopRecordingAndWait`
2. Старт записи B во время ASR A **сбрасывает** глобальные pipeline steps → UI A врёт.  
   `AppState.beginRecording`
3. На detail «чужого» митинга крутится «Generating summary…» (нет проверки `busyRecordingID == entry.id`).  
   `RecordingDetailView.recapPanel`
4. `selectRecording` mid-pipeline перетирает `.running` статусами выбранной записи.  
   `AppState.selectRecording`
5. Recap A завершается во время митинга B → **focus steal** окна.  
   `AppState.surfaceSummaryUI`

#### Потеря / порча данных
6. **Оверлей-заметки (⌃⌥N) затираются** in-window `liveNotes` на stop/`onDisappear`.  
   `NoteOverlayController` · `RecordingInProgressView.flushNotes`
7. **Плеер играет аудио прошлого митинга** после новой записи (`player.stop` в select, но не в begin/stop record; `autoLoad` early-exit при `totalDuration > 0`).  
   `AppState.beginRecording` · `RecordingDetailView.autoLoadAudioForPlayer`
8. Гонка Stop vs Discard / Zoom-end — два terminal action без mutex.  
   `cancelRecordingAndDiscard` · `stopRecordingAndWait` · `handleZoomMeetingEnded`
9. Delete meeting удаляет audio+index, **не** markdown/recap/follow-up на диске.  
   `RecordingStore.remove`
10. ⌘K → открыть другой митинг во время REC: notepad пишет notes не в тот entry (overlay OK по `recordingID`, UI — нет).  
    `SearchPalette` · `RecordingInProgressView`

#### Ложные продуктовые жесты
11. Upcoming **«Don't record» не глушит Zoom auto-record** — только session dismiss списка.  
    `CalendarService.dismiss` · `AppState.startRecordingFromZoom`
12. В живом UI **нет Discard** (есть в неиспользуемом `MenuBarPanelView` + notification).  
    `RecordingInProgressView` · `MenuBarPopover` / ContentView
13. Ручная запись + Zoom mid-session → hangup Zoom **остановит** ручную запись (`recordingLinkedToZoom = true`).  
    `handleZoomMeetingStarted` / `Ended`
14. Нет Join / open Zoom link из Upcoming.  
    `MainView.upcomingRow`

#### Quit / recover
15. Quit mid-REC: WAV сохраняется, **auto-transcribe не запускается**.  
    `applicationShouldTerminate` · `stopRecordingAndWait(autoTranscribe: false)`
16. Quit mid-ASR: sidecar kill; recovery меняет status, **без авто-продолжения**.  
    `GigasttSidecar.stop` · `recoverInterruptedRecordings`
17. Menu bar во время recap показывает **idle** (не учитывает `recapStep`).  
    `MenuBarContentView.status`

### 5.2 Annoying (добивают доверие)

18. Empty Summary без CTA «Generate» / слабый путь к Settings при no provider.  
19. Rename speaker → полный `runSave` → перегенерация recap.  
20. **«Mic only» badge глобальный** — залипает на чужих митингах.  
21. Auto: Ollama >5s → уход на платный API при ключе.  
22. Короткая запись &lt;5s исчезает из списка, но живёт в Search.  
23. `preferredDetailTab` залипает на следующий чужой митинг после Back на list.  
24. Edit transcript во время re-transcribe → commit затирает новый ASR.  
25. Двойной regenerate / backfill vs ручной edit summary (last-write-wins).  
26. Follow-up empty без inline CTA; «regenerate» = local compress, не LLM.  
27. Screen Recording отозван mid-call → UI правда в основном после Stop.  
28. Notifications denied → auto-record без баннера отказа.  
29. Rename title не переименовывает файлы на диске (Finder/Obsidian видят старые имена).  
30. Recap A notification / surface ворует фокус.

### 5.3 Edge

31. Delete Audio alert в detail — мёртвый код (удаление только из context menu списка).  
32. Ручной edit transcript → invalidate segments → rename-speakers UI пропадает без объяснения.  
33. Тишина → ASR noResults → failed/recorded без «это была тишина».  
34. `preferredSidebarSection` пишется, нигде не читается.  
35. Provider Off: UI выглядит как «ещё не готово», не «выключено».  
36. Dismiss Upcoming не переживает relaunch.  
37. Hard kill mid-notes debounce — потеря последних keystrokes.

### 5.4 Карта хрупкости по классам путей

| Класс путей | Хрупкость |
|-------------|-----------|
| Один Zoom, дождаться, copy | низкая |
| Back-to-back / parallel pipeline | **высокая** |
| Menu-bar-only + discard/cancel | **высокая** |
| Calendar «mute meeting» | **высокая** (product mismatch) |
| Quit mid-pipeline | **высокая** |
| Edit old meeting / delete | средняя |
| Notes overlay + window | **высокая** (потеря данных) |

---

## 6. План на 2 дня — ship-пакет (scope freeze)

**Принцип:** не делать Sparkle, бандл Ollama, возврат Process Tap, Developer ID, Telegram, serif/waveform polish. Делать то, без чего коллега не получит ценность или потеряет данные/доверие.

### День 1 — правда, данные, сценарии дня

1. Честный онбординг copy (Screenshots / Google / Screen Recording wording) — онбординг-флоу можно оставить «всегда открытым».
2. `build.sh`: fail hard без `gigastt`; не глотать codesign errors.
3. Убрать или починить Retention UI; cloud Auto — явный copy + безопасный дефолт.
4. Empty library + Record CTA; Follow-up/Summary empty не тупик.
5. **P0 scenario:** merge notes overlay ↔ window; `player.stop` + правильный load на record lifecycle.
6. **P0 scenario:** не блокировать второй транскрипт всей длительностью recap (очередь или сузить `isTranscribing`); pipeline UI только при `busyRecordingID == entry.id`.
7. Calendar «Don't record» → реально `ignoredZoomMeeting` (или аналог) для ближайшего Zoom.
8. Discard в Recording UI + menu bar.

### День 2 — поставка + dogfood

1. DMG (`hdiutil`) поверх `build.sh` + версия из Bundle.
2. `COLLEAGUES.md`: ПКМ→Открыть, Mic, Screen Recording, Notifications, Ollama/qwen или API key.
3. Summary empty: «Нужен Ollama или API key» + путь в Settings — не тишина.
4. Notifications gate для Zoom auto (denied → не автостартовать или in-app decline).
5. Resume recovered recordings на launch (хотя бы предложить Transcribe).
6. Cold-path smoke: DMG → permissions → Zoom → Summary → Copy; плюс dogfood-матрица ниже.
7. Scope freeze в plan-v2: R1 ship list vs deferred; поправить docs drift Process Tap → SCK.

### Явно НЕ делать в эти 2 дня

| Тема | Почему |
|------|--------|
| Sparkle / appcast | Съест день; не нужен для 3–5 коллег |
| Бандл Ollama ~4.5 ГБ | Честный empty state закрывает 80% боли |
| Вернуть Process Tap | SCK подтверждён; не трогать без нужды |
| Developer ID / нотаризация | ПКМ→Открыть достаточен |
| Telegram / шаблоны / полный RU i18n | R2 |
| Serif / waveform polish | Не меняют trust |

---

## 7. Dogfood-чеклист (15 прогонов)

Прогнать до раздачи коллегам. Любой fail = will-hurt.

1. Cold start → permissions → имя → первая запись 3–5 мин Zoom → Summary появляется → Copy.  
2. Сразу второй Zoom, пока первый ещё «Transcribing/Summarizing» → оба получают transcript+summary.  
3. Во время ASR открыть старый митинг — нет чужого спиннера; вернуться — прогресс первого жив.  
4. Запись + ⌃⌥N заметка + Stop → заметка на месте в Notes.  
5. Play на митинге A → новая запись B → Play на B играет B.  
6. Upcoming «Don't record» → зайти в Zoom этой встречи → **не** пишется.  
7. Случайный auto-record → Discard из окна / menu bar → нет файла в списке.  
8. Ручная Record → открыть Zoom → hangup Zoom → запись **не** обрывается (или осознанное поведение задокументировано).  
9. Quit mid-recording → relaunch → файл есть → можно Transcribe.  
10. Quit mid-transcribe → relaunch → не «вечный recorded» без CTA.  
11. Нет Ollama/ключа → Summary показывает что делать, не пустоту.  
12. Есть только OpenAI key, provider Auto → понятно, что уйдёт в облако (или local-only default).  
13. Delete meeting → нет orphan md/recap **или** осознанный leave + docs.  
14. Menu bar only: Start/Stop, статус processing на этапе summary, Open window.  
15. Mic-only встреча → бейдж только на ней; следующий митинг с sys audio — без ложного Mic only.

---

## 8. Решения от владельца (не код)

1. **Язык UI** — RU целиком для менеджеров, или EN UI + RU notifications осознанно?  
2. **Саммари без Ollama** — требовать модель/ключ в онбординге, или ship с честным «summary unavailable»?  
3. **Definition of Done** — предложение: 3 коллеги, 1 неделя, ≥1 саммари каждый без пинга автору.

---

## 9. Приоритет фикса scenario-багов (если время до DMG)

1. Merge/reload notes: overlay ↔ `liveNotes` + flush без overwrite.  
2. `player.stop()` на start/stop recording + load audio строго для текущего `entry.id`.  
3. Мутекс stop/cancel; очередь транскриптов (не держать `isTranscribing` на recap).  
4. Pipeline UI только при `busyRecordingID == entry.id`.  
5. Calendar mute → реальный ignore auto-record; Discard в UI.  
6. Auto-resume / CTA для recovered recordings.

---

## 10. Источники

Код: `AppState.swift`, `AudioRecorder.swift`, `SystemAudioCapture.swift`, `ProcessTapAudioCapture.swift` (не в live path), `RecordingDetailView.swift`, `RecordingInProgressView.swift`, `MainView.swift`, `MenuBarContentView.swift`, `MenuBarPanelView.swift`, `NoteOverlayController.swift`, `Onboarding*`, `RecapService.swift`, `RecordingStore.swift`, `CalendarService.swift`, `NotificationManager.swift`, `build.sh`.

Доки: `plan-v2.md`, `plan-optimization.md`, `product-ideas.md`, `design/propeller-ui.md`, `meeting-recorder/docs/SPEC.md`, `ARCHITECTURE.md`.
