# pytest 이벤트 형식 v2

## 저장 위치와 로드 방식

- 플러그인은 `pytest11` entry point로 설치된 환경의 모든 pytest 실행에서 자동 로드됩니다. 등록하지 않은 프로젝트의 실행도 기록합니다. 앱은 `project_root`로 거르지 않고, 자신이 정한 실행 ID의 파일만 읽습니다(아래 "앱이 이벤트를 읽는 방법").
- 기본: `~/Library/Application Support/pytest-menu-helper/events/<run_id>.jsonl`. 실행 1번이 파일 1개이며 폴더 권한은 0700입니다. `PYTEST_MENU_EVENTS_DIR`로 폴더를 바꿀 수 있습니다(테스트·개발용).
- `--menu-events PATH`를 주면 그 파일에 이어서 기록합니다(기존 방식).
- `PYTEST_MENU_DISABLE=1`이면 기록하지 않습니다. xdist 워커 프로세스와 `--help`는 기록하지 않습니다.
- 환경 식별자는 앱이 `PMH_ENV_ID`로 지정하고, 없으면 `sys.prefix` 실제 경로의 SHA-256 앞 12자리를 씁니다.
- **실행 ID는 앱이 정할 수 있습니다(플러그인 0.2.0부터).** 앱이 UUID를 만들어 환경변수 `PMH_RUN_ID`로 넘기면 플러그인이 그 값을 `run_id`로 쓰고 파일 이름도 `<run_id>.jsonl`이 됩니다. 값이 표준 UUID 문자열(8-4-4-4-12, 대소문자 무관)이 아니면 **무시하고 새 UUID를 만듭니다.** 값이 파일 이름이 되므로 `../` 같은 경로 조작을 막기 위해서입니다. 대문자는 소문자로 바꿔 씁니다. `{}`·`urn:uuid:`·하이픈 없는 형식도 무시합니다. `--menu-events PATH`를 함께 주면 파일 경로는 PATH를 따르고 `run_id`만 `PMH_RUN_ID`를 씁니다.
- **플러그인은 `PMH_RUN_ID`·`PMH_ENV_ID`를 읽은 뒤 환경변수에서 지웁니다.** 테스트 안에서 pytest를 다시 실행하면 자식이 환경변수를 물려받아 같은 실행 ID로 같은 파일에 섞여 쓰기 때문입니다. 그래서 테스트 코드에서는 두 변수가 보이지 않으며, 자식 pytest는 새 실행 ID로 따로 기록합니다.
- 앱은 이벤트 폴더도 `PYTEST_MENU_EVENTS_DIR`로 직접 지정해 앱이 읽는 폴더와 플러그인이 쓰는 폴더가 같게 합니다.
- 파일 정리(개수 상한)는 앱이 합니다. 앱 시작 때와 실행 종료 때 `events/`의 `<uuid>.jsonl`, `logs/`의 `<uuid>.log`(소문자 UUID 이름의 일반 파일)만 최신 50개씩 남기고 지웁니다. 다른 이름의 파일, 폴더, 심볼릭 링크, `--menu-events`로 만든 임의 경로 파일은 건드리지 않습니다. 플러그인 자체는 파일을 지우지 않습니다.

UTF-8 JSONL 파일에 한 줄당 이벤트 하나를 기록합니다. 같은 파일은 덮어쓰지 않고 이어서 기록합니다.

## 공통 필드

- `schema_version`: 정수 `2`. 집계기는 v1 파일도 읽습니다(없는 필드는 `null`).
- `seq`: 실행 안에서 1부터 늘어나는 이벤트 순번. v1에는 없습니다.
- `event`: 이벤트 종류
- `run_id`: 실행마다 생성하는 UUID 문자열. 같은 pytest 실행의 모든 이벤트가 공유합니다.
- `project_root`: pytest가 결정한 프로젝트 루트의 절대 경로
- `timestamp`: UTC ISO 8601 시각

## 이벤트 종류

### session_start

pytest 세션 시작입니다. v2는 아래 필드를 더합니다.

- `env`: `{id, python_path, python_version, pytest_version, plugin_version}`. `plugin_version`은 설치 정보가 없으면 `null`
- `args`: pytest 실행 인수 문자열 목록(`-k` 등 선택 조건 확인용)

