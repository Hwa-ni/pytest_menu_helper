"""데모·사용자 확인용 느린 샘플(테스트 5개, 약 10초). 실행 중 팝오버 응답성과 중지 동작을 눈으로 볼 때 쓴다.

8단계에서 저장소 밖(~/.pmh-build/slow-sample)에 있던 파일을 테스트 내용 그대로 옮겼다.
"""
import time

import pytest


def test_fast_before():
    assert True


@pytest.mark.parametrize("n", range(1, 4))
def test_slow_ten_seconds_each_part(n):
    # 합계 약 10초. 진행률이 천천히 올라가고, 그동안 메뉴를 열어 볼 수 있다.
    time.sleep(3.3)


def test_fast_after():
    assert True
