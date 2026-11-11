"""§SPEC-003 behaviour at the notifier level: filtering, dedup, reconnect,
auth rejection, chat-id discovery failure, permanent-failure quarantine,
stale-chat recovery, once-mode auth bound, read-timeout reconnect.
Real WS + real Telegram client classes over the local fakes."""

import io
import json
import threading

from multica_telegram_notifier.config import load_config
from multica_telegram_notifier.jsonlog import JsonLogger
from multica_telegram_notifier.notifier import (
    EXIT_AUTH_REJECTED,
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


class EventCapture:
    """Collects JSONL log lines so tests can assert on emitted events."""

    def __init__(self):
        self.lines = []

    def write(self, text):
        if text.strip():
            self.lines.append(text.strip())
        return len(text)

    def flush(self):
        pass

    def events(self, name=None):
        out = []
        for line in self.lines:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if name is None or record.get("event") == name:
                out.append(record)
        return out


def build(tmp_path, multica, telegram, env_over=None):
    cfg = load_config(make_env(multica, telegram, tmp_path, **(env_over or {})))
    capture = EventCapture()
    logger = JsonLogger(Redactor([cfg.multica_pat, cfg.telegram_bot_token]), stream=capture)
    telegram_client, state, ws_factory = build_components(cfg, ws_cls=WSClient)
    notifier = Notifier(cfg, logger, telegram_client, state, ws_factory, once=True)
    return notifier, cfg, capture


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
            notifier, _cfg, _capture = build(tmp_path, server, fake_telegram)
            notifier.once = False
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


class TestPermanentSendFailure:
    def test_non_retryable_failure_quarantines_item_then_delivers_next(self, tmp_path, fake_telegram):
        fake_telegram.responses = [
            (200, {"ok": True, "result": [private_chat_update(987654)]}),
            (400, {"ok": False, "error_code": 400, "description": "Bad Request: rejected item"}),
        ]
        server = FakeMulticaWS(script=[
            ("text", make_inbox_frame(item_id="bad-item")),
            ("text", make_inbox_frame(item_id="good-item")),
            ("sleep", 5),
        ])
        try:
            notifier, cfg, capture = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert len(send_calls(fake_telegram)) == 2
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("bad-item")
            assert state.is_seen("good-item")
            assert len(capture.events("delivery_failed_permanent")) == 1
        finally:
            server.close()

    def test_quarantined_item_not_redispatched_after_reconnect(self, tmp_path, fake_telegram):
        fake_telegram.responses = [
            (200, {"ok": True, "result": [private_chat_update(987654)]}),
            (400, {"ok": False, "error_code": 400, "description": "Bad Request: rejected item"}),
        ]
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="poison")), ("close",)])
        try:
            notifier, cfg, capture = build(tmp_path, server, fake_telegram)
            notifier.once = False
            stop = threading.Event()
            notifier.stop_event = stop
            stopper = threading.Timer(1.5, stop.set)
            stopper.start()
            thread, result = run_in_thread(notifier)
            stopper.cancel()
            assert result.get("code") == EXIT_STOPPED, result
            assert server.connect_count >= 2, "session must reconnect after the failed delivery"
            # Quarantine: exactly one send attempt for the poison item ever.
            assert len(send_calls(fake_telegram)) == 1
            assert len(capture.events("delivery_failed_permanent")) == 1
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("poison")
        finally:
            server.close()


