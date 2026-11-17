"""pytest JSONL event collector (schema v2).

Installed in a Python environment it loads automatically (``pytest11`` entry point) and writes
one file per run to the events folder. ``--menu-events PATH`` appends to an explicit file instead.
Set ``PYTEST_MENU_DISABLE=1`` to turn collection off.

이벤트 폴더 결정 순서(6단계, 앱과 같은 규칙):
1. 환경변수 ``PYTEST_MENU_EVENTS_DIR`` (앱이 자기 자식 pytest에 넘기는 값, 테스트·개발용)
2. 공통 설정 파일 ``~/Library/Application Support/pytest-menu-helper/config.json`` 의 ``events_dir``
3. 기본 폴더 ``~/Library/Application Support/pytest-menu-helper/events``
2번이 있는 이유: 이미 열린 다른 터미널은 앱이 정한 환경변수를 받지 못한다. 그래서 앱과 플러그인이
둘 다 같은 위치의 설정 파일을 읽어 같은 폴더를 고른다. 설정 파일이 없거나 잘못되면 둘 다 기본 폴더를 쓴다.

다른 터미널의 실행을 앱이 알아보도록 session_start에 pid, invocation_dir, parent_run_id, env.prefix를
남긴다(플러그인 0.3.0). 자세한 규칙은 docs/EVENTS.md 의 "다른 터미널의 실행" 절.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pytest


SCHEMA_VERSION = 2
# 중첩 pytest 표시용 환경변수. 바깥 실행이 자기 실행 ID를 넣고, 안쪽 pytest가 parent_run_id로 기록한다.
PARENT_RUN_VARIABLE = "PMH_PARENT_RUN_ID"


def data_home() -> Path:
    """앱과 플러그인이 함께 쓰는 기준 폴더를 돌려준다.

    반환값: ~/Library/Application Support/pytest-menu-helper (홈은 그때그때 다시 읽는다).
    모듈 상수로 고정하지 않는 이유: 테스트가 HOME을 바꿔 설정 파일 읽기를 확인할 수 있어야 한다.
    """
    return Path.home() / "Library" / "Application Support" / "pytest-menu-helper"


def _configured_events_dir() -> Path | None:
    """공통 설정 파일(config.json)의 events_dir 값을 읽는다.

    반환값: 사용할 폴더 경로. 파일이 없거나, JSON이 깨졌거나, 값이 문자열이 아니거나,
    ~ 를 풀어도 절대 경로가 아니면 None(기본 폴더를 쓴다).
    실패해도 예외를 던지지 않는다. 설정 파일 하나 때문에 pytest 실행이 멈추면 안 되기 때문이다.
    주의: 앱(Swift AppPaths.resolve)도 똑같은 규칙으로 읽어야 두 쪽이 같은 폴더를 본다.
    규칙을 바꾸면 양쪽을 함께 고치고 docs/EVENTS.md 도 고친다.
    """
    try:
        with open(data_home() / "config.json", encoding="utf-8") as handle:
            config = json.load(handle)
    except (OSError, ValueError):
        return None
    value = config.get("events_dir") if isinstance(config, dict) else None
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    # "~"와 "~/..."만 푼다. os.path.expanduser는 "~user"도 풀지만 앱(Swift)은 풀지 않아
    # 두 쪽이 다른 폴더를 고르게 되므로 일부러 쓰지 않는다.
    if text == "~":
        text = str(Path.home())
    elif text.startswith("~/"):
        text = str(Path.home()) + text[1:]
    path = Path(text)
    # 상대 경로는 pytest를 실행한 폴더마다 뜻이 달라져 앱과 어긋나므로 받지 않는다.
    return path if path.is_absolute() else None


def events_dir() -> Path:
    """이벤트 폴더를 정한다(환경변수 > 공통 설정 파일 > 기본 폴더, 모듈 설명 참고)."""
    override = os.environ.get("PYTEST_MENU_EVENTS_DIR")
    if override:
        return Path(override)
    return _configured_events_dir() or data_home() / "events"


def _take_app_variable(name: str) -> str | None:
    """앱이 이번 실행에만 넘긴 환경변수를 읽고 os.environ에서 지운다.

    매개변수 name: 읽을 변수 이름(PMH_RUN_ID, PMH_ENV_ID).
    반환값: 변수 값, 없으면 None.

    지우는 이유: 테스트가 subprocess로 pytest를 또 실행하면 자식이 os.environ을 물려받는다.
    그러면 자식 pytest가 바깥 실행과 같은 실행 ID로 같은 이벤트 파일에 섞여 쓰고,
    앱 집계가 틀어진다(이 저장소 테스트가 앱에서 33개 통과 대신 29 통과 4 실패로 나왔다).
    주의: 수집기를 만들 때 한 번만 불러야 한다. 지운 뒤에는 다시 읽어도 None이다.
    xdist 워커는 이 값이 필요 없으므로(컨트롤러만 기록) 미리 지워도 문제없다.
    """
    return os.environ.pop(name, None)


def _requested_run_id(value: str | None) -> str | None:
    """앱이 정한 실행 ID(PMH_RUN_ID 값)를 검증한다.

    매개변수 value: _take_app_variable("PMH_RUN_ID")로 꺼낸 값.
    반환값: 정규형 UUID(소문자) 문자열, 값이 없거나 정규형이 아니면 None.
    값이 그대로 파일 이름이 되므로 경로 조작(../)이나 다른 UUID 표기는 모두 무시한다.
    """
    if not value:
        return None
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        return None
    return str(parsed) if str(parsed) == value.lower() else None


def _plugin_version() -> str | None:
    try:
        from importlib.metadata import version
        return version("pytest-menu-helper")
    except Exception:
        return None


def _environment(env_id: str | None) -> dict[str, Any]:
    """session_start 이벤트에 넣을 환경 정보를 만든다.

    매개변수 env_id: 앱이 넘긴 환경 id(PMH_ENV_ID). 수집기 생성 때 미리 꺼내 둔 값이다.
    반환값: id, 인터프리터 경로, Python·pytest·플러그인 버전 사전.
    """
    # Name and version alone do not identify an environment; the prefix path does.
    prefix = os.path.realpath(sys.prefix)
    return {
        "id": env_id or hashlib.sha256(prefix.encode()).hexdigest()[:12],
        # 앱이 다른 터미널의 실행을 등록한 환경에 연결할 때 쓰는 값(0.3.0).
        # python_path는 실제 경로라 가상환경이 기반 Python으로 풀려 버려 환경 구분에 쓸 수 없다.
        "prefix": prefix,
        "python_path": os.path.realpath(sys.executable),
        "python_version": platform.python_version(),
        "pytest_version": pytest.__version__,
        "plugin_version": _plugin_version(),
    }


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.getgroup("menu helper").addoption(
        "--menu-events", metavar="PATH", default=None,
        help="append pytest events as JSON lines to PATH",
    )


def pytest_configure(config: pytest.Config) -> None:
    if os.environ.get("PYTEST_MENU_DISABLE") == "1":
        return
    # xdist workers report to the controller; only the controller records the run.
    if hasattr(config, "workerinput") or getattr(config.option, "help", False):
        return
    config.pluginmanager.register(_Collector(config, config.getoption("--menu-events")), "menu-helper-collector")


class _Collector:
    def __init__(self, config: pytest.Config, path: str | None) -> None:
        self.config = config
        self.root = Path(config.rootpath).resolve()
        # 앱 변수는 여기서 한 번에 꺼내 지운다. 자식 pytest가 물려받지 않게 하려는 것이다.
        self.env_id = _take_app_variable("PMH_ENV_ID")
        self.run_id = _requested_run_id(_take_app_variable("PMH_RUN_ID")) or str(uuid.uuid4())
        # 바깥 pytest가 남긴 실행 ID. 있으면 이 실행은 테스트 안에서 다시 띄운 중첩 pytest다.
        # 앱은 parent_run_id가 있는 실행을 터미널 실행으로 보여 주지 않는다(바깥 실행의 일부이기 때문).
        self.previous_parent = os.environ.get(PARENT_RUN_VARIABLE)
        self.parent_run_id = _requested_run_id(self.previous_parent)
        # 자식 pytest에 알려 줄 값을 넣는다. pytest_unconfigure에서 원래 값으로 되돌린다
        # (같은 프로세스에서 pytest.main을 여러 번 부르는 경우 다음 실행이 중첩으로 오인되지 않게).
        os.environ[PARENT_RUN_VARIABLE] = self.run_id
        self.occurrences: dict[str, int] = {}
        self.seq = 0
        self.stream = None
        try:
            if path is None:
                folder = events_dir()
                folder.mkdir(mode=0o700, parents=True, exist_ok=True)
                path = str(folder / f"{self.run_id}.jsonl")
            self.stream = open(path, "a", encoding="utf-8", buffering=1)
        except (OSError, ValueError) as exc:
            self._warn(exc)

    def _warn(self, exc: Exception) -> None:
        # Python warnings can be promoted to errors, which must not alter pytest's verdict.
        message = f"pytest-menu-helper: event collection disabled: {exc}"
        try:
            reporter = self.config.pluginmanager.get_plugin("terminalreporter")
            if reporter is not None:
                reporter.write_line(message, red=True)
            else:
                print(message, file=sys.stderr)
        except Exception:
            pass

    def _write(self, event: str, **fields: Any) -> None:
        if self.stream is None:
            return
        self.seq += 1
        payload = {
            "schema_version": SCHEMA_VERSION,
            "seq": self.seq,
            "event": event,
            "run_id": self.run_id,
            "project_root": str(self.root),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            **fields,
        }
        try:
            self.stream.write(json.dumps(payload, ensure_ascii=True) + "\n")
            self.stream.flush()
        except Exception as exc:
            try:
                self.stream.close()
            except Exception:
                pass
            self.stream = None
            self._warn(exc)

    def _absolute(self, path: str | os.PathLike[str] | None) -> str | None:
        if path is None:
            return None
        candidate = Path(path)
        if not candidate.is_absolute():
            candidate = self.root / candidate
        return str(candidate.resolve())

    def _failure(self, report: Any) -> dict[str, Any] | None:
        if not report.failed:
            return None
        representation = report.longrepr
        crash = getattr(representation, "reprcrash", None)
        return {
            "path": self._absolute(getattr(crash, "path", None)),
            "line": getattr(crash, "lineno", None),
            "message": str(getattr(crash, "message", None) or representation),
            "detail": str(representation),
        }

    def pytest_sessionstart(self, session: pytest.Session) -> None:
        self._write(
            "session_start", env=_environment(self.env_id),
            args=[str(arg) for arg in self.config.invocation_params.args],
            # 아래 세 필드는 0.3.0에서 추가했다. 앱이 다른 터미널의 실행을 알아보는 데 쓴다.
            # pid: 종료 이벤트 없이 끝난 실행을 "미완료"로 확정하려면 프로세스 생존을 확인해야 한다.
            pid=os.getpid(),
            # invocation_dir: pytest를 실행한 폴더(실제 경로). rootdir(project_root)는 상위 폴더의
            # 설정 파일 때문에 프로젝트 폴더보다 위가 될 수 있어, 프로젝트 매칭은 이 값을 먼저 본다.
            invocation_dir=os.path.realpath(str(self.config.invocation_params.dir)),
            parent_run_id=self.parent_run_id,
        )

    def pytest_collection_finish(self, session: pytest.Session) -> None:
        self._write("session_collected", nodeids=[item.nodeid for item in session.items])

    def pytest_runtest_logstart(self, nodeid: str, location: Any) -> None:
        self.occurrences[nodeid] = self.occurrences.get(nodeid, 0) + 1

    @pytest.hookimpl(hookwrapper=True)
    def pytest_runtest_makereport(self, item: pytest.Item, call: Any) -> Any:
        result = yield
        report = result.get_result()
        # pytest의 strict XPASS는 failed report와 전용 longrepr로 전달된다.
        report.menu_strict_xpass = (
            report.when == "call" and report.failed
            and isinstance(report.longrepr, str)
            and report.longrepr.startswith("[XPASS(strict)] ")
            and item.get_closest_marker("xfail") is not None
        )

    def pytest_runtest_logreport(self, report: pytest.TestReport) -> None:
        path, line, _ = report.location
        self._write(
            "test_report", nodeid=report.nodeid, occurrence=self.occurrences.get(report.nodeid, 1), phase=report.when,
            outcome=report.outcome, wasxfail=getattr(report, "wasxfail", None),
            strict_xpass=getattr(report, "menu_strict_xpass", False),
            duration=report.duration,
            location={"path": self._absolute(path), "line": line + 1 if line is not None else None},
            failure=self._failure(report),
        )

    def pytest_collectreport(self, report: pytest.CollectReport) -> None:
        if report.failed:
            self._write("collection_error", nodeid=report.nodeid, failure=self._failure(report))

    def pytest_keyboard_interrupt(self, excinfo: Any) -> None:
        self._write("session_interrupted", reason="keyboard_interrupt")

    def pytest_sessionfinish(self, session: pytest.Session, exitstatus: int) -> None:
        self._write("session_finish", exit_code=int(exitstatus), collected=session.testscollected)

    def pytest_unconfigure(self, config: pytest.Config) -> None:
        # 중첩 표시 변수를 이 실행 전 값으로 되돌린다(없었으면 지운다).
        if self.previous_parent is None:
            os.environ.pop(PARENT_RUN_VARIABLE, None)
        else:
            os.environ[PARENT_RUN_VARIABLE] = self.previous_parent
        if self.stream is not None:
            try:
                self.stream.close()
            except Exception as exc:
                self._warn(exc)
            self.stream = None
