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
cp "$REPO/assets/mascot-fox-menubar@2x.png" "$APP/Contents/Resources/"
# 7단계 캐릭터 포즈 SVG(대기·달리기·성공·실패·갸웃). 앱이 읽어 WKWebView 페이지에 넣는다(CharacterWindow.swift).
# 하나라도 없으면 cp가 실패해 빌드가 멈춘다(set -e). 빠진 채로 번들을 만들면 그 포즈에서 캐릭터가 사라지는데
# 앱을 실행해 그 상태가 되기 전에는 알 수 없다.
for name in mascot-fox mascot-fox-animated mascot-fox-success mascot-fox-error mascot-fox-attention; do
  cp "$REPO/assets/$name.svg" "$APP/Contents/Resources/"
done
codesign --force --sign - "$APP"
echo "built: $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|flags" || true
echo "실행: open \"$APP\""
