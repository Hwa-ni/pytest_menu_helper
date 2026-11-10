"""Demo only: the second test intentionally fails."""

from fastapi.testclient import TestClient

from app import app

client = TestClient(app)


def test_health_passes():
    assert client.get("/health").json() == {"status": "ok"}


def test_health_intentionally_fails():
    assert client.get("/health").json() == {"status": "unhealthy"}
