#!/bin/bash
# Печатает всё, по чему Propeller может опознать созвон, для запущенных сейчас
# приложений: bundle id, процессы, заголовки окон, power-assertions.
#
# Зачем: правила детекта в `MeetingPlatform` — это данные (bundle id, имена
# процессов, куски заголовков). Для Zoom они сняты с живого приложения, для
# Контур.Толк — предположены. Запусти этот скрипт ВО ВРЕМЯ созвона в Толке,
# и он покажет, что там на самом деле.
#
#   ./tools/detect-meeting-signals.sh              # всё подряд
#   ./tools/detect-meeting-signals.sh толк talk    # только совпадения

set -uo pipefail
FILTER="${*:-}"

matches() {
    [ -z "$FILTER" ] && return 0
    local haystack; haystack=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    for needle in $FILTER; do
        case "$haystack" in *"$(echo "$needle" | tr '[:upper:]' '[:lower:]')"*) return 0 ;; esac
    done
    return 1
}

echo "== Запущенные приложения (имя + bundle id) =="
echo "   Работает без разрешений — берём из LaunchServices."
lsappinfo list 2>/dev/null | awk '
    /^[0-9]+\)/ { name=$0; sub(/^[0-9]+\) *"/, "", name); sub(/".*/, "", name) }
    /bundleID=/ { b=$0; sub(/.*bundleID="/, "", b); sub(/".*/, "", b);
                  if (name != "" && b != "") printf "  %-28s %s\n", name, b; name="" }
' | while read -r line; do
    matches "$line" && echo "$line"
done

echo
echo "== Заголовки окон на экране =="
echo "   (нужно разрешение Screen Recording — Propeller его уже просит)"
osascript <<'APPLESCRIPT' 2>/dev/null | tr ',' '\n' | sed 's/^ *//' | while read -r line; do
tell application "System Events"
    set out to {}
    repeat with p in (every application process whose background only is false)
        repeat with w in (every window of p)
            set end of out to (name of p) & " | " & (name of w)
        end repeat
    end repeat
    return out
end tell
APPLESCRIPT
    [ -n "$line" ] && matches "$line" && echo "  $line"
done

echo
echo "== Процессы (кандидаты в helper созвона) =="
ps -Ao comm= | sed 's|.*/||' | sort -u | while read -r proc; do
    matches "$proc" && echo "  $proc"
done

echo
echo "== Power assertions (видеозвонок держит display sleep) =="
pmset -g assertions 2>/dev/null | grep -iE "PreventUserIdleDisplaySleep|NoDisplaySleep" -A 1 | while read -r line; do
    matches "$line" && echo "  $line"
done

echo
echo "Что делать с выводом: перенести реальные значения в"
echo "swift/PropellerPure/MeetingPlatform.swift → MeetingPlatform.konturTalk"
echo "и поправить тесты в MeetingPlatformTests (они на реальных заголовках)."
