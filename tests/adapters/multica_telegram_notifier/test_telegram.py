"""§SPEC-002: Telegram sendMessage normal/error paths, result validation and
text limits; the bot token never appears in raised error messages."""

import pytest

from multica_telegram_notifier.telegram import (
    TelegramClient,
    TelegramError,
    _error_detail,
)

from multica_notifier_fakes import FakeTelegram

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


class TestSendInvalidResult:
    def test_non_object_result_raises_telegram_error_not_attribute_error(self, fake_telegram):
        # A broken/malicious proxy answering ok:true with a non-object result
        # must surface as TelegramError, never crash the caller.
        fake_telegram.responses = [(200, {"ok": True, "result": "nope"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.retryable is True
        assert exc.value.is_channel_error is True
        assert BOT not in str(exc.value)

    def test_missing_result_raises_telegram_error(self, fake_telegram):
        fake_telegram.responses = [(200, {"ok": True})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError):
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)

    def test_numeric_result_raises_telegram_error(self, fake_telegram):
        fake_telegram.responses = [(200, {"ok": True, "result": 123})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError):
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)


class TestTextLengthLimit:
    def test_long_text_truncated_to_telegram_limit(self, fake_telegram):
        client, retries, sleep = make_client(fake_telegram.base_url)
        result = client.send_message(42, "x" * 5000, retries=retries, sleep=sleep)
        assert result == {"message_id": 4242}
        _path, body = fake_telegram.requests[0]
        assert len(body["text"]) == 4096
        assert set(body["text"]) == {"x"}

    def test_text_at_limit_unchanged(self, fake_telegram):
        client, retries, sleep = make_client(fake_telegram.base_url)
        client.send_message(42, "y" * 4096, retries=retries, sleep=sleep)
        _path, body = fake_telegram.requests[0]
        assert body["text"] == "y" * 4096

    def test_non_bmp_heavy_text_truncated_by_utf16_units(self, fake_telegram):
        # 3000 emoji = 3000 Python chars but 6000 UTF-16 units: a codepoint
        # cut alone would still exceed Telegram's limit.
        client, retries, sleep = make_client(fake_telegram.base_url)
        client.send_message(42, "🚀" * 3000, retries=retries, sleep=sleep)
        _path, body = fake_telegram.requests[0]
        assert len(body["text"].encode("utf-16-le")) // 2 == 4096
        assert len(body["text"]) == 2048

    def test_text_at_utf16_limit_unchanged(self, fake_telegram):
        client, retries, sleep = make_client(fake_telegram.base_url)
        client.send_message(42, "🚀" * 2048, retries=retries, sleep=sleep)
        _path, body = fake_telegram.requests[0]
        assert body["text"] == "🚀" * 2048

    def test_mixed_text_truncated_at_utf16_boundary(self, fake_telegram):
        # 4000 ASCII + 100 emoji = 4200 UTF-16 units → cut to 4096.
        client, retries, sleep = make_client(fake_telegram.base_url)
        client.send_message(42, "a" * 4000 + "🚀" * 100, retries=retries, sleep=sleep)
        _path, body = fake_telegram.requests[0]
        assert len(body["text"].encode("utf-16-le")) // 2 == 4096
        assert body["text"].startswith("a" * 4000)

    def test_lone_surrogate_does_not_crash_and_is_dropped(self, fake_telegram):
        # A lone surrogate (e.g. from upstream "\ud800" escapes) must not
        # blow up the UTF-16 encode inside truncation — it is dropped.
        client, retries, sleep = make_client(fake_telegram.base_url)
        result = client.send_message(42, "hi \ud800 there", retries=retries, sleep=sleep)
        assert result == {"message_id": 4242}
        _path, body = fake_telegram.requests[0]
        assert "hi  there" == body["text"]
        assert "\ud800" not in body["text"]

    def test_lone_surrogate_with_emoji_truncated_safely(self, fake_telegram):
        client, retries, sleep = make_client(fake_telegram.base_url)
        client.send_message(42, "🚀" * 3000 + "\udfff", retries=retries, sleep=sleep)
        _path, body = fake_telegram.requests[0]
        assert len(body["text"].encode("utf-16-le")) // 2 == 4096
        assert "\udfff" not in body["text"]


class TestErrorClassification:
    def test_http_401_is_channel_error(self, fake_telegram):
        fake_telegram.responses = [(401, {"ok": False, "error_code": 401,
                                          "description": "Unauthorized"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.is_channel_error is True
        assert exc.value.retryable is False

    def test_http_403_blocked_bot_is_channel_error(self, fake_telegram):
        fake_telegram.responses = [(403, {"ok": False, "error_code": 403,
                                          "description": "Forbidden: bot was blocked by the user"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.is_channel_error is True

    def test_http_404_is_channel_error(self, fake_telegram):
        fake_telegram.responses = [(404, {"ok": False, "error_code": 404,
                                          "description": "Not Found"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.is_channel_error is True

    def test_http_400_is_message_level(self, fake_telegram):
        fake_telegram.responses = [(400, {"ok": False, "error_code": 400,
                                          "description": "Bad Request: message text is empty"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.is_channel_error is False
        assert exc.value.retryable is False

    def test_server_error_is_retryable_not_channel(self, fake_telegram):
        fake_telegram.responses = [(500, {"ok": False, "error_code": 500,
                                          "description": "internal error"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.retryable is True
        assert exc.value.is_channel_error is False

    def test_network_error_is_channel_and_retryable(self):
        client = TelegramClient("http://127.0.0.1:1", BOT, timeout=1.0)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.retryable is True
        assert exc.value.is_channel_error is True

    def test_http_200_ok_false_with_channel_code_is_channel_error(self, fake_telegram):
        # Some proxies/relays answer HTTP 200 with ok:false in the body; the
        # channel/message classification must match the HTTP-status path.
        fake_telegram.responses = [(200, {"ok": False, "error_code": 401,
                                          "description": "Unauthorized"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.is_channel_error is True
        assert exc.value.retryable is False

    def test_http_200_ok_false_with_400_is_message_level(self, fake_telegram):
        fake_telegram.responses = [(200, {"ok": False, "error_code": 400,
                                          "description": "Bad Request: message text is empty"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.is_channel_error is False
        assert exc.value.retryable is False

    def test_http_200_ok_false_429_is_retryable(self, fake_telegram):
        # 429 in an ok:false body must inherit the RETRYABLE_HTTP treatment
        # of the HTTP-status path (contrast: 401 body above is not retryable).
        fake_telegram.responses = [(200, {"ok": False, "error_code": 429,
                                          "description": "Too Many Requests: retry after 3"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.retryable is True
        assert exc.value.is_channel_error is False

    def test_http_200_ok_false_500_is_retryable(self, fake_telegram):
        fake_telegram.responses = [(200, {"ok": False, "error_code": 500,
                                          "description": "internal server error"})]
        client, _retries, _sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.retryable is True

    def test_error_code_parsed_into_exception(self, fake_telegram):
        fake_telegram.responses = [(400, {"ok": False, "error_code": 400,
                                          "description": "Bad Request: chat not found"})]
        client, retries, sleep = make_client(fake_telegram.base_url)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.error_code == 400
        assert exc.value.retryable is False


# D-1: chat-id discovery/selection is gone by design — the adapter only ever
# writes to the configured NOTIFIER_TELEGRAM_CHAT_ID, so other private chats
# in the bot's updates can never receive Inbox content.


class _BodyExc:
    """Stands in for an urllib HTTPError with a controllable response body."""

    def __init__(self, payload):
        self.payload = payload

    def read(self):
        if isinstance(self.payload, Exception):
            raise self.payload
        return self.payload


class TestErrorDetailTolerance:
    def test_unreadable_body_yields_no_detail(self):
        # exc.read() failing must degrade to (None, ""), never raise out of the
        # error classifier (which would mask the original Telegram failure).
        assert _error_detail(_BodyExc(OSError("socket gone"))) == (None, "")

    def test_non_object_body_yields_no_detail(self):
        # A non-object JSON body carries no error_code/description.
        assert _error_detail(_BodyExc(b"[1, 2, 3]")) == (None, "")


class _RawResponse:
    def __init__(self, body):
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        return False

    def read(self):
        return self._body


class TestInvalidJsonResponse:
    def test_non_json_body_is_retryable_error(self, monkeypatch):
        # An intermediary returning a non-JSON 200 body must surface as a
        # retryable TelegramError, never a raw JSONDecodeError.
        import multica_telegram_notifier.telegram as telegram_mod
        monkeypatch.setattr(telegram_mod.urllib.request, "urlopen",
                            lambda *a, **k: _RawResponse(b"this is not json"))
        client = TelegramClient("http://127.0.0.1:1", BOT, timeout=1.0)
        with pytest.raises(TelegramError) as exc:
            client.send_message(42, "hi", retries=(), sleep=lambda _s: None)
        assert exc.value.retryable is True
        assert "invalid JSON" in str(exc.value)
