# multi_env_demo

여러 가상환경에서 **같은 테스트를 동시에** 돌릴 때를 보여 주는 9단계 샘플입니다. 두 가지를 확인합니다.

- 환경에 따라 결과가 갈리는 테스트: Python 3.9에서만 1건 실패하고, 3.10 이상은 모두 통과합니다.
- 동시 실행 때 공유 자원(파일·포트·SQLite·pytest 캐시)을 어떻게 써야 서로 부딪히지 않는지.

| 파일 | 내용 | 기본 실행 |
|---|---|---|
| `test_version.py` | `zip(..., strict=True)`. 3.9에서 TypeError로 **테스트 실패**(수집 오류 아님) | 포함 |
| `test_shared.py` | 바른 예: `tmp_path`, 포트 0 바인딩, 환경마다 다른 SQLite 파일 | 포함 |
| `test_shared_bad.py` | 나쁜 예: 고정 파일 이름, 고정 포트(48765), 고정 SQLite 파일 | **빠짐**(`conflict` 표식) |

테스트마다 약 1초 걸려 동시 실행이 눈에 보입니다. 기본 실행은 6건, 약 6초입니다.

## 실행

```sh
cd examples/multi_env_demo
~/.venvs/pmh-3.9/bin/python -m pytest -q    # 1 failed, 5 passed, 3 deselected
~/.venvs/pmh-3.13/bin/python -m pytest -q   # 6 passed, 3 deselected

# 나쁜 예를 켜서 두 환경을 동시에 실행
for v in 3.9 3.13; do ~/.venvs/pmh-$v/bin/python -m pytest -q -m conflict test_shared_bad.py & done; wait
```

이 폴더의 `pytest.ini`가 설정 파일이자 rootdir입니다. 없으면 저장소 루트 `pyproject.toml`이 설정이 되어 `conflict` 표식 등록과 기본 제외를 저장소 설정에 넣어야 하고, `.pytest_cache`도 저장소 루트를 함께 쓰게 됩니다. 저장소 루트에서 `pytest examples/multi_env_demo`로 실행해도 이 폴더의 `pytest.ini`가 쓰입니다(확인함). 저장소 루트에서 인수 없이 `pytest`만 실행하면 저장소 설정의 `testpaths = ["tests"]` 때문에 이 샘플은 돌지 않습니다.

## 왜 나쁜 예처럼 쓰면 안 되는가

고정 파일 이름·고정 포트·고정 DB 파일은 혼자 돌릴 때는 통과하므로 문제가 숨어 있다가, 여러 환경을 함께 돌리는 순간 **늦게 시작한 쪽만** 실패합니다. 아래 측정처럼 3.9는 통과하고 3.13만 실패하므로 환경 비교 화면에서는 "3.13에서만 실패"로 보여 **버전 차이처럼 오해**하기 쉽지만, 원인은 코드가 아니라 실행끼리 자원을 나눠 쓴 것이고 어느 환경이 실패할지는 시작 시점에 따라 바뀝니다. 테스트는 `tmp_path`처럼 실행마다 다른 폴더, 포트 0(OS가 빈 포트를 고름), 환경·프로세스마다 다른 DB 파일 이름을 써야 환경 비교 결과를 믿을 수 있습니다.

측정(2026-11-17, 나쁜 예를 켜고 3.9와 3.13을 동시에, 5회 반복):

```sh
for i in 1 2 3 4 5; do
  for v in 3.9 3.13; do
    perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' ~/.venvs/pmh-$v/bin/python -m pytest -m conflict -q -p no:cacheprovider test_shared_bad.py > badr-$v.txt 2>&1 &
  done; wait
  echo "round $i: 3.9 [$(tail -1 badr-3.9.txt)] 3.13 [$(tail -1 badr-3.13.txt)]"
done
```

```text
round 1: 3.9 [3 passed in 3.04s] 3.13 [2 failed, 1 passed in 2.04s]
round 2: 3.9 [3 passed in 3.03s] 3.13 [2 failed, 1 passed in 2.04s]
round 3: 3.9 [3 passed in 3.03s] 3.13 [2 failed, 1 passed in 2.04s]
round 4: 3.9 [3 passed in 3.04s] 3.13 [2 failed, 1 passed in 2.04s]
round 5: 3.9 [3 passed in 3.04s] 3.13 [2 failed, 1 passed in 2.05s]
```

3.13 쪽 실패 내용(1회차, `-rA`):

