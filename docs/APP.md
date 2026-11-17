# macOS 메뉴 막대 앱 (3단계)

상태: **완료.** 로직은 자동 테스트로, 메뉴 표시·폴더 선택 창·환경 추가 동선은 사용자가 직접 확인했다(2026-11-17).

## 구조

- `app/Package.swift`: SwiftPM 패키지.
- `app/Sources/PMHCore`: 등록 저장, 환경 검사, 결과 해석(테스트 대상, AppKit 없음).
- `app/Sources/PMHApp`: AppKit UI만(메뉴 막대 아이콘, 메뉴, 폴더·파일 선택 창).
- `app/Sources/pmh-check`: 같은 PMHCore로 환경을 검사해 출력하는 개발용 명령줄 도구.
- `app/Tests/PMHCoreTests`: swift-testing 단위 테스트(27개).

## 빌드·실행

```sh
app/build.sh                      # ~/.pmh-build/PytestMenuHelper.app (ad-hoc 서명)
open ~/.pmh-build/PytestMenuHelper.app
swift test --scratch-path ~/.pmh-build/swiftpm --package-path app
```

- 산출물과 SwiftPM 중간물은 저장소 밖 `~/.pmh-build/`에만 만든다. 실행은 `open`으로 한다(`docs/NOTIFICATION_BUNDLE.md`).
- Bundle ID `dev.yohwan.pytest-menu-helper`, `LSUIElement=true`(Dock 아이콘 없음). 종료는 메뉴의 "종료".
- 메뉴 아이콘은 `assets/mascot-fox-menubar.svg`를 번들에 복사해 `NSImage`로 읽는다(원본은 수정하지 않음). 읽지 못하면 기본 기호로 대체한다.
- 빌드 때 이 저장소 경로를 `Info.plist`(`PMHRepoPath`)에 기록해 플러그인 설치 명령에 쓴다.
- 이 Mac은 Command Line Tools만 있어 **XCTest가 없다.** 그래서 테스트는 swift-testing(`import Testing`)으로 작성했고 `swift test`로 실행된다.

## 메뉴

맨 위 "프로젝트 추가..."(폴더 선택), 프로젝트별 하위 메뉴, "종료". 별도 설정 창은 없다.
프로젝트 하위 메뉴: 경로, 환경 목록(이름 · Python 버전 · 상태), "환경 추가...", "환경 다시 검사", "프로젝트 제거".
환경 항목을 열면 pytest·FastAPI·플러그인 상태, 문제와 "설치 명령 복사", "이 환경 다시 검사", "환경 제거"가 있다.
프로젝트 상태는 환경 중 가장 나쁜 상태이고, 환경이 없으면 "조치 필요", 검사 중이면 "검사 중"이다.

## 등록 파일

`~/Library/Application Support/pytest-menu-helper/projects.json` (앱이 홈에 쓰는 유일한 파일).
`{version, projects:[{id(UUID), path, environments:[{id, name, python_path}]}]}`. 환경 `id`는 앱이 만들며 실행 때 `PMH_ENV_ID`로 넘길 값이다.
읽기 실패·깨진 파일이면 앱은 죽지 않고 메뉴 맨 위에 안내를 띄우고 빈 목록으로 시작한다. 깨진 파일은 `projects.json.broken`으로 옮겨 보존한다.

## 환경 검사

선택한 Python으로 작은 스크립트를 **1번** 실행한다: `python -I -c <스크립트>`, 작업 폴더 `/`, 10초 제한, 백그라운드 큐에서 실행(메인 스레드를 막지 않음).
스크립트는 `importlib.metadata`로 설치 정보만 읽는다: Python 버전, pytest·FastAPI 버전, `pytest11` entry point `pytest_menu_helper.plugin` 설치 여부.
**pytest를 실행하지 않고 프로젝트 코드를 import하지 않는다.** 프로젝트 폴더는 `.venv/bin/python` 존재 확인(후보 제안)에만 쓴다. 테스트로 확인한다(`NoTestExecutionTests`).

| 상태 | 조건 |
|---|---|
| 오류 | 경로 없음, 실행 불가(권한·폴더·종료 코드≠0·10초 초과·출력 해석 실패), Python 3.9 미만, pytest 누락 |
| 조치 필요 | 플러그인 미설치, FastAPI 누락(경고) |
| 준비됨 | 위 문제 없음 |

앱은 환경을 변경하지 않는다. 조치는 명령을 보여 주고 클립보드 복사만 한다. 예: `uv pip install --python <경로> -e <이 저장소 경로>`.
Python 후보: `<프로젝트>/.venv/bin/python`, `~/.venvs/*/bin/python`, 그 밖에는 파일 선택 창("다른 파일 선택...").

## 알려진 제한

- 메뉴 표시·선택 창 동작은 자동화하지 못했다(사용자 확인 필요).
- ad-hoc 서명이라 다른 Mac 배포·알림 권한 유지는 미확인(`docs/NOTIFICATION_BUNDLE.md`).
- 앱 시작 때와 환경 추가·다시 검사 때만 검사한다. 이후 환경이 바뀌어도 자동 감지하지 않는다.
- 잘못된 경로도 등록은 되고 "오류"로 표시된다(제거 가능).
- 검사 도중 앱을 종료하면 검사 프로세스는 10초 제한으로 끝난다.
- 같은 프로젝트에 같은 Python 경로는 한 번만 등록된다. 여러 환경 동시 실행은 9단계.
