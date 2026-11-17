"""pytest JSONL event collector (schema v2).

Installed in a Python environment it loads automatically (``pytest11`` entry point) and writes
one file per run to the events folder. ``--menu-events PATH`` appends to an explicit file instead.
Set ``PYTEST_MENU_DISABLE=1`` to turn collection off.
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
DEFAULT_EVENTS_DIR = Path.home() / "Library" / "Application Support" / "pytest-menu-helper" / "events"


def events_dir() -> Path:
    """Folder shared with the app. PYTEST_MENU_EVENTS_DIR overrides it for tests and development."""
    override = os.environ.get("PYTEST_MENU_EVENTS_DIR")
    return Path(override) if override else DEFAULT_EVENTS_DIR


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
        if self.stream is not None:
            try:
                self.stream.close()
            except Exception as exc:
                self._warn(exc)
            self.stream = None
