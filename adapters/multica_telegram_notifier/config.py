"""Config loading for the notifier.

Dotenv-style file, values override the process environment (the file is the
operator-curated secret surface; env vars are only a convenience fallback).
Missing required keys fail loudly naming the key — never guess a default for
a credential or endpoint.
"""

import os
import urllib.parse
from dataclasses import dataclass
from typing import Mapping

DEFAULT_TELEGRAM_API_BASE = "https://api.telegram.org"
DEFAULT_CONNECT_TIMEOUT = 10.0
# Must exceed the Multica server ping interval (~54 s): a longer quiet
# stretch means the link is dead and the session should be rebuilt.
DEFAULT_READ_TIMEOUT = 90.0

REQUIRED_KEYS = (
    "NOTIFIER_MULTICA_PAT",
    "NOTIFIER_TELEGRAM_BOT_TOKEN",
    "NOTIFIER_MULTICA_SERVER_URL",
    "NOTIFIER_WORKSPACE_ID",
)


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Config:
    multica_pat: str
    telegram_bot_token: str
    server_url: str
    workspace_id: str
    state_file: str
    telegram_api_base: str
    reconnect_backoff: tuple
    send_retries: tuple
    connect_timeout: float
    read_timeout: float


def parse_env_text(text: str) -> dict:
    env = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            continue
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def default_state_file() -> str:
    base = os.path.join(os.path.expanduser("~"), ".local", "state", "dev-forge",
                        "multica-telegram-notifier")
    return os.path.join(base, "state.json")


def _parse_delays(raw: str, key: str) -> tuple:
    parts = [p.strip() for p in raw.split(",") if p.strip()]
    if not parts:
        raise ConfigError(f"{key} must be a comma-separated list of seconds")
    delays = []
    for part in parts:
        try:
            seconds = float(part)
        except ValueError as exc:
            raise ConfigError(f"{key} has a non-numeric delay: {part!r}") from exc
        if seconds < 0:
            raise ConfigError(f"{key} has a negative delay: {part!r}")
        delays.append(seconds)
    return tuple(delays)


def _parse_positive_seconds(raw: str, key: str) -> float:
    try:
        value = float(raw)
    except ValueError as exc:
        raise ConfigError(f"{key} is not a number: {raw!r}") from exc
    if value <= 0:
        raise ConfigError(f"{key} must be positive")
    return value


def load_config(env: Mapping) -> Config:
    def required(key: str) -> str:
        value = env.get(key)
        if value is None or not value.strip():
            raise ConfigError(f"missing required config key: {key}")
        return value.strip()

    server_url = required("NOTIFIER_MULTICA_SERVER_URL")
    if not server_url.startswith(("http://", "https://")):
        raise ConfigError(
            "NOTIFIER_MULTICA_SERVER_URL must start with http:// or https://, "
            f"got: {server_url[:40]}")

    def optional(key: str, default):
        value = env.get(key)
        return default if value is None or not value.strip() else value.strip()

    connect_timeout = _parse_positive_seconds(
        optional("NOTIFIER_CONNECT_TIMEOUT", str(DEFAULT_CONNECT_TIMEOUT)),
        "NOTIFIER_CONNECT_TIMEOUT")
    read_timeout = _parse_positive_seconds(
        optional("NOTIFIER_READ_TIMEOUT", str(DEFAULT_READ_TIMEOUT)),
        "NOTIFIER_READ_TIMEOUT")

    return Config(
        multica_pat=required("NOTIFIER_MULTICA_PAT"),
        telegram_bot_token=required("NOTIFIER_TELEGRAM_BOT_TOKEN"),
        server_url=server_url.rstrip("/"),
        workspace_id=required("NOTIFIER_WORKSPACE_ID"),
        state_file=optional("NOTIFIER_STATE_FILE", default_state_file()),
        telegram_api_base=optional("NOTIFIER_TELEGRAM_API_BASE", DEFAULT_TELEGRAM_API_BASE).rstrip("/"),
        reconnect_backoff=_parse_delays(
            optional("NOTIFIER_RECONNECT_BACKOFF", "1,2,4,8,15,30"), "NOTIFIER_RECONNECT_BACKOFF"),
        send_retries=_parse_delays(
            optional("NOTIFIER_SEND_RETRIES", "1,2,4"), "NOTIFIER_SEND_RETRIES"),
        connect_timeout=connect_timeout,
        read_timeout=read_timeout,
    )


def load_config_file(path: str) -> Config:
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    merged = dict(os.environ)
    merged.update(parse_env_text(text))
    return load_config(merged)


def ws_url(config: Config) -> str:
    if config.server_url.startswith("https://"):
        scheme, rest = "wss://", config.server_url[len("https://"):]
    else:
        scheme, rest = "ws://", config.server_url[len("http://"):]
    query = urllib.parse.quote(config.workspace_id, safe="")
    return f"{scheme}{rest}/ws?workspace_id={query}"
