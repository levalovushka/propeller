# Phase 4 — простой режим вывода + иконка

Дата: 2026-07-22  
Статус: **сделано**

## Что сделано

- [`MarkdownWriter.swift`](../meeting-recorder/swift/Sources/MarkdownWriter.swift): форматы `simple` / `obsidian`; `render()` + `chatClipboardText()`
- Settings → Output: переключатель Simple / Obsidian (дефолт **Simple**)
- People pages path показывается только в Obsidian-режиме
- Action bar: **Copy for chat** — читаемый markdown в буфер (для Telegram/Slack); иконка копирования в панели транскрипта — сырой текст
- Иконка [`propellericon.icon`](../propellericon.icon) (Icon Composer): `build.sh` компилирует через `actool` → `Assets.car` + `propellericon.icns`, `CFBundleIconName=propellericon`

## Verify

- `phase4/verify_main.swift`: оба формата PASS; сэмплы в `phase4/samples/`
- `build.sh`: бандл с `Assets.car` + `propellericon.icns`

## Заметки на Фазу 5

Кнопка «Copy for chat» пока только транскрипт; после появления `recap.md` — добавить копирование рекапа тем же форматом.