```text
PASSED test_shared_bad.py::test_fixed_sqlite_file_is_locked
FAILED test_shared_bad.py::test_fixed_file_name_is_overwritten - AssertionErr...
FAILED test_shared_bad.py::test_fixed_port_is_already_in_use - OSError: [Errn...
```

SQLite 잠금 충돌은 이 측정에서는 나지 않았습니다. 포트 테스트가 바로 실패해 3.13의 SQLite 테스트가 3.9보다 먼저 시작·종료되어 잠금 시간이 겹치지 않았기 때문입니다. 이처럼 충돌은 타이밍에 따라 일부만 나타납니다. 따로 한 번만 돌리면(3.13 단독) `3 passed`입니다.

## 공유 자원 점검 (.pytest_cache, __pycache__)

같은 프로젝트를 여러 환경에서 동시에 돌릴 때 pytest가 프로젝트 안에 쓰는 캐시가 깨지는지 측정했습니다.

### 측정 방법

한 라운드에 `multi_env_demo`와 `slow_demo`(테스트 5개, 약 10초)를 각각 `pmh-3.9`, `pmh-3.12`, `pmh-3.13`, `pmh-3.13`(같은 환경 한 번 더) 4개로 **동시에** 돌립니다(프로세스 8개). 1~5라운드는 `.pytest_cache`·`__pycache__`를 지우고 시작(캐시 폴더·pyc를 동시에 새로 만듦), 6~10라운드는 지우지 않고 시작(기존 캐시를 동시에 읽고 덮어씀)해 **모두 10라운드**입니다. 라운드마다 종료 코드, 캐시 JSON 파일이 모두 읽히는지, 출력의 warning·traceback·internalerror·could not 줄을 셉니다. 이벤트는 `PYTEST_MENU_EVENTS_DIR`로 임시 폴더에 쓰게 해 앱 이벤트 폴더를 건드리지 않았습니다.

```zsh
cd /Users/kimyohwan/orca/projects/character_api_follow
export PYTEST_MENU_EVENTS_DIR=<임시 폴더>/events
for round in {1..10}; do
  (( round <= 5 )) && rm -rf .pytest_cache examples/multi_env_demo/.pytest_cache \
      examples/multi_env_demo/__pycache__ examples/slow_demo/__pycache__
  pids=()
  for proj in multi_env_demo slow_demo; do
    for tag in 3.9 3.12 3.13 3.13b; do
      perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' ~/.venvs/pmh-${tag%b}/bin/python -m pytest -q -rA examples/$proj > r$round-$proj-$tag.log 2>&1 &
      pids+=($!)
    done
  done
  codes=(); for p in $pids; do wait $p; codes+=($?); done
  # 캐시 JSON 검사: .pytest_cache/v 아래 모든 파일을 json.loads로 읽어 본다.
  # warn: grep -ciE "warning|traceback|internalerror|could not" r$round-*.log
done
```

종료 코드 순서는 multi_env_demo(3.9, 3.12, 3.13, 3.13), slow_demo(3.9, 3.12, 3.13, 3.13)입니다. multi_env_demo의 3.9는 의도한 실패 1건이라 1이 정상입니다.

### 결과 (2026-11-17)

```text
round 1 (cold) exit=[1 0 0 0 0 0 0 0] cache_json=ok warn_lines=0
round 2 (cold) exit=[1 0 0 0 0 0 0 0] cache_json=ok warn_lines=0
round 3 (cold) exit=[1 0 0 0 0 0 0 0] cache_json=ok warn_lines=0
round 4 (cold) exit=[1 0 0 0 0 0 0 0] cache_json=ok warn_lines=0
round 5 (cold) exit=[1 0 0 0 0 0 0 0] cache_json=ok warn_lines=0
round 6 (warm) exit=[1 0 0 0 0 0 0 0] cache_json=ok warn_lines=0
round 7 (warm) exit=[1 0 0 0 0 0 0 0] cache_json=ok warn_lines=5
round 8 (warm) exit=[1 0 0 0 0 0 0 0] cache_json=ok warn_lines=0
round 9 (warm) exit=[1 0 0 0 0 0 0 0] cache_json=ok warn_lines=5
round 10 (warm) exit=[1 0 0 0 0 0 0 0] cache_json=ok warn_lines=0
```

- **실패·손상 없음.** 10라운드(프로세스 80회) 모두 종료 코드가 기대대로였고, `.pytest_cache` JSON이 깨진 채 남은 적이 없습니다. 테스트 결과에 영향을 준 경우도 없습니다.

