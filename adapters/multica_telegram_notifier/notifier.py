"""Notifier orchestration and CLI entry (§SPEC-003/005).

Run modes:
- steady: reconnect forever, deliver every new inbox:new item once.
- --once: exit 0 after the first delivered notification (live probe);
  a permanently rejected auth token ends the probe deterministically.

Exit codes: 0 delivered (once) / 2 config failure /
3 stopped without delivering / 4 auth permanently rejected (--once) /
5 delivery channel permanently down (--once) / 6 persistent retryable
delivery failures (--once) / 130 interrupted.
"""

import argparse
import json
import os
import sys
import threading
import time

_PKG_PARENT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if __name__ == "__main__" and _PKG_PARENT not in sys.path:
    sys.path.insert(0, _PKG_PARENT)

from multica_telegram_notifier.config import ConfigError, load_config_file, ws_url
from multica_telegram_notifier.jsonlog import JsonLogger
from multica_telegram_notifier.protocol import (
    EVENT_INBOX_NEW,
    auth_error_message,
    auth_frame,
    format_notification,
    inbox_item_id,
    is_auth_ack,
    is_auth_error,
    item_workspace_id,
    parse_inbox_new,
    parse_server_frame,
)
from multica_telegram_notifier.redact import Redactor
from multica_telegram_notifier.state import DedupState
from multica_telegram_notifier.telegram import TelegramClient, TelegramError
from multica_telegram_notifier.wsclient import WSClient, WebSocketError

EXIT_OK = 0
EXIT_CONFIG = 2
EXIT_STOPPED = 3
EXIT_AUTH_REJECTED = 4
EXIT_CHANNEL_FAILED = 5
EXIT_DELIVERY_FAILED = 6
EXIT_INTERRUPTED = 130


class SessionError(Exception):
    """Protocol deviation inside a session; reconnecting may fix it."""


class AuthRejected(SessionError):
    """Server refused the auth frame (token invalid, non-member, disabled)."""


def build_components(config, ws_cls=WSClient):
    telegram = TelegramClient(
        config.telegram_api_base, config.telegram_bot_token,
        timeout=config.connect_timeout,
    )
    state = DedupState(config.state_file)
    state.load()

    def ws_factory():
        return ws_cls(ws_url(config), connect_timeout=config.connect_timeout,
                      read_timeout=config.read_timeout)

    return telegram, state, ws_factory


