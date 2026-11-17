# macOS 메뉴 막대 앱 (3~8단계)

상태: 3단계 **완료**(로직은 자동 테스트로, 메뉴 표시·폴더 선택 창·환경 추가 동선은 사용자가 직접 확인, 2026-11-17).
4단계(pytest 실행과 결과 연결)는 **완료**(로직은 자동 테스트로, 실행·실행 중 메뉴 갱신·중지·결과 문구는 사용자가 직접 확인, 2026-11-17). 플러그인 없는 환경에서 실행 버튼이 꺼지는 것도 확인했다.
5단계(결과 팝오버와 실패 상세)는 **완료**(자동 검증과 사용자 화면 확인, 2026-11-17, 아래 "5단계" 절).
그 뒤 메뉴(오른쪽 클릭·⚙)의 모든 동작을 팝오버 안으로 옮겼다(2026-11-17, 화면 사용자 확인, 아래 "팝오버 관리 동작" 절). 오른쪽 클릭 메뉴에는 "종료"만 남았다.
6단계(다른 터미널의 pytest 실행 감지)는 구현과 자동·통합 검증을 마쳤고 Terminal.app 화면은 사용자가 확인해 **완료**했다(2026-11-17, 아래 "6단계" 절).
7단계(캐릭터와 애니메이션)는 구현과 자동·통합 검증을 마쳤고 화면은 사용자가 확인해 **완료**했다(2026-11-17, 아래 "7단계" 절, 설계는 `docs/CHARACTER.md`).
8단계(완료 알림과 데모 정리)는 구현과 자동·통합 검증(알림 거부 상태)을 마쳤고 **화면 확인 대기**다(2026-11-17, 아래 "8단계" 절, 설계는 `docs/STEP8_DESIGN.md`).

## 구조

- `app/Package.swift`: SwiftPM 패키지.
- `app/Sources/PMHCore`: 등록 저장, 환경 검사, 결과 해석, pytest 실행·이벤트 읽기·정리(테스트 대상, AppKit 없음).
- `app/Sources/PMHApp`: 화면만(메뉴 막대 아이콘, 종료 메뉴, 폴더·파일 선택 창, 팝오버). 팝오버 내용은 SwiftUI(`PopoverView.swift`)를 `NSHostingController`로 `NSPopover`에 넣는다.
- `app/Sources/pmh-check`: 같은 PMHCore로 환경을 검사해 출력하는 개발용 명령줄 도구.
- `app/Sources/pmh-run`: 같은 PMHCore의 실행 로직(`RunController`)을 화면 없이 돌려 보는 개발용 명령줄 도구(통합 검증용).
- `app/Sources/PMHCore/ExternalRuns.swift`: 다른 터미널 실행 감시기(`ExternalRunWatcher`), 매칭·생존 확인·집계 호출(6단계).
- `app/Sources/PMHCore/CharacterPresentation.swift`: 상태→캐릭터 포즈 결정, 창 위치 규칙, 캐릭터 HTML 페이지(7단계, 순수 코드).
- `app/Sources/PMHApp/CharacterWindow.swift`: 캐릭터 창(투명 `NSPanel` + WKWebView), 클릭·끌기, 위치 기억(7단계).
- `app/Sources/PMHCore/NotificationPresentation.swift`: 완료 알림을 보낼지, 제목·본문·identifier, 권한 안내 문장(8단계, 순수 코드).
- `app/Sources/PMHApp/Notifier.swift`: `UNUserNotificationCenter` 감싸기. 권한 읽기·요청, 보내기, 보낸 실행 ID 집합, 알림 클릭(8단계).
- `app/Tests/PMHCoreTests`: swift-testing 단위 테스트(178개).

## 빌드·실행

```sh
app/build.sh                      # ~/.pmh-build/PytestMenuHelper.app (ad-hoc 서명)
open ~/.pmh-build/PytestMenuHelper.app
app/test.sh                       # Swift 테스트 (아래 도구 문제 우회 포함)
```

- 산출물과 SwiftPM 중간물은 저장소 밖 `~/.pmh-build/`에만 만든다. 실행은 `open`으로 한다(`docs/NOTIFICATION_BUNDLE.md`).
- Bundle ID `dev.yohwan.pytest-menu-helper`, `LSUIElement=true`(Dock 아이콘 없음). 종료는 팝오버 맨 아래 [종료] 또는 아이콘 오른쪽 클릭의 "종료".
- 메뉴 아이콘은 `assets/mascot-fox-menubar.svg`를 번들에 복사해 `NSImage`로 읽는다(원본은 수정하지 않음). 읽지 못하면 기본 기호로 대체한다.
- 캐릭터 포즈 SVG 다섯 개(`mascot-fox`, `-animated`, `-success`, `-error`, `-attention`)도 번들 `Resources/`에 복사한다. 하나라도 없으면 빌드가 멈춘다.
- 빌드 때 이 저장소 경로를 `Info.plist`(`PMHRepoPath`)에 기록해 플러그인 설치 명령에 쓴다.
- **알려진 도구 문제:** Command Line Tools만 있으면 swift-testing 매크로 플러그인이 `.../swift/host/plugins/testing/`에 있어 컴파일러가 못 찾을 때가 있다. 소스를 바꾼 뒤 `swift test`가 `plugin for module 'TestingMacros' not found`로 실패한다. `app/test.sh`는 `-Xswiftc -plugin-path`로 그 폴더를 넘겨 이 문제를 피한다(재컴파일 3회 연속 통과 확인). 직접 `swift test`를 쓰면 실패할 수 있다. 테스트 파일에 POSIX `write`와 겹치는 전역 함수 이름(`write`)을 쓰면 같은 오류가 반복되므로 쓰지 않는다.
- 이 Mac은 Command Line Tools만 있어 **XCTest가 없다.** 그래서 테스트는 swift-testing(`import Testing`)으로 작성했고 `swift test`로 실행된다.

## 팝오버 관리 동작

앱의 모든 동작은 아이콘 **왼쪽 클릭**으로 여는 팝오버 안에 있다. 별도 설정 창은 없다.
**오른쪽 클릭**(또는 control+클릭)은 "종료" 하나만 있는 작은 메뉴다(⌘Q 단축키 표시). 예전의 큰 메뉴와 ⚙ 버튼은 없앴다. 같은 기능을 메뉴와 팝오버 두 곳에서 관리하지 않기 위해서다.

| 동작 | 팝오버 위치 |
|---|---|
| 프로젝트 추가(폴더 선택) | 머리의 "+ 프로젝트". 프로젝트가 하나도 없으면 가운데 큰 "프로젝트 추가" 버튼 |
| 프로젝트 고르기 | 머리의 Picker(프로젝트가 2개 이상일 때), 아래 작은 글씨로 폴더 경로 |
| 환경 전체 다시 검사, 프로젝트 제거 | 머리 오른쪽 "⋯" |
| 환경 추가 | 환경 목록 아래 "+ 환경 추가"(인라인 폼) |
| 이 환경 다시 검사, 환경 제거 | 환경 행 오른쪽 "⋯" |
| 문제와 설치 명령 복사 | 조치 필요·오류인 환경 행 아래 문제 문장, 명령, [명령 복사] |
| 환경 정보(Python 경로, Python·pytest·FastAPI·플러그인 버전) | 행을 고르면 상세 맨 위 |
| 종료 | 맨 아래 [종료], 오른쪽 클릭 메뉴 |
| 등록 파일 읽기 경고, 저장 실패 | 팝오버 맨 위 주황 문장 |