- **경고 2회는 `.pytest_cache`가 아니라 pytest 임시 폴더 정리 경합입니다.** 7·9라운드에서 multi_env_demo의 3.13 실행 한 곳에 경고가 1건씩 나왔습니다(`warn_lines`는 그 경고가 차지한 출력 줄 수입니다). `tmp_path`가 쓰는 사용자 공용 폴더(`$TMPDIR/pytest-of-<사용자>/`)에서 오래된 폴더를 지우는 정리가 다른 pytest와 겹친 것입니다. 실행 중인 폴더는 잠금 파일로 보호되므로 결과에는 영향이 없고, 경고는 종료 코드를 바꾸지 않습니다.

  ```text
  PytestWarning: (rm_rf) error removing /private/var/folders/.../T/pytest-of-kimyohwan/garbage-b45f4e59-...
  <class 'OSError'>: [Errno 66] Directory not empty: '/private/var/folders/.../T/pytest-of-kimyohwan/garbage-b45f4e59-...'
  ```

- **`.pytest_cache` 내용은 환경끼리 섞입니다(손상이 아니라 공유).** `lastfailed`(마지막 실패 목록)는 환경 구분 없이 한 파일이며, 먼저 읽고 끝날 때 덮어쓰므로 **나중에 끝난 실행의 값이 남습니다.** 그래서 3.9의 실패가 3.13의 `--lf`(마지막 실패만 다시 실행)에 들어옵니다.

  ```text
  $ (3.9와 3.13으로 동시에 기본 실행한 뒤)
  lastfailed: {"test_version.py::test_zip_strict_rejects_uneven_lengths":true}
  $ ~/.venvs/pmh-3.13/bin/python -m pytest --lf
  run-last-failure: rerun previous 1 failure (skipped 2 files)
  ============================== 1 passed in 1.01s ===============================
  ```

  이 3.13 실행이 통과하면서 `lastfailed`가 비워지므로, 이어서 3.9로 `--lf`를 돌리면 3.9의 실패를 모르고 전체를 실행합니다. `--lf`·`--ff`·`--sw`를 환경마다 따로 쓰려면 사용자가 `-o cache_dir=.pytest_cache-py39`처럼 환경마다 캐시 폴더를 나누거나 `-p no:cacheprovider`로 끕니다. 앱은 사용자 환경을 바꾸지 않는다는 원칙에 따라 이 설정을 몰래 넣지 않습니다.

- **손상이 안 보였다고 안전이 보장되지는 않습니다.** pytest(8.4.2, 9.2.0 모두)는 캐시 값을 임시 파일 없이 그 자리에 덮어쓰고(`Cache.set`), 읽다가 JSON이 깨져 있으면 **경고 없이 빈 값으로 취급**합니다(`Cache.get`). 동시 쓰기가 정확히 겹치면 `lastfailed`가 말없이 사라질 수 있다는 뜻입니다. 결과 판정에는 쓰이지 않는 캐시라 테스트 결과는 바뀌지 않습니다.

- **`__pycache__`는 문제 없음.** pytest의 assert 재작성 pyc 이름에 Python·pytest 버전이 들어가(`test_version.cpython-313-pytest-9.2.0.pyc`) 버전이 다른 환경은 다른 파일을 씁니다. 같은 이름을 쓰는 같은 환경 2개 동시 실행(3.13 두 번)도 10라운드 모두 문제가 없었습니다. pytest가 `<pyc>.<pid>` 임시 파일에 쓴 뒤 `os.replace`로 바꾸기 때문입니다.

- **이 Mac의 3.9는 `__pycache__`를 쓰지 않습니다.** `pmh-3.9`의 기반 Python(Command Line Tools 3.9.6)은 `sys.pycache_prefix`가 `~/Library/Caches/com.apple.python`이라 pyc를 프로젝트 밖(`~/Library/Caches/com.apple.python/<프로젝트 경로>/...cpython-39-pytest-8.4.2.pyc`)에 씁니다. 그래서 측정 뒤 프로젝트 `__pycache__`에는 3.12·3.13 파일만 있습니다.

- **`slow_demo`의 캐시 위치.** `slow_demo`에는 자체 설정 파일이 없어 rootdir가 저장소 루트가 되고, `.pytest_cache`도 저장소 루트의 것을 씁니다(저장소 `tests/` 실행과 같은 캐시). 측정 전 저장소 루트 `.pytest_cache`를 백업했다가 측정 뒤 되돌렸습니다.
