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

from multica_telegram_notifier.config import Config, ConfigError, load_config_file, ws_url
from multica_telegram_notifier.formatting import render_notification_parts, utf16_len
from multica_telegram_notifier.jsonlog import JsonLogger
from multica_telegram_notifier.multica_api import (
    MetadataResolver,
    MulticaApiError,
    looks_like_uuid,
)
from multica_telegram_notifier.protocol import (
    EVENT_INBOX_NEW,
    auth_error_message,
    auth_frame,
    inbox_item_id,
    is_auth_ack,
    is_auth_error,
    item_workspace_id,
    parse_inbox_new,
    parse_server_frame,
)
from multica_telegram_notifier.redact import Redactor
from multica_telegram_notifier.state import DedupState
from multica_telegram_notifier.telegram import (
    MAX_TEXT_LENGTH,
    TelegramClient,
    TelegramError,
    is_get_updates_conflict,
    is_parse_entity_error,
    truncate_utf16,
)
from multica_telegram_notifier.wsclient import WSClient, WebSocketError

EXIT_OK = 0
EXIT_CONFIG = 2
EXIT_STOPPED = 3
EXIT_AUTH_REJECTED = 4
EXIT_CHANNEL_FAILED = 5
EXIT_DELIVERY_FAILED = 6
EXIT_INTERRUPTED = 130

# Inbound reply-sync loop (§SPEC-004): long-poll seconds handed to Telegram;
# the fake-friendly client-side pauses only apply after failed/empty polls.
REPLY_POLL_TIMEOUT_SECONDS = 25
REPLY_POLL_ERROR_SLEEP = 1.0
REPLY_IDLE_SLEEP = 0.05


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


def build_resolver(config: Config) -> MetadataResolver:
    """Bounded read-only name lookups (§SPEC-001); failures degrade, never block.
    The deep-link web root is NOTIFIER_WEB_BASE_URL only (§SPEC-002 R2): the
    real deployment serves the Web UI and the API/WS on different ports (QA
    H1), so the API origin is never used as a link root. Unset/invalid
    values degrade to an unlinked header."""
    return MetadataResolver(
        config.api_base, config.multica_pat, config.workspace_id,
        timeout=config.query_timeout, web_base=config.web_base_url)


class ReplyReceiver:
    """Inbound reply-sync loop (§SPEC-004/006/007): long-polls getUpdates on
    its own thread and syncs Telegram replies — to messages this notifier
    delivered — back to Multica as comments under the original comment.

    Filters, in order: only the configured chat (D-1's inbound twin — any
    other chat is a leak surface, not a feature), only private chats, only
    replies, only replies whose reply_to_message_id is in the persisted
    mapping. A 409 getUpdates conflict (another consumer on the same bot
    token) disables inbound only — outbound delivery is untouched.
    """

    def __init__(self, config, logger, telegram, state, resolver,
                 sleep=time.sleep, stop_event: threading.Event = None,
                 poll_timeout=REPLY_POLL_TIMEOUT_SECONDS,
                 error_sleep=REPLY_POLL_ERROR_SLEEP,
                 idle_sleep=REPLY_IDLE_SLEEP):
        self.config = config
        self.logger = logger
        self.telegram = telegram
        self.state = state
        self.resolver = resolver
        self.sleep = sleep
        self.stop_event = stop_event
        self.poll_timeout = poll_timeout
        self.error_sleep = error_sleep
        self.idle_sleep = idle_sleep
        self.disabled = False

    def run(self) -> None:
        while not self._stopped() and not self.disabled:
            self.poll_once()

    def poll_once(self) -> None:
        try:
            updates = self.telegram.get_updates(
                self.state.offset or None, timeout=self.poll_timeout,
                allowed_updates=["message"])
        except TelegramError as exc:
            if is_get_updates_conflict(exc):
                self.disabled = True
                self.logger.warning("reply_sync_conflict_disabled", error=str(exc))
            else:
                self.logger.warning("reply_sync_poll_failed", error=str(exc))
                self.sleep(self.error_sleep)
            return
        for update in updates:
            self._process_update(update)
            update_id = update.get("update_id") if isinstance(update, dict) else None
            if isinstance(update_id, int):
                self.state.advance_offset(update_id + 1)
        if not updates and not self._stopped() and self.idle_sleep:
            # Real Telegram long-polls server-side; this only keeps the loop
            # honest against fakes/proxies that answer instantly.
            self.sleep(self.idle_sleep)

    def _process_update(self, update) -> None:
        if not isinstance(update, dict):
            return
        message = update.get("message")
        if not isinstance(message, dict):
            return
        chat = message.get("chat")
        if not isinstance(chat, dict):
            return
        if chat.get("id") != self.config.telegram_chat_id or chat.get("type") != "private":
            self.logger.debug("reply_other_chat_ignored")
            return
        reply_to = message.get("reply_to_message")
        reply_message_id = (reply_to.get("message_id")
                            if isinstance(reply_to, dict) else None)
        if not isinstance(reply_message_id, int):
            self.logger.debug("reply_non_reply_ignored")
            return
        target = self.state.lookup_reply(reply_message_id)
        if target is None:
            # Not our delivery (or its mapping aged out of the FIFO ring):
            # the reply cannot be attributed, so it is never posted.
            self.logger.debug("reply_without_mapping_ignored",
                              reply_to_message_id=reply_message_id)
            return
        text = message.get("text")
        if not (isinstance(text, str) and text.strip()):
            self.logger.debug("reply_empty_text_ignored")
            return
        issue_id, comment_id = target
        try:
            created = self.resolver.post_comment(issue_id, comment_id, text)
        except MulticaApiError as exc:
            # Safe error (no token/URL): log and keep looping; the offset
            # still advances so one broken update cannot wedge the queue.
            self.logger.error("comment_sync_failed", issue_id=issue_id,
                              parent_comment_id=comment_id, error=str(exc))
            return
        self.logger.info("comment_synced", issue_id=issue_id,
                         parent_comment_id=comment_id, comment_id=created)

    def _stopped(self) -> bool:
        return self.stop_event is not None and self.stop_event.is_set()