### session_collected

v2에서 추가했습니다. 수집이 끝난 직후 `nodeids`에 수집된 전체 테스트 ID 목록을 기록합니다. 수집 오류로 수집이 끝나지 않으면 없을 수 있습니다. 집계기는 실행당 1건만 허용합니다.

### test_report

- `nodeid`: pytest 테스트 식별자
- `occurrence`: 같은 nodeid가 한 실행에서 반복 수집된 순서(1부터 시작). 기존 v1 이벤트에는 이 필드가 없으며 1로 취급합니다.
- `phase`: `setup`, `call`, `teardown`
- `outcome`: pytest report의 `passed`, `failed`, `skipped`
- `wasxfail`: pytest가 제공하는 xfail 관련 사유. 없으면 `null`
- `strict_xpass`: 엄격한 XPASS 여부. 기존 v1 이벤트에는 이 필드가 없을 수 있습니다.
- `duration`: 해당 단계 소요 시간(초)
- `location`: 테스트 정의 위치 `{path, line}`
- `failure`: 실패 정보 `{path, line, message, detail}`. 실패하지 않은 단계는 `null`

경로는 절대 경로, 줄 번호는 1부터 시작합니다. pytest가 위치를 제공하지 못하면 해당 값은 `null`일 수 있습니다. `location`은 테스트 정의 위치이고 `failure`는 실제 오류 위치이므로 서로 다를 수 있습니다.

테스트 하나에 여러 단계 이벤트가 발생합니다. 이벤트 수를 테스트 수로 세면 안 됩니다. 집계기는 실행 ID, 테스트 ID, 반복 번호를 기준으로 단계를 합칩니다. 이전 v1 기록에서 반복 번호 없이 같은 단계가 중복되면 오류를 반환합니다. `outcome`만으로 xfail과 xpass를 최종 판정하지 않습니다. 기존 이벤트에서 엄격한 XPASS 여부가 불분명하면 미완료로 분류합니다.

### collection_error

- `nodeid`: 수집에 실패한 대상의 식별자
- `failure`: `{path, line, message, detail}`

테스트 모듈 import 실패 등 수집 단계의 오류입니다. 테스트 본문의 실패와 구분합니다.

### session_interrupted

pytest가 `KeyboardInterrupt`를 감지한 경우 기록하며 v2는 `reason: "keyboard_interrupt"`를 담습니다. 이전 이벤트에는 없을 수 있으며, 강제 종료에서는 기록을 보장하지 않습니다.

### session_finish

- `exit_code`: pytest의 최종 종료 코드
- `collected`: pytest가 보고한 수집된 테스트 수

종료 코드 0은 모든 테스트의 실제 실행·통과를 보장하지 않습니다. 강제 종료하면 이 이벤트가 기록되지 않을 수 있습니다.

## 첫 단계의 범위와 제한

- 순차적인 pytest 실행을 대상으로 합니다. 동시 파일 쓰기와 pytest-xdist는 지원 범위에 포함하지 않습니다.
- 파일 쓰기 오류가 발생하면 진단 메시지를 출력하고 기록을 중단합니다. 원래 pytest 테스트 판정은 유지합니다. 수집 파일이 완전하다고 가정하면 안 됩니다.
- 이벤트는 traceback 등 프로젝트 정보가 담긴 로컬 데이터입니다. 저장 위치를 직접 정하며 샘플의 `.menu-events/`는 Git 추적에서 제외합니다.
- 타 터미널 자동 감지와 macOS UI는 후속 단계입니다.

## 결과 집계

`python -m pytest_menu_helper.aggregate PATH`는 JSONL의 마지막 실행을 JSON으로 출력합니다. `state`는 `waiting`, `running`, `completed`, `no_tests`, `collection_error`, `interrupted`, `incomplete` 중 하나이고, 정상 완료의 `verdict`는 `passed`, `failed`, `attention` 중 하나입니다. 그 외 실행의 `verdict`는 `null`입니다.

