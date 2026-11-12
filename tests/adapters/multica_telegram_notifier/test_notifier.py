"""§SPEC-003 behaviour at the notifier level: filtering, dedup, reconnect,
auth rejection, startup config failure (missing chat id), permanent-failure
quarantine, stale-chat re-affirm, once-mode auth/channel bounds, and
read-timeout reconnect. Real WS + real Telegram client classes over the
local fakes (only the process boundary is faked)."""

import io
import json
import os
import threading
from pathlib import Path

import pytest

from multica_telegram_notifier.config import load_config
from multica_telegram_notifier.jsonlog import JsonLogger
from multica_telegram_notifier.notifier import (
    EXIT_AUTH_REJECTED,
    build_resolver,
    EXIT_CHANNEL_FAILED,
    EXIT_CONFIG,
    EXIT_DELIVERY_FAILED,
    EXIT_INTERRUPTED,
    EXIT_OK,
    EXIT_STOPPED,
    Notifier,
    SessionError,
    build_components,
)
from multica_telegram_notifier.redact import Redactor
from multica_telegram_notifier.state import DedupState
from multica_telegram_notifier.wsclient import WSClient

from multica_notifier_fakes import (
    FakeMulticaAPI,
    FakeMulticaWS,
    FakeTelegram,
    make_env,
    make_inbox_frame,
)

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
            assert "<b>SEE-1561</b> code 子步骤" in body["text"]
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("item-1")
        finally:
            server.close()

    def test_configured_chat_id_used_and_no_getupdates_ever_called(self, tmp_path, fake_telegram):
        # D-1: the configured chat id is the ONLY delivery target; discovery
        # via getUpdates is gone, so a stranger's private chat can never win.
        server = FakeMulticaWS(script=[("text", make_inbox_frame())])
        try:
            notifier, _cfg, _logger = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            paths = [p for p, _ in fake_telegram.requests]
            assert paths == [f"/bot{BOT}/sendMessage"]
            assert fake_telegram.requests[0][1]["chat_id"] == 987654
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
            assert "<b>SEE-1561</b> code 子步骤" in send_calls(fake_telegram)[0][1]["text"]
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
    def test_missing_chat_id_exits_config_error(self, tmp_path, fake_telegram, monkeypatch):
        # load_config_file falls back to os.environ, so an exported
        # NOTIFIER_* key on a dev/CI shell would mask this missing-key case;
        # purge the inherited environment to keep the test discriminative.
        for key in [k for k in os.environ if k.startswith("NOTIFIER_")]:
            monkeypatch.delenv(key, raising=False)
        server = FakeMulticaWS()
        try:
            env = make_env(server, fake_telegram, tmp_path)
            del env["NOTIFIER_TELEGRAM_CHAT_ID"]
            env_path = tmp_path / "missing.env"
            env_path.write_text("\n".join(f"{k}={v}" for k, v in env.items()), encoding="utf-8")
            from multica_telegram_notifier.notifier import main
            code = main(["--config", str(env_path)])
            assert code == EXIT_CONFIG
            assert fake_telegram.requests == []
        finally:
            server.close()

    def test_legacy_state_chat_id_ignored_config_wins(self, tmp_path, fake_telegram):
        # Old state files carried a chat_id cache; it must never override the
        # configured id (the config value is the single authority).
        server = FakeMulticaWS(script=[("text", make_inbox_frame())])
        try:
            (tmp_path / "state.json").write_text(
                '{"chat_id": 555000, "delivered": []}', encoding="utf-8")
            notifier, _cfg, _logger = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            paths = [p for p, _ in fake_telegram.requests]
            assert paths == [f"/bot{BOT}/sendMessage"]
            assert fake_telegram.requests[0][1]["chat_id"] == 987654
        finally:
            server.close()

    def test_log_json_tilde_path_expanded_not_literal(self, tmp_path, fake_telegram, monkeypatch):
        # F-3: --log-json must expand `~` like NOTIFIER_STATE_FILE does; the
        # old behavior silently created a literal "./~" tree under the CWD.
        server = FakeMulticaWS(script=[("text", make_inbox_frame()), ("sleep", 5)])
        try:
            for key in [k for k in os.environ if k.startswith("NOTIFIER_")]:
                monkeypatch.delenv(key, raising=False)
            monkeypatch.setenv("HOME", str(tmp_path))
            env = make_env(server, fake_telegram, tmp_path)
            env_path = tmp_path / "log.env"
            env_path.write_text("\n".join(f"{k}={v}" for k, v in env.items()), encoding="utf-8")
            from multica_telegram_notifier.notifier import main
            code = main(["--config", str(env_path), "--once",
                         "--log-json", "~/see1561-log/probe.jsonl"])
            assert code == EXIT_OK
            assert (tmp_path / "see1561-log" / "probe.jsonl").exists()
            assert not (Path.cwd() / "~").exists()
        finally:
            server.close()

    def test_unwritable_log_file_exits_config_error(self, tmp_path, capsys):
        # Final-Review LOW: an unwritable --log-json path is a startup config
        # error (config_error JSON + exit 2), never a raw traceback exit 1.
        blocker = tmp_path / "blocker"
        blocker.write_text("i am a file", encoding="utf-8")
        env = make_env(FakeMulticaWS(), FakeTelegram(), tmp_path)
        env_path = tmp_path / "log.env"
        env_path.write_text("\n".join(f"{k}={v}" for k, v in env.items()), encoding="utf-8")
        from multica_telegram_notifier.notifier import main
        code = main(["--config", str(env_path),
                     "--log-json", str(blocker / "probe.jsonl")])
        assert code == EXIT_CONFIG
        assert "config_error" in capsys.readouterr().err

    def test_non_utf8_config_file_exits_config_error(self, tmp_path, capsys):
        # E-3: invalid config must follow the CLI contract — config_error JSON
        # on stderr and exit 2, never a raw traceback with exit 1.
        bad_path = tmp_path / "bad.env"
        bad_path.write_bytes(b"\xff\xfe not utf-8 at all\n")
        from multica_telegram_notifier.notifier import main
        code = main(["--config", str(bad_path)])
        assert code == EXIT_CONFIG
        stderr = capsys.readouterr().err
        assert "config_error" in stderr