class TestChannelFailureKeepsPending:
    def test_401_keeps_item_pending_and_delivers_after_recovery(self, tmp_path, fake_telegram):
        fake_telegram.responses = [
            (200, {"ok": True, "result": [private_chat_update(987654)]}),
            (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
        ]
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="during-outage")), ("close",)])
        try:
            notifier, cfg, capture = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            # Channel failure must NOT quarantine: the item stays pending and
            # is delivered once the channel works again (next session).
            assert len(capture.events("delivery_failed_permanent")) == 0
            assert capture.events("session_ended")
            sends = send_calls(fake_telegram)
            assert len(sends) == 2
            assert sends[0][1]["text"] == sends[1][1]["text"]
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("during-outage")
        finally:
            server.close()

    def test_stale_chat_rediscovery_failure_keeps_item_pending(self, tmp_path, fake_telegram):
        # Channel dead AND chat gone: rediscovery fails (no /start yet) — the
        # notification must survive and flow once the channel recovers.
        fake_telegram.responses = [
            (200, {"ok": True, "result": [private_chat_update(1111111)]}),
            (400, {"ok": False, "error_code": 400, "description": "Bad Request: chat not found"}),
            (200, {"ok": True, "result": []}),
        ]
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="orphaned")), ("close",)])
        try:
            notifier, cfg, capture = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert len(capture.events("delivery_failed_permanent")) == 0
            sends = send_calls(fake_telegram)
            assert [body["chat_id"] for _p, body in sends] == [1111111, 987654]
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("orphaned")
            assert state.chat_id == 987654
        finally:
            server.close()


class TestStaleChatRecovery:
    def test_stale_chat_id_rediscovered_and_retried(self, tmp_path, fake_telegram):
        fake_telegram.responses = [
            (200, {"ok": True, "result": [private_chat_update(1111111)]}),
            (400, {"ok": False, "error_code": 400, "description": "Bad Request: chat not found"}),
            (200, {"ok": True, "result": [private_chat_update(987654)]}),
        ]
        server = FakeMulticaWS(script=[("text", make_inbox_frame()), ("sleep", 5)])
        try:
            notifier, cfg, capture = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            sends = send_calls(fake_telegram)
            assert len(sends) == 2
            assert sends[0][1]["chat_id"] == 1111111
            assert sends[1][1]["chat_id"] == 987654
            assert capture.events("stale_chat_id")
            assert capture.events("chat_id_rediscovered")
            state = DedupState(cfg.state_file)
            state.load()
            assert state.chat_id == 987654
        finally:
            server.close()


class TestOnceAuthBound:
    def test_once_gives_up_after_backoff_cycle_with_exit_4(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(reject_auth_times=10 ** 9)
        try:
            notifier, cfg, capture = build(
                tmp_path, server, fake_telegram,
                env_over={"NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05"})
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_AUTH_REJECTED, result
            assert server.connect_count == 2
            assert len(send_calls(fake_telegram)) == 0
        finally:
            server.close()

    def test_steady_mode_keeps_retrying_auth_rejection(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(reject_auth_times=10 ** 9)
        try:
            notifier, cfg, capture = build(
                tmp_path, server, fake_telegram,
                env_over={"NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05"})
            notifier.once = False
            stop = threading.Event()
            notifier.stop_event = stop
            stopper = threading.Timer(0.8, stop.set)
            stopper.start()
            thread, result = run_in_thread(notifier)
            stopper.cancel()
            assert result.get("code") == EXIT_STOPPED, result
            assert server.connect_count > 2, "steady mode must keep retrying beyond the once-bound"
        finally:
            server.close()


class TestReadTimeoutReconnect:
    def test_silent_connection_reconnects_and_delivers(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(script=[("sleep", 5)])
        try:
            notifier, cfg, capture = build(
                tmp_path, server, fake_telegram,
                env_over={"NOTIFIER_READ_TIMEOUT": "0.3"})
            holder = {}
            sessions = {"n": 0}
            original_factory = notifier.ws_factory

            def factory():
                if sessions["n"] == 0:
                    sessions["n"] += 1
                    return original_factory()
                second = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="after-timeout"))])
                holder["second"] = second
                return WSClient(f"{second.url}?workspace_id=ws-target",
                                connect_timeout=cfg.connect_timeout,
                                read_timeout=cfg.read_timeout)

            notifier.ws_factory = factory
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert sessions["n"] == 1, "silent first session must have been replaced"
            assert len(send_calls(fake_telegram)) == 1
            assert capture.events("session_ended")
        finally:
            server.close()
            if "second" in holder:
                holder["second"].close()


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
