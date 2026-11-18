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


def test_stop_after_first_failure_is_failed_with_not_run(tmp_path):
    """-x로 첫 실패에서 멈춘 실제 실행은 미완료가 아니라 실패로 끝난 완료 실행이어야 한다.

    뒤에 남은 테스트는 판정을 바꾸지 않고 counts.not_run과 not_run 목록에만 남는다.
    """
    result, events = run_case(tmp_path, 'def test_fail(): assert False\ndef test_other(): pass\n', '-x')
    assert result.returncode == 1
    summary = aggregate(events)
    assert summary['state'] == 'completed' and summary['verdict'] == 'failed'
    assert summary['counts']['failed'] == 1
    # -x로 멈추면 뒤의 테스트는 결과 이벤트가 없으므로 미실행으로 센다.
    assert summary['counts']['not_run'] == 1
    assert summary['not_run'] == ['test_sample.py::test_other']


MAXFAIL_SOURCE = """import pytest

@pytest.fixture
def broken():
    raise RuntimeError('setup')

def test_first_fail(): assert False
def test_pass(): pass
def test_setup_error(broken): pass
def test_after_a(): pass
def test_after_b(): pass
"""


def test_maxfail_two_counts_error_and_keeps_not_run(tmp_path):
    """--maxfail=2에서 실패 1건과 setup 오류 1건으로 멈춘 실제 실행을 본다.

    pytest는 오류도 maxfail에 세므로 두 번째 문제(오류)에서 멈춘다. 실패·오류가 섞여도
    completed/failed이고, 남은 두 테스트는 수집 순서대로 not_run에 담겨야 한다.
    """
    result, events = run_case(tmp_path, MAXFAIL_SOURCE, '--maxfail=2')
    assert result.returncode == 1
    summary = aggregate(events)
    assert summary['state'] == 'completed' and summary['verdict'] == 'failed'
    assert summary['counts']['failed'] == 1 and summary['counts']['error'] == 1
    assert summary['counts']['passed'] == 1 and summary['counts']['incomplete'] == 0
    assert summary['counts']['not_run'] == 2
    assert summary['not_run'] == ['test_sample.py::test_after_a', 'test_sample.py::test_after_b']


def test_not_run_without_failures_stays_incomplete(tmp_path):
    """실패·오류 없이 미실행만 남은 실행은 여전히 미완료여야 한다.

    실제 -x 실행에서 실패한 테스트의 이벤트를 지워, "종료 코드 1인데 결과에 실패가 없고
    미실행만 있는" 기록(중간 기록 누락과 같은 모양)을 만든다. 실패로 멈췄다는 근거가 없으므로
    조기 종료 규칙이 적용되면 안 된다.
    """
    _, events = run_case(tmp_path, 'def test_fail(): assert False\ndef test_other(): pass\n', '-x')
    without_failure = [e for e in events if e.get('nodeid') != 'test_sample.py::test_fail']
    summary = aggregate(without_failure)
    assert summary['state'] == 'incomplete' and summary['verdict'] is None
    assert summary['counts']['failed'] == 0 and summary['counts']['not_run'] == 2


def test_partial_phases_with_failure_stay_incomplete(tmp_path):
    """실패가 있어도 일부 단계만 보고된 테스트가 섞이면 미완료로 둔다.

    실제 --maxfail=2 실행에서 setup 오류 테스트의 teardown만 지워 counts.incomplete를 1로 만든다.
    판정이 확정되지 않은 테스트가 있으므로 실패로 끝났다고 단정하지 않는다.
    """
    _, events = run_case(tmp_path, MAXFAIL_SOURCE, '--maxfail=2')
    cut = [e for e in events
           if not (e.get('nodeid') == 'test_sample.py::test_setup_error' and e.get('phase') == 'teardown')]
    summary = aggregate(cut)
    assert summary['counts']['failed'] == 1 and summary['counts']['incomplete'] == 1
    assert summary['state'] == 'incomplete' and summary['verdict'] is None


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


# 9단계: 집계 결과에 session_start의 실행 인수(args)를 싣는다.
# 앱의 환경 비교가 환경마다 실행 조건(-k, 경로 지정 등)이 같은지 보려고 쓴다.

def test_args_from_real_run_are_copied_to_summary(tmp_path):
    """실제 pytest 실행의 명령줄 인수가 집계 결과 args에 순서 그대로 들어가는지 본다."""
    result, events = run_case(tmp_path, 'def test_a(): pass\ndef test_b(): pass\n', '-k', 'test_a')
    assert result.returncode == 0
    summary = aggregate(events)
    assert summary['args'] == events[0]['args']
    # run_case가 붙이는 -p, --menu-events 등도 명령줄 인수이므로 함께 남는다. -k 조건이 순서대로 있는지만 본다.
    position = summary['args'].index('-k')
    assert summary['args'][position + 1] == 'test_a'
    assert summary['args'][-1] == str(tmp_path / 'test_sample.py')


def test_args_absent_in_old_events_is_null():
    """args가 없는 옛 이벤트(v1, 또는 v2지만 키가 빠진 파일)는 빈 목록이 아니라 None이어야 한다."""
    base = {'schema_version': 2, 'run_id': 'r', 'project_root': '/p'}
    events = [dict(base, event='session_start'), dict(base, event='session_finish', exit_code=5, collected=0)]
    assert aggregate(events)['args'] is None
    v1 = [dict(event, schema_version=1) for event in events]
    assert aggregate(v1)['args'] is None


@pytest.mark.parametrize('value, expected', [
    ([], []),                      # 인수 없이 실행: 확인된 빈 목록은 그대로 둔다
    (['-x', 'tests'], ['-x', 'tests']),
    ('-x tests', None),            # 목록이 아니면 알 수 없음
    (['-x', 3], None),             # 문자열이 아닌 원소가 섞이면 알 수 없음
    (None, None),
])
def test_args_shape_is_checked(value, expected):
    """형식이 틀린 args는 집계 오류로 만들지 않고 None으로 둔다. 빈 목록은 None과 구분한다."""
    base = {'schema_version': 2, 'run_id': 'r', 'project_root': '/p'}
    events = [dict(base, event='session_start', args=value),
              dict(base, event='session_finish', exit_code=5, collected=0)]
    summary = aggregate(events)
    assert summary['args'] == expected
    assert summary['state'] == 'no_tests'


def test_waiting_summary_has_null_args():
    """이벤트가 없을 때도 args 키가 있어야 앱 쪽 디코드가 상태마다 달라지지 않는다."""
    assert aggregate([])['args'] is None


def test_cli_json_includes_args(tmp_path):
    """앱이 실제로 부르는 방식(python -I -m pytest_menu_helper.aggregate)의 JSON 출력에 args가 있는지 본다.

    -I(격리 모드)는 PYTHONPATH를 무시하므로 src를 sys.path에 직접 넣고 모듈을 실행한다.
    """
    result, events = run_case(tmp_path, 'def test_a(): pass\n', '-q')
    assert result.returncode == 0
    events_file = tmp_path / 'events.jsonl'
    code = ('import runpy, sys; sys.path.insert(0, sys.argv[1]); sys.argv = sys.argv[1:]; '
            'runpy.run_module("pytest_menu_helper.aggregate", run_name="__main__")')
    output = subprocess.run([sys.executable, '-I', '-c', code, str(ROOT / 'src'), str(events_file)],
                            capture_output=True, text=True, timeout=30, check=True)
    summary = json.loads(output.stdout)
    assert summary['args'] == events[0]['args'] and '-q' in summary['args']