class TestPermanentSendFailure:
    def test_non_retryable_failure_quarantines_item_then_delivers_next(self, tmp_path, fake_telegram):
        fake_telegram.responses = [
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
            assert {body["chat_id"] for _p, body in sends} == {987654}
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("during-outage")
        finally:
            server.close()


class TestStaleChatRecovery:
    def test_stale_chat_id_reaffirmed_and_retried(self, tmp_path, fake_telegram):
        # "chat not found" re-affirms the configured id and retries once; the
        # adapter never falls back to scanning other private chats (D-1).
        fake_telegram.responses = [
            (400, {"ok": False, "error_code": 400, "description": "Bad Request: chat not found"}),
        ]
        server = FakeMulticaWS(script=[("text", make_inbox_frame()), ("sleep", 5)])
        try:
            notifier, cfg, capture = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            sends = send_calls(fake_telegram)
            assert len(sends) == 2
            assert {body["chat_id"] for _p, body in sends} == {987654}
            assert capture.events("stale_chat_id")
            assert capture.events("chat_id_reaffirmed")
        finally:
            server.close()

    def test_repeat_chat_not_found_keeps_pending(self, tmp_path, fake_telegram):
        # A second "chat not found" after the re-affirm still means the
        # channel has not recovered: the item stays pending, never quarantined,
        # and lands once Telegram accepts again.
        fake_telegram.responses = [
            (400, {"ok": False, "error_code": 400, "description": "Bad Request: chat not found"}),
            (400, {"ok": False, "error_code": 400, "description": "Bad Request: chat not found"}),
        ]
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="still-stale")), ("close",)])
        try:
            notifier, cfg, capture = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert len(capture.events("delivery_failed_permanent")) == 0
            sends = send_calls(fake_telegram)
            assert [body["chat_id"] for _p, body in sends] == [987654, 987654, 987654]
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("still-stale")
        finally:
            server.close()