- **환경 추가 폼:** 후보 Python 목록(`<프로젝트>/.venv/bin/python`, `~/.venvs/*/bin/python`, 이미 등록한 경로는 뺌, 첫 후보가 기본), 이름 칸, "다른 파일 선택..."(숨김 파일 보이기, 기본 폴더 `~/.venvs`), [취소][추가]. 이름은 고른 Python에서 자동으로 정한다(`<이름>/bin/python`이면 `<이름>`). 사용자가 고친 이름은 Python을 바꿔도 유지한다. 이름을 비우고 추가하면 자동 이름을 쓴다. 이미 등록한 경로나 Python 없이 누른 [추가]는 폼 아래에 이유를 보인다. 추가하면 폼이 닫히고 새 환경이 선택되며 검사가 시작된다. 이름 칸에서 Return을 눌러도 추가된다.
- **프로젝트 추가 뒤:** 폴더를 고르면 그 프로젝트로 바뀌고 환경 추가 폼이 바로 열린다. 이미 등록한 폴더면 새로 등록하지 않고 그 프로젝트의 폼만 연다.
- **제거 확인:** "⋯ > 프로젝트 제거..." 또는 "환경 제거..."를 고르면 팝오버 안(프로젝트는 머리 아래, 환경은 그 행 바로 아래)에 "정말 제거할까요? 등록 정보만 지우고 폴더·환경은 그대로 둡니다. [취소][제거]"가 뜬다. 확인 창(NSAlert)을 쓰지 않는다.
- **실행 중 제거 막기:** 실행 중인 환경의 "환경 제거"와 그 환경이 속한 프로젝트의 "프로젝트 제거"는 꺼지고, 같은 "⋯" 메뉴 안에 "실행 중에는 제거할 수 없습니다. 먼저 중지하세요."가 보인다. 확인 상자가 떠 있는 동안 실행이 시작되면 [제거]가 꺼지고 같은 이유가 보인다. 동작 함수(`removeProject`·`removeEnvironment`)도 컨트롤러의 현재 상태로 한 번 더 막는다(화면 갱신 전에 눌린 경우).
- **선택 창과 팝오버:** 팝오버는 `.transient`라 선택 창(NSOpenPanel)이 뜨면 닫힌다. 그래서 창을 띄우기 전에 팝오버를 닫고, 창이 끝나면(확인·취소 모두) 팝오버를 자동으로 다시 연다(`AppDelegate.runPanelOutsidePopover`). 다시 열 때는 선택한 프로젝트와 열려 있던 폼·입력값을 그대로 둔다(화면 상태가 뷰 모델에 있다). 창이 떠 있는 동안 behavior를 바꿔 팝오버를 열어 두는 방법은 쓰지 않았다. 상태 막대 팝오버 창이 선택 창보다 높은 층에 떠 가리거나 바깥 클릭에 엉뚱하게 반응할 수 있어서다. 아이콘을 눌러 새로 열 때는 선택·폼·확인 상자를 처음 상태로 돌린다.
- **높이:** 머리와 [종료] 사이를 스크롤 영역으로 두고, 최대 높이를 화면 높이(메뉴 막대·Dock 제외) − 160pt(최소 240pt)로 잡는다. 내용이 적으면 내용 높이만큼만 차지한다.
- **갱신:** 실행 상태는 예전처럼 common 모드 `CFRunLoopPerformBlock`으로 메인에 와서 열린 팝오버를 바로 고친다. 검사 결과(`checkAsync` 완료는 메인 큐, common 모드에서 처리)와 등록 변경도 같은 `pushPopoverState`로 열린 팝오버에 바로 반영된다. 팝오버 안 "⋯" 메뉴가 열려 있어도 처리된다.
- 프로젝트 상태 요약(`ProjectSummary`)은 메뉴 제목에만 쓰던 값이라 지금 화면에는 보이지 않는다. 환경별 상태는 각 행에 있다.
- 순수 로직(폼 자동 이름 규칙과 제출 판정, 제거 가능 여부와 이유, 확인 문구, 조치 줄, 환경 정보 줄, 스크롤 높이)은 PMHCore `ManagementPresentation.swift`에 두고 `ManagementTests`로 고정했다.

## 등록 파일

`~/Library/Application Support/pytest-menu-helper/projects.json`. 앱이 홈에 쓰는 것은 이 파일과 4단계의 `logs/<run_id>.log`뿐이다(`events/`는 플러그인이 쓴다).
`{version, projects:[{id(UUID), path, environments:[{id, name, python_path}]}]}`. 환경 `id`는 앱이 만들며 실행 때 `PMH_ENV_ID`로 넘길 값이다.
읽기 실패·깨진 파일이면 앱은 죽지 않고 팝오버 맨 위에 안내를 띄우고 빈 목록으로 시작한다. 깨진 파일은 `projects.json.broken`으로 옮겨 보존한다.

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

(아래 메뉴 설명은 4단계 당시의 기록이다. 지금 실행·중지·결과는 팝오버의 ▶/■와 상세에 있다.)

환경 하위 메뉴에 실행 영역이 있다: "pytest 실행"(실행 중에는 진행 줄 "실행 중 12/40"과 "중지"로 바뀜), "마지막 결과: 실패 · 통과 1 · 실패 1" 줄.
플러그인 미설치·구버전, 환경 오류, 환경 검사 중이면 실행 버튼을 끄고 "실행 불가: <이유>"를 보여 준다. FastAPI 누락(경고)만으로는 막지 않는다.
환경 항목 제목에도 실행 중 상태가 붙는다. 결과 목록·상세는 5단계 팝오버에 있다.

### 실행 방식

- 앱이 UUID(소문자)를 만들어 `PMH_RUN_ID`로 넘기고, 선택한 환경의 `<python> -m pytest`를 **프로젝트 폴더를 작업 폴더로** 실행한다. 앱이 실행하는 것은 등록한 환경의 pytest와 그 환경의 집계 호출뿐이다.
- 자식 환경변수: 앱 프로세스의 환경을 그대로 쓰되 `PYTEST_DISABLE_PLUGIN_AUTOLOAD`, `PYTEST_MENU_DISABLE`은 제거하고 `PMH_ENV_ID`(환경 id), `PMH_RUN_ID`, `PYTEST_MENU_EVENTS_DIR`(앱이 읽는 이벤트 폴더)를 넣는다. 플러그인은 `PMH_ENV_ID`·`PMH_RUN_ID`를 읽은 뒤 지워서 테스트 안에서 다시 실행한 pytest가 물려받지 않게 한다.
- **주의: 앱 프로세스의 환경은 터미널 환경과 다르다.** `open`으로 띄운 앱은 셸 설정(`.zshrc`의 변수, PATH)을 받지 않고 가상환경도 활성화되지 않는다. 환경변수나 PATH의 외부 명령에 의존하는 테스트는 앱에서만 실패할 수 있다.
- pytest 출력(표준 출력·오류)은 파이프가 아니라 `~/Library/Application Support/pytest-menu-helper/logs/<run_id>.log`(0600) 파일로 보낸다. 읽는 쪽이 없어도 자식이 멈추지 않는다.
- 이벤트는 `events/<run_id>.jsonl`을 0.25초마다 읽는다(상세는 `docs/EVENTS.md`). 6단계의 다른 터미널 감지도 FSEvents 대신 주기 읽기를 쓴다(이유는 `docs/EVENTS.md` "다른 터미널의 실행").
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
- 중지: SIGINT를 보내고(pytest가 중단 이벤트와 종료 이벤트를 남김) 5초 안에 끝나지 않으면 SIGKILL로 강제 종료한다. 강제 종료된 실행은 종료 이벤트가 없어 "미완료"로 남는다.
- 앱 종료: 앱이 끝나기 전에 실행 중인 pytest에 SIGINT를 바로 보내고 최대 2.5초 기다린 뒤, 남아 있으면 SIGKILL한다(`RunController.stopForTermination`). 메인 스레드를 막는 시간은 실행이 없으면 0, 있어도 약 3초 안이다(기다림 상한 5초 + SIGKILL 확인 0.5초). work 큐를 기다리지 않으므로 집계 호출 중이어도 막히지 않는다. 종료가 시작된 뒤에는 새 pytest를 띄우지 않는다. 예전에는 신호를 백그라운드 큐에 넘기기만 해서 신호가 나가기 전에 앱이 끝나 pytest가 남을 수 있었다(2026-11-17 수정).
- 제거 제한: 실행 중인 환경의 "환경 제거"와 그 환경이 속한 프로젝트의 "프로젝트 제거"는 꺼지고 "실행 중에는 제거할 수 없습니다. 먼저 중지하세요." 줄이 보인다. 실행이 끝나면 다시 켜진다(지금은 팝오버의 "⋯" 메뉴와 확인 상자, 위 "팝오버 관리 동작"). 예전에는 실행 중 제거하면 "중지" 버튼이 사라지고 그 실행이 끝날 때까지 다른 환경의 실행 버튼도 꺼진 채 남았다(2026-11-17 수정).
- 정리: 앱 시작 때와 실행 종료 때 `events/<uuid>.jsonl`, `logs/<uuid>.log`를 최신 50개씩만 남긴다. 다른 파일·폴더·심볼릭 링크·`--menu-events`로 만든 파일은 건드리지 않는다.

