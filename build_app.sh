#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Soripan.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Soripan "$APP/Contents/MacOS/Soripan"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
echo "Done: $(pwd)/$APP"
