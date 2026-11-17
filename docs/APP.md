# macOS 메뉴 막대 앱 (3~4단계)

상태: 3단계 **완료**(로직은 자동 테스트로, 메뉴 표시·폴더 선택 창·환경 추가 동선은 사용자가 직접 확인, 2026-11-17).
4단계(pytest 실행과 결과 연결)는 **완료**(로직은 자동 테스트로, 실행·실행 중 메뉴 갱신·중지·결과 문구는 사용자가 직접 확인, 2026-11-17). 플러그인 없는 환경에서 실행 버튼이 꺼지는 것도 확인했다.

## 구조

- `app/Package.swift`: SwiftPM 패키지.
- `app/Sources/PMHCore`: 등록 저장, 환경 검사, 결과 해석, pytest 실행·이벤트 읽기·정리(테스트 대상, AppKit 없음).
- `app/Sources/PMHApp`: AppKit UI만(메뉴 막대 아이콘, 메뉴, 폴더·파일 선택 창).
- `app/Sources/pmh-check`: 같은 PMHCore로 환경을 검사해 출력하는 개발용 명령줄 도구.
- `app/Sources/pmh-run`: 같은 PMHCore의 실행 로직(`RunController`)을 화면 없이 돌려 보는 개발용 명령줄 도구(통합 검증용).
- `app/Tests/PMHCoreTests`: swift-testing 단위 테스트(51개).

## 빌드·실행

```sh
app/build.sh                      # ~/.pmh-build/PytestMenuHelper.app (ad-hoc 서명)
open ~/.pmh-build/PytestMenuHelper.app
app/test.sh                       # Swift 테스트 (아래 도구 문제 우회 포함)
```

- 산출물과 SwiftPM 중간물은 저장소 밖 `~/.pmh-build/`에만 만든다. 실행은 `open`으로 한다(`docs/NOTIFICATION_BUNDLE.md`).
- Bundle ID `dev.yohwan.pytest-menu-helper`, `LSUIElement=true`(Dock 아이콘 없음). 종료는 메뉴의 "종료".
- 메뉴 아이콘은 `assets/mascot-fox-menubar.svg`를 번들에 복사해 `NSImage`로 읽는다(원본은 수정하지 않음). 읽지 못하면 기본 기호로 대체한다.
- 빌드 때 이 저장소 경로를 `Info.plist`(`PMHRepoPath`)에 기록해 플러그인 설치 명령에 쓴다.
- **알려진 도구 문제:** Command Line Tools만 있으면 swift-testing 매크로 플러그인이 `.../swift/host/plugins/testing/`에 있어 컴파일러가 못 찾을 때가 있다. 소스를 바꾼 뒤 `swift test`가 `plugin for module 'TestingMacros' not found`로 실패한다. `app/test.sh`는 `-Xswiftc -plugin-path`로 그 폴더를 넘겨 이 문제를 피한다(재컴파일 3회 연속 통과 확인). 직접 `swift test`를 쓰면 실패할 수 있다. 테스트 파일에 POSIX `write`와 겹치는 전역 함수 이름(`write`)을 쓰면 같은 오류가 반복되므로 쓰지 않는다.
- 이 Mac은 Command Line Tools만 있어 **XCTest가 없다.** 그래서 테스트는 swift-testing(`import Testing`)으로 작성했고 `swift test`로 실행된다.

## 메뉴

맨 위 "프로젝트 추가..."(폴더 선택), 프로젝트별 하위 메뉴, "종료". 별도 설정 창은 없다.
프로젝트 하위 메뉴: 경로, 환경 목록(이름 · Python 버전 · 상태), "환경 추가...", "환경 다시 검사", "프로젝트 제거".
환경 항목을 열면 pytest·FastAPI·플러그인 상태, 문제와 "설치 명령 복사", "이 환경 다시 검사", "환경 제거"가 있다.
프로젝트 상태는 환경 중 가장 나쁜 상태이고, 환경이 없으면 "조치 필요", 검사 중이면 "검사 중"이다.

## 등록 파일

`~/Library/Application Support/pytest-menu-helper/projects.json`. 앱이 홈에 쓰는 것은 이 파일과 4단계의 `logs/<run_id>.log`뿐이다(`events/`는 플러그인이 쓴다).
`{version, projects:[{id(UUID), path, environments:[{id, name, python_path}]}]}`. 환경 `id`는 앱이 만들며 실행 때 `PMH_ENV_ID`로 넘길 값이다.
읽기 실패·깨진 파일이면 앱은 죽지 않고 메뉴 맨 위에 안내를 띄우고 빈 목록으로 시작한다. 깨진 파일은 `projects.json.broken`으로 옮겨 보존한다.

## 환경 검사

