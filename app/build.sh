#!/bin/bash
# 사용법: ./build.sh
# 빌드 중간물과 .app은 저장소 밖 ~/.pmh-build/ 에만 만든다.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$APP_DIR/.." && pwd)"
OUT="$HOME/.pmh-build"
APP="$OUT/PytestMenuHelper.app"

swift build -c release --package-path "$APP_DIR" --scratch-path "$OUT/swiftpm" --product PMHApp
BIN="$(swift build -c release --package-path "$APP_DIR" --scratch-path "$OUT/swiftpm" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PMHApp" "$APP/Contents/MacOS/PMHApp"
cp "$APP_DIR/Info.plist" "$APP/Contents/Info.plist"
# 플러그인 설치 명령에 넣을 이 저장소 경로를 번들에 기록한다.
/usr/libexec/PlistBuddy -c "Add :PMHRepoPath string $REPO" "$APP/Contents/Info.plist"
# 메뉴 아이콘 원본은 수정하지 않고 복사만 한다.
cp "$REPO/assets/mascot-fox-menubar.svg" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "built: $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|flags" || true
echo "실행: open \"$APP\""