### 개발용 통합 검증(`pmh-run`)

```sh
swift build --scratch-path ~/.pmh-build/swiftpm --package-path app --product pmh-run
BIN=$(swift build --scratch-path ~/.pmh-build/swiftpm --package-path app --show-bin-path)/pmh-run
$BIN ~/.venvs/pmh-3.13/bin/python examples/fastapi_demo --data-dir ~/.pmh-build/it/data   # 실패 · 통과 1 · 실패 1
$BIN <python> examples/slow_demo --data-dir ~/.pmh-build/it/data --stop-after 4      # 중지(중단됨)
```

### 4단계 사용자 확인(화면 동작)

자동으로 확인하지 못한 항목이다. 1~6번 모두 사용자가 확인했다(2026-11-17, 1~5번은 메뉴 갱신 수정 후 느린 샘플로, 6번은 `pmh-noplugin` 화면으로). 느린 샘플 프로젝트: 당시 `~/.pmh-build/slow-sample/`(저장소 밖, 테스트 5개, 약 10초). 8단계에서 같은 테스트를 `examples/slow_demo/`로 옮겼다.
1. 환경 하위 메뉴의 "pytest 실행"이 보이고 누르면 실행되는가.
2. 실행 중 메뉴를 열었을 때 앱이 멈추지 않고 반응하는가(느린 샘플 사용). 진행 줄이 "수집 대기" → "실행 중 n/5"로 바뀌는가.
3. 실행 중 모든 환경의 "pytest 실행"이 꺼져 있는가.
4. "중지"를 누르면 "중지하는 중…" 뒤에 "마지막 결과: 중단됨 …"이 나오는가.
5. 끝난 뒤 "마지막 결과: 성공 · 통과 5 · 실패 0"(느린 샘플) 또는 "실패 · 통과 1 · 실패 1"(`examples/fastapi_demo`)이 보이는가.
6. 플러그인이 없는 환경(`pmh-noplugin`)에서 실행 버튼이 꺼지고 이유가 보이는가.

## 5단계: 결과 팝오버와 실패 상세

### 열기 방식

- 아이콘 **왼쪽 클릭**: `NSPopover`(`.transient`, 바깥을 누르면 닫힘)를 아이콘 아래에 연다. 열린 상태에서 아이콘을 다시 누르면 닫힌다.
- **오른쪽 클릭**, control+클릭: "종료"만 있는 메뉴(5단계 당시에는 4단계 메뉴와 ⚙ 버튼이었고, 지금은 모든 동작이 팝오버 안에 있다).
- `statusItem.menu`를 고정으로 걸면 왼쪽 클릭도 메뉴를 열기 때문에 걸지 않는다. 버튼 동작을 `sendAction(on: [.leftMouseUp, .rightMouseUp])`로 받아 나누고, 메뉴는 열 때만 잠깐 건 뒤 `performClick`으로 열고 바로 뗀다(`AppDelegate.showQuitMenu`).
- `.transient` 팝오버는 아이콘을 누르는 순간 먼저 닫히고, 손을 뗄 때 클릭 동작이 다시 열려고 한다. 닫힌 지 0.3초 안이면 다시 열지 않는다.

### 화면(위에서 아래)

1. 머리: 프로젝트 이름(여럿이면 Picker), "+ 프로젝트", "⋯"(위 "팝오버 관리 동작"). "전체 실행"은 9단계 몫이라 없다.
2. 환경 목록: 환경마다 상태 점, 이름·Python 버전, 진행 바와 done/total, 상태 문구(통과 / 실패 N / 실행 중 n/m / 수집 대기 / 미완료 / 실행 불가: 이유 / 환경 검사 중 / 실행 전), ▶ 또는 ■. 실패 N은 failed+error. 동시 실행은 앱 전체 1건이라 실행 중이면 다른 환경의 ▶가 꺼진다. 행을 누르면 그 환경이 선택된다. 팝오버를 열 때마다 기본 선택(실행 중인 환경, 없으면 첫 환경)으로 돌아간다. 환경이 5개 이상이면 목록만 스크롤한다(최대 260pt, 조치 줄이 붙어 행이 높아져 200pt에서 늘림).
3. 선택 환경 상세: 링 3개(진행 done/수집 수, 통과율 passed/수집 수, 소요 시간), 세부 건수 8개(통과·실패·오류·skip·xfail·xpass·미실행·미완료, 0은 흐리게), 안내 문장.
4. 실패한 테스트: 수집 오류, failed, error, incomplete 순서. 줄마다 nodeid, 상태, 파일:줄(실제 실패 위치 우선, 없으면 테스트 정의 위치, pytest rootdir 기준 상대 경로). 누르면 단계별 오류 메시지와 traceback(`failure.detail`)을 고정폭 글꼴로 펼친다. traceback 상자는 최대 220pt, 목록 전체는 최대 300pt에서 스크롤하고 텍스트를 선택·복사할 수 있다.
5. "환경별 차이" 절은 9단계 몫이라 없다. 화면 값은 환경 목록 구조라 다중 실행에도 그대로 쓴다.

### 데이터와 갱신

- 수집 수 = counts의 8개 항목 합(집계기는 수집 수를 따로 주지 않는다. tests와 not_run은 겹치지 않는다). 끝난 수 = 수집 수 − 미실행 − 미완료.
- 실행 중에는 진행률과 경과 시간(1초마다 다시 그림)만 보여 준다. 건수·실패 목록은 끝난 뒤 집계기 JSON으로 보여 준다(판정 규칙을 Swift에 옮기지 않는다).
- 소요 시간은 pytest 프로세스 시작부터 종료까지다. 집계 호출 시간은 뺀다(`RunSnapshot.elapsed`).
- `RunSummary`가 집계기 JSON의 `tests[]`(nodeid, occurrence, status, phases의 outcome·duration·location·failure), `not_run`, `collection_errors`, `project_root`도 디코드한다. 목록 필드가 없는 4단계 형식도 읽는다. 집계기 출력 형식은 바꾸지 않았다.
- 화면 로직은 PMHCore `ResultPresentation`·`ManagementPresentation`(순수 함수, 단위 테스트), 그리기는 PMHApp `PopoverView.swift`, 상태 연결은 `PopoverViewModel`(ObservableObject)이다. 실행 상태 알림은 common 모드 `CFRunLoopPerformBlock`으로 메인에 와서 팝오버를 고친다. 팝오버가 열린 채로도 바로 갱신된다.
- 색은 시스템 색과 `.secondary`만 쓴다(다크·라이트 대응). 폭 390pt, 높이는 내용에 맞춘다.
- **결과는 메모리에만 있다.** 앱을 다시 시작하면 팝오버의 결과가 사라진다(보존은 11단계).
- **도구 제약:** Command Line Tools에는 SwiftUI 매크로 플러그인(`SwiftUIMacros`)이 없어 `@State`가 컴파일되지 않는다. 화면 안 상태(펼친 실패 항목, 환경 추가 폼 입력값, 제거 확인)도 뷰 모델의 `@Published`에 둔다. `@Published`·`@ObservedObject`는 속성 래퍼라 문제없다.
- `pmh-run`은 팝오버와 같은 함수로 만든 화면 값을 `[화면 링]`, `[화면 건수]`, `[화면 실패]` 줄로 출력한다.