선택한 Python으로 작은 스크립트를 **1번** 실행한다: `python -I -c <스크립트>`, 작업 폴더 `/`, 10초 제한, 백그라운드 큐에서 실행(메인 스레드를 막지 않음).
스크립트는 `importlib.metadata`로 설치 정보만 읽는다: Python 버전, pytest·FastAPI 버전, `pytest11` entry point `pytest_menu_helper.plugin` 설치 여부, 플러그인(`pytest-menu-helper`) 버전.
플러그인 버전이 0.2.0 미만이거나 읽을 수 없으면 "플러그인 업데이트가 필요합니다"(조치 필요)로 구분하고 실행 버튼을 끈다. 조치 명령은 설치 때와 같은 `uv pip install --python <경로> -e <저장소>`이며 복사만 제공한다. 편집 가능(`-e`) 설치는 설치 시점의 버전이 메타데이터에 남으므로 저장소를 업데이트한 뒤 이 명령을 다시 실행해야 새 버전으로 보인다.
**pytest를 실행하지 않고 프로젝트 코드를 import하지 않는다.** 프로젝트 폴더는 `.venv/bin/python` 존재 확인(후보 제안)에만 쓴다. 테스트로 확인한다(`NoTestExecutionTests`).

| 상태 | 조건 |
|---|---|
| 오류 | 경로 없음, 실행 불가(권한·폴더·종료 코드≠0·10초 초과·출력 해석 실패), Python 3.9 미만, pytest 누락 |
| 조치 필요 | 플러그인 미설치, **플러그인 구버전(0.2.0 미만, `PMH_RUN_ID` 미지원)**, FastAPI 누락(경고) |
| 준비됨 | 위 문제 없음 |

앱은 환경을 변경하지 않는다. 조치는 명령을 보여 주고 클립보드 복사만 한다. 예: `uv pip install --python <경로> -e <이 저장소 경로>`.
Python 후보: `<프로젝트>/.venv/bin/python`, `~/.venvs/*/bin/python`, 그 밖에는 파일 선택 창("다른 파일 선택...").

## 4단계: pytest 실행과 결과 연결

환경 하위 메뉴에 실행 영역이 있다: "pytest 실행"(실행 중에는 진행 줄 "실행 중 12/40"과 "중지"로 바뀜), "마지막 결과: 실패 · 통과 1 · 실패 1" 줄.
플러그인 미설치·구버전, 환경 오류, 환경 검사 중이면 실행 버튼을 끄고 "실행 불가: <이유>"를 보여 준다. FastAPI 누락(경고)만으로는 막지 않는다.
환경 항목 제목에도 실행 중 상태가 붙는다. 결과 목록·상세는 5단계라 만들지 않았다.

### 실행 방식

- 앱이 UUID(소문자)를 만들어 `PMH_RUN_ID`로 넘기고, 선택한 환경의 `<python> -m pytest`를 **프로젝트 폴더를 작업 폴더로** 실행한다. 앱이 실행하는 것은 등록한 환경의 pytest와 그 환경의 집계 호출뿐이다.
- 자식 환경변수: 앱 프로세스의 환경을 그대로 쓰되 `PYTEST_DISABLE_PLUGIN_AUTOLOAD`, `PYTEST_MENU_DISABLE`은 제거하고 `PMH_ENV_ID`(환경 id), `PMH_RUN_ID`, `PYTEST_MENU_EVENTS_DIR`(앱이 읽는 이벤트 폴더)를 넣는다. 플러그인은 `PMH_ENV_ID`·`PMH_RUN_ID`를 읽은 뒤 지워서 테스트 안에서 다시 실행한 pytest가 물려받지 않게 한다.
- **주의: 앱 프로세스의 환경은 터미널 환경과 다르다.** `open`으로 띄운 앱은 셸 설정(`.zshrc`의 변수, PATH)을 받지 않고 가상환경도 활성화되지 않는다. 환경변수나 PATH의 외부 명령에 의존하는 테스트는 앱에서만 실패할 수 있다.
- pytest 출력(표준 출력·오류)은 파이프가 아니라 `~/Library/Application Support/pytest-menu-helper/logs/<run_id>.log`(0600) 파일로 보낸다. 읽는 쪽이 없어도 자식이 멈추지 않는다.
- 이벤트는 `events/<run_id>.jsonl`을 0.25초마다 읽는다(상세는 `docs/EVENTS.md`). FSEvents는 6단계 몫이라 쓰지 않는다.
- 스레드: Process 실행, 파일 읽기, 집계 호출은 `RunController`의 백그라운드 큐에서 하고 메뉴 갱신만 메인 스레드에서 한다. 진행 숫자만 바뀔 때는 열려 있는 메뉴의 줄만 고쳐 쓴다.

### 상태와 결과

| 상황 | 표시 |
|---|---|
| 프로세스는 살아 있고 이벤트 파일이 아직 없음 | 수집 대기(실패 아님) |
| 실행 중 | 실행 중 12/40 (끝난 테스트 / 수집된 전체) |
| 종료 이벤트 있음 + 집계 성공 | 집계기의 판정: 성공 / 실패 / 확인 필요 / 테스트 없음 / 수집 오류 / 중단됨 + 건수 |
| 프로세스 종료 + 종료 이벤트 없음 | 미완료 · 종료 코드 N 또는 시그널 N(KILL) (중지로 끝났으면 "중지함") |
| 프로세스 종료 + 이벤트 0건 | 수집 실패 · 종료 코드 + 로그 마지막 줄 |
| 집계 호출 실패 | 집계 오류(구버전 플러그인 등, 판정으로 보지 않음) |
| 다른 run_id 이벤트가 섞임 | 집계 오류 · 다른 실행 이벤트 N건 섞임 |
| 시작 실패(폴더 없음 등) | 실행 오류 |

