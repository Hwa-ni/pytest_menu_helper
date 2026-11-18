# pytest 이벤트 형식 v2

## 저장 위치와 로드 방식

- 플러그인은 `pytest11` entry point로 설치된 환경의 모든 pytest 실행에서 자동 로드됩니다. 등록하지 않은 프로젝트의 실행도 기록합니다. 앱이 실행한 pytest는 자신이 정한 실행 ID의 파일만 읽고(아래 "앱이 이벤트를 읽는 방법"), 다른 터미널의 실행은 실행 폴더·환경으로 등록 프로젝트에 연결합니다(아래 "다른 터미널의 실행").
- 기본: `~/Library/Application Support/pytest-menu-helper/events/<run_id>.jsonl`. 실행 1번이 파일 1개이며 폴더 권한은 0700입니다.
- **이벤트 폴더 결정 순서(6단계, 앱과 플러그인이 같은 규칙):** 1) 환경변수 `PYTEST_MENU_EVENTS_DIR`(앱이 자기 자식 pytest에 넘김, 테스트·개발용) 2) 공통 설정 파일 `~/Library/Application Support/pytest-menu-helper/config.json`의 `events_dir` 3) 기본 폴더. 아래 "공통 설정 파일" 참고.
- `--menu-events PATH`를 주면 그 파일에 이어서 기록합니다(기존 방식).
- `PYTEST_MENU_DISABLE=1`이면 기록하지 않습니다. xdist 워커 프로세스와 `--help`는 기록하지 않습니다.
- 환경 식별자는 앱이 `PMH_ENV_ID`로 지정하고, 없으면 `sys.prefix` 실제 경로의 SHA-256 앞 12자리를 씁니다.
- **실행 ID는 앱이 정할 수 있습니다(플러그인 0.2.0부터).** 앱이 UUID를 만들어 환경변수 `PMH_RUN_ID`로 넘기면 플러그인이 그 값을 `run_id`로 쓰고 파일 이름도 `<run_id>.jsonl`이 됩니다. 값이 표준 UUID 문자열(8-4-4-4-12, 대소문자 무관)이 아니면 **무시하고 새 UUID를 만듭니다.** 값이 파일 이름이 되므로 `../` 같은 경로 조작을 막기 위해서입니다. 대문자는 소문자로 바꿔 씁니다. `{}`·`urn:uuid:`·하이픈 없는 형식도 무시합니다. `--menu-events PATH`를 함께 주면 파일 경로는 PATH를 따르고 `run_id`만 `PMH_RUN_ID`를 씁니다.
- **플러그인은 `PMH_RUN_ID`·`PMH_ENV_ID`를 읽은 뒤 환경변수에서 지웁니다.** 테스트 안에서 pytest를 다시 실행하면 자식이 환경변수를 물려받아 같은 실행 ID로 같은 파일에 섞여 쓰기 때문입니다. 그래서 테스트 코드에서는 두 변수가 보이지 않으며, 자식 pytest는 새 실행 ID로 따로 기록합니다.
- 앱은 이벤트 폴더도 `PYTEST_MENU_EVENTS_DIR`로 직접 지정해 앱이 읽는 폴더와 플러그인이 쓰는 폴더가 같게 합니다.
- 파일 정리(개수 상한)는 앱이 합니다. 앱 시작 때와 실행 종료 때 `events/`의 `<uuid>.jsonl`, `logs/`의 `<uuid>.log`(소문자 UUID 이름의 일반 파일)만 최신 50개씩 남기고 지웁니다. 다른 이름의 파일, 폴더, 심볼릭 링크, `--menu-events`로 만든 임의 경로 파일은 건드리지 않습니다. 플러그인 자체는 파일을 지우지 않습니다.

UTF-8 JSONL 파일에 한 줄당 이벤트 하나를 기록합니다. 같은 파일은 덮어쓰지 않고 이어서 기록합니다.

## 공통 설정 파일 (6단계)

이미 열린 다른 터미널은 앱이 정한 환경변수를 받지 못합니다. 그래서 앱과 플러그인은 **고정된 위치의 설정 파일**을 각자 읽어 같은 이벤트 폴더를 고릅니다. 파일은 선택이며, 없으면 둘 다 기본 폴더를 씁니다. 앱은 이 파일을 만들거나 고치지 않습니다.

