"""Config loading: dotenv parsing, required keys, defaults, ws URL derivation."""

import os

import pytest

from multica_telegram_notifier.config import (
    ConfigError,
    load_config,
    load_config_file,
    parse_env_text,
    ws_url,
)

REQUIRED = {
    "NOTIFIER_MULTICA_PAT": "test-pat-value-0123456789",
    "NOTIFIER_TELEGRAM_BOT_TOKEN": "test-bot-token-value",
    "NOTIFIER_TELEGRAM_CHAT_ID": "987654",
    "NOTIFIER_MULTICA_SERVER_URL": "http://multica.internal:9278",
    "NOTIFIER_WORKSPACE_ID": "1a011680-a476-4553-929d-478690824e46",
}


class TestParseEnvText:
    def test_basic_pairs(self):
        assert parse_env_text("A=1\nB=two") == {"A": "1", "B": "two"}

    def test_comments_and_blank_lines_skipped(self):
        assert parse_env_text("# comment\n\nA=1\n   # indented comment\n") == {"A": "1"}

    def test_quotes_stripped(self):
        assert parse_env_text('A="quoted"\nB=\'single\'') == {"A": "quoted", "B": "single"}

    def test_value_may_contain_equals(self):
        assert parse_env_text("A=x=y=z") == {"A": "x=y=z"}

    def test_blank_value_kept_as_empty(self):
        assert parse_env_text("A=") == {"A": ""}

    def test_line_without_equals_is_ignored(self):
        # A stray non-comment line (no "=") must be skipped, not turned into a
        # bogus empty key.
        assert parse_env_text("NOEQUALS\nA=1") == {"A": "1"}


