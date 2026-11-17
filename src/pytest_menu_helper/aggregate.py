"""테스트 단계 이벤트를 실행 단위 결과로 집계한다."""

from __future__ import annotations

import json
from collections import Counter
from typing import Any, Iterable


CATEGORIES = ("passed", "failed", "error", "skipped", "xfailed", "xpassed", "incomplete")
# counts에만 들어가는 항목. 테스트 하나의 상태(status)가 아니라
# "수집됐는데 결과 이벤트가 하나도 없는 테스트 수"라서 CATEGORIES와 따로 둔다.
# 중지(Ctrl+C), -x 같은 조기 종료 때 수집 수와 합계가 안 맞는 이유를 보여 주려는 값이다.
COUNT_KEYS = CATEGORIES + ("not_run",)


def _not_run(collected_nodeids: list[str] | None, finish: dict[str, Any] | None,
             reported: set[str]) -> tuple[int, list[str]]:
    """수집됐지만 결과 이벤트가 전혀 없는 테스트의 수와 nodeid 목록을 구한다.

    매개변수:
        collected_nodeids: session_collected 이벤트의 nodeids. v1 이벤트처럼 없으면 None.
        finish: session_finish 이벤트. 아직 끝나지 않았으면 None.
        reported: setup·call·teardown 중 한 단계라도 보고된 nodeid 집합.
    반환값:
        (미실행 수, 미실행 nodeid 목록). 목록은 수집 순서를 따른다.
        수집 목록 없이 수만 알 때는 목록이 비어 있다.
    """
    if collected_nodeids is not None:
        # 같은 nodeid가 occurrence로 여러 번 돌 수 있어 nodeid 기준으로만 본다.
        # 한 번이라도 단계가 보고됐으면 미실행이 아니라 incomplete 쪽에서 센다(이중 집계 방지).
        missing = [node for node in collected_nodeids if node not in reported]
        return len(missing), missing
    collected = finish.get("collected") if finish else None
    if type(collected) is int:
        # 수집 목록이 없는 이전 이벤트는 수만 비교할 수 있다. 음수가 되지 않게 0으로 막는다.
        return max(0, collected - len(reported)), []
    # 수집 정보가 전혀 없으면 알 수 없으므로 0으로 둔다(없는 미실행을 지어내지 않는다).
    return 0, []