### 5단계 사용자 확인(화면 동작, 2026-11-17 사용자가 "잘 된다"고 확인)

1. 왼쪽 클릭으로 팝오버가 아이콘 아래에 열리고, 다시 누르거나 바깥을 누르면 닫히는가(닫자마자 다시 열리지 않는가).
2. 오른쪽 클릭(control+클릭)과 ⚙가 기존 메뉴를 여는가. 메뉴의 모든 기능(프로젝트·환경 추가, 검사, 설치 명령 복사, 제거, 종료)이 그대로인가. 메뉴를 닫은 뒤 왼쪽 클릭이 다시 팝오버를 여는가.
3. 팝오버를 연 채로 느린 샘플을 ▶로 실행하면 행의 진행 바·문구, 링, 경과 시간이 실시간으로 바뀌고, 끝나면 결과로 바뀌는가. ■로 중지하면 "중지하는 중…" 뒤 "중단됨"이 되는가.
4. 실행 중 다른 환경의 ▶가 꺼지고, 메뉴의 실행 중 제거 막기와 열린 메뉴 갱신이 예전처럼 동작하는가.
5. `examples/fastapi_demo` 실패 항목을 누르면 오류 메시지와 traceback이 펼쳐지고, 긴 traceback이 상자 안에서 스크롤되며 텍스트를 선택·복사할 수 있는가.
6. 프로젝트가 여럿이면 Picker로 바뀌고, 행을 누르면 상세가 그 환경으로 바뀌는가.
7. 다크 모드와 라이트 모드 모두에서 글자·링·점이 읽기 쉬운가.

## 6단계: 다른 터미널의 pytest 실행 감지

설계 결정과 이유, 감지되지 않는 조건은 `docs/EVENTS.md`의 "공통 설정 파일"과 "다른 터미널의 실행"에 있다. 여기에는 앱 쪽 동작과 검증만 적는다.

### 앱 동작

- 시작 때 `config.json`을 읽어 이벤트 폴더를 정하고(`AppPaths.resolve`), 그 폴더를 `ExternalRunWatcher`가 0.5초마다 읽는다(백그라운드 큐). 설정 파일을 쓸 수 없으면 팝오버 위 주황 문장으로 알리고 기본 폴더를 쓴다.
- 상태 알림은 앱 실행과 같은 직렬 큐를 거쳐 common 모드 `CFRunLoopPerformBlock` + `CFRunLoopWakeUp`으로 메인에 온다. 열린 팝오버도 바로 바뀐다.
- 매칭 대상(프로젝트 실제 경로, 환경 id·Python·검사 결과의 prefix)은 등록·검사 결과가 바뀔 때마다 감시기에 넘긴다. 환경 검사 스크립트가 `sys.prefix` 실제 경로를 함께 읽는다.
- 앱 실행 상태와 외부 실행 상태는 `RunSnapshot.merged(external:)`(순수 함수)로 합친다. 나중에 끝난 쪽이 마지막 결과다.
- 행·상세 문구(`ResultPresentation.row`/`detail`/`terminalNotice`, `ManagementPresentation.terminalDetectionNote`)는 단위 테스트로 고정했다. 상세 맨 아래에 "터미널 감지:" 문장으로 감지 조건과 끄는 조건(자동 로드 끔, `-p no:`, `PYTEST_MENU_DISABLE`)을 보여 준다. 플러그인이 없으면 "터미널 감지 불가"다.
- 플러그인 0.2.x 환경은 "조치 필요"(다른 터미널 실행을 정확히 감지하려면 0.3.0 이상)로 업데이트 명령을 보여 주지만 ▶는 막지 않는다.
- 외부 실행 사건(감시 시작, 연결, 제외 이유, 결과, 미등록 환경)과 그때의 행 문구(`[화면 행]`)를 시스템 로그에 남긴다. 보기: `/usr/bin/log show --last 5m --style compact --predicate 'subsystem == "dev.yohwan.pytest-menu-helper"'` (zsh에서는 `log`가 내장 명령이라 경로를 붙인다).

### 통합 검증(2026-11-17, 앱 pid와 별개 셸에서 실행)

등록된 프로젝트 `~/.pmh-build/slow-sample`(환경 pmh-3.13, pmh-3.12, pmh-noplugin)에서 앱을 켜 둔 채 실행하고 위 로그로 확인했다.

| 실행 | 결과 |
|---|---|
| `~/.venvs/pmh-3.13/bin/python -m pytest` | 연결(env=pmh-3.13, pid 기록) → `[화면 행] 터미널 실행 중 1/5`·`2/5`·`3/5` → `성공 · 통과 5 · 실패 0` → `통과 · 터미널` |
| `pmh-noplugin`으로 실행 | 이벤트 파일이 생기지 않음, 로그 없음 |
| `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1` (pmh-3.13) | 이벤트 파일 없음 |
| `-p no:pytest_menu_helper.plugin` | 이벤트 파일 없음 |
| `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 ... -p pytest_menu_helper.plugin` (pmh-3.12) | 연결 → `통과 · 터미널` |
| 등록하지 않은 `pmh-3.9`로 실행 | `등록하지 않은 환경의 실행 ... env=~/.venvs/pmh-3.9`, 결과는 연결하지 않음 |
| pmh-3.13 실행 5초 뒤 `kill -9` | `미완료 · 프로세스 종료됨(종료 코드 모름) · 2/5 끝남` → `미완료 · 터미널` |
| `config.json`에 `{"events_dir": "~/.pmh-build/it/shared-events"}`를 두고 앱 재시작 후 실행 | 감시 폴더가 그 폴더로 바뀌고 이벤트도 그 폴더에 써져 연결됨. 확인 뒤 파일을 지우고 앱을 다시 시작해 기본 폴더로 되돌림 |

자동 테스트: Swift 134개(`ExternalRunTests` 37개 추가), Python 43개(3.9·3.12·3.13, 공통 설정·새 필드·중첩 표시 6개 추가).

### 6단계 사용자 확인(Terminal.app, 화면)

결과(2026-11-17): 6항목 모두 확인했다. 1·2·3(Ctrl+C)·4·5·6은 사용자가 화면으로 봤다. 3의 kill -9와 4의 "기록 없음"은 별도 셸에서 실행하고 앱 로그로도 확인했다. 6에서 앱 ▶ 실행이 끝난 뒤 행이 "통과"로 바뀌는 것은 로그로 5/5 진행까지만 봤다.

전체 자동 테스트 재실행(2026-11-17, 커밋 db00ac6 기준): `app/test.sh` Swift 134개(26개 묶음) 통과. Python `tests/`는 `~/.venvs/pmh-3.9`·`pmh-3.12`·`pmh-3.13`에서 각각 43개 통과.

앱을 켜고 팝오버를 연 채로 확인한다. 느린 샘플: `examples/slow_demo`(테스트 5개, 약 10초. 6단계 확인 당시에는 같은 테스트가 `~/.pmh-build/slow-sample`에 있었다).

