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
                                  'xfailed': 1, 'xpassed': 2, 'incomplete': 0, 'not_run': 0}
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
    report = next(e for e in events if e['event'] == 'test_report')
    with pytest.raises(ValueError):
        aggregate(events[:1] + [report, report])
    collected = next(e for e in events if e['event'] == 'session_collected')
    with pytest.raises(ValueError):
        aggregate(events[:1] + [collected, collected])


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


def test_v1_events_still_aggregate():
    base = {'schema_version': 1, 'run_id': 'r', 'project_root': '/p', 'timestamp': 't'}
    events = [dict(base, event='session_start'),
              *[dict(base, event='test_report', nodeid='t::a', phase=ph, outcome='passed', wasxfail=None,
                     strict_xpass=False, failure=None) for ph in ('setup', 'call', 'teardown')],
              dict(base, event='session_finish', exit_code=0, collected=1)]
    summary = aggregate(events)
    assert summary['state'] == 'completed' and summary['verdict'] == 'passed'
    assert summary['env'] is None


def test_forced_process_exit_is_incomplete(tmp_path):
    result, events = run_case(tmp_path, 'import os\ndef test_stop(): os._exit(7)\n')
    assert result.returncode == 7
    assert aggregate(events)['state'] == 'incomplete'


def test_same_test_file_selected_twice(tmp_path):
    # pytest 9는 중복 인수를 제거하므로 --keep-duplicates로 버전과 무관하게 두 번 실행시킨다.
    result, events = run_case(tmp_path, 'def test_ok(): pass\n', '--keep-duplicates', str(tmp_path / 'test_sample.py'))
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
    # -x로 멈추면 뒤의 테스트는 결과 이벤트가 없으므로 미실행으로 센다.
    assert summary['counts']['not_run'] == 1
    assert summary['not_run'] == ['test_sample.py::test_other']


def test_interrupt_counts_not_run_tests(tmp_path):
    # 실제 중지(Ctrl+C)와 같은 경로: 두 번째 테스트 도중 KeyboardInterrupt가 나면
    # 첫 테스트는 통과, 두 번째는 단계가 끊겨 incomplete, 세 번째는 시작 전이라 미실행이다.
    result, events = run_case(tmp_path, """def test_a(): pass
def test_b(): raise KeyboardInterrupt
def test_c(): pass
""")
    assert result.returncode == 2
    summary = aggregate(events)
    assert summary['state'] == 'interrupted' and summary['verdict'] is None
    assert summary['counts']['passed'] == 1
    assert summary['counts']['incomplete'] == 1
    assert summary['counts']['not_run'] == 1
    assert summary['not_run'] == ['test_sample.py::test_c']


def test_not_run_falls_back_to_finish_collected_without_nodeids():
    # session_collected가 없는 v1 이벤트는 session_finish의 collected 수로만 센다(목록은 비어 있음).
    base = {'schema_version': 1, 'run_id': 'r', 'project_root': '/p'}
    report = dict(base, event='test_report', nodeid='t.py::a', outcome='passed', wasxfail=None)
    events = [dict(base, event='session_start'),
              *(dict(report, phase=ph) for ph in ('setup', 'call', 'teardown')),
              dict(base, event='session_finish', exit_code=1, collected=3)]
    summary = aggregate(events)
    assert summary['counts']['not_run'] == 2 and summary['not_run'] == []
    assert summary['state'] == 'incomplete'


def test_waiting_summary_has_not_run_key():
    summary = aggregate([])
    assert summary['counts']['not_run'] == 0 and summary['not_run'] == []