class TestOnceAuthBound:
    def test_once_gives_up_after_backoff_cycle_with_exit_4(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(reject_auth_times=10 ** 9)
        try:
            notifier, _cfg, capture = build(
                tmp_path, server, fake_telegram,
                env_over={"NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05"})
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_AUTH_REJECTED, result
            assert server.connect_count == 2
            assert len(send_calls(fake_telegram)) == 0
            # The give-up must be recorded as auth_gave_up (distinct from the
            # delivery/channel give-up events).
            assert len(capture.events("auth_gave_up")) == 1
            assert len(capture.events("delivery_gave_up")) == 0
            assert len(capture.events("channel_gave_up")) == 0
        finally:
            server.close()

    def test_steady_mode_keeps_retrying_auth_rejection(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(reject_auth_times=10 ** 9)
        try:
            notifier, _cfg, _capture = build(
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


class TestOnceChannelBound:
    def test_once_gives_up_on_persistent_channel_failure_exit_5(self, tmp_path, fake_telegram):
        fake_telegram.responses = [
            (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
            (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
        ]
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="probe-item")),
                                       ("sleep", 0.1)])
        try:
            notifier, cfg, capture = build(
                tmp_path, server, fake_telegram,
                env_over={"NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05"})
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_CHANNEL_FAILED, result
            assert len(send_calls(fake_telegram)) == 2
            assert len(capture.events("delivery_failed_permanent")) == 0
            assert capture.events("channel_gave_up")
            state = DedupState(cfg.state_file)
            state.load()
            # The pending item was never quarantined by the channel failure.
            assert not state.is_seen("probe-item")
        finally:
            server.close()

    def test_channel_counter_resets_on_non_channel_session(self, tmp_path, fake_telegram):
        # 401 → (session ends via ws drop — non-channel, breaks the run of
        # consecutive failures) → 401: the once bound counts CONSECUTIVE
        # channel failures and must not fire; delivery lands normally once
        # the scripted failures are exhausted.
        fake_telegram.responses = [
            (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
            (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
        ]
        holder = {}
        sessions = {"n": 0}
        first = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="reset-case")), ("close",)])
        try:
            notifier, cfg, capture = build(
                tmp_path, first, fake_telegram,
                env_over={"NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05"})
            original_factory = notifier.ws_factory

            def factory():
                if sessions["n"] == 0:
                    sessions["n"] += 1
                    return original_factory()
                if sessions["n"] == 1:
                    # A session that ends via plain ws drop (non-channel).
                    sessions["n"] += 1
                    dropper = FakeMulticaWS(script=[("close",)])
                    holder["dropper"] = dropper
                    return WSClient(f"{dropper.url}?workspace_id=ws-target",
                                    connect_timeout=cfg.connect_timeout,
                                    read_timeout=cfg.read_timeout)
                delivering = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="reset-case")), ("close",)])
                holder.setdefault("delivering", delivering)
                return WSClient(f"{delivering.url}?workspace_id=ws-target",
                                connect_timeout=cfg.connect_timeout,
                                read_timeout=cfg.read_timeout)

            notifier.ws_factory = factory
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert len(capture.events("channel_gave_up")) == 0
            assert len(capture.events("delivery_failed_permanent")) == 0
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("reset-case")
        finally:
            first.close()
            for server in holder.values():
                server.close()

    def test_steady_mode_keeps_retrying_channel_failure(self, tmp_path, fake_telegram):
        # Supply far exceeds the worst-case send count inside the 0.8 s stop
        # window (measured ~9 sends here, faster CI more): a scripted-failure
        # shortage would flip the run into "delivered" and pseudo-fail.
        fake_telegram.responses = [
            (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
        ] * 200
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="probe-item")),
                                       ("sleep", 0.1)])
        try:
            notifier, _cfg, _capture = build(
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
            assert len(send_calls(fake_telegram)) > 2, "steady mode retries beyond the once-bound"
        finally:
            server.close()

    def test_once_gives_up_on_persistent_transient_failure_exit_6(self, tmp_path, fake_telegram):
        # E-1: persistent retryable (non-channel) failures — e.g. a stuck
        # 500/429 upstream — must end a --once probe deterministically while
        # keeping the item pending (never quarantined).
        fake_telegram.responses = [
            (500, {"ok": False, "error_code": 500, "description": "internal error"}),
        ] * 4  # each session burns send_retries before surfacing the failure
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="probe-item")),
                                       ("sleep", 0.1)])
        try:
            notifier, cfg, capture = build(
                tmp_path, server, fake_telegram,
                env_over={"NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05",
                          "NOTIFIER_SEND_RETRIES": "0.01"})
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_DELIVERY_FAILED, result
            assert capture.events("delivery_gave_up")
            assert len(capture.events("delivery_failed_permanent")) == 0
            assert len(capture.events("channel_gave_up")) == 0
            state = DedupState(cfg.state_file)
            state.load()
            assert not state.is_seen("probe-item")
        finally:
            server.close()

    def test_once_alternating_failures_still_bound_exit_6(self, tmp_path, fake_telegram):
        # F-1: channel and transient counters clear each other, so strictly
        # alternating 500/401 would never reach a per-class bound; the total
        # Telegram-failure run must still bound the probe (item stays pending).
        fake_telegram.responses = [
            # Each session surfaces its LAST response; 500/500 keeps it
            # transient, then a lone 401 surfaces channel — a true surfaced
            # alternation that per-class bounds can never accumulate.
            (500, {"ok": False, "error_code": 500, "description": "internal error"}),
            (500, {"ok": False, "error_code": 500, "description": "internal error"}),
            (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
            (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
            (500, {"ok": False, "error_code": 500, "description": "internal error"}),
            (500, {"ok": False, "error_code": 500, "description": "internal error"}),
            (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
            (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
        ]
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="probe-item")),
                                       ("sleep", 0.1)])
        try:
            notifier, cfg, capture = build(
                tmp_path, server, fake_telegram,
                env_over={"NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05",
                          "NOTIFIER_SEND_RETRIES": "0.01"})
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_DELIVERY_FAILED, result
            assert capture.events("delivery_gave_up")
            assert len(capture.events("delivery_failed_permanent")) == 0
            state = DedupState(cfg.state_file)
            state.load()
            assert not state.is_seen("probe-item")
        finally:
            server.close()

    def test_steady_mode_keeps_retrying_transient_failure(self, tmp_path, fake_telegram):
        # Each send burns up to 2 responses (send_retries), so supply far
        # beyond the measured 0.8 s consumption (~16 sends => 32 responses,
        # already over the old supply of 20): exhaustion would flip the run
        # into "delivered" and pseudo-fail on faster machines.
        fake_telegram.responses = [
            (500, {"ok": False, "error_code": 500, "description": "internal error"}),
        ] * 200
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_id="probe-item")),
                                       ("sleep", 0.1)])
        try:
            notifier, _cfg, _capture = build(
                tmp_path, server, fake_telegram,
                env_over={"NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05",
                          "NOTIFIER_SEND_RETRIES": "0.01"})
            notifier.once = False
            stop = threading.Event()
            notifier.stop_event = stop
            stopper = threading.Timer(0.8, stop.set)
            stopper.start()
            thread, result = run_in_thread(notifier)
            stopper.cancel()
            assert result.get("code") == EXIT_STOPPED, result
            assert len(send_calls(fake_telegram)) > 2, "steady mode retries beyond the once-bound"
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