class TestLoadConfig:
    def test_minimal_config_with_defaults(self):
        cfg = load_config(dict(REQUIRED))
        assert cfg.multica_pat == REQUIRED["NOTIFIER_MULTICA_PAT"]
        assert cfg.telegram_bot_token == REQUIRED["NOTIFIER_TELEGRAM_BOT_TOKEN"]
        assert cfg.telegram_chat_id == 987654
        assert cfg.server_url == "http://multica.internal:9278"
        assert cfg.workspace_id == REQUIRED["NOTIFIER_WORKSPACE_ID"]
        assert cfg.telegram_api_base == "https://api.telegram.org"
        assert cfg.reconnect_backoff == (1.0, 2.0, 4.0, 8.0, 15.0, 30.0)
        assert cfg.send_retries == (1.0, 2.0, 4.0)
        assert cfg.connect_timeout == 10.0
        assert cfg.read_timeout == 90.0
        assert cfg.state_file.endswith("state.json")

    @pytest.mark.parametrize("key", list(REQUIRED))
    def test_missing_required_key_fails_loudly_naming_the_key(self, key):
        env = {k: v for k, v in REQUIRED.items() if k != key}
        with pytest.raises(ConfigError) as exc:
            load_config(env)
        assert key in str(exc.value)

    def test_blank_required_value_fails(self):
        env = dict(REQUIRED)
        env["NOTIFIER_MULTICA_PAT"] = "  "
        with pytest.raises(ConfigError):
            load_config(env)

    def test_server_url_must_be_http_https(self):
        env = dict(REQUIRED)
        env["NOTIFIER_MULTICA_SERVER_URL"] = "ftp://multica.internal"
        with pytest.raises(ConfigError):
            load_config(env)

    def test_optional_overrides(self, tmp_path):
        env = dict(REQUIRED)
        env.update({
            "NOTIFIER_TELEGRAM_API_BASE": "http://127.0.0.1:1",
            "NOTIFIER_STATE_FILE": str(tmp_path / "s.json"),
            "NOTIFIER_RECONNECT_BACKOFF": "0.01,0.02",
            "NOTIFIER_SEND_RETRIES": "0.05",
            "NOTIFIER_CONNECT_TIMEOUT": "2.5",
            "NOTIFIER_READ_TIMEOUT": "2",
        })
        cfg = load_config(env)
        assert cfg.telegram_api_base == "http://127.0.0.1:1"
        assert cfg.state_file == str(tmp_path / "s.json")
        assert cfg.reconnect_backoff == (0.01, 0.02)
        assert cfg.send_retries == (0.05,)
        assert cfg.connect_timeout == 2.5
        assert cfg.read_timeout == 2.0

    def test_state_file_tilde_is_expanded(self):
        # E-2: the template documents a `~` path; a literal "~" directory in
        # the CWD would be silently wrong, so expanduser is part of loading.
        env = dict(REQUIRED)
        env["NOTIFIER_STATE_FILE"] = "~/.local/state/dev-forge/x/state.json"
        cfg = load_config(env)
        assert not cfg.state_file.startswith("~")
        assert cfg.state_file == os.path.expanduser("~/.local/state/dev-forge/x/state.json")

    def test_non_utf8_config_file_raises_config_error(self, tmp_path):
        # E-3: a non-UTF-8 config file is a configuration error (naming the
        # file), not an unhandled UnicodeDecodeError traceback.
        path = tmp_path / "bad.env"
        path.write_bytes(b"\xff\xfe not utf-8 at all\n")
        with pytest.raises(ConfigError) as exc:
            load_config_file(str(path))
        assert "bad.env" in str(exc.value) or "UTF-8" in str(exc.value)

    def test_invalid_backoff_fails_naming_key(self):
        env = dict(REQUIRED)
        env["NOTIFIER_RECONNECT_BACKOFF"] = "1,abc"
        with pytest.raises(ConfigError) as exc:
            load_config(env)
        assert "NOTIFIER_RECONNECT_BACKOFF" in str(exc.value)

    @pytest.mark.parametrize("key", ["NOTIFIER_RECONNECT_BACKOFF", "NOTIFIER_SEND_RETRIES"])
    def test_empty_delay_list_fails_naming_key(self, key):
        # ",," is non-blank (so it is not replaced by the default) yet parses
        # to zero delays — an explicit configuration error, not a silent empty
        # backoff that would make the once-bound a no-op.
        env = dict(REQUIRED)
        env[key] = ",,"
        with pytest.raises(ConfigError) as exc:
            load_config(env)
        assert key in str(exc.value)

    @pytest.mark.parametrize("key", ["NOTIFIER_RECONNECT_BACKOFF", "NOTIFIER_SEND_RETRIES"])
    def test_negative_delay_fails_naming_key(self, key):
        env = dict(REQUIRED)
        env[key] = "-1"
        with pytest.raises(ConfigError) as exc:
            load_config(env)
        assert key in str(exc.value)

    def test_negative_timeout_fails(self):
        env = dict(REQUIRED)
        env["NOTIFIER_CONNECT_TIMEOUT"] = "-1"
        with pytest.raises(ConfigError):
            load_config(env)

    def test_non_numeric_read_timeout_fails(self):
        env = dict(REQUIRED)
        env["NOTIFIER_READ_TIMEOUT"] = "abc"
        with pytest.raises(ConfigError) as exc:
            load_config(env)
        assert "NOTIFIER_READ_TIMEOUT" in str(exc.value)

    def test_non_positive_read_timeout_fails(self):
        env = dict(REQUIRED)
        env["NOTIFIER_READ_TIMEOUT"] = "0"
        with pytest.raises(ConfigError):
            load_config(env)

    def test_non_integer_chat_id_fails(self):
        env = dict(REQUIRED)
        env["NOTIFIER_TELEGRAM_CHAT_ID"] = "not-a-number"
        with pytest.raises(ConfigError) as exc:
            load_config(env)
        assert "NOTIFIER_TELEGRAM_CHAT_ID" in str(exc.value)

    @pytest.mark.parametrize("raw", ["0", "-5"])
    def test_non_positive_chat_id_fails(self, raw):
        env = dict(REQUIRED)
        env["NOTIFIER_TELEGRAM_CHAT_ID"] = raw
        with pytest.raises(ConfigError) as exc:
            load_config(env)
        assert "NOTIFIER_TELEGRAM_CHAT_ID" in str(exc.value)

    @pytest.mark.parametrize("key", [
        "NOTIFIER_CONNECT_TIMEOUT",
        "NOTIFIER_READ_TIMEOUT",
        "NOTIFIER_RECONNECT_BACKOFF",
        "NOTIFIER_SEND_RETRIES",
    ])
    @pytest.mark.parametrize("raw", ["nan", "inf", "-inf"])
    def test_non_finite_time_and_backoff_values_fail(self, key, raw):
        env = dict(REQUIRED)
        env[key] = raw
        with pytest.raises(ConfigError) as exc:
            load_config(env)
        assert key in str(exc.value)

    def test_trailing_slash_on_server_url_is_stripped(self):
        env = dict(REQUIRED)
        env["NOTIFIER_MULTICA_SERVER_URL"] = "http://multica.internal:9278/"
        assert load_config(env).server_url == "http://multica.internal:9278"

    def test_process_env_used_as_fallback(self, tmp_path, monkeypatch):
        # Only one key lives in the file; the rest come from the process env.
        for k, v in REQUIRED.items():
            monkeypatch.setenv(k, v)
        env_path = tmp_path / "partial.env"
        env_path.write_text("NOTIFIER_WORKSPACE_ID=from-file\n", encoding="utf-8")
        cfg = load_config_file(str(env_path))
        assert cfg.workspace_id == "from-file"
        assert cfg.multica_pat == REQUIRED["NOTIFIER_MULTICA_PAT"]
        assert cfg.telegram_bot_token == REQUIRED["NOTIFIER_TELEGRAM_BOT_TOKEN"]
        assert cfg.server_url == REQUIRED["NOTIFIER_MULTICA_SERVER_URL"]

    def test_file_values_win_over_process_env(self, tmp_path, monkeypatch):
        for k, v in REQUIRED.items():
            monkeypatch.setenv(k, "env-loses")
        env_path = tmp_path / "full.env"
        env_path.write_text(
            "\n".join(f"{k}={v}" for k, v in REQUIRED.items()), encoding="utf-8")
        cfg = load_config_file(str(env_path))
        assert cfg.workspace_id == REQUIRED["NOTIFIER_WORKSPACE_ID"]
        assert cfg.multica_pat == REQUIRED["NOTIFIER_MULTICA_PAT"]