```json
{"events_dir": "/Users/me/pmh-events"}
```

- 위치: `~/Library/Application Support/pytest-menu-helper/config.json`(UTF-8 JSON 객체).
- `events_dir`: 절대 경로 문자열. `~`와 `~/...`만 홈으로 풉니다. `~user/...`는 풀지 않습니다(Swift와 Python이 다르게 풀 수 있어서).
- 다음이면 **둘 다 기본 폴더**를 씁니다: 파일 없음, JSON 아님, 최상위가 객체가 아님, 값이 문자열이 아님·빈 문자열·상대 경로. 플러그인은 조용히 무시하고(pytest를 멈추지 않기 위해), 앱은 팝오버 위 주황 문장으로 알립니다. `events_dir` 키가 없는 파일은 정상입니다.
- 플러그인은 실행마다 읽고, 앱은 시작할 때 한 번 읽습니다. **값을 바꾸면 앱을 다시 시작**해야 합니다.
- 바꾸는 것은 이벤트 폴더뿐입니다. 로그(`logs/`)와 등록 파일(`projects.json`)은 기준 폴더에 그대로 둡니다. 앱의 정리(최신 50개)는 그 폴더의 `<uuid>.jsonl`에도 적용되므로 다른 용도의 폴더를 지정하지 마세요.
- 터미널에서 `PYTEST_MENU_EVENTS_DIR`를 직접 설정해 두었다면 그 실행은 다른 폴더에 쓰므로 앱에 보이지 않습니다.

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

플러그인 0.3.0부터 다른 터미널의 실행을 알아보기 위한 필드를 더합니다(스키마 번호는 2 그대로, 추가만 함).

- `pid`: pytest 프로세스 id. 종료 이벤트 없이 끝난 실행을 확인하는 데 씁니다.
- `invocation_dir`: pytest를 실행한 폴더의 실제 경로. `project_root`(rootdir)는 상위 폴더의 pytest 설정 때문에 프로젝트보다 위일 수 있어 따로 남깁니다.
- `parent_run_id`: 테스트 안에서 다시 실행한 pytest면 바깥 실행의 `run_id`, 아니면 `null`. 플러그인은 자기 `run_id`를 `PMH_PARENT_RUN_ID` 환경변수에 넣어 자식 pytest가 읽게 하고, 실행이 끝나면(unconfigure) 원래 값으로 되돌립니다. `PMH_RUN_ID`·`PMH_ENV_ID`를 읽은 뒤 지우는 동작은 그대로입니다.
- `env.prefix`: `sys.prefix`의 실제 경로(가상환경 폴더). `env.python_path`는 실제 경로라 uv 가상환경에서 기반 Python으로 풀려 여러 환경이 같은 값이 되므로 환경 구분에 쓰지 않습니다.

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
- 다른 터미널 실행 감지는 아래 "다른 터미널의 실행"(6단계)에 있습니다.

## 결과 집계

`python -m pytest_menu_helper.aggregate PATH`는 JSONL의 마지막 실행을 JSON으로 출력합니다. `state`는 `waiting`, `running`, `completed`, `no_tests`, `collection_error`, `interrupted`, `incomplete` 중 하나이고, 정상 완료의 `verdict`는 `passed`, `failed`, `attention` 중 하나입니다. 그 외 실행의 `verdict`는 `null`입니다.

실패·오류가 있으면 `failed`, 전부 실제 통과한 테스트가 1건 이상이면 `passed`, skip·xfail·xpass 등이 있으면 `attention`입니다. 강제 종료·종료 이벤트 누락·일부 테스트 단계 누락은 `incomplete`입니다(실패로 멈춘 실행의 미실행 처리는 아래). 이전 이벤트의 종료 코드 2만으로 중단을 단정하지 않습니다. `running`은 Python API `aggregate(events, process_running=True)`로 프로세스가 실제로 실행 중임을 호출자가 전달해야 합니다.