1. 새 Terminal.app 창에서 `cd examples/slow_demo && ~/.venvs/pmh-3.13/bin/python -m pytest`를 실행한다. pmh-3.13 행이 "터미널 실행 중 n/5"로 바뀌고 진행 바·링·경과 시간이 움직이며, 행에 ■ 없이 ▶가 켜져 있는가. 상세에 "다른 터미널에서 시작한 실행입니다(pid N)"가 보이는가.
2. 끝나면 행이 "통과 · 터미널", 상세가 "성공 · 통과 5 · 실패 0"과 "다른 터미널에서 실행한 결과입니다."로 바뀌고, 터미널 요약(5 passed)과 건수가 같은가.
3. 같은 명령을 돌리다 Ctrl+C를 누르면 "중단됨 · 터미널"이 되는가. 다른 창에서 `kill -9 <pid>`(상세에 보이는 pid)로 끊으면 "미완료 · 터미널"이 되는가(실패가 아님).
4. `~/.venvs/pmh-noplugin/bin/python -m pytest`와 `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 ~/.venvs/pmh-3.13/bin/python -m pytest`는 화면에 아무 변화가 없고, pmh-noplugin 상세 맨 아래에 "터미널 감지 불가", pmh-3.13 상세 맨 아래에 끄는 조건 문장이 보이는가.
5. `~/.venvs/pmh-3.9/bin/python -m pytest`(등록하지 않은 환경)를 실행하면 팝오버 위에 "등록하지 않은 Python 환경(~/.venvs/pmh-3.9)…" 안내 한 줄이 회색으로 보이는가.
6. 앱에서 ▶로 실행했을 때는 예전처럼 "실행 중 n/5"(터미널 표시 없음)로만 보이고 같은 실행이 두 번 보이지 않는가. 그 뒤 터미널에서 실행하면 나중에 끝난 쪽이 행의 결과가 되는가.

## 7단계: 캐릭터와 애니메이션

설계 결정과 이유, 상태→동작 대응표는 `docs/CHARACTER.md`에 있다. 여기에는 앱 쪽 동작과 검증만 적는다.

### 앱 동작

- 앱을 켜면 주 화면 오른쪽 아래(Dock 위, 가장자리에서 20pt)에 168×134pt 투명 창으로 여우가 뜬다. 끌어서 옮기면 위치를 기억한다(UserDefaults). 팝오버 맨 아래 [캐릭터 보이기]로 숨기거나 다시 보인다(기본은 보임, 설정 저장).
- 포즈: 대기(정지), 실행 중 달리기, 성공 점프 반복, 실패·수집 오류는 넘어진 옆모습, 별도 상태(테스트 없음·중단됨·미완료·확인 필요·수집 실패·집계 오류·실행 오류·상태 확인 불가)는 갸웃 포즈. 결과 포즈는 다음 실행까지 유지한다. 마우스를 올리면 "환경 · 상태" 도움말이 보인다.
- 상태 글씨: 모든 포즈의 캐릭터 아래에 팝오버 환경 행과 같은 문구가 보인다("실행 전", "실행 중 2/5", "터미널 실행 중 2/5", "통과", "실패 1 · 터미널", "중단됨" 등, 대응표는 `docs/CHARACTER.md`). 진행 글씨가 바뀌어도 애니메이션은 이어진다. 긴 글씨는 말줄임으로 창 안에서 자른다.
- 갱신 흐름: 기존 `runStateArrived`/`externalStateArrived`(common 모드 `CFRunLoopPerformBlock` + `CFRunLoopWakeUp`) → `pushPopoverState`에서 팝오버와 같은 합친 상태로 `CharacterPresentation.state`를 계산해 캐릭터에 넣는다. 열린 팝오버·메뉴가 있어도 캐릭터가 바뀐다.
- 캐릭터를 누르면 결과 팝오버가 캐릭터 위쪽에 열리고, 캐릭터가 따르던 환경이 선택돼 있다. 다시 누르거나 바깥을 누르면 닫힌다. 아이콘을 누르면 아이콘 아래로 옮겨 열린다.
- 포즈 전환은 시스템 로그 category `character`에 남는다: `/usr/bin/log show --last 5m --style compact --predicate 'subsystem == "dev.yohwan.pytest-menu-helper" AND category == "character"'`. 줄 형식 `[캐릭터] pose=… label=… env=… key=… help=…`. 창 표시(`frame`, `windowNumber`), 위치 저장, 클릭도 남는다.

### 통합 검증(2026-11-17, 앱과 별개 셸에서 실행)

`~/.pmh-build/slow-sample`(등록됨, 환경 pmh-3.13)과 `examples/fastapi_demo`(검증 동안만 pmh-3.13으로 임시 등록, 끝난 뒤 `projects.json`을 원래대로 되돌림)에서 `~/.venvs/pmh-3.13/bin/python -m pytest`를 실행하고 위 로그와 창 캡처로 확인했다.

| 실행 | 캐릭터 로그 |
|---|---|
| 앱 시작 | `pose=idle` → 창 표시 `{{1660, 114}, {120, 134}}` |
| slow-sample 전체 실행 | `pose=running help=pmh-3.13 · 터미널 실행 중 1/5`·`2/5`·`3/5`(같은 key라 다시 재생하지 않음) → `pose=success help=pmh-3.13 · 통과 · 터미널` |
| fastapi_demo(통과 1·실패 1) | `pose=failure help=pmh-3.13 · 실패 1 · 터미널`(다른 프로젝트 환경으로 따라감) |
| slow-sample 4초 뒤 SIGINT | `running` → `pose=attention label=중단됨`(pytest exit 2, 2 passed). 성공 포즈 아님 |
| slow-sample 4초 뒤 `kill -9` | `running` → `pose=attention label=미완료 help=… 미완료 · 터미널`. 성공·실패 포즈 아님 |
| `-k does_not_exist_xyz`(exit 5) | `pose=attention label=테스트 없음` |

창 캡처(`screencapture -o -l <windowNumber>`): `~/.pmh-build/it/character/`의 `idle.png`, `running.png`, `success.png`, `failure.png`, `interrupted.png`, `killed.png`, `notests.png`, 한 장으로 붙인 `all-poses.png`. 다섯 포즈와 상태 글씨가 투명 창에 그려지는 것을 확인했다(애니메이션 움직임 자체는 캡처로 확인할 수 없다).
주의: 비대화형 bash에서 `&`로 띄운 pytest는 SIGINT를 무시한다(작업 제어가 꺼져 있으면 백그라운드 작업의 SIGINT가 무시됨). 첫 시도는 그래서 끝까지 돌아 "통과"가 됐고, `bash -c 'set -m; …'`로 다시 해 중단됨을 확인했다. 앱 문제가 아니다.
앱 ▶ 실행은 화면 자동화가 없어 이번에 돌리지 못했다. 같은 합친 상태를 쓰는 것은 단위 테스트(`appRunIsRunning`, `latestStartedRunWins`)로 고정했고, 화면은 아래 확인 목록 2번으로 본다.

자동 테스트: Swift 158개(`CharacterTests` 24개 추가: 결과→포즈, 성공 아닌 모든 결과, 따를 상태 고르기, key, 위치 규칙, 페이지·스크립트). Python은 바꾸지 않았다.

#### 모든 포즈에 상태 글씨(2026-11-17 추가)

같은 방식(앱과 별개 셸, `bash` + `set -m`, `examples/fastapi_demo`는 검증 동안만 임시 등록 후 `projects.json` 복원)으로 다시 실행했다. 창이 168×134로 넓어졌다(`창 표시 frame={{1631, 152}, {168, 134}}`, 저장 위치를 화면 안으로 맞춤).

| 실행 | 캐릭터 로그 |
|---|---|
| 앱 시작 | `pose=idle label=실행 전` |
| slow-sample 전체 실행 | `pose=running label=터미널 실행 중 1/5` → `2/5` → `3/5`(세 줄 모두 같은 `key=run:639ec6bf…`, 애니메이션 다시 시작 안 함) → `pose=success label=통과 · 터미널` |
| fastapi_demo | `pose=running label=터미널 실행 중 0/?` → `pose=failure label=실패 1 · 터미널` |
| SIGINT | `running` `1/5`·`2/5` → `pose=attention label=중단됨 · 터미널` |
| `kill -9` | `running` `1/5`·`2/5` → `pose=attention label=미완료 · 터미널` |
| `-k does_not_exist_xyz` | `pose=attention label=테스트 없음 · 터미널` |

