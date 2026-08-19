#!/bin/bash
# Собрать пробу как .app, чтобы «Универсальный доступ» выдавался ей, а не терминалу.
#
# Разрешение TCC привязано к подписи, поэтому подписываем тем же Developer ID,
# что и приложение: иначе каждая пересборка сбрасывает выданный доступ.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="$PWD/axprobe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>axprobe</string>
  <key>CFBundleDisplayName</key><string>axprobe (проба Пропеллера)</string>
  <key>CFBundleIdentifier</key><string>design.pragmatica.axprobe</string>
  <key>CFBundleExecutable</key><string>axprobe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Никаких обёрток: главный исполняемый файл бандла — сам бинарник. Скрипт в
# середине ломает привязку TCC (право уходит интерпретатору), и доступ выданный
# .app не действует. Без аргументов бинарник сам снимает отчёт.
cp .build/release/axprobe "$APP/Contents/MacOS/axprobe"
chmod +x "$APP/Contents/MacOS/axprobe"

codesign --force --deep --options runtime \
  --sign "Developer ID Application: Levon Lobanov (9T455555U3)" "$APP"
codesign --verify --verbose=1 "$APP"

echo
echo "Собрано: $APP"
echo
echo "Один раз выдай доступ:"
echo "  Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → +"
echo "  и выбери $APP"
echo
echo "Потом, ВО ВРЕМЯ звонка в Zoom:  open $APP"
echo "Отчёт: ~/diarize-lab-corpus/axprobe-report.txt"