`counts`에는 테스트 상태별 수와 함께 `not_run`(미실행)이 들어갑니다. 수집됐지만 setup·call·teardown 어느 단계도 보고되지 않은 테스트 수이며, 중지(Ctrl+C)나 `-x`처럼 도중에 끝난 실행에서 수집 수와 합계가 맞지 않는 이유를 보여 줍니다. 한 단계라도 보고된 테스트는 `incomplete`로 세므로 둘은 겹치지 않습니다. 해당 nodeid는 최상위 `not_run` 목록에 수집 순서대로 담깁니다. `session_collected`가 없는 이전 이벤트는 `session_finish.collected`와의 차이로 수만 세고 목록은 비워 둡니다. `-x`, `--maxfail`처럼 실패 때문에 pytest가 스스로 멈춘 실행은 미실행이 남아 있어도 `state: completed`, `verdict: failed`입니다. 조건은 `session_finish`가 있고, 중단(`interrupted`)·수집 오류가 아니며, `exit_code`가 1이고, 실패(`failed`) 또는 오류(`error`)가 1건 이상인 경우입니다. 이때도 `counts.not_run`과 `not_run` 목록은 그대로 담깁니다. 실패·오류 없이 미실행만 남은 실행, 일부 단계만 보고된 테스트(`counts.incomplete`)가 있는 실행은 실패가 있더라도 `incomplete`입니다. Ctrl+C 중단은 미실행 여부와 관계없이 `interrupted`입니다.

`args`(9단계)는 `session_start`의 `args`(pytest 명령줄 인수 문자열 목록)를 그대로 옮긴 값입니다. 키 이름은 이벤트 필드와 같게 했습니다(`env`와 같은 방식). 환경 비교가 환경마다 실행 조건(`-k`, 경로 지정 등)이 같은지 보는 데 씁니다. 명령줄에 준 인수만 담기며 설정 파일의 `addopts`는 들어가지 않습니다. 이벤트에 `args`가 없는 옛 파일(v1 등), 목록이 아니거나 문자열이 아닌 원소가 섞인 값은 `null`입니다. 인수 없이 실행한 것은 `[]`로 `null`과 구분합니다. 이벤트가 없는 `waiting` 결과도 `args: null`을 담습니다. 형식이 틀린 `args`는 판정에 쓰지 않는 참고 정보라 집계 오류로 만들지 않습니다. 플러그인 버전은 0.3.0 그대로입니다(이벤트 형식은 바뀌지 않았고, editable 설치는 바로 반영됩니다. 이 키가 없는 집계 결과는 `null`과 같은 "알 수 없음"으로 읽으면 됩니다).

```json
{"state": "completed", "verdict": "failed", "args": ["examples/multi_env_demo"], "counts": {"passed": 5, "failed": 1, "...": 0}}
```

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

## 다른 터미널의 실행 (6단계)

앱이 실행하지 않은 pytest(이하 외부 실행)도 이벤트 폴더에서 찾아 등록한 프로젝트·환경에 연결합니다. 코드는 `app/Sources/PMHCore/ExternalRuns.swift`(`ExternalRunWatcher`)입니다.

### 결정과 이유