창 캡처: `~/.pmh-build/it/character/labels/`의 `idle.png`, `running-1.png`(1/5), `running-3.png`(캡처 시점 2/5), `success.png`, `failure.png`, `interrupted.png`, `killed.png`, `notests.png`, 한 장으로 붙인 `all-poses.png`. 가장 긴 "테스트 없음 · 터미널"까지 잘리지 않고 창 안에 보였다.
자동 테스트: Swift 161개(`CharacterLabelTests` 4개 추가: 결과 글씨가 행 문구와 같음(앱·터미널 출처 모두), 대기 "실행 전", 실행 중 글씨, 진행이 바뀌어도 key 유지. 포즈 테스트는 글씨를 빼고 정리).

### 7단계 사용자 확인(화면)

결과(2026-11-17): 3번(별도 상태)은 코디네이터가 별도 셸에서 SIGINT·`kill -9`·`-k 없는이름`을 하나씩 실행하고 사용자가 화면에서 갸웃 포즈와 "중단됨"·"미완료"·"테스트 없음"을 확인했다(앱 로그도 같은 포즈). 나머지 항목은 사용자가 한 번씩 해 보고 잘 된다고 알려 왔다. 팝오버 ■ 중지로 인한 중단은 SIGINT 중단과 같은 판정이라 따로 보지 않았다. 성공 점프가 반복되는 동안 PMHApp CPU는 약 3.6%였다.

앱을 켠 상태에서 확인한다. 느린 샘플: `examples/slow_demo`(테스트 5개, 약 10초. 7단계 확인 당시에는 같은 테스트가 `~/.pmh-build/slow-sample`에 있었다).

1. **다른 앱 사용 중 표시:** 앱을 켜면 주 화면 오른쪽 아래에 투명 배경의 여우가 보이는가(흰 사각형·그림자 없음). Safari·Terminal 등 다른 앱을 앞에 두고 클릭해 써도 여우가 그 창들 위에 남아 있고, 여우가 키보드 포커스를 가져가지 않는가.
2. **포즈:** 팝오버 ▶로 느린 샘플을 실행하면 제자리 달리기, 끝나면 팔 든 점프와 반짝임이 다음 실행까지 반복되는가. 터미널(`cd examples/slow_demo && ~/.venvs/pmh-3.13/bin/python -m pytest`)로 실행해도 같은가. 실패하는 실행(예: `examples/fastapi_demo`를 등록해 실행)이면 한 번 넘어진 뒤 얼굴을 바닥에 댄 채 누워 있는가.
3. **별도 상태:** ■ 중지 또는 터미널 Ctrl+C면 갸웃 포즈와 "중단됨", `kill -9`면 "미완료", `-k 없는이름`이면 "테스트 없음"이 보이고 점프하지 않는가. 갸웃 동작이 한 번만 움직이고 멈추는가.
4. **클릭:** 여우를 누르면 결과 팝오버가 여우 위쪽에 열리고, 여우가 따르던 환경(마지막에 실행한 환경)이 선택돼 있는가. 다시 누르거나 바깥을 누르면 닫히는가. 메뉴 막대 아이콘 팝오버가 열린 채 여우를 누르면 여우 쪽에 다시 열리는가.
5. **위치·끌기:** 여우를 끌면 따라오고, 놓은 자리가 앱을 다시 시작해도 유지되는가. 화면 밖으로 끌어 놓으면 화면 안으로 돌아오는가. 살짝 누르기만 하면(끌지 않으면) 팝오버가 열리는가.
6. **Spaces·전체화면:** Mission Control에서 다른 데스크톱으로 바꿔도 여우가 같은 자리에 보이는가. Safari 등을 전체화면(초록 버튼)으로 만든 Space에서도 여우가 앱 위에 보이고, 눌러서 팝오버가 열리는가.
7. **켜고 끄기:** 팝오버 맨 아래 [캐릭터 보이기]를 끄면 여우가 사라지고, 앱을 다시 시작해도 꺼진 채인가. 다시 켜면 같은 자리에 나타나는가.
8. (선택) 시스템 설정 > 손쉬운 사용 > 디스플레이 > "동작 줄이기"를 켜면 애니메이션이 멈추고 각 포즈의 정지 모습만 보이는가.
9. **상태 글씨(2026-11-17 추가, 사용자 확인: 터미널 실행 중 1/5에서 3/5로 바뀌는 동안 달리기가 끊기지 않고 이어짐, 통과 · 터미널):** 모든 포즈의 여우 아래에 글씨가 보이고 팝오버 환경 행 문구와 같은가(앱 시작 "실행 전", 팝오버 ▶ 실행 중 "실행 중 n/5", 터미널 실행 중 "터미널 실행 중 n/5", 끝나면 "통과"·"실패 1"·"중단됨" 등, 터미널 결과면 " · 터미널"). 실행 중 글씨가 1/5→2/5로 바뀔 때 달리기가 끊기거나 처음부터 다시 시작하지 않는가. 성공 뒤 글씨가 바뀌어도 점프가 이어지는가. 글씨가 창 밖으로 잘리지 않는가(길면 …로 줄고, 마우스를 올리면 전체 문구).

## 8단계: 완료 알림과 견고성

설계와 결정(2026-11-17, "정할 것" 5가지 모두 추천안)은 `docs/STEP8_DESIGN.md`에 있다. 여기에는 앱 쪽 동작과 검증만 적는다.

### 앱 동작

- **보내는 때:** 실행 하나가 끝나 결과가 정해지면 1건. 앱 ▶ 실행과 터미널 실행 모두(결정 1), 팝오버가 열려 있어도(결정 3) 보낸다. 앱이 앞에 있을 때도 배너가 뜨게 delegate가 `.banner`를 돌려준다.
- **보내지 않는 때:** 중단됨(■ 중지 SIGINT, 터미널 Ctrl+C)과 ■ 뒤 강제 종료된 "미완료 · 중지함"(결정 2, 사용자가 직접 멈춘 실행). [완료 알림] 토글이 꺼져 있을 때. 권한이 없을 때(로그만 남김).
- **한 번만:** 결정한 실행 ID(보냄·안 보냄 모두)를 메모리 집합에 넣고 다시 결정하지 않는다. 알림 요청 identifier도 실행 ID라 같은 ID가 다시 들어가도 알림 센터가 덮어쓴다. 앱을 다시 켜면 집합은 비지만 결과도 비고, 감시기는 앱 시작 전에 끝난 실행을 무시해 다시 보낼 일이 없다(재시작 직후 로그에 알림 줄 없음, 2026-11-17 확인).
- **문구:** 제목 `통과 · slow_demo / pmh-3.13`, `실패 1 · fastapi_demo / pmh-3.13 · 터미널`(머리말은 팝오버 행 문구와 같은 `ResultPresentation.outcomeStatus`). 본문 첫 줄은 건수와 시간(`통과 5 · 실패 0 · 9.9초`), 건수가 없는 결과는 결과 제목 전체(`미완료 · 시그널 9(KILL) · 2/5 끝남`). 실패가 있으면 둘째 줄에 첫 실패 테스트(`examples/fastapi_demo/test_app.py::test_health_intentionally_fails`, 여럿이면 `… 외 N건`).
- **누르면:** 그 실행의 환경을 고른 팝오버를 연다. 캐릭터가 보이면 캐릭터 옆, 숨겼으면 메뉴 막대 아이콘 아래.
- **권한:** 앱을 켤 때 상태를 읽고 `notDetermined`일 때만 한 번 요청한다. 팝오버를 열 때와 보낼 때마다 다시 읽는다(시스템 설정에서 바꾼 값을 반영). 팝오버 맨 아래 [캐릭터 보이기] 옆에 [완료 알림] 토글(기본 켬, UserDefaults `completionNotificationsEnabled`). 토글이 켜져 있고 권한이 `denied`면 회색 한 줄 "알림이 꺼져 있습니다. 시스템 설정 > 알림 > pytest Menu Helper에서 허용하세요."와 [설정 열기](시스템 설정 알림 화면). 권한이 없어도 팝오버·캐릭터·실행·중지는 그대로다.
- **프로젝트 폴더 없음:** 앱 시작, 다시 검사, 팝오버 열기 때 등록 폴더가 있는지 본다(`ProjectFolderCheck.missing`). 없으면 머리의 경로 아래에 빨간 "프로젝트 폴더가 없습니다"와 [폴더 다시 지정]. 다시 지정하면 프로젝트 id와 환경 등록은 그대로 두고 경로만 바꾼 뒤 환경을 다시 검사한다(결정 4). 다른 프로젝트가 이미 쓰는 폴더면 바꾸지 않고 팝오버 위에 이유를 보인다. ▶는 지금처럼 켜져 있고 누르면 "실행 오류 · 프로젝트 폴더가 없습니다"가 된다.
- **로그(category `notify`):** `알림 권한 시작 상태=… cdhash=…`, `알림 권한 요청 결과 granted=…`, `알림 보냄 run=… 제목=… 본문=…`, `알림 보내지 않음(중단) run=…`, `알림 보내지 않음(권한 없음: denied) run=… 제목=…`, `알림 보내지 않음(완료 알림 꺼짐) run=…`, `알림 클릭 run=… env=…`. 폴더는 category `external`에 `[프로젝트 폴더] <이름>: 프로젝트 폴더가 없습니다 path=…`.
  보기: `/usr/bin/log show --last 5m --style compact --predicate 'subsystem == "dev.yohwan.pytest-menu-helper" AND category == "notify"'`.

