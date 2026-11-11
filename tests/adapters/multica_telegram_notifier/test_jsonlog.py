"""§SPEC-002 secret hygiene: redaction and structured JSON logging never
carry the PAT or bot token into logs, exceptions, or fixture text."""

import io
import json

from multica_telegram_notifier.jsonlog import JsonLogger
from multica_telegram_notifier.redact import Redactor

PAT = "test-pat-value-0123456789"
BOT = "test-bot-token-value"


def make_logger(buf, file_path=None):
    return JsonLogger(Redactor([PAT, BOT]), stream=buf, file_path=file_path)


class TestRedactor:
    def test_replaces_all_secrets(self):
        r = Redactor([PAT, BOT])
        out = r.redact(f"auth with {PAT} and bot {BOT} failed")
        assert out == "auth with [REDACTED] and bot [REDACTED] failed"

    def test_short_secrets_ignored(self):
        # Short strings would mangle unrelated log text (e.g. "abc" inside
        # words), so the redactor deliberately skips secrets shorter than 8.
        r = Redactor(["abc"])
        assert r.redact("abcdef") == "abcdef"

    def test_redact_value_recurses(self):
        r = Redactor([PAT])
        out = r.redact_value({"a": [f"leak {PAT}"], "b": 5, "c": None})
        assert out == {"a": ["leak [REDACTED]"], "b": 5, "c": None}

    def test_redact_passes_through_non_strings(self):
        # redact() is also called directly; a non-string must be returned as-is
        # rather than raising on .replace().
        r = Redactor([PAT])
        assert r.redact(123) == 123
        assert r.redact(None) is None


class TestJsonLogger:
    def test_line_shape(self):
        buf = io.StringIO()
        logger = make_logger(buf)
        logger.info("delivered", item_id="i-1", message_id=42)
        rec = json.loads(buf.getvalue().splitlines()[-1])
        assert rec["event"] == "delivered"
        assert rec["level"] == "info"
        assert rec["item_id"] == "i-1"
        assert rec["message_id"] == 42
        assert rec["ts"].endswith("Z")

    def test_secrets_redacted_in_fields(self):
        buf = io.StringIO()
        logger = make_logger(buf)
        logger.warning("session_ended", error=f"token {BOT} rejected at {PAT}")
        assert BOT not in buf.getvalue()
        assert PAT not in buf.getvalue()
        assert "[REDACTED]" in buf.getvalue()

    def test_lone_surrogate_in_field_writes_safely(self, tmp_path):
        # A lone surrogate (upstream "\udXXX" escapes) must not crash the
        # JSONL write after a successful delivery: the line is sanitized
        # once before any sink sees it.
        path = tmp_path / "probe.jsonl"
        logger = make_logger(io.StringIO(), file_path=str(path))
        logger.info("delivered", title="\ud800bad ✈ safe")
        logger.close()
        text = path.read_text(encoding="utf-8")
        assert "\ud800" not in text
        assert "delivered" in text
        assert "safe" in text

    def test_jsonl_file_output(self, tmp_path):
        path = tmp_path / "probe.jsonl"
        buf = io.StringIO()
        logger = make_logger(buf, file_path=str(path))
        logger.info("auth_ok")
        logger.error("auth_rejected", error="invalid token")
        logger.close()
        lines = path.read_text(encoding="utf-8").strip().splitlines()
        assert [json.loads(x)["event"] for x in lines] == ["auth_ok", "auth_rejected"]

    def test_file_parent_dirs_created(self, tmp_path):
        path = tmp_path / "deep" / "nested" / "probe.jsonl"
        logger = make_logger(io.StringIO(), file_path=str(path))
        logger.info("auth_ok")
        logger.close()
        assert path.exists()

    def test_close_is_idempotent(self, tmp_path):
        logger = make_logger(io.StringIO(), file_path=str(tmp_path / "x.jsonl"))
        logger.info("e")
        logger.close()
        logger.close()


class _BrokenStream:
    """A log sink whose write fails — logging must never crash the notifier."""

    def write(self, _text):
        raise OSError("stream gone")

    def flush(self):
        pass


class _BrokenFile:
    """A file-like sink with individually failing operations."""

    def __init__(self, write_error=None, close_error=None):
        self.write_error = write_error
        self.close_error = close_error

    def write(self, _text):
        if self.write_error is not None:
            raise self.write_error
        return len(_text)

    def flush(self):
        pass

    def close(self):
        if self.close_error is not None:
            raise self.close_error


class TestLoggerNeverCrashes:
    # A delivery that already succeeded must not be turned into a crash by a
    # broken log sink: every sink failure is swallowed (§SPEC-002 evidence log
    # is best-effort, never load-bearing).

    def test_broken_stream_write_is_swallowed(self):
        logger = JsonLogger(Redactor([PAT]), stream=_BrokenStream())
        logger.info("delivered", item_id="i-1")  # must not raise

    def test_broken_file_write_is_swallowed(self):
        logger = make_logger(io.StringIO())
        logger._file = _BrokenFile(write_error=OSError("disk full"))
        logger.info("delivered", item_id="i-1")  # must not raise
        logger.close()

    def test_broken_file_close_is_swallowed(self):
        logger = make_logger(io.StringIO())
        logger._file = _BrokenFile(close_error=OSError("close failed"))
        logger.close()  # must not raise
        assert logger._file is None
