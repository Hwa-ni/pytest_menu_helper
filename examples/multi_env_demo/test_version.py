"""Python 버전에 따라 결과가 갈리는 샘플(9단계 다중 환경 비교용).

입력: 없음(pytest가 수집해 실행한다).
출력: Python 3.9에서는 test_zip_strict_rejects_uneven_lengths 하나가 실패하고 나머지는 통과한다.
      Python 3.10 이상에서는 모두 통과한다.

환경 비교 화면이 "한 환경에서만 실패"를 보여 주는지 확인하려는 파일이다.
각 테스트는 동시 실행이 눈에 보이도록 약 1초 걸린다.
"""
import sys
import time

import pytest

# 동시 실행 중 진행 바가 움직이는 것을 볼 수 있게 테스트마다 기다리는 시간(초).
STEP_SECONDS = 1.0


def test_zip_strict_rejects_uneven_lengths():
    """zip(strict=True)가 길이가 다른 입력을 ValueError로 거절하는지 본다.

    zip의 strict 인수는 Python 3.10에서 생겼다. 3.9에서는 zip()이 키워드 인수를 받지 않아
    TypeError가 난다. pytest.raises(ValueError)는 다른 예외를 잡지 않으므로 TypeError가 그대로
    올라와 테스트가 "실패"한다.

    주의: strict=True를 모듈 맨 위(import 시점)에서 쓰면 3.9에서 수집 오류가 되어
    "테스트 실패"가 아니라 "수집 오류"로 보인다. 그래서 반드시 함수 안에서 부른다.
    """
    time.sleep(STEP_SECONDS)
    with pytest.raises(ValueError):
        list(zip([1, 2, 3], ["a", "b"], strict=True))


def test_zip_strict_accepts_equal_lengths():
    """길이가 같으면 3.10 이상에서는 그대로 짝을 짓는다. 3.9에서는 strict를 쓰지 않는 길로 같은 결과를 본다.

    버전 분기를 두는 이유: 이 파일에서 3.9 실패는 위 테스트 1건만 나와야 비교 화면의
    "3.9만 실패 1" 확인이 쉬워진다. 이 테스트는 어느 버전에서나 통과해야 한다.
    """
    time.sleep(STEP_SECONDS)
    if sys.version_info >= (3, 10):
        pairs = list(zip([1, 2], ["a", "b"], strict=True))
    else:
        pairs = list(zip([1, 2], ["a", "b"]))
    assert pairs == [(1, "a"), (2, "b")]


def test_runs_everywhere():
    """버전과 관계없이 통과하는 기준 테스트. 비교 표의 "모두 같음" 줄에 들어간다."""
    time.sleep(STEP_SECONDS)
    assert sorted({3, 1, 2}) == [1, 2, 3]
