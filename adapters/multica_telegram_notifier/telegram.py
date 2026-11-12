"""Telegram Bot API client (§SPEC-002).

Secret discipline: the bot token appears only inside the request URL, which
never reaches a log or exception — errors are rebuilt from the status code
and response description (Telegram's own text, which contains no client
secret), with the original exception context suppressed.
"""

import http.client
import json
import socket
import time
import urllib.error
import urllib.request

RETRYABLE_HTTP = {408, 429, 500, 502, 503, 504}

# Channel-level failures: the delivery pipe itself is broken (bot token
# invalid, bot blocked, endpoint not found) — notifications must stay
# pending until the channel recovers, never be quarantined per-message.
CHANNEL_HTTP_CODES = {401, 403, 404}

# Telegram sendMessage hard limit on the text field (Bot API contract).
MAX_TEXT_LENGTH = 4096


def truncate_utf16(text: str, limit: int = MAX_TEXT_LENGTH) -> str:
    # Telegram measures length in UTF-16 code units (non-BMP chars count 2),
    # so cutting by Python len() alone can still exceed the limit for
    # emoji-heavy text; cut on the UTF-16 byte stream instead.
    # errors="ignore" also drops lone surrogates (possible in upstream
    # "\udXXX" escapes) which would otherwise raise UnicodeEncodeError and
    # crash the notifier loop.
    encoded = text.encode("utf-16-le", errors="ignore")
    if len(encoded) <= limit * 2:
        return encoded.decode("utf-16-le")
    # errors="ignore" drops a dangling lone surrogate left by the byte cut.
    return encoded[: limit * 2].decode("utf-16-le", errors="ignore")


def _error_detail(exc) -> tuple:
    """Read (error_code, description) from a Telegram HTTP error body.

    Telegram returns non-2xx with a JSON body carrying error_code/description
    (e.g. 400 "chat not found"); body reads never raise here.
    """
    try:
        body = json.loads(exc.read().decode("utf-8"))
    except (OSError, ValueError, UnicodeDecodeError, http.client.HTTPException):
        # HTTPException (e.g. IncompleteRead on a truncated body) is neither
        # an OSError nor a ValueError, yet must never escape TelegramError.
        return None, ""
    if not isinstance(body, dict):
        return None, ""
    raw = body.get("error_code")
    return (raw if isinstance(raw, int) else None), str(body.get("description", ""))


def _ok_false_error(method: str, body) -> "TelegramError":
    """Build the error for an HTTP 200 + ok:false response: classify by the
    body's error_code so the channel/message split AND the retryable set
    match the HTTP-status path."""
    description = body.get("description", "invalid response") if isinstance(body, dict) else "invalid response"
    raw_code = body.get("error_code") if isinstance(body, dict) else None
    error_code = raw_code if isinstance(raw_code, int) else None
    return TelegramError(
        f"telegram {method} failed: {description}",
        retryable=error_code in RETRYABLE_HTTP,
        error_code=error_code,
        is_channel_error=error_code in CHANNEL_HTTP_CODES)


class TelegramError(Exception):
    def __init__(self, message: str, retryable: bool = True, error_code=None,
                 is_channel_error: bool = False):
        super().__init__(message)
        self.retryable = retryable
        self.error_code = error_code
        self.is_channel_error = is_channel_error


class TelegramClient:
    def __init__(self, api_base: str, bot_token: str, timeout: float = 10.0):
        self.api_base = api_base.rstrip("/")
        self.bot_token = bot_token
        self.timeout = timeout

    def send_message(self, chat_id: int, text: str, parse_mode=None,
                     retries=(), sleep=time.sleep) -> dict:
        # Truncate at the API boundary: one oversized inbox item must not
        # wedge delivery (Telegram rejects > 4096 UTF-16 units outright).
        text = truncate_utf16(text)
        attempts = 1 + len(retries)
        for attempt in range(attempts):
            try:
                body = self._call("sendMessage", _payload(chat_id, text, parse_mode))
                result = body.get("result")
                if not isinstance(result, dict):
                    # A broken/malicious proxy answer must not crash callers
                    # that read message_id off the result.
                    raise TelegramError(
                        "telegram sendMessage returned a non-object result: "
                        f"{type(result).__name__}",
                        retryable=True, is_channel_error=True)
                return result
            except TelegramError as exc:
                if not exc.retryable or attempt == attempts - 1:
                    raise
                sleep(retries[attempt])
        raise TelegramError("sendMessage: retries exhausted", retryable=True)

    # --- internals ---

    def _call(self, method: str, payload: dict) -> dict:
        url = f"{self.api_base}/bot{self.bot_token}/{method}"
        data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            url, data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            # exc and its __context__ embed the token-bearing URL; `from None`
            # keeps that context out of any traceback that reaches a log.
            error_code, description = _error_detail(exc)
            detail = description or f"HTTP {exc.code}"
            raise TelegramError(
                f"telegram {method} failed: {detail}",
                retryable=exc.code in RETRYABLE_HTTP,
                error_code=error_code,
                is_channel_error=exc.code in CHANNEL_HTTP_CODES,
            ) from None
        except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as exc:
            reason = type(exc).__name__
            raise TelegramError(
                f"telegram {method} network error: {reason}", retryable=True,
                is_channel_error=True) from None
        except http.client.HTTPException as exc:
            # Truncated/malformed HTTP framing (e.g. IncompleteRead on the
            # success body): same channel-level retryable treatment.
            raise TelegramError(
                f"telegram {method} http framing error: {type(exc).__name__}",
                retryable=True, is_channel_error=True) from None
        try:
            body = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise TelegramError(
                f"telegram {method} returned invalid JSON", retryable=True) from None
        if not isinstance(body, dict) or body.get("ok") is not True:
            # HTTP 200 + ok:false: classify by the body's error_code so the
            # channel/message split AND the retryable set match the
            # HTTP-status path.
            raise _ok_false_error(method, body)
        return body


def _payload(chat_id: int, text: str, parse_mode) -> dict:
    payload = {"chat_id": chat_id, "text": text}
    if parse_mode is not None:
        payload["parse_mode"] = parse_mode
    return payload


def is_parse_entity_error(exc: BaseException) -> bool:
    # §SPEC-004: Telegram reports an HTML entity it cannot parse as HTTP 400
    # "can't parse entities". Only that explicit rejection may trigger the
    # one-shot plain-text fallback; every other 400 keeps its classification.
    return (isinstance(exc, TelegramError)
            and exc.error_code == 400
            and "can't parse entities" in str(exc).lower())
