"""Opt-in pytest JSONL event collector.

Load with ``-p pytest_menu_helper.plugin --menu-events PATH``.
"""

from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pytest


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.getgroup("menu helper").addoption(
        "--menu-events", metavar="PATH", default=None,
        help="append pytest events as JSON lines to PATH",
    )


def pytest_configure(config: pytest.Config) -> None:
    path = config.getoption("--menu-events")
    if path is not None:
        config.pluginmanager.register(_Collector(config, path), "menu-helper-collector")


class _Collector:
    def __init__(self, config: pytest.Config, path: str) -> None:
        self.config = config
        self.root = Path(config.rootpath).resolve()
        self.run_id = str(uuid.uuid4())
        self.occurrences: dict[str, int] = {}
        self.stream = None
        try:
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
        payload = {
            "schema_version": 1,
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
        self._write("session_start")

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
        self._write("session_interrupted")

    def pytest_sessionfinish(self, session: pytest.Session, exitstatus: int) -> None:
        self._write("session_finish", exit_code=int(exitstatus), collected=session.testscollected)

    def pytest_unconfigure(self, config: pytest.Config) -> None:
        if self.stream is not None:
            try:
                self.stream.close()
            except Exception as exc:
                self._warn(exc)
            self.stream = None