판정 규칙은 Swift에 옮기지 않았다. 최종 판정은 프로세스 종료 후 `python -I -m pytest_menu_helper.aggregate <이벤트 파일>`을 1번 호출해 받은 JSON을 그대로 쓴다.

### 중복 실행·중지·정리

- 앱 전체에서 실행 1개만 허용한다. 시작 요청은 잠금 안에서 확인하므로 연달아 눌러도 1건만 시작된다. 실행 중에는 모든 환경의 실행 버튼이 꺼진다.
- 중지: SIGINT를 보내고(pytest가 중단 이벤트와 종료 이벤트를 남김) 5초 안에 끝나지 않으면 SIGKILL로 강제 종료한다. 강제 종료된 실행은 종료 이벤트가 없어 "미완료"로 남는다. 앱을 종료하면 실행 중인 pytest에 SIGINT를 보낸다(최선의 시도).
- 정리: 앱 시작 때와 실행 종료 때 `events/<uuid>.jsonl`, `logs/<uuid>.log`를 최신 50개씩만 남긴다. 다른 파일·폴더·심볼릭 링크·`--menu-events`로 만든 파일은 건드리지 않는다.

### 개발용 통합 검증(`pmh-run`)

```sh
swift build --scratch-path ~/.pmh-build/swiftpm --package-path app --product pmh-run
BIN=$(swift build --scratch-path ~/.pmh-build/swiftpm --package-path app --show-bin-path)/pmh-run
$BIN ~/.venvs/pmh-3.13/bin/python examples/fastapi_demo --data-dir ~/.pmh-build/it/data   # 실패 · 통과 1 · 실패 1
$BIN <python> ~/.pmh-build/slow-sample --data-dir ~/.pmh-build/it/data --stop-after 4      # 중지(중단됨)
```

### 사용자 확인 필요(화면 동작)

자동으로 확인하지 못한 항목이다. 1~6번 모두 사용자가 확인했다(2026-11-17, 1~5번은 메뉴 갱신 수정 후 느린 샘플로, 6번은 `pmh-noplugin` 화면으로). 느린 샘플 프로젝트: `~/.pmh-build/slow-sample/`(저장소 밖, 테스트 5개, 약 10초).
1. 환경 하위 메뉴의 "pytest 실행"이 보이고 누르면 실행되는가.
2. 실행 중 메뉴를 열었을 때 앱이 멈추지 않고 반응하는가(느린 샘플 사용). 진행 줄이 "수집 대기" → "실행 중 n/5"로 바뀌는가.
3. 실행 중 모든 환경의 "pytest 실행"이 꺼져 있는가.
4. "중지"를 누르면 "중지하는 중…" 뒤에 "마지막 결과: 중단됨 …"이 나오는가.
5. 끝난 뒤 "마지막 결과: 성공 · 통과 5 · 실패 0"(느린 샘플) 또는 "실패 · 통과 1 · 실패 1"(`examples/fastapi_demo`)이 보이는가.
6. 플러그인이 없는 환경(`pmh-noplugin`)에서 실행 버튼이 꺼지고 이유가 보이는가.

## 알려진 제한

- 메뉴 표시·선택 창 동작은 자동화하지 못했다(사용자 확인 필요).
- ad-hoc 서명이라 다른 Mac 배포·알림 권한 유지는 미확인(`docs/NOTIFICATION_BUNDLE.md`).
- 열려 있는 메뉴도 실행 상태(진행 줄, 종료, 중지, 마지막 결과)를 그 자리에서 갱신한다. 메뉴 전체를 바꿔 끼우면 열린 메뉴에는 보이지 않기 때문에, 환경 하위 메뉴의 내용만 다시 채운다. 상태 알림은 메인 런루프의 common 모드로 넘겨 메뉴가 열린 동안에도 처리한다. 프로젝트·환경 추가·제거나 검사 결과처럼 메뉴 구조가 바뀌는 변화는 메뉴를 닫을 때 반영한다(2026-11-17 수정, 느린 샘플로 사용자 확인).
- 한 번에 실행 1건만 가능하다. 여러 환경 동시 실행은 9단계.
- 앱이 강제 종료되면 이미 시작한 pytest는 남을 수 있다(정상 종료 때만 SIGINT를 보낸다).
- 앱 시작 때와 환경 추가·다시 검사 때만 검사한다. 이후 환경이 바뀌어도 자동 감지하지 않는다.
- 잘못된 경로도 등록은 되고 "오류"로 표시된다(제거 가능).
- 검사 도중 앱을 종료하면 검사 프로세스는 10초 제한으로 끝난다.
- 같은 프로젝트에 같은 Python 경로는 한 번만 등록된다. 여러 환경 동시 실행은 9단계.
