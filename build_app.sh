#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Soripan.app"
# 애플 실리콘 + 인텔 유니버설 바이너리
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Soripan" "$APP/Contents/MacOS/Soripan"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
echo "Done: $(pwd)/$APP"