def aggregate(events: Iterable[dict[str, Any]], *, process_running: bool = False) -> dict[str, Any]:
    """한 실행의 이벤트를 집계한다. 미완료 실행은 호출자가 프로세스 상태를 전달한다."""
    rows = list(events)
    if not rows:
        return {"state": "waiting", "verdict": None, "run_id": None,
                "counts": dict.fromkeys(COUNT_KEYS, 0), "tests": [], "not_run": [],
                "collection_errors": []}
    first = rows[0]
    run_id, root = first.get("run_id"), first.get("project_root")
    if not run_id or not root or first.get("event") != "session_start":
        raise ValueError("실행 시작 이벤트가 필요합니다")
    reports: dict[tuple[str, int], dict[str, dict[str, Any]]] = {}
    errors = []
    finish = None
    interrupted = False
    collected = False
    collected_nodeids: list[str] | None = None
    for index, row in enumerate(rows):
        if row.get("schema_version") not in (1, 2) or row.get("run_id") != run_id or row.get("project_root") != root:
            raise ValueError("서로 다른 실행 또는 지원하지 않는 이벤트가 섞였습니다")
        kind = row.get("event")
        if (index and kind == "session_start") or finish is not None:
            raise ValueError("이벤트 순서가 올바르지 않습니다")
        if kind == "test_report":
            node, phase, outcome = row.get("nodeid"), row.get("phase"), row.get("outcome")
            if not isinstance(node, str) or phase not in ("setup", "call", "teardown") or outcome not in ("passed", "failed", "skipped"):
                raise ValueError("유효하지 않은 테스트 결과입니다")
            occurrence = row.get("occurrence", 1)
            if type(occurrence) is not int or occurrence < 1:
                raise ValueError("유효하지 않은 테스트 실행 번호입니다")
            phases = reports.setdefault((node, occurrence), {})
            if phase in phases:
                raise ValueError("중복된 테스트 단계입니다")
            phases[phase] = row
        elif kind == "collection_error":
            errors.append(row)
        elif kind == "session_interrupted":
            interrupted = True
        elif kind == "session_finish":
            finish = row
        elif kind == "session_collected":
            if collected:
                raise ValueError("수집 목록 이벤트가 중복되었습니다")
            collected = True
            nodeids = row.get("nodeids")
            # 목록 형식이 아니면 미실행 계산에 쓰지 않고 finish.collected로 대신 센다.
            if isinstance(nodeids, list) and all(isinstance(n, str) for n in nodeids):
                collected_nodeids = nodeids
        elif kind != "session_start":
            raise ValueError("지원하지 않는 이벤트 종류입니다")

    tests = []
    for (node, occurrence), phases in reports.items():
        setup, call, teardown = (phases.get(k) for k in ("setup", "call", "teardown"))
        phase_error = any(r and r["outcome"] == "failed" for r in (setup, teardown))
        if setup is None or teardown is None:
            status = "incomplete"
        elif phase_error:
            status = "error"
        elif call and call["outcome"] == "failed":
            failure = call.get("failure") or {}
            if "strict_xpass" not in call and str(failure.get("message", "")).startswith("[XPASS(strict)]"):
                status = "incomplete"
            else:
                status = "xpassed" if call.get("strict_xpass") is True else "failed"
        elif any(r and r.get("wasxfail") is not None for r in (setup, call, teardown)):
            xreport = next(r for r in (setup, call, teardown) if r and r.get("wasxfail") is not None)
            status = "xpassed" if xreport["outcome"] == "passed" else "xfailed"
        elif any(r and r["outcome"] == "skipped" for r in (setup, call, teardown)):
            status = "skipped"
        elif setup and call and teardown and all(r["outcome"] == "passed" for r in (setup, call, teardown)):
            status = "passed"
        else:
            status = "incomplete"
        tests.append({"nodeid": node, "occurrence": occurrence, "status": status, "phases": phases})
    counts = dict.fromkeys(COUNT_KEYS, 0)
    counts.update(Counter(test["status"] for test in tests))
    counts["not_run"], not_run = _not_run(collected_nodeids, finish, {node for node, _ in reports})
    if finish is None:
        state = "running" if process_running else "incomplete"
    elif errors:
        state = "collection_error"
    elif interrupted:
        state = "interrupted"
    elif finish.get("exit_code") == 5:
        state = "no_tests"
    elif finish.get("exit_code") not in (0, 1):
        state = "incomplete"
    # 일부 단계만 보고된 테스트가 있으면 실패가 함께 있어도 미완료로 둔다.
    # 이런 테스트는 판정 자체가 확정되지 않았고(teardown 누락, 이전 이벤트의 strict xpass 모호성 등)
    # 이벤트 기록이 중간에 끊겼을 가능성도 있어 "실패로 끝난 실행"이라고 단정할 근거가 없다.
    # 이 검사를 아래 조기 종료 규칙보다 먼저 두어야 한다. 순서를 바꾸면 끊긴 기록이 실패 판정으로 덮인다.
    elif counts["incomplete"]:
        state = "incomplete"
    # -x, --maxfail처럼 실패 때문에 pytest가 스스로 멈춘 실행은 실패로 끝난 완료 실행으로 본다.
    # 조건: 정상 종료(session_finish 있음, 중단·수집 오류 아님은 위 분기에서 이미 걸렀다),
    # 종료 코드 1, 실패 또는 오류가 1건 이상. 이때 남은 테스트는 counts.not_run과 not_run 목록에
    # 그대로 남아 화면이 "몇 건이 실행되지 않았는지" 보여 줄 수 있다.
    # 종료 코드 1을 꼭 확인하는 이유: 0이면 pytest가 실패를 보고하지 않았다는 뜻이라 이벤트와 어긋나고,
    # 그 밖의 코드는 위에서 이미 미완료로 처리했지만 조건을 명시해 두면 분기 순서가 바뀌어도 안전하다.
    elif finish.get("exit_code") == 1 and (counts["failed"] or counts["error"]):
        state = "completed"
    # 실패·오류 없이 미실행만 남았다면 pytest가 실패로 멈춘 것이 아니므로(기록 누락 등) 완료로 보지 않는다.
    # 수집 수와 결과 수가 다르면(재실행 occurrence가 우연히 맞춘 경우 제외) 역시 미완료다.
    elif counts["not_run"] or finish.get("collected") != len(tests):
        state = "incomplete"
    else:
        state = "completed"
    verdict = None
    if state == "completed":
        if counts["failed"] or counts["error"]:
            verdict = "failed"
        elif finish["exit_code"] != 0:
            verdict = "attention"
        elif counts["passed"] and not any(counts[k] for k in CATEGORIES if k != "passed"):
            verdict = "passed"
        else:
            verdict = "attention"
    return {"state": state, "verdict": verdict, "run_id": run_id, "project_root": root,
            "env": first.get("env"),
            "exit_code": finish.get("exit_code") if finish else None,
            "counts": counts, "tests": tests, "not_run": not_run, "collection_errors": errors}


def read_jsonl(path: str) -> dict[str, Any]:
    """여러 실행이 이어진 JSONL의 마지막 실행을 읽는다."""
    rows = []
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            if not line.strip():
                continue
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError("이벤트는 JSON 객체여야 합니다")
            if row.get("event") == "session_start":
                rows = []
            rows.append(row)
    return aggregate(rows)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="마지막 pytest 실행 결과를 집계합니다")
    parser.add_argument("path", help="수집된 JSONL 파일")
    args = parser.parse_args()
    print(json.dumps(read_jsonl(args.path), ensure_ascii=False, indent=2))
