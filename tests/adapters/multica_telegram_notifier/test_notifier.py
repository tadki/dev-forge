"""§SPEC-003 behaviour at the notifier level: filtering, dedup, reconnect,
auth rejection, chat-id discovery failure. Real WS + real Telegram client
classes over the local fakes (only the process boundary is faked)."""

import io
import threading

from multica_telegram_notifier.config import load_config
from multica_telegram_notifier.jsonlog import JsonLogger
from multica_telegram_notifier.notifier import (
    EXIT_CONFIG,
    EXIT_OK,
    EXIT_STOPPED,
    Notifier,
    build_components,
)
from multica_telegram_notifier.redact import Redactor
from multica_telegram_notifier.state import DedupState
from multica_telegram_notifier.wsclient import WSClient, WebSocketError

from multica_notifier_fakes import FakeMulticaWS, make_env, make_inbox_frame, private_chat_update

PAT = "test-pat-value-0123456789"
BOT = "test-bot-token-value"


def send_calls(telegram):
    return [req for req in telegram.requests if req[0].endswith("/sendMessage")]


def build(tmp_path, multica, telegram, env_over=None):
    cfg = load_config(make_env(multica, telegram, tmp_path, **(env_over or {})))
    logger = JsonLogger(Redactor([cfg.multica_pat, cfg.telegram_bot_token]), stream=io.StringIO())
    telegram_client, state, ws_factory = build_components(cfg, ws_cls=WSClient)
    notifier = Notifier(cfg, logger, telegram_client, state, ws_factory, once=True)
    return notifier, cfg, logger


def run_in_thread(notifier):
    result = {}

    def target():
        try:
            result["code"] = notifier.run()
        except Exception as exc:  # surface unexpected crashes to the assertion
            result["error"] = exc

    thread = threading.Thread(target=target, daemon=True)
    thread.start()
    thread.join(timeout=15)
    return thread, result


