"""공유 자원을 동시 실행에 안전하게 쓰는 바른 예.

입력: 없음(pytest가 수집해 실행한다).
출력: 모든 환경에서 통과한다. 여러 가상환경이 이 파일을 동시에 돌려도 서로 부딪히지 않는다.

같은 프로젝트를 Python 3.9·3.12·3.13 환경에서 동시에 돌리면 파일·포트·DB를 함께 쓰게 된다.
여기서는 자원을 실행마다(또는 환경마다) 따로 갖게 하는 세 가지 방법을 보여 준다.
나쁜 예는 test_shared_bad.py에 있다.
각 테스트는 약 1초 동안 자원을 붙잡아, 동시 실행이 실제로 겹치게 한다.
"""
import hashlib
import os
import socket
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

# 자원을 붙잡고 기다리는 시간(초). 다른 환경의 실행과 겹치게 하려는 값이다.
HOLD_SECONDS = 1.0


def _env_tag() -> str:
    """이 가상환경을 가리키는 짧은 이름표를 만든다.

    반환값: sys.prefix 실제 경로의 SHA-256 앞 12자리. 플러그인의 기본 환경 id와 같은 규칙이다.
    Python 버전이 아니라 prefix를 쓰는 이유: 같은 버전의 가상환경이 둘이면 버전으로는 구분되지 않는다.
    """
    return hashlib.sha256(os.path.realpath(sys.prefix).encode()).hexdigest()[:12]


def test_tmp_path_is_private_per_run(tmp_path):
    """pytest의 tmp_path는 실행(프로세스)마다 다른 폴더라, 고정 이름 파일을 써도 다른 환경과 섞이지 않는다.

    매개변수:
        tmp_path: pytest가 이 테스트에 주는 빈 임시 폴더.
    실패 조건: 기다리는 동안 다른 실행이 같은 파일을 덮어쓰면 읽은 값이 달라져 실패한다(바른 예에서는 일어나지 않음).
    """
    token = f"{_env_tag()}-{os.getpid()}"
    target = tmp_path / "state.txt"
    target.write_text(token, encoding="utf-8")
    time.sleep(HOLD_SECONDS)
    assert target.read_text(encoding="utf-8") == token


def test_port_zero_lets_os_choose_free_port():
    """포트 0으로 바인딩하면 OS가 비어 있는 포트를 고른다. 여러 환경이 동시에 서버를 띄워도 부딪히지 않는다.

    실패 조건: 바인딩 실패(OSError)나 0번 포트가 그대로 남는 경우.
    127.0.0.1만 쓰는 이유: 시험용 소켓을 바깥 네트워크에 열지 않으려고.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.bind(("127.0.0.1", 0))
        server.listen()
        port = server.getsockname()[1]
        assert port != 0
        time.sleep(HOLD_SECONDS)
        # 고른 포트로 실제 연결이 되는지까지 확인해, 바인딩만 하고 끝나는 빈 테스트가 되지 않게 한다.
        with socket.create_connection(("127.0.0.1", port), timeout=2):
            pass


def test_sqlite_file_per_environment():
    """SQLite 파일 이름에 환경 이름표를 넣어, 환경마다 다른 DB 파일을 쓴다.

    배타 잠금(BEGIN EXCLUSIVE)을 1초 붙잡아도 다른 환경은 다른 파일이라 기다리거나 실패하지 않는다.
    이름에 pid도 넣는 이유: 앱은 한 환경을 동시에 한 번만 돌리지만, 터미널에서는 같은 환경을
    두 번 동시에 돌릴 수 있다. 그때도 부딪히지 않게 한다.
    실패 조건: 잠금 대기 0.1초 안에 잠금을 얻지 못하면 sqlite3.OperationalError("database is locked").
    끝나면 파일을 지워 임시 폴더에 쌓이지 않게 한다.
    """
    db_path = Path(tempfile.gettempdir()) / f"pmh_multi_env_demo_{_env_tag()}_{os.getpid()}.sqlite"
    # isolation_level=None: 파이썬 sqlite3의 자동 트랜잭션을 끄고 BEGIN을 직접 쓰기 위해서.
    connection = sqlite3.connect(str(db_path), timeout=0.1, isolation_level=None)
    try:
        connection.execute("BEGIN EXCLUSIVE")
        connection.execute("CREATE TABLE IF NOT EXISTS runs (tag TEXT)")
        connection.execute("INSERT INTO runs VALUES (?)", (_env_tag(),))
        time.sleep(HOLD_SECONDS)
        connection.execute("COMMIT")
        assert connection.execute("SELECT count(*) FROM runs").fetchone()[0] >= 1
    finally:
        connection.close()
        db_path.unlink(missing_ok=True)