class TestWsUrl:
    def test_http_derives_ws_with_query(self):
        cfg = load_config(dict(REQUIRED))
        url = ws_url(cfg)
        assert url == (
            "ws://multica.internal:9278/ws"
            "?workspace_id=1a011680-a476-4553-929d-478690824e46"
        )

    def test_https_derives_wss(self):
        env = dict(REQUIRED)
        env["NOTIFIER_MULTICA_SERVER_URL"] = "https://multica.internal"
        assert ws_url(load_config(env)).startswith("wss://multica.internal/ws?")


class TestMetadataApiConfig:
    BASE_ENV = {
        "NOTIFIER_MULTICA_PAT": "p",
        "NOTIFIER_TELEGRAM_BOT_TOKEN": "t",
        "NOTIFIER_TELEGRAM_CHAT_ID": "1",
        "NOTIFIER_MULTICA_SERVER_URL": "http://srv.example",
        "NOTIFIER_WORKSPACE_ID": "ws",
    }

    def test_api_base_defaults_to_server_url(self):
        cfg = load_config(self.BASE_ENV)
        assert cfg.api_base == "http://srv.example"

    def test_api_base_override(self):
        cfg = load_config(dict(self.BASE_ENV, NOTIFIER_API_BASE="http://api.example/"))
        assert cfg.api_base == "http://api.example"

    def test_query_timeout_default(self):
        cfg = load_config(self.BASE_ENV)
        assert cfg.query_timeout == 5.0

    def test_query_timeout_override_and_validation(self):
        cfg = load_config(dict(self.BASE_ENV, NOTIFIER_QUERY_TIMEOUT="0.3"))
        assert cfg.query_timeout == 0.3
        with pytest.raises(ConfigError):
            load_config(dict(self.BASE_ENV, NOTIFIER_QUERY_TIMEOUT="0"))


class TestWebBaseConfig:
    """§SPEC-002 R2: the optional deep-link web root key. Loading stays
    permissive — an invalid value degrades links at render time (it must
    never fall back to the API origin), it must not fail startup."""

    BASE_ENV = {
        "NOTIFIER_MULTICA_PAT": "p",
        "NOTIFIER_TELEGRAM_BOT_TOKEN": "t",
        "NOTIFIER_TELEGRAM_CHAT_ID": "1",
        "NOTIFIER_MULTICA_SERVER_URL": "http://srv.example:9278",
        "NOTIFIER_WORKSPACE_ID": "ws",
    }

    def test_unset_defaults_to_empty(self):
        cfg = load_config(self.BASE_ENV)
        assert cfg.web_base_url == ""

    def test_override_stripped_and_trailing_slash_removed(self):
        cfg = load_config(dict(
            self.BASE_ENV, NOTIFIER_WEB_BASE_URL="http://192.168.1.210:9277/"))
        assert cfg.web_base_url == "http://192.168.1.210:9277"

    def test_blank_value_treated_as_unset(self):
        cfg = load_config(dict(self.BASE_ENV, NOTIFIER_WEB_BASE_URL="  "))
        assert cfg.web_base_url == ""

    def test_invalid_value_does_not_fail_startup(self):
        # Degradation contract: link-time gates reject this; config load
        # must stay green so notifications keep flowing unlinked.
        cfg = load_config(dict(self.BASE_ENV, NOTIFIER_WEB_BASE_URL="not a url"))
        assert cfg.web_base_url == "not a url"