class TestHappyPath:
    def test_once_mode_delivers_and_exits_zero(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(script=[("text", make_inbox_frame()), ("sleep", 5)])
        try:
            notifier, cfg, logger = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert len(send_calls(fake_telegram)) == 1
            path, body = send_calls(fake_telegram)[0]
            assert body["chat_id"] == 987654
            assert "SEE-1561 code 子步骤" in body["text"]
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("item-1")
            assert state.chat_id == 987654
        finally:
            server.close()

    def test_chat_id_discovered_from_getupdates(self, tmp_path, fake_telegram):
        fake_telegram.responses = [(200, {"ok": True, "result": [private_chat_update(987654)]})]
        server = FakeMulticaWS(script=[("text", make_inbox_frame())])
        try:
            notifier, _cfg, _logger = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            # Discovery consumed the scripted response; the delivery used the default ok.
            assert fake_telegram.requests[0][0].endswith("/getUpdates")
            assert fake_telegram.requests[1][0].endswith("/sendMessage")
        finally:
            server.close()


class TestFiltering:
    def test_ignores_noise_then_delivers_valid(self, tmp_path, fake_telegram):
        script = [
            ("text", '{"type":"issue:updated","payload":{}}'),          # non-inbox event
            ("text", "definitely not json"),                            # malformed frame
            ("text", '{"type":"inbox:new","payload":{"item":"x"}}'),    # unparseable item
            ("text", make_inbox_frame(workspace_id="ws-other")),        # other workspace
            ("text", make_inbox_frame(item_id="item-ok")),              # valid
            ("sleep", 5),
        ]
        server = FakeMulticaWS(script=script)
        try:
            notifier, _cfg, logger = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert len(send_calls(fake_telegram)) == 1
            assert "SEE-1561 code 子步骤" in send_calls(fake_telegram)[0][1]["text"]
        finally:
            server.close()


class TestDedup:
    def test_already_delivered_item_skipped(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(script=[
            ("text", make_inbox_frame(item_id="seen-already")),
            ("text", make_inbox_frame(item_id="fresh-item")),
            ("sleep", 5),
        ])
        try:
            state_path = tmp_path / "state.json"
            pre = DedupState(str(state_path))
            pre.load()
            pre.mark_seen("seen-already")
            notifier, _cfg, _logger = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert len(send_calls(fake_telegram)) == 1
            # The delivered one is the fresh item, not the seen one.
            state = DedupState(str(state_path))
            state.load()
            assert state.is_seen("fresh-item")
        finally:
            server.close()


class TestReconnect:
    def test_reconnects_after_auth_rejection_then_delivers(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(reject_auth_times=1, script=[("text", make_inbox_frame())])
        try:
            notifier, _cfg, _logger = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert server.connect_count == 2
        finally:
            server.close()

    def test_reconnects_after_session_drop(self, tmp_path, fake_telegram):
        # First session: drops right after auth_ack. Second session: delivers.
        server = FakeMulticaWS(script=[("close",)])
        delivered_server_started = threading.Event()
        holder = {}

        factory_sessions = {"n": 0}

        notifier, cfg, logger = build(tmp_path, server, fake_telegram)

        original_factory = notifier.ws_factory

        def factory():
            if factory_sessions["n"] == 0:
                factory_sessions["n"] += 1
                return original_factory()
            second = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="second-session"))])
            holder["second"] = second
            return WSClient(f"{second.url}?workspace_id=ws-target", connect_timeout=cfg.connect_timeout)

        notifier.ws_factory = factory
        try:
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert factory_sessions["n"] == 1
            assert len(send_calls(fake_telegram)) == 1
        finally:
            server.close()
            if "second" in holder:
                holder["second"].close()

    def test_auth_rejection_loops_until_stopped(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(reject_auth_times=10**9)
        try:
            notifier, _cfg, _logger = build(tmp_path, server, fake_telegram)
            stop = threading.Event()
            notifier.stop_event = stop
            stopper = threading.Timer(1.0, stop.set)
            stopper.start()
            thread, result = run_in_thread(notifier)
            stopper.cancel()
            assert result.get("code") == EXIT_STOPPED, result
            assert server.connect_count >= 2
            assert len(send_calls(fake_telegram)) == 0
        finally:
            server.close()


class TestStartupFailures:
    def test_discovery_failure_exits_config_error(self, tmp_path, fake_telegram):
        fake_telegram.responses = [(200, {"ok": True, "result": []})]
        server = FakeMulticaWS()
        try:
            notifier, _cfg, logger = build(tmp_path, server, fake_telegram)
            code = notifier.run()
            assert code == EXIT_CONFIG
            assert len(fake_telegram.requests) == 1  # only the discovery call
        finally:
            server.close()

    def test_cached_chat_id_skips_discovery(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(script=[("text", make_inbox_frame())])
        try:
            state_path = tmp_path / "state.json"
            pre = DedupState(str(state_path))
            pre.load()
            pre.chat_id = 555000
            pre.save()
            notifier, _cfg, _logger = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            paths = [p for p, _ in fake_telegram.requests]
            assert paths == [f"/bot{BOT}/sendMessage"]
            assert fake_telegram.requests[0][1]["chat_id"] == 555000
        finally:
            server.close()


class TestSecretHygiene:
    def test_log_stream_and_state_file_never_carry_secrets(self, tmp_path, fake_telegram):
        log_path = tmp_path / "probe.jsonl"
        server = FakeMulticaWS(script=[("text", make_inbox_frame())])
        try:
            cfg = load_config(make_env(server, fake_telegram, tmp_path))
            logger = JsonLogger(Redactor([cfg.multica_pat, cfg.telegram_bot_token]),
                                stream=io.StringIO(), file_path=str(log_path))
            telegram_client, state, ws_factory = build_components(cfg, ws_cls=WSClient)
            notifier = Notifier(cfg, logger, telegram_client, state, ws_factory, once=True)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            logger.close()
            file_text = log_path.read_text(encoding="utf-8")
            assert PAT not in file_text
            assert BOT not in file_text
            state_text = (tmp_path / "state.json").read_text(encoding="utf-8")
            assert PAT not in state_text
            assert BOT not in state_text
        finally:
            server.close()
