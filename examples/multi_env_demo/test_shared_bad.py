"""공유 자원을 고정 이름으로 쓰는 나쁜 예. 여러 환경에서 동시에 돌리면 서로 부딪혀 실패한다.

입력: 없음. 기본 실행에서는 pytest.ini의 addopts(-m "not conflict") 때문에 선택되지 않는다.
      보려면 `python -m pytest -m conflict`로 켠다.
출력: 혼자 돌리면 모두 통과한다. 다른 환경과 동시에 돌리면 아래 중 일부가 실패한다.
  - 고정 파일: 다른 실행이 덮어쓴 값을 읽어 AssertionError.
  - 고정 포트: 이미 쓰는 포트라 OSError(Address already in use).
  - 고정 SQLite 파일: 배타 잠금을 얻지 못해 sqlite3.OperationalError(database is locked).

이 실패는 코드가 Python 버전에서 틀려서가 아니라 실행끼리 자원을 나눠 써서 생긴다.
환경 비교 화면에서는 "한 환경에서만 실패"로 보여 버전 차이처럼 오해할 수 있으므로, 실제 테스트에서는
test_shared.py처럼 실행마다 다른 자원을 쓴다.
"""
import os
import socket
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

import pytest

# 모듈 안 모든 테스트에 conflict 표식을 붙인다. 표식이 빠지면 기본 실행에 섞여 동시 실행 때마다 실패가 난다.
pytestmark = pytest.mark.conflict

# 자원을 붙잡는 시간(초). 두 환경을 거의 함께 시작하면 이 동안 겹친다.
HOLD_SECONDS = 1.0

# 일부러 모든 실행이 같은 값을 쓰게 한 고정 자원들.
# macOS의 tempfile.gettempdir()은 사용자별 폴더라, 같은 사용자가 띄운 환경끼리는 같은 경로가 된다.
FIXED_FILE = Path(tempfile.gettempdir()) / "pmh_multi_env_demo_bad_state.txt"
FIXED_DB = Path(tempfile.gettempdir()) / "pmh_multi_env_demo_bad.sqlite"
# 다른 프로그램이 거의 쓰지 않을 번호. 이미 쓰이고 있으면 혼자 돌려도 실패한다(그것도 고정 포트의 문제다).
FIXED_PORT = 48765


def test_fixed_file_name_is_overwritten():
    """고정 이름 파일에 자기 표식을 쓰고 1초 뒤 다시 읽는다.

    실패 조건: 그 사이 다른 환경이 같은 파일에 자기 표식을 쓰면 읽은 값이 달라 AssertionError.
    파일을 지우지 않는 이유: 지우는 순간 다른 실행이 읽으면 FileNotFoundError로 실패 모양이 바뀌어
    "덮어쓰기" 충돌을 보여 주려는 목적이 흐려진다.
    """
    token = f"{sys.version_info[0]}.{sys.version_info[1]}-{os.getpid()}"
    FIXED_FILE.write_text(token, encoding="utf-8")
    time.sleep(HOLD_SECONDS)
    assert FIXED_FILE.read_text(encoding="utf-8") == token


def test_fixed_port_is_already_in_use():
    """고정 포트에 서버 소켓을 열고 1초 붙잡는다.

    실패 조건: 다른 환경이 먼저 같은 포트를 열었으면 bind에서 OSError(Address already in use).
    SO_REUSEADDR·SO_REUSEPORT를 켜지 않는 이유: 고정 포트 충돌을 소켓 옵션으로 덮는 것은 처방이 아니다.
    바른 방법은 test_shared.py처럼 포트 0으로 OS가 빈 포트를 고르게 하는 것이다.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.bind(("127.0.0.1", FIXED_PORT))
        server.listen()
        time.sleep(HOLD_SECONDS)


def test_fixed_sqlite_file_is_locked():
    """모든 환경이 같은 SQLite 파일에 배타 잠금을 1초 붙잡는다.

    실패 조건: 다른 환경이 잠금을 쥐고 있으면 0.1초 기다린 뒤 sqlite3.OperationalError(database is locked).
    timeout을 짧게 둔 이유: 기본값(5초)이면 잠금이 풀릴 때까지 기다렸다가 통과해 충돌이 지연으로만 보인다.
    """
    connection = sqlite3.connect(str(FIXED_DB), timeout=0.1, isolation_level=None)
    try:
        connection.execute("BEGIN EXCLUSIVE")
        connection.execute("CREATE TABLE IF NOT EXISTS runs (tag TEXT)")
        connection.execute("INSERT INTO runs VALUES (?)", (str(os.getpid()),))
        time.sleep(HOLD_SECONDS)
        connection.execute("COMMIT")
    finally:
        connection.close()