class TestAuthRejectedResetsFailureRuns:
    @pytest.mark.parametrize("kind,code", [("transient", 500), ("channel", 401)])
    def test_auth_rejection_breaks_the_failure_run(self, tmp_path, fake_telegram, kind, code):
        # Sequence: fail -> auth rejected -> fail -> deliver. AuthRejected must
        # reset the per-class AND total failure runs; without the reset the
        # second failure would reach the once-bound and exit 5/6 instead of
        # delivering. This pins the "AuthRejected 打断失败连击" branch.
        failure = {"ok": False, "error_code": code,
                   "description": "internal" if kind == "transient" else "Unauthorized"}
        if kind == "transient":
            # send_retries "0.01" => 2 attempts per send, so 2 failures per session.
            fake_telegram.responses = [(code, failure)] * 4
        else:
            # A non-retryable channel error fails fast: 1 attempt per session.
            fake_telegram.responses = [(code, failure)] * 2
        item = make_inbox_frame(item_id="auth-reset-item")
        first = FakeMulticaWS(script=[("text", item), ("close",)])
        reject = FakeMulticaWS(reject_auth_times=1)
        third = FakeMulticaWS(script=[("text", item), ("close",)])
        fourth = FakeMulticaWS(script=[("text", item), ("sleep", 5)])
        servers = [first, reject, third, fourth]
        sessions = {"n": 0}
        try:
            notifier, cfg, capture = build(
                tmp_path, first, fake_telegram,
                env_over={"NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05",
                          "NOTIFIER_SEND_RETRIES": "0.01"})
            original_factory = notifier.ws_factory

            def factory():
                idx = sessions["n"]
                sessions["n"] += 1
                if idx == 0:
                    return original_factory()
                server = servers[min(idx, len(servers) - 1)]
                return WSClient(f"{server.url}?workspace_id=ws-target",
                                connect_timeout=cfg.connect_timeout,
                                read_timeout=cfg.read_timeout)

            notifier.ws_factory = factory
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert len(capture.events("auth_rejected")) >= 1
            assert len(capture.events("auth_gave_up")) == 0
            assert len(capture.events("channel_gave_up")) == 0
            assert len(capture.events("delivery_gave_up")) == 0
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("auth-reset-item")
        finally:
            for server in servers:
                server.close()


class _StubRecvWS:
    def __init__(self, message):
        self._message = message

    def recv_message(self):
        return self._message