| 항목 | 결정 | 이유 |
|---|---|---|
| 감시 방식 | **주기 읽기**: 0.5초마다 폴더 목록을 읽고, 추적 중인 파일은 앱 실행과 같은 `EventTail`로 새 줄만 읽음 | FSEvents·폴더 DispatchSource는 파일 생성은 알려도 기존 파일에 줄이 붙는 것은 알리지 않아 파일마다 따로 감시해야 합니다. 폴더 안 파일은 정리 규칙상 50여 개라 목록 읽기 비용이 작고, 앱 실행 읽기(0.25초 주기)와 같은 방식이라 테스트로 고정하기 쉽습니다. |
| 외부 실행 식별 | 파일 이름의 실행 ID가 **이 앱이 시작한 ID가 아니고**, `parent_run_id`가 없음 | 앱은 시작 전에 실행 ID를 기억해 두므로(끝난 뒤에도 유지) 한 실행이 앱 쪽과 외부 쪽에 동시에 보이지 않습니다. 중첩 pytest는 바깥 실행의 일부라 숨깁니다(숨기지 않으면 같은 환경의 결과를 덮어씀). |
| 프로젝트 매칭 | `invocation_dir`가 등록 폴더이거나 그 아래 → 없으면 `project_root`로 다시 → 여럿이면 가장 깊은 경로 | 이 저장소처럼 상위에 pytest 설정이 있으면 rootdir가 프로젝트보다 위가 됩니다. 실행한 폴더가 의도에 더 가깝습니다. 경로는 양쪽 다 POSIX realpath로 비교합니다(`/tmp`와 `/private/tmp` 차이). |
| 환경 매칭 | 같은 프로젝트에서 1) `env.id` = 등록 환경 id 2) `env.prefix` = 검사 결과의 prefix 3) prefix가 없으면(0.2.x) `env.id` = prefix의 SHA-256 앞 12자리 | 환경 검사 스크립트가 `sys.prefix` 실제 경로도 읽습니다. 검사가 끝나기 전에 본 실행은 판단을 미뤘다가 검사가 끝나면 연결합니다. |
| 앱을 켜기 전 파일 | 첫 목록 읽기 때 이미 있던 파일은 **아직 살아 있는 실행만** 이어서 봄 | 끝난 실행을 결과로 되살리는 것은 11단계(이력) 몫입니다. |
| 끝 판정 | `session_finish` → 그 환경의 집계기 1번 호출. 종료 이벤트 없이 프로세스가 사라짐 → **미완료**(종료 코드 모름). `pid`가 없어 확인 불가 → **"상태 확인 불가"로 남김** | 시간 초과로 실패 처리하지 않습니다. 긴 테스트는 오래 걸릴 뿐입니다. |
| 생존 확인 | `sysctl(KERN_PROC_PID)`: 프로세스 없음·좀비·**시작 시각이 session_start보다 2초 넘게 늦음**(pid 재사용)이면 끝남 | `kill(pid, 0)`만으로는 같은 pid를 다른 프로세스가 다시 쓴 경우를 가릴 수 없습니다. 사라진 것을 확인하면 파일을 한 번 더 읽어, 종료 이벤트를 쓰고 바로 끝난 실행을 미완료로 잘못 보지 않습니다. |

### 보이는 방식 (사용자 결정 A, 2026-11-17)

- 같은 환경 행에 합칩니다. 진행 중이면 "터미널 실행 중 3/5", 끝나면 "실패 1 · 터미널"처럼 출처를 붙입니다.
- 앱 실행과 터미널 실행 중 **나중에 끝난 것**이 그 환경의 마지막 결과입니다(`RunSnapshot.merged`). 같은 환경에서 터미널 실행이 여럿이면 가장 나중에 시작한 것의 진행을 보여 줍니다.
- 터미널 실행 중에도 ▶는 켜 둡니다. 앱이 띄운 프로세스가 아니라 ■(중지)는 없습니다. 같은 환경에서 앱 실행이 돌면 행은 앱 실행을 먼저 보여 줍니다.
- 등록 프로젝트에서 **등록하지 않은 Python**으로 돌린 실행은 결과를 숨기고 팝오버 위 안내 한 줄만 보입니다("등록하지 않은 Python 환경(~/.venvs/x)에서 실행한 pytest를 감지했습니다. "+ 환경 추가"로 등록하면 결과가 보입니다."). 그 환경을 등록하면 안내가 사라집니다.
- 등록하지 않은 폴더에서 실행한 pytest는 보이지 않습니다.

### 감지되지 않는 조건

플러그인이 기록하지 않으면 앱은 실행이 있었는지조차 알 수 없습니다. 그래서 이 조건은 화면(상세 맨 아래 "터미널 감지" 문장)과 문서로만 안내합니다.

- 그 환경에 플러그인이 설치되지 않음(`pmh-noplugin` 대조로 확인: 파일이 생기지 않음).
- `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1`: entry point 자동 로드가 꺼져 기록하지 않습니다. 이때도 `-p pytest_menu_helper.plugin`을 주면 기록합니다(확인함).
- `-p no:pytest_menu_helper.plugin`, `PYTEST_MENU_DISABLE=1`, 프로젝트 설정의 `addopts`에 넣은 같은 옵션.
- `--menu-events PATH`: 이벤트 폴더가 아닌 파일에 쓰므로 감지하지 않습니다.
- 터미널에 설정한 `PYTEST_MENU_EVENTS_DIR`가 앱의 폴더와 다름.
- 플러그인 0.2.x: 실행은 연결되지만 `pid`가 없어 끝났는지 확인할 수 없습니다(종료 기록이 오면 결과, 안 오면 "상태 확인 불가"로 남음). 앱은 "조치 필요"로 업데이트 명령을 보여 주지만 실행 버튼은 막지 않습니다.