### 견고성 점검(설계 3절, 2026-11-17)

| 상황 | 확인한 동작 | 근거 |
|---|---|---|
| 앱 재실행 | 등록은 남고 결과·캐릭터는 대기로 시작. 앱 전에 끝난 터미널 실행은 다시 보이지 않고 알림도 다시 오지 않음 | 재시작 로그(`pose=idle`, 알림 줄 없음), 6단계 감시기 단위 테스트 |
| 프로젝트 폴더 이름 변경 | 앱 시작 때 `[프로젝트 폴더] tmpproj: 프로젝트 폴더가 없습니다` | 임시 폴더를 등록하고 이름을 바꾼 뒤 재시작한 로그, `ProjectFolderTests` 5개 |
| 플러그인 누락 | "조치 필요"와 설치 명령, ▶ 꺼짐, 상세의 "터미널 감지 불가" | `pmh-check ~/.venvs/pmh-noplugin/bin/python`, 기존 단위 테스트 |
| 플러그인 구버전(0.2.x) | 막지 않는 "조치 필요" 안내 | 단위 테스트 `plugin020WarnsAboutTerminalButDoesNotBlockRun`(0.2.x 환경이 없어 실제 환경으로는 보지 않음) |
| Python 경로 사라짐 | "오류 · Python 경로가 없습니다: …", ▶ 꺼짐 | `pmh-check ~/.venvs/pmh-gone/bin/python`(없는 경로) |
| pytest 없음 | "오류 · pytest가 설치되어 있지 않습니다" | `pmh-check ~/.venvs/pmh-nopytest/bin/python` |

### 통합 검증(2026-11-17, 앱과 별개 셸에서 실행)

검증 동안만 `projects.json`에 `examples/slow_demo`, `examples/fastapi_demo`, 임시 폴더를 pmh-3.13으로 등록했고 끝난 뒤 원래 파일로 되돌렸다. 실행 명령은 `~/.venvs/pmh-3.13/bin/python -m pytest -q -p no:cacheprovider`.

알림 거부(`denied`) 상태 결과. 실행마다 결정 줄이 정확히 1번씩 남았다.

| 실행 | 앱 로그(category notify) |
|---|---|
| slow_demo 전체(5 passed, 9.93초) | `알림 보내지 않음(권한 없음: denied) run=89f4aa4b… 제목=통과 · slow_demo / pmh-3.13 · 터미널` |
| fastapi_demo(1 failed, 1 passed) | `알림 보내지 않음(권한 없음: denied) run=1faecc09… 제목=실패 1 · fastapi_demo / pmh-3.13 · 터미널` |
| slow_demo 4초 뒤 SIGINT(2 passed) | `알림 보내지 않음(중단) run=dcc0b897… env=it8-slow` |
| slow_demo 4초 뒤 `kill -9` | `알림 보내지 않음(권한 없음: denied) run=17fa31fa… 제목=미완료 · slow_demo / pmh-3.13 · 터미널` |

알림 허용(`authorized`) 상태 결과(사용자가 시스템 설정에서 허용한 뒤). 실행마다 결정 줄이 정확히 1번씩 남았다.

| 실행 | 앱 로그(category notify) |
|---|---|
| slow_demo 전체(5 passed, 9.92초) | `알림 보냄 run=47e633d4… 제목=통과 · slow_demo / pmh-3.13 · 터미널 본문=통과 5 · 실패 0 · 9.9초` |
| fastapi_demo(1 failed, 1 passed) | `알림 보냄 run=5c7aa60f… 제목=실패 1 · fastapi_demo / pmh-3.13 · 터미널 본문=통과 1 · 실패 1 · 0.1초 / examples/fastapi_demo/test_app.py::test_health_intentionally_fails` |
| slow_demo 4초 뒤 SIGINT(2 passed) | `알림 보내지 않음(중단) run=fcaf237d… env=it8-slow` |
| slow_demo 4초 뒤 `kill -9` | `알림 보냄 run=355f8f35… 제목=미완료 · slow_demo / pmh-3.13 · 터미널 본문=미완료 · 프로세스 종료됨(종료 코드 모름) · 2/5 끝남` |

터미널 실행의 nodeid는 pytest rootdir(저장소 루트, `pyproject.toml`) 기준이라 `examples/fastapi_demo/…`로 시작한다. 터미널 `kill -9`는 종료 코드와 소요 시간을 알 수 없어 본문에 시간이 없다. 알림이 화면에 실제로 뜨는지와 누르면 팝오버가 열리는지는 아래 확인 목록 1번으로 본다.

**다시 빌드 뒤 알림 권한(설계 6절 위험) 시험:** 권한은 Bundle ID 기준으로 유지됐다. 로그 `알림 권한 시작 상태=…`의 cdhash와 상태를 차례로 기록했다.

| 순서 | cdhash(앞 8자리) | 시작 상태 |
|---|---|---|
| 첫 빌드, 첫 실행 | ce1d06c3 | notDetermined → 요청했으나 콜백 없이 대기(팝업 응답 기록 없음) |
| 같은 빌드 재시작 3회 | ce1d06c3 | denied |
| (사용자가 시스템 설정에서 허용) 코드를 바꿔 다시 빌드 | 2093c507 | authorized |
| 코드를 되돌려 다시 빌드 | ce1d06c3 | authorized |

권한 창이 실제로 화면에 떴는지, 사용자가 [허용 안 함]을 눌렀는지는 알 수 없다(2.5단계 샘플과 같은 현상). 그래서 안내 줄과 [설정 열기]가 필요하다. 허용한 뒤에는 서명(cdhash)이 바뀌어도 다시 허용할 필요가 없었다.

주의: 비대화형 셸에서 `&`로 띄운 pytest는 SIGINT를 무시한다. 중단 시험은 `perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' <명령> &`로 감싸 띄웠다. pytest pid는 `pgrep -f "pmh-3.13/bin/python -m pytest"`로 찾는다(`ps | grep test`는 앱 경로 `PytestMenuHelper.app`에도 걸린다).
앱 ▶ 실행의 알림은 화면 자동화가 없어 돌리지 못했다. 앱 실행 결과에도 실행 ID가 붙어 같은 결정 함수를 지나는 것은 단위 테스트(`passedRunSendsOneNoticeWithRunIDAsIdentifier`, `mergedKeepsAppRunIDWhenAppResultIsNewer`)로 고정했고 화면은 아래 확인 목록으로 본다.