class TestAuthProtocolDeviation:
    def test_auth_response_not_json_object_raises_session_error(self, tmp_path, fake_telegram):
        server = FakeMulticaWS()
        try:
            notifier, _cfg, _capture = build(tmp_path, server, fake_telegram)
            with pytest.raises(SessionError):
                notifier._read_auth_response(_StubRecvWS("not json"))
        finally:
            server.close()

    def test_auth_first_frame_wrong_type_raises_session_error(self, tmp_path, fake_telegram):
        server = FakeMulticaWS()
        try:
            notifier, _cfg, _capture = build(tmp_path, server, fake_telegram)
            with pytest.raises(SessionError):
                notifier._read_auth_response(_StubRecvWS('{"type":"welcome"}'))
        finally:
            server.close()


class TestStaleChatSecondError:
    def test_second_send_non_stale_error_quarantines_item(self, tmp_path, fake_telegram):
        # First "chat not found" re-affirms and retries; a non-stale failure on
        # the retry must propagate as a message-level error (permanent, so the
        # poison item is quarantined) rather than be rewritten as channel-level.
        fake_telegram.responses = [
            (400, {"ok": False, "error_code": 400, "description": "Bad Request: chat not found"}),
            (400, {"ok": False, "error_code": 400, "description": "Bad Request: message text is empty"}),
        ]
        server = FakeMulticaWS(script=[
            ("text", make_inbox_frame(item_id="poison-stale")),
            ("text", make_inbox_frame(item_id="good-after")),
            ("sleep", 5),
        ])
        try:
            notifier, cfg, capture = build(tmp_path, server, fake_telegram)
            thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            assert len(capture.events("delivery_failed_permanent")) == 1
            state = DedupState(cfg.state_file)
            state.load()
            assert state.is_seen("poison-stale")
            assert state.is_seen("good-after")
        finally:
            server.close()


class TestMainKeyboardInterrupt:
    def test_keyboard_interrupt_returns_130(self, tmp_path, fake_telegram, monkeypatch):
        import multica_telegram_notifier.notifier as notifier_mod
        server = FakeMulticaWS()
        try:
            env_path = tmp_path / "ki.env"
            env_path.write_text(
                "\n".join(f"{k}={v}" for k, v in make_env(server, fake_telegram, tmp_path).items()),
                encoding="utf-8")

            def _interrupt(_self):
                raise KeyboardInterrupt()

            monkeypatch.setattr(notifier_mod.Notifier, "run", _interrupt)
            code = notifier_mod.main(["--config", str(env_path)])
            assert code == EXIT_INTERRUPTED
        finally:
            server.close()


class TestDirectScriptBootstrap:
    def test_direct_script_inserts_package_parent(self, monkeypatch):
        # When notifier.py is executed directly (not imported), adapters/ is not
        # on sys.path yet; the __main__ guard must insert it so the package
        # imports resolve. Under pytest adapters/ is already present, so the
        # guard body only runs once we simulate a bare script launch.
        import runpy
        import sys as _sys

        from multica_telegram_notifier import notifier as notifier_mod

        module_file = notifier_mod.__file__
        pkg_parent = os.path.dirname(os.path.dirname(os.path.abspath(module_file)))
        monkeypatch.setattr(
            _sys, "path", [p for p in _sys.path if os.path.abspath(p) != pkg_parent])
        monkeypatch.setattr(
            _sys, "argv", ["notifier.py", "--config", "/nonexistent/see1561.env"])
        with pytest.raises(SystemExit) as exc:
            runpy.run_path(module_file, run_name="__main__")
        assert exc.value.code == EXIT_CONFIG
        assert pkg_parent in _sys.path


def build_with_resolver(tmp_path, multica, telegram, api=None, env_over=None):
    cfg = load_config(make_env(multica, telegram, tmp_path, api=api, **(env_over or {})))
    capture = EventCapture()
    logger = JsonLogger(Redactor([cfg.multica_pat, cfg.telegram_bot_token]), stream=capture)
    telegram_client, state, ws_factory = build_components(cfg, ws_cls=WSClient)
    notifier = Notifier(cfg, logger, telegram_client, state, ws_factory, once=True,
                        resolver=build_resolver(cfg))
    return notifier, cfg, capture


UUID_ACTOR = "22222222-2222-2222-2222-222222222222"
UUID_ISSUE = "11111111-1111-1111-1111-111111111111"


