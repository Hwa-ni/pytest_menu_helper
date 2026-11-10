# pytest Menu Helper

FastAPI 프로젝트의 pytest 실행 결과를 캐릭터와 macOS 메뉴 막대에 보여주는 기말 과제용 미니프로젝트입니다.

## 현재 상태

1단계인 FastAPI 샘플과 pytest 이벤트 수집기를 구현했습니다. macOS 앱과 결과 집계는 후속 단계입니다.

기능을 추가할 순서와 단계별 완료 기준은 [구현 순서](IMPLEMENTATION_PLAN.md)에 정리합니다.

## 개발 환경과 실행

Python 3.12 이상에서 가상환경을 만들고 개발 의존성을 설치합니다.

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[dev]'
python -m pytest
```

루트의 기본 테스트 실행은 수집기의 검증 테스트만 실행합니다. 의도적으로 실패하는 FastAPI 샘플은 따로 실행합니다.

```sh
mkdir -p .menu-events
python -m pytest -p pytest_menu_helper.plugin \
  --menu-events .menu-events/demo.jsonl examples/fastapi_demo
```

샘플은 성공 1건·실패 1건이므로 종료 코드 1이 정상적인 데모 결과입니다. `.menu-events/demo.jsonl`에서 수집 이벤트를 확인합니다. 같은 파일로 다시 실행하면 새 실행 ID로 이어서 기록합니다.

현재는 `-p pytest_menu_helper.plugin`과 `--menu-events`를 명시해야 합니다. 이벤트 형식과 제한은 [이벤트 명세](docs/EVENTS.md)를 참고하세요.

## 첫 버전 목표

1. 사용자가 프로젝트를 선택하면 프로젝트 파일과 pytest 환경을 확인합니다.
2. pytest 실행을 감지하고 테스트 결과를 수집합니다.
3. 테스트 중에는 캐릭터가 걷고, 전체 성공 시 점프하며, 하나라도 실패하면 넘어집니다.
4. 테스트가 완료되면 macOS 알림을 보냅니다.
5. 메뉴 막대 아이콘이나 캐릭터를 누르면 성공·실패 건수와 테스트 목록을 보여줍니다.
6. 실패한 테스트의 이름, 실패 위치와 오류 내용을 보여줍니다.

성공과 실패는 API 응답 자체가 아니라 pytest의 테스트 판정을 따릅니다.

## 첫 대상 환경

- macOS
- Python 3.12 이상
- FastAPI 프로젝트와 pytest

## 검토할 사항

- pytest 실행 감지 및 결과 수집 방식과 구현 기술을 결정합니다.
- 다른 터미널에서 실행한 pytest를 자동으로 감지할 수 있는지 검증합니다. 감지 가능 여부와 필요한 설정은 아직 정해지지 않았습니다.
- 테스트가 수집되지 않거나 중단되는 경우 등 성공·실패 외 상태의 표시 방식을 정합니다.

## 보류한 아이디어

- 이전 실행과 비교해 새로 실패하거나 다시 성공한 테스트 표시
- 실패 위치를 클릭해 에디터에서 해당 파일 열기
- 프로젝트 자동 스캔으로 맵을 만들고 실행 경로를 캐릭터로 재생
