"""§SPEC-002: Telegram chat-id discovery and sendMessage normal/error paths;
the bot token never appears in raised error messages."""

import pytest

from multica_telegram_notifier.telegram import TelegramClient, TelegramError

from multica_notifier_fakes import FakeTelegram, private_chat_update

BOT = "test-bot-token-value"


def make_client(base_url, retries=(), sleep=None):
    return TelegramClient(base_url, BOT, timeout=5.0), retries, (sleep or (lambda _s: None))


class TestSendMessage:
    def test_success_returns_result(self, fake_telegram):
        client, retries, sleep = make_client(fake_telegram.base_url)
        result = client.send_message(42, "hello", retries=retries, sleep=sleep)
        assert result == {"message_id": 4242}
        path, body = fake_telegram.requests[0]
        assert path == f"/bot{BOT}/sendMessage"
        assert body == {"chat_id": 42, "text": "hello"}

    def test_retryable_failure_then_success(self, fake_telegram):
        fake_telegram.responses = [(500, {"ok": False, "description": "boom"}),
                                   (500, {"ok": False, "description": "boom"})]
        client, retries, sleep = make_client(fake_telegram.base_url)
        sleeps = []
        result = client.send_message(42, "hello", retries=(0.5, 1.0), sleep=sleeps.append)
        assert result == {"message_id": 4242}
        assert len(fake_telegram.requests) == 3
        assert sleeps == [0.5, 1.0]

    def test_retries_exhausted_raises(self, fake_telegram):
        fake_telegram.responses = [
            (500, {"ok": False}), (500, {"ok": False}), (500, {"ok": False}),
        ]
        client, retries, sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError):
            client.send_message(42, "hello", retries=(0.1, 0.1), sleep=lambda _s: None)
        assert len(fake_telegram.requests) == 3

    def test_non_retryable_failure_fails_fast(self, fake_telegram):
        fake_telegram.responses = [(400, {"ok": False, "description": "chat not found"})]
        client, retries, sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError):
            client.send_message(42, "hello", retries=(0.1, 0.1), sleep=lambda _s: None)
        assert len(fake_telegram.requests) == 1

    def test_error_message_carries_no_token(self, fake_telegram):
        fake_telegram.responses = [(500, {"ok": False})]
        client, retries, sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hello", retries=(), sleep=lambda _s: None)
        assert BOT not in str(exc.value)

    def test_network_refused_raises_retryable(self):
        # Port 1 on localhost is never our fake — connection refused path.
        client = TelegramClient("http://127.0.0.1:1", BOT, timeout=1.0)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hello", retries=(), sleep=lambda _s: None)
        assert exc.value.retryable is True
        assert BOT not in str(exc.value)


class TestGetUpdates:
    def test_returns_result_list(self, fake_telegram):
        fake_telegram.responses = [(200, {"ok": True, "result": [private_chat_update(7)]})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        updates = client.get_updates()
        assert updates == [private_chat_update(7)]
        path, _body = fake_telegram.requests[0]
        assert path.endswith("/getUpdates")

    def test_invalid_result_raises(self, fake_telegram):
        fake_telegram.responses = [(200, {"ok": True, "result": "nope"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError):
            client.get_updates()


class TestDiscoverChatId:
    def test_finds_private_chat(self, fake_telegram):
        fake_telegram.responses = [(200, {"ok": True, "result": [private_chat_update(987654)]})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        assert client.discover_chat_id() == 987654

    def test_prefers_most_recent_private_chat(self, fake_telegram):
        updates = [private_chat_update(111), private_chat_update(222)]
        fake_telegram.responses = [(200, {"ok": True, "result": updates})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        assert client.discover_chat_id() == 222

    def test_group_chats_ignored(self, fake_telegram):
        group = {"update_id": 2, "message": {"chat": {"id": 5, "type": "group"}, "text": "hi"}}
        fake_telegram.responses = [(200, {"ok": True, "result": [group]})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.discover_chat_id()
        assert "/start" in str(exc.value)
        assert exc.value.retryable is False
