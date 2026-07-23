# Phase 6 — автодетект Zoom

Дата: 2026-07-22  
Статус: **сделано** (поведение уточнено 2026-07-22: без Ask)

## Что сделано

- [`ZoomMeetingDetector.swift`](../meeting-recorder/swift/Sources/ZoomMeetingDetector.swift): полл каждые 2 с
  - сигнал встречи: `aomhost` **или** meeting-window **или** display-sleep assertion от zoom.us
  - `caphost` / просто запущенный `zoom.us` — **не** встреча (проверено на idle)
  - debounce: 2 тика на вход, 3 на выход
- Settings → Zoom: **Off / Auto-record** (дефолт **Auto**). Устаревший `ask` в UserDefaults мигрирует в `auto`.
- Auto: старт записи без диалога; [`NotificationManager`](../meeting-recorder/swift/Sources/NotificationManager.swift) показывает уведомление с действием **«Не записывать»** (стоп + удаление записи). Конец звонка → стоп + транскрипт (если auto-transcribe).
- Онбординг: подсказка про авто-запись Zoom

## Verify

- Idle Zoom на машине: `zoomRunning=true`, `caphost=true`, `aomhost=false`, `inMeeting=false` — PASS
- Live join/leave звонка не прогонялся в CI (нужен реальный call); логика сигналов покрыта probe

## Как проверить руками

1. Settings → Zoom = Auto-record  
2. Войти в Zoom-встречу → через ~4 с запись + уведомление  
3. «Не записывать» → запись исчезает; либо выйти из встречи → стоп и обработка  
