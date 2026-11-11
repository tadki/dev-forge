"""§SPEC-004 end-to-end: fake Multica WS → real adapter → fake Telegram API,
covering auth failure, send failure, and retry. Scenario A runs the real CLI
entry (subprocess) exactly as the live-probe judgment command does."""

import io
import json
import os
import subprocess
import sys
import threading

from multica_telegram_notifier.config import load_config
from multica_telegram_notifier.jsonlog import JsonLogger
from multica_telegram_notifier.notifier import EXIT_OK, Notifier, build_components
from multica_telegram_notifier.redact import Redactor
from multica_telegram_notifier.wsclient import WSClient

from multica_notifier_fakes import FakeMulticaWS, make_env, make_inbox_frame

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
PAT = "test-pat-value-0123456789"
BOT = "test-bot-token-value"


def _run_in_thread(notifier):
    result = {}

    def target():
        result["code"] = notifier.run()

    thread = threading.Thread(target=target, daemon=True)
    thread.start()
    thread.join(timeout=15)
    return thread, result


def _build(tmp_path, multica, telegram, env_over=None):
    cfg = load_config(make_env(multica, telegram, tmp_path, **(env_over or {})))
    logger = JsonLogger(Redactor([cfg.multica_pat, cfg.telegram_bot_token]),
                        stream=io.StringIO(), file_path=str(tmp_path / "probe.jsonl"))
    tg, state, ws_factory = build_components(cfg, ws_cls=WSClient)
    return Notifier(cfg, logger, tg, state, ws_factory, once=True), cfg


class TestAuthFailureRecovery:
    def test_rejected_then_accepted_delivers(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(reject_auth_times=2, script=[("text", make_inbox_frame())])
        try:
            # Four-entry backoff so the once-mode auth bound (== len(backoff))
            # does not fire before the third, accepted connection.
            notifier, _cfg = _build(tmp_path, server, fake_telegram,
                                    env_over={"NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05,0.05,0.05"})
            _thread, result = _run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert server.connect_count == 3
            send_calls = [req for req in fake_telegram.requests if req[0].endswith("/sendMessage")]
            assert len(send_calls) == 1
        finally:
            server.close()


class TestSendFailureRetry:
    def test_500_then_ok_delivers_with_retry(self, tmp_path, fake_telegram):
        fake_telegram.responses = [(500, {"ok": False, "description": "upstream dead"})]
        server = FakeMulticaWS(script=[("text", make_inbox_frame())])
        try:
            notifier, _cfg = _build(tmp_path, server, fake_telegram)
            _thread, result = _run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            send_calls = [p for p, _ in fake_telegram.requests if p.endswith("/sendMessage")]
            assert len(send_calls) == 2
        finally:
            server.close()


class TestSurrogateLogE2E:
    def test_once_with_log_json_survives_surrogate_title(self, tmp_path, fake_telegram):
        # End-to-end: an inbox title carrying a lone surrogate must not crash
        # the process after a successful delivery when --log-json is active.
        server = FakeMulticaWS(script=[
            ("text", make_inbox_frame(item_overrides={"title": "\ud800SEE-1561 收口"})),
            ("sleep", 5),
        ])
        try:
            env_path = tmp_path / "see-1561.env"
            env_path.write_text(
                "\n".join(f"{k}={v}" for k, v in make_env(server, fake_telegram, tmp_path).items()),
                encoding="utf-8",
            )
            log_path = tmp_path / "probe.jsonl"
            proc = subprocess.run(
                [sys.executable,
                 os.path.join(REPO_ROOT, "adapters", "multica_telegram_notifier", "notifier.py"),
                 "--config", str(env_path),
                 "--once",
                 "--log-json", str(log_path)],
                capture_output=True, text=True, timeout=30,
            )
            assert proc.returncode == 0, proc.stderr[-2000:]
            events = [json.loads(x)["event"] for x in log_path.read_text(encoding="utf-8").splitlines()]
            assert "delivered" in events
            log_text = log_path.read_text(encoding="utf-8")
            assert "\ud800" not in log_text
            assert "SEE-1561 收口" in log_text
            send_calls = [req for req in fake_telegram.requests if req[0].endswith("/sendMessage")]
            assert len(send_calls) == 1
        finally:
            server.close()


class TestFragmentedFrameE2E:
    def test_inbox_frame_split_mid_codepoint_still_delivers(self, tmp_path, fake_telegram):
        # D-2 end-to-end: one inbox frame delivered as two WebSocket
        # fragments split inside a multi-byte character must still produce a
        # delivered notification.
        from multica_notifier_fakes import text_frame_bytes

        frame = json.loads(make_inbox_frame(item_overrides={"title": "中文分片通知"}))
        payload = json.dumps(frame, ensure_ascii=False).encode("utf-8")
        cut = payload.index("中".encode("utf-8")) + 1  # inside the 3-byte 中
        server = FakeMulticaWS(script=[
            ("raw", text_frame_bytes(payload[:cut], fin=False)),
            ("raw", text_frame_bytes(payload[cut:], fin=True, opcode=0x0)),
            ("sleep", 5),
        ])
        try:
            notifier, _cfg = _build(tmp_path, server, fake_telegram,
                                    env_over={"NOTIFIER_READ_TIMEOUT": "2"})
            _thread, result = _run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            send_calls = [req for req in fake_telegram.requests if req[0].endswith("/sendMessage")]
            assert len(send_calls) == 1
            assert "中文分片通知" in send_calls[0][1]["text"]
        finally:
            server.close()


class TestCliSubprocess:
    def test_spec_command_shape_delivers_once(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(script=[("text", make_inbox_frame())])
        try:
            env_path = tmp_path / "see-1561.env"
            env_path.write_text(
                "\n".join(f"{k}={v}" for k, v in make_env(server, fake_telegram, tmp_path).items()),
                encoding="utf-8",
            )
            log_path = tmp_path / "live-probe.jsonl"
            proc = subprocess.run(
                [sys.executable,
                 os.path.join(REPO_ROOT, "adapters", "multica_telegram_notifier", "notifier.py"),
                 "--config", str(env_path),
                 "--once",
                 "--log-json", str(log_path)],
                capture_output=True, text=True, timeout=30,
            )
            assert proc.returncode == 0, proc.stderr[-2000:]
            send_calls = [p for p, _ in fake_telegram.requests if p.endswith("/sendMessage")]
            assert len(send_calls) == 1
            events = [json.loads(x)["event"] for x in log_path.read_text(encoding="utf-8").splitlines()]
            assert "delivered" in events
            assert "auth_ok" in events
            log_text = log_path.read_text(encoding="utf-8")
            assert PAT not in log_text and BOT not in log_text
        finally:
            server.close()