class TestReadableNotification:
    def test_delivered_payload_has_readable_header_and_html_table(self, tmp_path, fake_telegram):
        api = FakeMulticaAPI()
        body = "| 状态 | 说明 |\n|---|---|\n| ok | 好 |"
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_overrides={
            "actor_id": UUID_ACTOR, "issue_id": UUID_ISSUE, "body": body,
            "title": "优化 Telegram 排版"})), ("sleep", 5)])
        try:
            notifier, _cfg, _capture = build_with_resolver(tmp_path, server, fake_telegram, api)
            _thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            api_requests = api.requests
            assert any("/api/agents/" in p for p in api_requests)
            assert any("/api/issues/" in p for p in api_requests)
            req = send_calls(fake_telegram)[0]
            assert req[1]["parse_mode"] == "HTML"
            text = req[1]["text"]
            assert text.startswith("🤖 <b>Bachi</b> · <b>SEE-1567</b>")
            assert "|---|" not in text
            assert "<b>状态</b>: ok · <b>说明</b>: 好" in text
            assert UUID_ACTOR not in text and UUID_ISSUE not in text
        finally:
            server.close()
            api.close()

    def test_metadata_failure_falls_back_without_uuid_and_still_delivers(self, tmp_path, fake_telegram):
        server = FakeMulticaWS(script=[("text", make_inbox_frame(item_overrides={
            "actor_id": UUID_ACTOR, "issue_id": UUID_ISSUE})), ("sleep", 5)])
        try:
            notifier, _cfg, _capture = build_with_resolver(
                tmp_path, server, fake_telegram,
                env_over={"NOTIFIER_API_BASE": "http://127.0.0.1:1"})
            _thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            req = send_calls(fake_telegram)[0]
            text = req[1]["text"]
            assert text.startswith("🤖 <b>Agent</b>")
            assert UUID_ACTOR not in text and UUID_ISSUE not in text
        finally:
            server.close()


class TestParseEntityFallback:
    _PARSE_ERROR = (400, {"ok": False, "error_code": 400,
                          "description": "Bad Request: can't parse entities: Unsupported start tag"})

    def test_parse_rejection_falls_back_to_plain_once(self, tmp_path, fake_telegram):
        fake_telegram.responses = [self._PARSE_ERROR]
        server = FakeMulticaWS(script=[("text", make_inbox_frame()), ("sleep", 5)])
        try:
            notifier, _cfg, capture = build(tmp_path, server, fake_telegram)
            _thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            calls = send_calls(fake_telegram)
            assert len(calls) == 2
            assert calls[0][1].get("parse_mode") == "HTML"
            assert "parse_mode" not in calls[1][1]
            assert "<b>" in calls[0][1]["text"] and "<b>" not in calls[1][1]["text"]
            assert any(e.get("event") == "html_parse_rejected_plain_fallback"
                       for e in capture.events())
        finally:
            server.close()

    def test_fallback_failure_keeps_item_pending_then_recovers(self, tmp_path, fake_telegram):
        boom = (500, {"ok": False, "description": "boom"})
        fake_telegram.responses = [self._PARSE_ERROR, boom, boom, boom]
        server = FakeMulticaWS(script=[("text", make_inbox_frame()), ("sleep", 5)])
        try:
            notifier, _cfg, _capture = build(tmp_path, server, fake_telegram)
            _thread, result = run_in_thread(notifier)
            assert result.get("code") == EXIT_OK, result
            calls = send_calls(fake_telegram)
            assert len(calls) == 5
            assert calls[0][1].get("parse_mode") == "HTML"
            assert all("parse_mode" not in c[1] for c in calls[1:4])
            assert calls[4][1].get("parse_mode") == "HTML"
        finally:
            server.close()

    def test_other_400_never_triggers_plain_fallback(self, tmp_path, fake_telegram):
        fake_telegram.responses = [(400, {"ok": False, "error_code": 400,
                                          "description": "Bad Request: chat not found"})]
        server = FakeMulticaWS(script=[("text", make_inbox_frame()), ("sleep", 5)])
        try:
            notifier, _cfg, capture = build(tmp_path, server, fake_telegram)
            _thread, result = run_in_thread(notifier)
            # chat-not-found keeps its stale-chat/reaffirm semantics: exactly two
            # HTML-mode attempts (original + reaffirmed retry), no plain fallback.
            calls = send_calls(fake_telegram)
            assert all(c[1].get("parse_mode") == "HTML" for c in calls)
            assert not any(e.get("event") == "html_parse_rejected_plain_fallback"
                           for e in capture.events())
        finally:
            server.close()
