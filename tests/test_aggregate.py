import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from pytest_menu_helper.aggregate import aggregate, read_jsonl

ROOT = Path(__file__).resolve().parents[1]


def run_case(tmp_path, source, *args):
    test_file = tmp_path / 'test_sample.py'
    test_file.write_text(source, encoding='utf-8')
    output = tmp_path / 'events.jsonl'
    env = os.environ.copy()
    env.update(PYTHONPATH=str(ROOT / 'src'), PYTEST_DISABLE_PLUGIN_AUTOLOAD='1', PYTHONDONTWRITEBYTECODE='1')
    result = subprocess.run([sys.executable, '-m', 'pytest', '-p', 'no:cacheprovider',
                             '-p', 'pytest_menu_helper.plugin', '--menu-events', str(output),
                             *args, str(test_file)], cwd=tmp_path, env=env,
                            capture_output=True, text=True, timeout=30)
    events = [json.loads(line) for line in output.read_text().splitlines()]
    return result, events


def test_real_pytest_results_and_phases(tmp_path):
    result, events = run_case(tmp_path, '''import pytest

def test_pass(): pass

def test_fail(): assert False

@pytest.mark.skip(reason="skip")
def test_skip(): pass

@pytest.mark.xfail(reason="known")
def test_xfail(): assert False

@pytest.mark.xfail(reason="unexpected")
def test_xpass(): pass

@pytest.mark.xfail(reason="strict", strict=True)
def test_strict_xpass(): pass

@pytest.fixture
def broken(): raise RuntimeError("setup error")
def test_error(broken): pass

@pytest.fixture
def cleanup_error():
    yield
    raise RuntimeError("teardown error")
def test_teardown_error(cleanup_error): pass
''')
    summary = aggregate(events)
    assert result.returncode == 1
    assert summary['state'] == 'completed' and summary['verdict'] == 'failed'
    assert summary['counts'] == {'passed': 1, 'failed': 1, 'error': 2, 'skipped': 1,
                                  'xfailed': 1, 'xpassed': 2, 'incomplete': 0}
    assert len(summary['tests']) == 8
    assert sum(e['event'] == 'test_report' for e in events) > 8


@pytest.mark.parametrize(('source', 'state', 'verdict', 'exitcode'), [
    ('def test_ok(): pass\n', 'completed', 'passed', 0),
    ('import pytest\n@pytest.mark.skip(reason="s")\ndef test_skip(): pass\n', 'completed', 'attention', 0),
    ('', 'no_tests', None, 5),
    ('import no_such_project_module\n', 'collection_error', None, 2),
    ('def test_stop(): raise KeyboardInterrupt()\n', 'interrupted', None, 2),
])
def test_session_states(tmp_path, source, state, verdict, exitcode):
    result, events = run_case(tmp_path, source)
    summary = aggregate(events)
    assert result.returncode == exitcode
    assert (summary['state'], summary['verdict']) == (state, verdict)


def test_missing_finish_and_invalid_stream(tmp_path):
    _, events = run_case(tmp_path, 'def test_ok(): pass\n')
    assert aggregate(events[:-1])['state'] == 'incomplete'
    assert aggregate(events[:-1], process_running=True)['state'] == 'running'
    assert aggregate([])['state'] == 'waiting'
    with pytest.raises(ValueError):
        aggregate(events + events)
    with pytest.raises(ValueError):
        aggregate(events[:1] + [dict(events[1], run_id='other')])
    with pytest.raises(ValueError):
        aggregate(events[:1] + [events[1], events[1]])


def test_multiple_runs_reader_and_partial_json(tmp_path):
    _, first = run_case(tmp_path, 'def test_ok(): pass\n')
    _, all_events = run_case(tmp_path, 'def test_ok(): pass\n')
    output = tmp_path / 'events.jsonl'
    assert len([e for e in all_events if e['event'] == 'session_start']) == 2
    assert read_jsonl(str(output))['run_id'] != first[0]['run_id']
    with output.open('a') as stream:
        stream.write('{"event":')
    with pytest.raises(json.JSONDecodeError):
        read_jsonl(str(output))


def test_old_ambiguous_exit_two_is_not_claimed_as_interrupt(tmp_path):
    _, events = run_case(tmp_path, 'def test_stop(): raise KeyboardInterrupt()\n')
    old = [row for row in events if row['event'] != 'session_interrupted']
    assert aggregate(old)['state'] == 'incomplete'


def test_strict_xpass_and_legacy_ambiguity(tmp_path):
    result, events = run_case(tmp_path, 'import pytest\n@pytest.mark.xfail(strict=True)\ndef test_x(): pass\n')
    assert result.returncode == 1
    summary = aggregate(events)
    assert summary['counts']['xpassed'] == 1
    assert summary['verdict'] == 'attention'
    old = [dict(row) for row in events]
    for row in old:
        row.pop('strict_xpass', None)
    assert aggregate(old)['state'] == 'incomplete'


def test_missing_teardown_does_not_claim_completion(tmp_path):
    _, events = run_case(tmp_path, 'def test_fail(): assert False\n')
    without_teardown = [e for e in events if e.get('phase') != 'teardown']
    assert aggregate(without_teardown)['state'] == 'incomplete'


def test_forced_process_exit_is_incomplete(tmp_path):
    result, events = run_case(tmp_path, 'import os\ndef test_stop(): os._exit(7)\n')
    assert result.returncode == 7
    assert aggregate(events)['state'] == 'incomplete'


def test_same_test_file_selected_twice(tmp_path):
    result, events = run_case(tmp_path, 'def test_ok(): pass\n', str(tmp_path / 'test_sample.py'))
    assert result.returncode == 0
    summary = aggregate(events)
    assert summary['state'] == 'completed' and summary['verdict'] == 'passed'
    assert summary['counts']['passed'] == 2
    assert [test['occurrence'] for test in summary['tests']] == [1, 2]


def test_stop_after_first_failure_is_incomplete(tmp_path):
    result, events = run_case(tmp_path, 'def test_fail(): assert False\ndef test_other(): pass\n', '-x')
    assert result.returncode == 1
    summary = aggregate(events)
    assert summary['state'] == 'incomplete'
    assert summary['counts']['failed'] == 1