자동 테스트: Swift 178개(`NotificationTests` 17개 추가: 결과별 보낼지, 제목·본문(팝오버 행 문구와 직접 비교), 같은 실행 1번, 중단·중지함 안 보냄, 토글 꺼짐, 터미널 실행 ID와 출처 표시, 권한 안내, 폴더 없음 검사·다시 지정). Python 소스는 바꾸지 않았다.

### 8단계 사용자 확인(화면)

상태: **일부 확인(2026-11-17).** 1번: 터미널 실행으로 성공(slow-sample)·실패(fastapi_demo)·미완료(kill -9) 알림이 1번씩 뜨고, 실패 알림 둘째 줄에 실패 위치가 보이며, 알림을 누르면 팝오버가 열리는 것을 사용자가 확인했다(앱 로그 "알림 보냄"·"알림 클릭"과 일치). 2번: 터미널 Ctrl+C 중단에 알림이 없고 여우가 "중단됨"인 것을 확인했다(■ 중지는 따로 보지 않음). 6번: 워커가 다시 빌드해 서명(cdhash)이 바뀐 뒤에도 권한이 authorized로 남는 것을 로그로 확인했다. 3·4·5·7번은 화면 확인 대기다.

앱을 켠 상태에서 확인한다. 샘플: `examples/slow_demo`(테스트 5개, 약 10초), `examples/fastapi_demo`(통과 1·실패 1). 두 폴더를 팝오버에서 프로젝트로 등록하고 pmh-3.13 환경을 추가해 둔다.

1. **알림 허용 상태:** 시스템 설정 > 알림 > pytest Menu Helper에서 알림을 허용한다. slow_demo ▶ 성공, fastapi_demo ▶ 실패, slow_demo를 터미널에서 돌리다 다른 창에서 `kill -9 <pid>`(미완료)를 하면 알림이 1번씩 뜨고 제목·본문이 팝오버 행 문구와 맞는가(실패는 둘째 줄에 `examples/fastapi_demo/test_app.py::test_health_intentionally_fails`). 알림을 누르면 팝오버가 그 환경을 고른 채 열리는가.
2. **중단은 알림 없음:** slow_demo ▶ 뒤 ■ 중지, 터미널 실행 뒤 Ctrl+C 모두 알림이 뜨지 않는가.
3. **알림 거부 상태:** 시스템 설정에서 알림을 끈 뒤 팝오버를 열면 맨 아래에 회색 안내 줄과 [설정 열기]가 보이고, 누르면 시스템 설정의 알림 화면이 열리는가. 이 상태에서 ▶ 실행·캐릭터·결과 확인이 그대로 되는가.
4. **토글:** [완료 알림]을 끄면 실행이 끝나도 알림이 없고, 앱을 다시 시작해도 꺼진 채인가. 다시 켜면 다음 실행부터 오는가(꺼진 동안 끝난 실행은 오지 않음).
5. **폴더 없음:** 등록한 프로젝트 폴더 이름을 Finder에서 바꾼 뒤 팝오버를 열면 경로 아래에 "프로젝트 폴더가 없습니다"와 [폴더 다시 지정]이 보이는가. 바뀐 폴더를 고르면 오류가 사라지고 환경 행이 그대로 남아 다시 검사되는가.
6. **다시 빌드 뒤 권한:** `app/build.sh`로 다시 빌드하고 `pkill -x PMHApp; sleep 1.5; open ~/.pmh-build/PytestMenuHelper.app`로 켠 뒤에도 알림이 뜨는가(시스템 설정에서 다시 허용하지 않아도 되는가).
7. **데모 대본:** README "데모 대본"대로 처음부터 끝까지(slow_demo 성공 → fastapi_demo 실패 → slow_demo 중단 → 터미널 실행) 막힘 없이 되는가.

## 알려진 제한

- 팝오버 화면·선택 창 동작은 자동화하지 못했다(사용자 확인 필요). 화면이 쓰는 판단 값은 단위 테스트로 고정했다.
- 실행 결과는 메모리에만 있어 앱을 다시 시작하면 사라진다(11단계).
- ad-hoc 서명이라 다른 Mac 배포는 미확인(`docs/NOTIFICATION_BUNDLE.md`). 다시 빌드한 뒤 알림 권한이 유지되는지는 아래 "8단계" 절의 시험 결과를 본다.
- 알림: 집중 모드(방해 금지)에서는 알림이 화면에 뜨지 않는다(앱 문제 아님). 보낸 실행 ID는 메모리에만 있다.
- 선택 창(폴더·Python 파일)이 떠 있는 동안 팝오버는 닫혀 있다. 창이 끝나면 다시 열리며 하던 상태가 이어진다. 창이 떠 있는 동안 아이콘을 눌러도 팝오버는 열리지 않는다.
- 팝오버 바깥을 눌러 닫았다가 아이콘으로 새로 열면 작성 중이던 환경 추가 폼과 제거 확인은 사라진다(새로 열 때는 기본 선택부터 보여 준다).
- 저장 실패는 경고 창 대신 팝오버 맨 위 문장으로 알린다. 메모리의 등록 정보는 바뀐 채로 두고 다음 변경 때 다시 저장한다.
- 한 번에 실행 1건만 가능하다. 여러 환경 동시 실행은 9단계.
- 앱이 강제 종료(SIGKILL, 충돌 등)되면 이미 시작한 pytest는 남을 수 있다. 정상 종료 때만 SIGINT·SIGKILL로 정리한다. 신호는 pytest 본체에만 보내므로, pytest가 따로 띄운 손자 프로세스는 남을 수 있다.
- 실행 중인 환경과 그 프로젝트는 제거할 수 없다. 먼저 중지해야 한다.
- 화면 확인 필요(2026-11-17 팝오버 이전분): 프로젝트·환경 추가와 제거, 폼과 선택 창 뒤 팝오버 다시 열림, 명령 복사, 실행 중 제거 막기(실행이 끝나면 "⋯"에서 다시 켜지는지), 오른쪽 클릭 종료. 팝오버에서의 실행 성공·중지와 실행 중 [종료]로 pytest가 남지 않는 것(KeyboardInterrupt, exit 2)은 사용자가 확인했다(2026-11-17).
- 앱 시작 때와 환경 추가·다시 검사 때만 검사한다. 이후 환경이 바뀌어도 자동 감지하지 않는다.
- 잘못된 경로도 등록은 되고 "오류"로 표시된다(행의 "⋯"에서 제거 가능).
- 검사 도중 앱을 종료하면 검사 프로세스는 10초 제한으로 끝난다.
- 같은 프로젝트에 같은 Python 경로는 한 번만 등록된다. 여러 환경 동시 실행은 9단계.
- 다른 터미널 실행: 앱을 켜기 전에 끝난 실행은 보이지 않는다(이력은 11단계). 터미널 실행은 앱에서 중지할 수 없다. 실행 폴더(또는 rootdir)가 등록 프로젝트 안이어야 연결된다. `config.json`을 바꾸면 앱을 다시 시작해야 한다.
- 다른 터미널 실행 결과도 메모리에만 있다. 앱에서 정한 동시 실행 1건 제한은 앱 실행에만 적용되며, 터미널 실행은 개수 제한 없이 따로 돈다.
- 캐릭터 창 안의 투명한 부분(그림 바깥)도 클릭을 받는다. 앱을 다시 시작하면 캐릭터는 대기 포즈로 시작한다(결과가 메모리에만 있음). 전체화면 앱 위 표시는 화면 확인 전이다.