class Notifier:
    def __init__(self, config, logger, telegram, state, ws_factory,
                 sleep=time.sleep, stop_event: threading.Event = None, once: bool = False):
        self.config = config
        self.logger = logger
        self.telegram = telegram
        self.state = state
        self.ws_factory = ws_factory
        self.sleep = sleep
        self.stop_event = stop_event
        self.once = once
        # D-1: the configured chat id is the ONLY delivery target. Discovery
        # via getUpdates is deliberately absent — picking the "newest private
        # chat" could leak Inbox content to somebody else's chat.
        self._chat_id = config.telegram_chat_id
        self._auth_failures = 0
        self._channel_failures = 0
        self._transient_failures = 0

    def run(self) -> int:
        attempt = 0
        while not self._stopped():
            delivered = False
            try:
                delivered = self._session()
                attempt = 0
            except AuthRejected as exc:
                self.logger.error("auth_rejected", error=str(exc))
                # Auth happens before any Telegram send, so this session never
                # tested the channel — every failure run breaks here.
                self._channel_failures = 0
                self._transient_failures = 0
                self._auth_failures += 1
                if self._once_bound_reached(self._auth_failures):
                    self.logger.error("auth_gave_up", attempts=self._auth_failures)
                    return EXIT_AUTH_REJECTED
            except (SessionError, WebSocketError, TelegramError, OSError) as exc:
                self.logger.warning("session_ended", error=str(exc))
                fired = self._session_failure_exit(exc)
                if fired is not None:
                    return fired
            if delivered:
                self._channel_failures = 0
                self._transient_failures = 0
                return EXIT_OK
            self._wait_backoff(attempt)
            attempt += 1
        self.logger.info("stopped")
        return EXIT_STOPPED

    def _session_failure_exit(self, exc) -> int | None:
        """Counts a session outcome toward the --once bounds; returns the exit
        code when a bound fired, else None (and resets runs it breaks)."""
        if isinstance(exc, TelegramError) and exc.is_channel_error:
            self._channel_failures += 1
            self._transient_failures = 0
            if self._once_bound_reached(self._channel_failures):
                self.logger.error("channel_gave_up", attempts=self._channel_failures)
                return EXIT_CHANNEL_FAILED
            return None
        if isinstance(exc, TelegramError):
            # E-1: persistent retryable failures (stuck 500/429 upstream) must
            # also end a --once probe deterministically — without quarantining
            # the still-pending notification.
            self._transient_failures += 1
            self._channel_failures = 0
            if self._once_bound_reached(self._transient_failures):
                self.logger.error("delivery_gave_up", attempts=self._transient_failures)
                return EXIT_DELIVERY_FAILED
            return None
        # Any other session outcome (ws drop, protocol deviation) ends the
        # runs of consecutive channel and transient failures.
        self._channel_failures = 0
        self._transient_failures = 0
        return None

    def _once_bound_reached(self, failures: int) -> bool:
        # A --once live probe must terminate deterministically once a run of
        # consecutive failures — channel failures, retryable delivery
        # failures, or auth rejections — fills one full backoff cycle; any
        # other session outcome resets the runs (see run()).
        if not self.once:
            return False
        limit = len(self.config.reconnect_backoff or (1.0,))
        return failures >= limit

    def _reaffirm_chat_id(self) -> int:
        # After "chat not found" the configured id is re-affirmed — never
        # re-picked from getUpdates, which could select somebody else's chat.
        self._chat_id = self.config.telegram_chat_id
        self.logger.info("chat_id_reaffirmed", chat_id=self._chat_id)
        return self._chat_id

    def _session(self) -> bool:
        ws = self.ws_factory()
        try:
            ws.connect()
            ws.send_text(auth_frame(self.config.multica_pat))
            self._read_auth_response(ws)
            self._auth_failures = 0
            self.logger.info("auth_ok", server=self.config.server_url)
            return self._event_loop(ws)
        finally:
            ws.close()

    def _read_auth_response(self, ws) -> None:
        frame = parse_server_frame(ws.recv_message())
        if frame is None:
            raise SessionError("auth response is not a JSON object")
        if is_auth_error(frame):
            raise AuthRejected(auth_error_message(frame))
        if not is_auth_ack(frame):
            raise SessionError(f"unexpected first frame type: {frame.get('type')!r}")

    def _event_loop(self, ws) -> bool:
        while True:
            frame = parse_server_frame(ws.recv_message())
            if frame is None:
                self.logger.debug("malformed_frame_ignored")
                continue
            delivered = self._dispatch_frame(frame)
            if delivered:
                return True

    def _dispatch_frame(self, frame: dict) -> bool:
        if frame.get("type") != EVENT_INBOX_NEW:
            self.logger.debug("event_ignored", frame_type=str(frame.get("type")))
            return False
        item = parse_inbox_new(frame)
        if item is None:
            self.logger.debug("inbox_frame_unparseable_ignored")
            return False
        workspace = item_workspace_id(item)
        if workspace != self.config.workspace_id:
            self.logger.debug("other_workspace_ignored", workspace_id=workspace)
            return False
        return self._deliver(item)

    def _deliver(self, item: dict) -> bool:
        item_id = inbox_item_id(item)
        if self.state.is_seen(item_id):
            self.logger.debug("duplicate_skipped", item_id=item_id)
            return False
        text = format_notification(item)
        try:
            result = self._send_notification(text)
        except TelegramError as exc:
            if exc.retryable or exc.is_channel_error:
                # Transient or channel-level failure: the item stays pending
                # and the session loop retries — only a rejection of the
                # message itself may quarantine it.
                raise
            # A permanent rejection would otherwise be treated as an ordinary
            # session end and re-sent on every reconnect forever; record the
            # item as handled (quarantine) so redelivery loops cannot start.
            self.state.mark_seen(item_id)
            self.logger.error("delivery_failed_permanent", item_id=item_id, error=str(exc))
            return False
        self.state.mark_seen(item_id)
        self.logger.info(
            "delivered", item_id=item_id, message_id=result.get("message_id"),
            inbox_type=str(item.get("type")), title=str(item.get("title")))
        return self.once

    def _send_notification(self, text: str) -> dict:
        try:
            return self.telegram.send_message(
                self._chat_id, text, retries=self.config.send_retries, sleep=self.sleep)
        except TelegramError as exc:
            if not self._is_stale_chat_error(exc):
                raise
            self.logger.warning("stale_chat_id", error=str(exc))
            self._chat_id = self._reaffirm_chat_id()
            try:
                return self.telegram.send_message(
                    self._chat_id, text, retries=self.config.send_retries, sleep=self.sleep)
            except TelegramError as retry_exc:
                if not self._is_stale_chat_error(retry_exc):
                    raise
                # Fresh id rejected again means the channel hasn't recovered
                # (e.g. the user hasn't /started the bot yet) — surface it as
                # channel-level so the item stays pending, never quarantined.
                raise TelegramError(
                    str(retry_exc), retryable=retry_exc.retryable,
                    error_code=retry_exc.error_code,
                    is_channel_error=True) from retry_exc

    @staticmethod
    def _is_stale_chat_error(exc: TelegramError) -> bool:
        # Telegram reports a dead chat as HTTP 400 "chat not found".
        return exc.error_code == 400 and "chat not found" in str(exc).lower()

    def _stopped(self) -> bool:
        return self.stop_event is not None and self.stop_event.is_set()

    def _wait_backoff(self, attempt: int) -> None:
        delays = self.config.reconnect_backoff or (1.0,)
        delay = delays[min(attempt, len(delays) - 1)]
        self.logger.info("reconnect_scheduled", delay_seconds=delay, attempt=attempt + 1)
        if self.stop_event is not None:
            # Event wait instead of sleep keeps shutdown prompt mid-backoff.
            self.stop_event.wait(delay)
        else:
            self.sleep(delay)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Multica realtime inbox:new → Telegram bot notification adapter")
    parser.add_argument("--config", required=True,
                        help="dotenv-style config file with NOTIFIER_* keys")
    parser.add_argument("--once", action="store_true",
                        help="exit after the first delivered notification (live probe)")
    parser.add_argument("--log-json", default=None,
                        help="append structured JSONL logs to this file (secret-free)")
    args = parser.parse_args(argv)
    try:
        config = load_config_file(args.config)
    except (ConfigError, OSError) as exc:
        print(json.dumps({"level": "error", "event": "config_error", "error": str(exc)}),
              file=sys.stderr)
        return EXIT_CONFIG
    logger = JsonLogger(Redactor([config.multica_pat, config.telegram_bot_token]),
                        file_path=args.log_json)
    telegram, state, ws_factory = build_components(config)
    notifier = Notifier(config, logger, telegram, state, ws_factory, once=args.once)
    try:
        return notifier.run()
    except KeyboardInterrupt:
        logger.info("interrupted")
        return EXIT_INTERRUPTED
    finally:
        logger.close()


if __name__ == "__main__":
    sys.exit(main())
