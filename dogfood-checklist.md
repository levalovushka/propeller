# Dogfood checklist — перед раздачей коллегам (SHIP-08)

Любой fail = will-hurt. Отмечай вручную.

## Happy path
- [ ] Cold start → permissions → имя → Zoom 3–5 мин → Summary → Copy
- [ ] Нет Ollama/ключа → Summary показывает что делать + тост, не пустоту без объяснения

## День менеджера (пакет D)
- [ ] Второй Zoom, пока первый ещё Transcribing/Summarizing → оба получают transcript+summary
- [ ] Во время ASR открыть старый митинг — нет чужого спиннера
- [ ] Запись + ⌃⌥N заметка + Stop → заметка на месте
- [ ] Play на A → запись B → Play на B играет B
- [ ] Upcoming mute → Zoom этой встречи **не** пишется
- [ ] Auto-record → Discard из окна / menu bar → нет файла в списке
- [ ] Quit mid-recording → relaunch → файл есть → Transcribe / auto-reconcile
- [ ] Mic-only встреча → бейдж только на ней

## Поставка
- [ ] DMG открывается, drag в Applications работает
- [ ] ПКМ→Открыть описан и работает на чистом Mac
- [ ] `gigastt` внутри `.app` (`Contents/MacOS/gigastt`)

## Definition of Done
5 коллег × 1 неделя × ≥1 саммари каждый без пинга автору.
