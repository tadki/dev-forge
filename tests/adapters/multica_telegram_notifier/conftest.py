"""Fixtures for the Multica → Telegram notifier suite."""

import pytest

from multica_notifier_fakes import FakeMulticaWS, FakeTelegram


@pytest.fixture
def fake_multica():
    server = FakeMulticaWS()
    yield server
    server.close()


@pytest.fixture
def fake_telegram():
    server = FakeTelegram()
    yield server
    server.close()
