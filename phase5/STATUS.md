# Phase 5 — LLM-рекап

Дата: 2026-07-22  
Статус: **сделано**

## Что сделано

- [`RecapService.swift`](../meeting-recorder/swift/Sources/RecapService.swift): Ollama / OpenAI / Claude; Auto = Ollama → OpenAI → Claude
- [`KeychainHelper.swift`](../meeting-recorder/swift/Sources/KeychainHelper.swift): ключи API в Keychain
- Settings → **Recap (LLM)**: провайдер, модели, ключи, промпт (дефолт с подчисткой ASR-артефактов)
- После Save → авто-рекап; skip с подсказкой, если нет провайдера
- UI: pill Recap, Copy recap, Re-recap; файл `{id}-{slug}-recap.md` рядом с транскриптом
- Блок **Заметки** в рекапе — как есть, без LLM

## Verify

- `phase5/verify_main.swift`: skip-пути PASS (off / no provider / empty / resolve)
- Mock Ollama на `:11434`: generate PASS, notes preserved → `phase5/samples/mock-ollama-recap.md`
- Live OpenAI/Claude: нужны `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` (на машине не было — пропущено)

## Заметки

Провайдер по умолчанию Auto. Для пилота коллегам: поднять Ollama с `llama3.2` или вписать API-ключ в Settings.
