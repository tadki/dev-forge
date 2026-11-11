"""Telegram Bot API client (§SPEC-002).

Secret discipline: the bot token appears only inside the request URL, which
never reaches a log or exception — errors are rebuilt from the status code
and response description (Telegram's own text, which contains no client
secret), with the original exception context suppressed.
"""

import json
import socket
import time
import urllib.error
import urllib.request

RETRYABLE_HTTP = {408, 429, 500, 502, 503, 504}


class TelegramError(Exception):
    def __init__(self, message: str, retryable: bool = True):
        super().__init__(message)
        self.retryable = retryable


class TelegramClient:
    def __init__(self, api_base: str, bot_token: str, timeout: float = 10.0):
        self.api_base = api_base.rstrip("/")
        self.bot_token = bot_token
        self.timeout = timeout

    def send_message(self, chat_id: int, text: str, retries=(), sleep=time.sleep) -> dict:
        attempts = 1 + len(retries)
        for attempt in range(attempts):
            try:
                body = self._call("sendMessage", {"chat_id": chat_id, "text": text})
                return body.get("result", {})
            except TelegramError as exc:
                if not exc.retryable or attempt == attempts - 1:
                    raise
                sleep(retries[attempt])
        raise TelegramError("sendMessage: retries exhausted", retryable=True)

    def get_updates(self) -> list:
        body = self._call("getUpdates", {})
        result = body.get("result")
        if not isinstance(result, list):
            raise TelegramError("getUpdates returned an invalid result", retryable=False)
        return result

    def discover_chat_id(self) -> int:
        for update in reversed(self.get_updates()):
            chat = self._private_chat(update)
            if chat is not None:
                return chat["id"]
        raise TelegramError(
            "no private chat found in getUpdates; open the new bot in Telegram "
            "and send /start first",
            retryable=False,
        )

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
            raise TelegramError(
                f"telegram {method} HTTP {exc.code}",
                retryable=exc.code in RETRYABLE_HTTP,
            ) from None
        except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as exc:
            reason = type(exc).__name__
            raise TelegramError(
                f"telegram {method} network error: {reason}", retryable=True) from None
        try:
            body = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise TelegramError(
                f"telegram {method} returned invalid JSON", retryable=True) from None
        if not isinstance(body, dict) or body.get("ok") is not True:
            description = body.get("description", "invalid response") if isinstance(body, dict) else "invalid response"
            raise TelegramError(
                f"telegram {method} failed: {description}", retryable=False)
        return body

    @staticmethod
    def _private_chat(update):
        if not isinstance(update, dict):
            return None
        message = update.get("message")
        if not isinstance(message, dict):
            return None
        chat = message.get("chat")
        if not isinstance(chat, dict):
            return None
        if chat.get("type") != "private" or not isinstance(chat.get("id"), int):
            return None
        return chat
