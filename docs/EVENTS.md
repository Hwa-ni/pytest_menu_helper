# pytest 이벤트 형식 v1

`-p pytest_menu_helper.plugin --menu-events PATH`를 지정하면 UTF-8 JSONL 파일에 한 줄당 이벤트 하나를 기록합니다. 옵션을 생략하면 수집기를 활성화하지 않습니다. 같은 파일은 덮어쓰지 않고 이어서 기록합니다.

## 공통 필드

- `schema_version`: 정수 `1`
- `event`: 이벤트 종류
- `run_id`: 실행마다 생성하는 UUID 문자열. 같은 pytest 실행의 모든 이벤트가 공유합니다.
- `project_root`: pytest가 결정한 프로젝트 루트의 절대 경로
- `timestamp`: UTC ISO 8601 시각

## 이벤트 종류

### session_start

pytest 세션 시작입니다. 공통 필드만 기록합니다.

### test_report

- `nodeid`: pytest 테스트 식별자
- `phase`: `setup`, `call`, `teardown`
- `outcome`: pytest report의 `passed`, `failed`, `skipped`
- `wasxfail`: pytest가 제공하는 xfail 관련 사유. 없으면 `null`
- `duration`: 해당 단계 소요 시간(초)
- `location`: 테스트 정의 위치 `{path, line}`
- `failure`: 실패 정보 `{path, line, message, detail}`. 실패하지 않은 단계는 `null`

경로는 절대 경로, 줄 번호는 1부터 시작합니다. pytest가 위치를 제공하지 못하면 해당 값은 `null`일 수 있습니다. `location`은 테스트 정의 위치이고 `failure`는 실제 오류 위치이므로 서로 다를 수 있습니다.

테스트 하나에 여러 단계 이벤트가 발생합니다. 이벤트 수를 테스트 수로 세면 안 됩니다. 집계는 후속 단계에서 실행 ID와 테스트 ID를 기준으로 구현합니다. `outcome`만으로 xfail과 xpass를 최종 판정하지 않습니다.

### collection_error

- `nodeid`: 수집에 실패한 대상의 식별자
- `failure`: `{path, line, message, detail}`

테스트 모듈 import 실패 등 수집 단계의 오류입니다. 테스트 본문의 실패와 구분합니다.

### session_finish

- `exit_code`: pytest의 최종 종료 코드
- `collected`: pytest가 보고한 수집된 테스트 수

종료 코드 0은 모든 테스트의 실제 실행·통과를 보장하지 않습니다. 강제 종료하면 이 이벤트가 기록되지 않을 수 있습니다.

## 첫 단계의 범위와 제한

- 순차적인 pytest 실행을 대상으로 합니다. 동시 파일 쓰기와 pytest-xdist는 지원 범위에 포함하지 않습니다.
- 파일 쓰기 오류가 발생하면 진단 메시지를 출력하고 기록을 중단합니다. 원래 pytest 테스트 판정은 유지합니다. 수집 파일이 완전하다고 가정하면 안 됩니다.
- 이벤트는 traceback 등 프로젝트 정보가 담긴 로컬 데이터입니다. 저장 위치를 직접 정하며 샘플의 `.menu-events/`는 Git 추적에서 제외합니다.
- 타 터미널 자동 감지, 최종 성공·실패 집계, macOS UI는 후속 단계입니다.

pytest 훅과 report의 기준은 [pytest 8.4 API 문서](https://docs.pytest.org/en/8.4.x/reference/reference.html)를 따릅니다.
