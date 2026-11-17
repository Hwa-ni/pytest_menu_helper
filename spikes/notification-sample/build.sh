#!/bin/bash
# 사용법: ./build.sh [none|adhoc]   (기본 adhoc)
# 산출물은 저장소 밖 ~/.pmh-build/ 에만 만든다.
set -euo pipefail
MODE="${1:-adhoc}"
SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="$HOME/.pmh-build"
APP="$OUT/PMHNotificationSample-$MODE.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O "$SRC/main.swift" -o "$APP/Contents/MacOS/PMHNotificationSample"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
case "$MODE" in
  adhoc) codesign --force --sign - "$APP" ;;
  none)  codesign --remove-signature "$APP/Contents/MacOS/PMHNotificationSample" 2>/dev/null || true ;;
  *) echo "mode: none|adhoc"; exit 1 ;;
esac
echo "built: $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|flags" || true
