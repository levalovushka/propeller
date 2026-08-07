#!/bin/bash
# Теневой замер сигнала «процесс держит микрофон и одновременно играет звук».
#
# Зачем: решить, годится ли этот сигнал для автозаписи встреч в браузере.
# Критерий приёмки — не больше 2 ложных баннеров за неделю. Пробник ничего не
# записывает и ничего не показывает: только журнал эпизодов.
#
#   ./run.sh start          # запустить в фоне (до перезагрузки)
#   ./run.sh install-agent  # то же, но через launchd: переживает перезагрузку
#   ./run.sh status         # жив ли, сколько эпизодов уже в журнале
#   ./run.sh report         # отчёт: сколько баннеров было бы за неделю
#   ./run.sh stop           # остановить (и снять агента, если он стоит)
#   ./run.sh self-test      # 20 с проверки конвейера на afplay, отдельный журнал
#
# Журнал: ~/.meeting-recorder/shadow-mic.jsonl (имя процесса и время, больше
# ничего — ни звука, ни заголовков окон, ни адресов).
# Разрешений не требует.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

HOME_DIR="$HOME/Library/Application Support/propeller-shadow-probe"
BIN="$HOME_DIR/probe"
JOURNAL="$HOME/.meeting-recorder/shadow-mic.jsonl"
PIDFILE="$HOME_DIR/probe.pid"
LABEL="com.simplyai.meeting-recorder.shadow-mic-probe"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

build() {
    mkdir -p "$HOME_DIR"
    if [ ! -x "$BIN" ] || [ probe.swift -nt "$BIN" ]; then
        echo "собираю пробник…"
        xcrun swiftc -O probe.swift -o "$BIN" || exit 1
    fi
}

running_pid() {
    [ -f "$PIDFILE" ] || return 1
    local pid; pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

agent_installed() { [ -f "$PLIST" ]; }

agent_pid() {
    launchctl list 2>/dev/null | awk -v l="$LABEL" '$3 == l && $1 != "-" { print $1 }'
}

# Два пробника пишут в один журнал и удваивают каждый эпизод, поэтому запуск
# любым способом сначала гасит другой.
stop_all() {
    if pid=$(running_pid); then kill "$pid" 2>/dev/null; rm -f "$PIDFILE"; fi
    if agent_installed; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
            || launchctl unload "$PLIST" 2>/dev/null
    fi
}

case "${1:-}" in
start)
    if pid=$(running_pid); then echo "уже работает, pid $pid"; exit 0; fi
    if [ -n "$(agent_pid)" ]; then echo "работает через launchd, см. ./run.sh status"; exit 0; fi
    build
    nohup "$BIN" "--journal=$JOURNAL" >"$HOME_DIR/probe.out" 2>&1 &
    echo $! > "$PIDFILE"
    echo "пробник запущен, pid $(cat "$PIDFILE")"
    echo "журнал: $JOURNAL"
    echo "живёт до перезагрузки; чтобы пережил её — ./run.sh install-agent"
    ;;
install-agent)
    build
    stop_all
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>--journal=$JOURNAL</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$HOME_DIR/probe.out</string>
    <key>StandardErrorPath</key>
    <string>$HOME_DIR/probe.err</string>
</dict>
</plist>
PLIST_EOF
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
        || launchctl load -w "$PLIST" || exit 1
    sleep 1
    echo "агент установлен: $PLIST"
    echo "pid: $(agent_pid)"
    echo "снять: ./run.sh stop"
    ;;
uninstall-agent | stop)
    stop_all
    if [ "${1}" = "uninstall-agent" ] || agent_installed; then
        rm -f "$PLIST"
    fi
    echo "остановлен"
    ;;
status)
    if pid=$(agent_pid); then
        echo "работает через launchd, pid $pid"
    elif pid=$(running_pid); then
        echo "работает в фоне, pid $pid"
    else
        echo "не запущен"
    fi
    agent_installed && echo "агент установлен: $PLIST"
    if [ -f "$JOURNAL" ]; then
        episodes=$(grep -c '"event":"episode"' "$JOURNAL" 2>/dev/null)
        echo "эпизодов в журнале: ${episodes:-0}"
        echo "последняя запись: $(tail -1 "$JOURNAL" 2>/dev/null)"
    else
        echo "журнала ещё нет: $JOURNAL"
    fi
    ;;
report)
    shift
    ./report.py "$JOURNAL" "$@"
    ;;
self-test)
    build
    TEST_JOURNAL="$HOME_DIR/self-test.jsonl"
    rm -f "$TEST_JOURNAL"
    echo "20 с: считаем эпизодом воспроизведение, играем два звука…"
    "$BIN" "--journal=$TEST_JOURNAL" --debug-use-output &
    probe_pid=$!
    sleep 2
    afplay /System/Library/Sounds/Submarine.aiff
    sleep 10
    afplay /System/Library/Sounds/Submarine.aiff
    sleep 8
    kill "$probe_pid" 2>/dev/null
    wait "$probe_pid" 2>/dev/null
    echo
    cat "$TEST_JOURNAL"
    ;;
*)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