class Notifier:
    def __init__(self, config, logger, telegram, state, ws_factory,
                 sleep=time.sleep, stop_event: threading.Event = None, once: bool = False,
                 resolver: MetadataResolver = None):
        self.config = config
        self.logger = logger
        self.telegram = telegram
        self.state = state
        self.ws_factory = ws_factory
        self.sleep = sleep
        self.stop_event = stop_event
        self.once = once
        self.resolver = resolver
        # D-1: the configured chat id is the ONLY delivery target. Discovery
        # via getUpdates is deliberately absent — picking the "newest private
        # chat" could leak Inbox content to somebody else's chat.
        self._chat_id = config.telegram_chat_id
        self._auth_failures = 0
        self._channel_failures = 0
        self._transient_failures = 0
        self._total_failures = 0

    def run(self) -> int:
        self._start_reply_receiver()
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
                self._total_failures = 0
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
                self._total_failures = 0
                return EXIT_OK
            self._wait_backoff(attempt)
            attempt += 1
        self.logger.info("stopped")
        return EXIT_STOPPED

    def _start_reply_receiver(self) -> None:
        # §SPEC-004/008: the inbound loop is a steady-mode-only side thread;
        # --once is a bounded live probe and must never poll getUpdates.
        if not self.config.reply_sync or self.once:
            return
        if self.resolver is None:
            self.logger.warning("reply_sync_unavailable", reason="no resolver")
            return
        receiver = ReplyReceiver(self.config, self.logger, self.telegram,
                                 self.state, self.resolver,
                                 stop_event=self.stop_event)
        thread = threading.Thread(target=receiver.run, name="reply-sync",
                                  daemon=True)
        thread.start()
        self.logger.info("reply_sync_started")

    def _session_failure_exit(self, exc: Exception) -> int | None:
        """Counts a session outcome toward the --once bounds; returns the exit
        code when a bound fired, else None (and resets runs it breaks)."""
        if isinstance(exc, TelegramError) and exc.is_channel_error:
            self._channel_failures += 1
            self._transient_failures = 0
            self._total_failures += 1
            if self._once_bound_reached(self._channel_failures):
                self.logger.error("channel_gave_up", attempts=self._channel_failures)
                return EXIT_CHANNEL_FAILED
        elif isinstance(exc, TelegramError):
            # E-1: persistent retryable failures (stuck 500/429 upstream) must
            # also end a --once probe deterministically — without quarantining
            # the still-pending notification.
            self._transient_failures += 1
            self._channel_failures = 0
            self._total_failures += 1
            if self._once_bound_reached(self._transient_failures):
                self.logger.error("delivery_gave_up", attempts=self._transient_failures)
                return EXIT_DELIVERY_FAILED
        else:
            # Any other session outcome (ws drop, protocol deviation) ends the
            # runs of consecutive channel and transient failures.
            self._channel_failures = 0
            self._transient_failures = 0
            self._total_failures = 0
            return None
        # F-1: channel and transient counters clear each other, so strictly
        # alternating failures would never reach a per-class bound; the total
        # Telegram-failure run bounds the probe regardless of the pattern.
        if self._once_bound_reached(self._total_failures):
            self.logger.error("delivery_gave_up", attempts=self._total_failures)
            return EXIT_DELIVERY_FAILED
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
        # The id itself stays out of the logs (secret-surface discipline).
        self._chat_id = self.config.telegram_chat_id
        self.logger.info("chat_id_reaffirmed")
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
        return self._deliver(self._merge_frame_actor(item, frame))

    @staticmethod
    def _merge_frame_actor(item: dict, frame: dict) -> dict:
        # F6: the wire contract puts actor_id/actor_type at the frame top
        # level; fill them in for items that carry no actor fields of their
        # own, while item-embedded fields keep precedence (immutability: the
        # incoming item is copied, never mutated).
        merged = None
        for key in ("actor_type", "actor_id"):
            value = item.get(key)
            if (not isinstance(value, str) or not value.strip()) and isinstance(frame.get(key), str):
                if merged is None:
                    merged = dict(item)
                merged[key] = frame[key]
        return merged if merged is not None else item

    def _deliver(self, item: dict) -> bool:
        item_id = inbox_item_id(item)
        if self.state.is_seen(item_id):
            self.logger.debug("duplicate_skipped", item_id=item_id)
            return False
        parts = render_notification_parts(item, self.resolver,
                                          max_parts=self.config.max_parts)
        sends = []
        message_ids = []
        try:
            for part in parts:
                result, sent_text, sent_mode = self._send_notification(
                    part.html, part.plain)
                sends.append((result, sent_text, sent_mode))
                message_ids.append(result.get("message_id"))
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
        self._record_reply_mapping(item, message_ids)
        # §SPEC-007 evidence per part: each delivered event records the exact
        # outbound payload of its own message (surrogate-safe, ≤4096 UTF-16
        # units) so a real probe can verify readability and the no-bare-UUID
        # guarantee straight from the JSONL log; values still pass the Redactor.
        total = len(sends)
        for index, (result, sent_text, sent_mode) in enumerate(sends, 1):
            self.logger.info(
                "delivered", item_id=item_id, message_id=result.get("message_id"),
                part=index, part_count=total,
                inbox_type=str(item.get("type")), title=str(item.get("title")),
                parse_mode=sent_mode, text_units=utf16_len(sent_text),
                outbound_text=sent_text)
        return self.once

    @staticmethod
    def _reply_target(item: dict):
        """(issue_id, comment_id) when both are canonical UUIDs (§SPEC-005) —
        anything else can never be attributed to a comment, so no mapping is
        written (the post_comment gates would refuse it anyway)."""
        details = item.get("details")
        comment_id = details.get("comment_id") if isinstance(details, dict) else None
        issue_id = item.get("issue_id")
        if (isinstance(issue_id, str) and looks_like_uuid(issue_id)
                and isinstance(comment_id, str) and looks_like_uuid(comment_id)):
            return issue_id, comment_id
        return None

    def _record_reply_mapping(self, item: dict, message_ids: list) -> None:
        target = self._reply_target(item)
        if target is None:
            return
        issue_id, comment_id = target
        for message_id in message_ids:
            if isinstance(message_id, int):
                self.state.record_reply(message_id, issue_id, comment_id)

    def _send_notification(self, html: str, plain: str) -> tuple:
        # FR-2: both payloads pass the same boundary truncation BEFORE the
        # client, so the recorded outbound evidence (outbound_text/text_units)
        # equals the bytes actually sent. The HTML fitting already guarantees
        # ≤4096 here, so this pass is a no-op for it; the plain fallback can
        # be longer and must be truncated identically to the client's own cut.
        html = truncate_utf16(html, MAX_TEXT_LENGTH)
        plain = truncate_utf16(plain, MAX_TEXT_LENGTH)
        try:
            return self._send_with_stale_chat_retry(html, parse_mode="HTML"), html, "HTML"
        except TelegramError as exc:
            if not is_parse_entity_error(exc):
                raise
            # §SPEC-004: only the explicit HTML entity rejection downgrades to
            # a single plain-text send; all other errors keep their semantics.
            self.logger.warning("html_parse_rejected_plain_fallback", error=str(exc))
            return self._send_with_stale_chat_retry(plain, parse_mode=None), plain, None

    def _send_with_stale_chat_retry(self, text: str, parse_mode) -> dict:
        try:
            return self.telegram.send_message(
                self._chat_id, text, parse_mode=parse_mode,
                retries=self.config.send_retries, sleep=self.sleep)
        except TelegramError as exc:
            if not self._is_stale_chat_error(exc):
                raise
            self.logger.warning("stale_chat_id", error=str(exc))
            self._chat_id = self._reaffirm_chat_id()
            try:
                return self.telegram.send_message(
                    self._chat_id, text, parse_mode=parse_mode,
                    retries=self.config.send_retries, sleep=self.sleep)
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
    try:
        logger = JsonLogger(Redactor([config.multica_pat, config.telegram_bot_token]),
                            file_path=os.path.expanduser(args.log_json) if args.log_json else None)
    except OSError as exc:
        # An unwritable log path is a startup configuration problem: report it
        # under the config_error contract instead of a raw traceback exit 1.
        print(json.dumps({"level": "error", "event": "config_error",
                          "error": f"log file not writable: {exc}"}), file=sys.stderr)
        return EXIT_CONFIG
    telegram, state, ws_factory = build_components(config)
    notifier = Notifier(config, logger, telegram, state, ws_factory, once=args.once,
                        resolver=build_resolver(config))
    try:
        return notifier.run()
    except KeyboardInterrupt:
        logger.info("interrupted")
        return EXIT_INTERRUPTED
    finally:
        logger.close()


if __name__ == "__main__":
    sys.exit(main())
