"""Exercise the plugin in a real pytest process, without installing it."""

import json
import os
from pathlib import Path
import subprocess
import sys
from uuid import UUID


ROOT = Path(__file__).resolve().parents[1]
DEMO = ROOT / "examples" / "fastapi_demo"


def run_pytest(project, *args, use_project_root=True, extra_env=None, drop_env=()):
    """플러그인을 -p로 직접 불러 실제 pytest 프로세스를 실행한다.

    매개변수 drop_env: 기본으로 넣는 변수 중 지울 이름들. 공통 설정 파일(config.json) 확인처럼
    PYTEST_MENU_EVENTS_DIR이 없어야 하는 테스트가 쓴다.
    """
    env = os.environ.copy()
    # 이 테스트 자체를 플러그인이 설치된 환경에서 돌리면 바깥 pytest가 중첩 표시 변수를 넣는다.
    # 지우지 않으면 아래 실행이 모두 "중첩 실행"(parent_run_id)으로 기록된다.
    env.pop("PMH_PARENT_RUN_ID", None)
    env["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    env.pop("PYTEST_MENU_DISABLE", None)
    env.pop("PMH_ENV_ID", None)
    # Never write into the real events folder from tests.
    env["PYTEST_MENU_EVENTS_DIR"] = str(project / ".isolated-events")
    env.update(extra_env or {})
    for name in drop_env:
        env.pop(name, None)
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
        assert event["schema_version"] == 2
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
    first, second = tmp_path / "first.jsonl", tmp_path / "second.jsonl"
    assert run_pytest(tmp_path, "--menu-events", first, "test_ok.py").returncode == 0
    assert run_pytest(tmp_path, "--menu-events", second, "test_ok.py").returncode == 0
    assert assert_common(read_events(first), tmp_path) != assert_common(read_events(second), tmp_path)


def test_default_folder_gets_one_file_per_run(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    assert True\n")
    folder = tmp_path / ".isolated-events"
    for _ in range(2):
        assert run_pytest(tmp_path, "test_ok.py").returncode == 0
    files = sorted(folder.glob("*.jsonl"))
    assert len(files) == 2
    for file in files:
        events = read_events(file)
        run_id = assert_common(events, tmp_path)
        assert file.name == f"{run_id}.jsonl"
        assert [e["seq"] for e in events] == list(range(1, len(events) + 1))
    assert oct(folder.stat().st_mode & 0o777) == "0o700"


def test_session_start_has_env_args_and_collected_list(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_a():\n    pass\ndef test_b():\n    pass\n")
    destination = tmp_path / "events.jsonl"
    run_pytest(tmp_path, "--menu-events", destination, "-k", "test_a", "test_ok.py",
               extra_env={"PMH_ENV_ID": "env-a"})
    events = read_events(destination)
    start = events[0]
    assert start["env"]["id"] == "env-a"
    assert start["env"]["python_version"] == sys.version.split()[0]
    assert Path(start["env"]["python_path"]).is_absolute()
    assert start["env"]["pytest_version"] and "plugin_version" in start["env"]
    assert "-k" in start["args"] and "test_a" in start["args"]
    collected = next(e for e in events if e["event"] == "session_collected")
    assert collected["nodeids"] == ["test_ok.py::test_a"]


def test_env_id_defaults_to_prefix_hash(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    pass\n")
    destination = tmp_path / "events.jsonl"
    run_pytest(tmp_path, "--menu-events", destination, "test_ok.py")
    env_id = read_events(destination)[0]["env"]["id"]
    assert len(env_id) == 12 and int(env_id, 16) >= 0


def test_disable_switch_writes_nothing(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    pass\n")
    result = run_pytest(tmp_path, "test_ok.py", extra_env={"PYTEST_MENU_DISABLE": "1"})
    assert result.returncode == 0
    assert not (tmp_path / ".isolated-events").exists()


def test_interrupt_records_reason(tmp_path):
    (tmp_path / "test_stop.py").write_text("def test_stop():\n    raise KeyboardInterrupt()\n")
    destination = tmp_path / "events.jsonl"
    run_pytest(tmp_path, "--menu-events", destination, "test_stop.py")
    interrupted = next(e for e in read_events(destination) if e["event"] == "session_interrupted")
    assert interrupted["reason"] == "keyboard_interrupt"


def test_autoload_via_entry_point(tmp_path):
    from importlib.metadata import entry_points
    found = entry_points()
    group = found.select(group="pytest11") if hasattr(found, "select") else found.get("pytest11", [])
    names = [e.name for e in group]
    if "pytest_menu_helper.plugin" not in names:
        import pytest
        pytest.skip("패키지가 설치되지 않아 pytest11 entry point가 없습니다")
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    pass\n")
    env = os.environ.copy()
    env.pop("PYTEST_DISABLE_PLUGIN_AUTOLOAD", None)
    env.pop("PYTEST_MENU_DISABLE", None)
    env["PYTEST_MENU_EVENTS_DIR"] = str(tmp_path / "auto")
    result = subprocess.run([sys.executable, "-m", "pytest", "-p", "no:cacheprovider", "test_ok.py"],
                            cwd=tmp_path, env=env, text=True, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    files = list((tmp_path / "auto").glob("*.jsonl"))
    assert len(files) == 1
    assert read_events(files[0])[-1]["event"] == "session_finish"
    # 같은 모듈을 -p로 다시 지정해도 중복 등록 오류가 없어야 한다.
    again = subprocess.run([sys.executable, "-m", "pytest", "-p", "no:cacheprovider",
                            "-p", "pytest_menu_helper.plugin", "test_ok.py"],
                           cwd=tmp_path, env=env, text=True, capture_output=True, timeout=30)
    assert again.returncode == 0, again.stdout + again.stderr


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


def test_pmh_run_id_is_used_for_run_and_file_name(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    assert True\n")
    wanted = "3f2b8c1e-9d4a-4e6b-8a7c-1b2c3d4e5f60"
    assert run_pytest(tmp_path, "test_ok.py", extra_env={"PMH_RUN_ID": wanted}).returncode == 0
    files = list((tmp_path / ".isolated-events").glob("*.jsonl"))
    assert [f.name for f in files] == [f"{wanted}.jsonl"]
    assert assert_common(read_events(files[0]), tmp_path) == wanted


def test_pmh_run_id_uppercase_uuid_is_normalized(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    assert True\n")
    wanted = "3F2B8C1E-9D4A-4E6B-8A7C-1B2C3D4E5F60"
    assert run_pytest(tmp_path, "test_ok.py", extra_env={"PMH_RUN_ID": wanted}).returncode == 0
    names = [f.name for f in (tmp_path / ".isolated-events").glob("*.jsonl")]
    assert names == [f"{wanted.lower()}.jsonl"]


def test_app_variables_are_not_inherited_by_nested_pytest(tmp_path):
    """앱 변수(PMH_RUN_ID, PMH_ENV_ID)가 테스트 코드와 자식 프로세스에 남지 않는지 본다.

    회귀 방지: 예전에는 테스트 안에서 pytest를 다시 실행하면 자식이 같은 실행 ID로
    같은 파일에 이벤트를 섞어 써서 앱 집계가 틀어졌다. 값은 바깥 실행 기록에만 쓰여야 한다.
    """
    (tmp_path / "test_env.py").write_text(
        "import os\n\n"
        "def test_app_variables_removed():\n"
        "    assert 'PMH_RUN_ID' not in os.environ\n"
        "    assert 'PMH_ENV_ID' not in os.environ\n"
    )
    wanted = "3f2b8c1e-9d4a-4e6b-8a7c-1b2c3d4e5f60"
    result = run_pytest(tmp_path, "test_env.py",
                        extra_env={"PMH_RUN_ID": wanted, "PMH_ENV_ID": "env-a"})
    assert result.returncode == 0, result.stdout + result.stderr
    events = read_events(tmp_path / ".isolated-events" / f"{wanted}.jsonl")
    # 지우기 전에 읽은 값은 바깥 실행 기록에 그대로 남아야 한다.
    assert assert_common(events, tmp_path) == wanted
    assert events[0]["env"]["id"] == "env-a"


def test_invalid_pmh_run_id_is_ignored(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    assert True\n")
    folder = tmp_path / ".isolated-events"
    bad_values = ["../../evil", "not-a-uuid", "3f2b8c1e9d4a4e6b8a7c1b2c3d4e5f60",
                  "{3f2b8c1e-9d4a-4e6b-8a7c-1b2c3d4e5f60}", "urn:uuid:3f2b8c1e-9d4a-4e6b-8a7c-1b2c3d4e5f60"]
    for bad in bad_values:
        assert run_pytest(tmp_path, "test_ok.py", extra_env={"PMH_RUN_ID": bad}).returncode == 0
    files = list(folder.glob("*.jsonl"))
    assert len(files) == len(bad_values)
    for file in files:
        run_id = assert_common(read_events(file), tmp_path)
        assert file.name == f"{run_id}.jsonl"
        assert run_id.replace("-", "") not in [b.replace("-", "") for b in bad_values]
    assert not (tmp_path / "evil.jsonl").exists()


# 6단계: 공통 설정 파일과 다른 터미널 실행 감지용 필드


def _write_config(home, content):
    """HOME 아래 앱 기준 폴더에 config.json을 쓴다. content가 str이면 그대로(깨진 JSON 확인용) 쓴다."""
    base = home / "Library" / "Application Support" / "pytest-menu-helper"
    base.mkdir(parents=True, exist_ok=True)
    text = content if isinstance(content, str) else json.dumps(content)
    (base / "config.json").write_text(text, encoding="utf-8")
    return base


def test_config_file_sets_events_dir_without_environment_variable(tmp_path):
    """이미 열린 터미널처럼 PYTEST_MENU_EVENTS_DIR가 없을 때 공통 설정 파일의 폴더에 쓰는지 본다."""
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    pass\n")
    home = tmp_path / "home"
    target = tmp_path / "shared-events"
    _write_config(home, {"events_dir": str(target)})
    result = run_pytest(tmp_path, "test_ok.py", extra_env={"HOME": str(home)},
                        drop_env=("PYTEST_MENU_EVENTS_DIR",))
    assert result.returncode == 0, result.stdout + result.stderr
    assert len(list(target.glob("*.jsonl"))) == 1
    # 설정이 있으면 기본 폴더에는 쓰지 않는다.
    assert not (home / "Library" / "Application Support" / "pytest-menu-helper" / "events").exists()


def test_environment_variable_beats_config_file(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    pass\n")
    home = tmp_path / "home"
    _write_config(home, {"events_dir": str(tmp_path / "from-config")})
    assert run_pytest(tmp_path, "test_ok.py", extra_env={"HOME": str(home)}).returncode == 0
    assert len(list((tmp_path / ".isolated-events").glob("*.jsonl"))) == 1
    assert not (tmp_path / "from-config").exists()


def test_invalid_config_falls_back_to_default_folder(tmp_path):
    """깨진 JSON, 상대 경로, 문자열 아닌 값은 모두 무시하고 기본 폴더를 쓴다(앱과 같은 규칙)."""
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    pass\n")
    for index, content in enumerate(["{broken", {"events_dir": "relative/events"}, {"events_dir": 3}, [],
                                     {"events_dir": "~nobody/events"}]):
        home = tmp_path / f"home{index}"
        base = _write_config(home, content)
        result = run_pytest(tmp_path, "test_ok.py", extra_env={"HOME": str(home)},
                            drop_env=("PYTEST_MENU_EVENTS_DIR",))
        assert result.returncode == 0, result.stdout + result.stderr
        assert len(list((base / "events").glob("*.jsonl"))) == 1, content
    assert not (tmp_path / "relative").exists()


def test_config_events_dir_expands_home(tmp_path):
    (tmp_path / "test_ok.py").write_text("def test_ok():\n    pass\n")
    home = tmp_path / "home"
    _write_config(home, {"events_dir": "~/custom-events"})
    result = run_pytest(tmp_path, "test_ok.py", extra_env={"HOME": str(home)},
                        drop_env=("PYTEST_MENU_EVENTS_DIR",))
    assert result.returncode == 0, result.stdout + result.stderr
    assert len(list((home / "custom-events").glob("*.jsonl"))) == 1


def test_session_start_records_pid_invocation_dir_and_prefix(tmp_path):
    """앱이 외부 실행을 연결·생존 확인하는 데 쓰는 필드(pid, invocation_dir, env.prefix)를 본다."""
    sub = tmp_path / "pkg"
    sub.mkdir()
    (sub / "test_ok.py").write_text("def test_ok():\n    pass\n")
    destination = tmp_path / "events.jsonl"
    env = os.environ.copy()
    env.update({"PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1",
                "PYTHONPATH": os.pathsep.join([str(ROOT / "src"), env.get("PYTHONPATH", "")])})
    env.pop("PMH_PARENT_RUN_ID", None)
    process = subprocess.Popen(
        [sys.executable, "-m", "pytest", "--rootdir", str(tmp_path), "-p", "no:cacheprovider",
         "-p", "pytest_menu_helper.plugin", "--menu-events", str(destination), "test_ok.py"],
        cwd=sub, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    process.communicate(timeout=30)
    assert process.returncode == 0
    start = read_events(destination)[0]
    assert start["pid"] == process.pid
    # rootdir(project_root)는 tmp_path지만 실행한 폴더는 하위 폴더다. 둘을 따로 기록해야 한다.
    assert start["invocation_dir"] == os.path.realpath(sub)
    assert start["project_root"] == str(tmp_path.resolve())
    assert start["parent_run_id"] is None
    assert start["env"]["prefix"] == os.path.realpath(sys.prefix)


def test_nested_pytest_records_parent_run_id(tmp_path):
    """테스트 안에서 다시 띄운 pytest는 바깥 실행 ID를 parent_run_id로 남긴다.

    앱은 이 값이 있는 실행을 터미널 실행으로 보여 주지 않는다. 빠뜨리면 바깥 실행의 테스트가 띄운 pytest가
    같은 환경의 "외부 실행"으로 보여 결과를 덮어쓴다.
    """
    inner = tmp_path / "inner"
    inner.mkdir()
    (inner / "test_inner.py").write_text("def test_inner():\n    pass\n")
    (tmp_path / "test_outer.py").write_text(
        "import os, subprocess, sys\n\n"
        "def test_outer():\n"
        f"    inner = {str(inner)!r}\n"
        "    subprocess.run([sys.executable, '-m', 'pytest', '-p', 'no:cacheprovider',\n"
        "                    '-p', 'pytest_menu_helper.plugin', '--rootdir', inner, inner], check=True)\n"
    )
    wanted = "3f2b8c1e-9d4a-4e6b-8a7c-1b2c3d4e5f60"
    result = run_pytest(tmp_path, "test_outer.py", extra_env={"PMH_RUN_ID": wanted})
    assert result.returncode == 0, result.stdout + result.stderr
    files = {f.name: read_events(f) for f in (tmp_path / ".isolated-events").glob("*.jsonl")}
    assert len(files) == 2
    outer = files.pop(f"{wanted}.jsonl")
    assert outer[0]["parent_run_id"] is None
    nested = next(iter(files.values()))
    assert nested[0]["parent_run_id"] == wanted
    assert nested[0]["run_id"] != wanted