실패·오류가 있으면 `failed`, 전부 실제 통과한 테스트가 1건 이상이면 `passed`, skip·xfail·xpass 등이 있으면 `attention`입니다. 강제 종료·종료 이벤트 누락·일부 테스트 단계 누락은 `incomplete`입니다. 이전 이벤트의 종료 코드 2만으로 중단을 단정하지 않습니다. `running`은 Python API `aggregate(events, process_running=True)`로 프로세스가 실제로 실행 중임을 호출자가 전달해야 합니다.

`counts`에는 테스트 상태별 수와 함께 `not_run`(미실행)이 들어갑니다. 수집됐지만 setup·call·teardown 어느 단계도 보고되지 않은 테스트 수이며, 중지(Ctrl+C)나 `-x`처럼 도중에 끝난 실행에서 수집 수와 합계가 맞지 않는 이유를 보여 줍니다. 한 단계라도 보고된 테스트는 `incomplete`로 세므로 둘은 겹치지 않습니다. 해당 nodeid는 최상위 `not_run` 목록에 수집 순서대로 담깁니다. `session_collected`가 없는 이전 이벤트는 `session_finish.collected`와의 차이로 수만 세고 목록은 비워 둡니다. 미실행이 1건이라도 있으면 `completed`가 아닙니다.

불완전한 JSON 줄이나 섞인 실행, 중복 단계 등은 오류를 반환합니다. 실시간으로 쓰는 파일의 부분 줄 처리는 앱이 합니다(아래). 동시 실행은 9단계입니다.

## 앱이 이벤트를 읽는 방법 (4단계)

- 앱이 실행 ID를 정해 `PMH_RUN_ID`로 넘기므로 읽을 파일은 `events/<run_id>.jsonl` 하나로 정해집니다. 폴더를 훑어 "가장 최근 파일"을 고르지 않습니다. 그래서 이전 실행 파일이 폴더에 남아 있어도 섞이지 않습니다.
- 실행 중 0.25초마다 읽습니다. 읽은 바이트 위치를 기억해 새로 쓰인 부분만 읽고, 줄바꿈으로 끝나지 않은 마지막 조각은 다음 읽기까지 보류합니다. 문자열이 아니라 **바이트 버퍼**로 줄을 나누므로 읽기 경계가 한글(UTF-8 다중 바이트) 중간이어도 깨지지 않습니다.
- 매칭은 **실행 ID로만** 합니다. `project_root`는 pytest의 rootdir이라 프로젝트 폴더와 다를 수 있어 경로로 거르지 않습니다. 읽은 모든 이벤트의 `run_id`가 앱이 정한 값과 같은지 확인하고, 다른 값이 있으면 진행률에 세지 않고 결과를 "집계 오류"(다른 실행 이벤트 N건 섞임)로 구분합니다.
- 실행 중 Swift는 **진행률만** 셉니다: `session_collected`의 `nodeids` 수를 전체로, `teardown` 이벤트까지 끝난 테스트(nodeid+occurrence)를 완료로 봅니다(예: 12/40). 성공·실패 판정 규칙은 Swift에 없습니다.
- 최종 결과는 프로세스가 끝난 뒤 같은 환경의 `python -I -m pytest_menu_helper.aggregate <이벤트 파일>`을 1번 호출해 JSON으로 받습니다. 호출이 실패하면(구버전 플러그인 등) 판정이 아니라 "집계 오류"로 표시합니다.
- 프로세스가 끝났는데 `session_finish`가 없으면 **미완료**(종료 코드나 시그널 표시)입니다. 이 경우 집계기를 호출하지 않습니다(강제 종료로 마지막 줄이 잘려 집계가 오류를 낼 수 있기 때문). 이벤트 파일이 아예 없거나 일치하는 이벤트가 0건인 채 프로세스가 끝나면 **수집 실패**이며 로그 마지막 줄을 안내합니다. 프로세스가 살아 있는데 파일이 아직 없으면 실패가 아니라 **수집 대기**입니다.

`passed`는 이번 실행에서 선택된 테스트가 모두 통과했다는 뜻입니다. `-k` 등으로 선택하지 않은 다른 테스트가 통과했다는 뜻은 아닙니다. 현재 이벤트에는 전체 선택 범위가 기록되지 않습니다.

pytest 훅과 report의 기준은 [pytest 8.4 API 문서](https://docs.pytest.org/en/8.4.x/reference/reference.html)를 따릅니다.
