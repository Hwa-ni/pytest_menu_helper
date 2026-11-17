#!/bin/sh
# 앱 패키지(app/)의 Swift 단위 테스트를 실행한다.
# 입력: 추가 인자는 그대로 swift test에 넘긴다(예: --filter RunTests).
# 출력: swift test의 결과. 실패하면 0이 아닌 종료 코드를 돌려준다.
set -eu

# 저장소 루트를 스크립트 위치 기준으로 구한다. 어느 폴더에서 실행해도 같은 경로를 쓰기 위함이다.
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Command Line Tools만 설치된 Mac에서는 swift-testing의 매크로 플러그인이
# plugins/testing/ 하위 폴더에 있어 컴파일러가 찾지 못할 때가 있다.
# 소스를 바꾼 뒤 다시 컴파일하면 "plugin for module 'TestingMacros' not found"로 빌드가 실패한다.
# 경로를 직접 알려 주면 매번 통과한다. Xcode가 설치된 환경이면 이 폴더가 없을 수 있어 있을 때만 넘긴다.
PLUGIN_DIR=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [ -d "$PLUGIN_DIR" ]; then
  set -- -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" "$@"
fi

# 중간 산출물은 저장소 밖에 둔다. 기본 경로로 실행하면 app/.build가 저장소 안에 생긴다.
exec swift test --scratch-path "$HOME/.pmh-build/swiftpm" --package-path "$ROOT/app" "$@"
