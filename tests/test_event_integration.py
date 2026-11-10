"""Exercise the plugin in a real pytest process, without installing it."""

import json
import os
from pathlib import Path
import subprocess
import sys
from uuid import UUID


ROOT = Path(__file__).resolve().parents[1]
DEMO = ROOT / "examples" / "fastapi_demo"


def run_pytest(project, *args, use_project_root=True):
    env = os.environ.copy()
    env["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    env["PYTHONPATH"] = os.pathsep.join(
        [str(ROOT / "src"), env.get("PYTHONPATH", "")]
    )
    root_option = ["--rootdir", str(project)] if use_project_root else []
    return subprocess.run(
        [sys.executable, "-m", "pytest", *root_option, "-p", "no:cacheprovider",
         "-p", "pytest_menu_helper.plugin", *map(str, args)],
        cwd=project, env=env, text=True, capture_output=True, timeout=30,
    )


def read_events(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def assert_common(events, project):
    assert events
    run_ids = {event["run_id"] for event in events}
    assert len(run_ids) == 1
    UUID(next(iter(run_ids)))
    for event in events:
        assert event["schema_version"] == 1
        assert isinstance(event["event"], str)
        assert event["project_root"] == str(project.resolve())
        assert isinstance(event["timestamp"], str) and event["timestamp"]
    return next(iter(run_ids))


def test_demo_emits_phases_and_failure(tmp_path):
    destination = tmp_path / "events.jsonl"
    result = run_pytest(DEMO, "--menu-events", destination, "test_app.py")
    assert result.returncode == 1, result.stdout + result.stderr
    events = read_events(destination)
    assert_common(events, DEMO)
    assert events[0]["event"] == "session_start"
    assert events[-1]["event"] == "session_finish"
    assert events[-1]["exit_code"] == 1
    assert events[-1]["collected"] == 2

    reports = [event for event in events if event["event"] == "test_report"]
    ids = {event["nodeid"] for event in reports}
    assert ids == {"test_app.py::test_health_passes", "test_app.py::test_health_intentionally_fails"}
    for nodeid in ids:
        assert {e["phase"] for e in reports if e["nodeid"] == nodeid} == {"setup", "call", "teardown"}
    for event in reports:
        assert event["outcome"] in {"passed", "failed", "skipped"}
        assert "wasxfail" in event
        assert isinstance(event["duration"], (int, float)) and event["duration"] >= 0
        assert set(event["location"]) == {"path", "line"}
        assert Path(event["location"]["path"]).is_absolute()
        assert event["location"]["line"] >= 1
    failure = next(e["failure"] for e in reports if e["outcome"] == "failed")
    expected_line = next(i for i, line in enumerate((DEMO / "test_app.py").read_text().splitlines(), 1)
                         if '== {"status": "unhealthy"}' in line)
    assert failure["path"] == str((DEMO / "test_app.py").resolve())
    assert failure["line"] == expected_line
    assert failure["message"] and "unhealthy" in failure["detail"]
    assert all(e["failure"] is None for e in reports if e["outcome"] != "failed")


def test_collection_error_has_detail(tmp_path):
    (tmp_path / "test_broken.py").write_text("import nonexistent_menu_helper_module\n")
    destination = tmp_path / "events.jsonl"
    result = run_pytest(tmp_path, "--menu-events", destination, "test_broken.py")
    assert result.returncode == 2, result.stdout + result.stderr
    events = read_events(destination)
    assert_common(events, tmp_path)
    error = next(e for e in events if e["event"] == "collection_error")
    assert "test_broken.py" in error["nodeid"]
    assert "nonexistent_menu_helper_module" in error["failure"]["detail"]
    assert set(error["failure"]) == {"path", "line", "message", "detail"}
    assert events[-1]["event"] == "session_finish"
    assert events[-1]["exit_code"] == 2
    assert events[-1]["collected"] == 0


def test_disabled_and_run_ids_are_distinct(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    assert True\n")
    assert run_pytest(tmp_path, "test_ok.py").returncode == 0
    assert not list(tmp_path.glob("*.jsonl"))
    first, second = tmp_path / "first.jsonl", tmp_path / "second.jsonl"
    assert run_pytest(tmp_path, "--menu-events", first, "test_ok.py").returncode == 0
    assert run_pytest(tmp_path, "--menu-events", second, "test_ok.py").returncode == 0
    assert assert_common(read_events(first), tmp_path) != assert_common(read_events(second), tmp_path)


def test_repeated_runs_append_to_same_file(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    assert True\n")
    destination = tmp_path / "events.jsonl"
    for _ in range(2):
        assert run_pytest(tmp_path, "--menu-events", destination, "test_ok.py").returncode == 0
    events = read_events(destination)
    starts = [i for i, event in enumerate(events) if event["event"] == "session_start"]
    assert len(starts) == 2 and starts[0] == 0
    first, second = events[:starts[1]], events[starts[1]:]
    assert first[-1]["event"] == second[-1]["event"] == "session_finish"
    assert assert_common(first, tmp_path) != assert_common(second, tmp_path)


def test_subdirectory_run_with_parent_pytest_root(tmp_path):
    destination = tmp_path / "events.jsonl"
    result = run_pytest(DEMO, "--menu-events", destination, "test_app.py", use_project_root=False)
    assert result.returncode == 1, result.stdout + result.stderr
    events = read_events(destination)
    assert_common(events, ROOT)
    failure = next(e["failure"] for e in events
                   if e["event"] == "test_report" and e["outcome"] == "failed")
    assert failure["path"] == str((DEMO / "test_app.py").resolve())
    assert failure["line"] == 15


def test_event_io_error_does_not_change_pytest_verdict(tmp_path):
    (tmp_path / "test_outcomes.py").write_text(
        "def test_pass():\n    assert True\n\ndef test_fail():\n    assert False\n"
    )
    # A directory cannot be opened as the JSONL file, even for privileged users.
    for selection, expected in (("test_pass", 0), ("test_fail", 1)):
        result = run_pytest(tmp_path, "--menu-events", tmp_path,
                            f"test_outcomes.py::{selection}")
        assert result.returncode == expected, result.stdout + result.stderr
