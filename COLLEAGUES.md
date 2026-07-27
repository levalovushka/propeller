# Propeller для коллег

Внутренний local-first рекордер Zoom-встреч: запись → русский транскрипт → саммари.

**DoD первой раздачи:** 5 коллег × 1 неделя × ≥1 саммари без пинга автору.

## Установка

1. Скачай `.dmg` из GitHub Releases (или получи файл у Левона).
2. Открой DMG → перетащи **Propeller** в **Applications**.
3. Первый запуск macOS может сказать «неизвестный разработчик».  
   **ПКМ по Propeller → Открыть → Открыть** (один раз).  
   Пока нет Developer ID / нотаризации — это ожидаемо.

## Разрешения (обязательно)

| Разрешение | Зачем |
|------------|--------|
| **Микрофон** | Твоя речь |
| **Запись экрана** (Screen Recording) | Системный звук / Zoom (вторая сторона звонка) |
| **Уведомления** | Автозапись Zoom + кнопка «Не записывать» |
| **Календарь** (опционально) | Upcoming + названия встреч |
| **Универсальный доступ** (опционально) | ⌃⌥N — заметки поверх Zoom |

Системные настройки → Конфиденциальность и безопасность.

## Саммари (важно)

Саммари **не появится само**, если нет LLM:

1. **Предпочтительно локально:** установи [Ollama](https://ollama.com), затем:
   ```bash
   ollama pull qwen2.5:7b
   ```
   Propeller по умолчанию ждёт эту модель.
2. **Или** в Настройках → Recap укажи API-ключ OpenAI / Claude.

Без провайдера увидишь пустой Summary и тост/подсказку — это не поломка записи.

## Как пользоваться

- Zoom Auto (в настройках) — запись стартует сама; можно Discard / «Не записывать».
- Или кнопка Record / ⌘R в окне / menu bar.
- После звонка: вкладка **Summary** → Copy в чат.
- Upcoming → иконка mic.slash = не автозаписывать эту встречу в Zoom.

## Сборка для разработчиков

```bash
# Нужен бинарь tools/gigastt/gigastt (без него build.sh падает)
cd meeting-recorder/swift
./build.sh          # → /Applications/Propeller.app
# TelemetryDeck (dogfood): создай app на https://dashboard.telemetrydeck.com
# и передай App ID:
TELEMETRYDECK_APP_ID='xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' ./build.sh
./package-dmg.sh    # → ../../dist/Propeller-….dmg
./make-appcast.sh   # → ../../dist/appcast.xml (нужен private key)
```

Обновления: Settings → About → **Check for Updates…** (Sparkle + GitHub Releases). Первый запуск по-прежнему **ПКМ → Открыть** (нет Developer ID).

Телеметрия (TelemetryDeck): по умолчанию вкл; Settings → Основное → выкл. Сигналы без контента: `Propeller.Recording.*`, `Transcription.*`, `Recap.*`, `Search.opened`, `Onboarding.completed`. DEBUG-сборки видны в дашборде как Test Signals.
Для стабильных TCC между пересборками создай self-signed identity **`MeetingRecorder Dev`**  
(`security` / Keychain → Certificate Assistant → Code Signing). Без него каждый rebuild = заново Mic/Screen/Calendar.

## Проблемы

- Нет системного звука → проверь Screen Recording для Propeller, переключи тумблер off/on, перезапусти приложение.
- Нет саммари → Ollama / ключ (см. выше).
- Короткая случайная запись (<5 с) может не показываться в списке.
