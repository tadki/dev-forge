"""Deterministic mock-based coverage for version_check.py (SEE-889).

The pre-existing test_version_check.py covers the pure helpers and runs the
script end-to-end against the LIVE multica CLI and the LIVE GitHub API (it
skips on network failure). That leaves the I/O boundaries untested in CI:
`parse_current_version()` shells out to `multica version`, and
`http_get_json()` / `fetch_releases()` hit api.github.com.

This file adds deterministic coverage by mocking those two boundaries so the
full pipeline (version parse -> release fetch -> filter -> analyze -> report ->
comment posting) can be exercised without `multica` installed and without any
network access. Covers normal path, boundary (no newer versions), and the
three error paths (version parse fail, fetch HTTP error, fetch URL error).
"""

import argparse
import io
import json
import os
import subprocess
import sys
import urllib.error

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

import pytest

import version_check as vc


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _completed(stdout="", stderr="", returncode=0):
    return subprocess.CompletedProcess(
        args=["multica", "version"],
        returncode=returncode, stdout=stdout, stderr=stderr,
    )


class _FakeResponse:
    """Minimal stand-in for the object returned by urllib.request.urlopen."""

    def __init__(self, payload_bytes):
        self._payload = payload_bytes

    def read(self):
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _set_args(**overrides):
    """Build a Namespace matching every field main() reads off the global args."""
    defaults = dict(
        max_releases=20,
        dry_run=True,
        issue_id="",
        kill_switch="false",
        verbose=False,
        output_json=True,
    )
    defaults.update(overrides)
    vc.args = argparse.Namespace(**defaults)
    return vc.args


# ---------------------------------------------------------------------------
# parse_current_version: mock `multica version` subprocess
# ---------------------------------------------------------------------------

class TestParseCurrentVersion:
    def test_parses_semver_from_multica_output(self, monkeypatch):
        monkeypatch.setattr(
            vc.subprocess, "run",
            lambda *a, **k: _completed(
                stdout="multica 0.3.8 (commit: e351f898, built: 2026-05-25T12:30:29Z)"
            ),
        )
        version, output = vc.parse_current_version()
        assert version == "0.3.8"
        assert "0.3.8" in output

    def test_handles_double_digit_parts(self, monkeypatch):
        monkeypatch.setattr(
            vc.subprocess, "run",
            lambda *a, **k: _completed(stdout="multica 1.12.300 (commit: abc)"),
        )
        version, _ = vc.parse_current_version()
        assert version == "1.12.300"

    def test_returns_none_on_nonzero_exit(self, monkeypatch):
        monkeypatch.setattr(
            vc.subprocess, "run",
            lambda *a, **k: _completed(returncode=1, stderr="multica: not logged in"),
        )
        version, msg = vc.parse_current_version()
        assert version is None
        assert "not logged in" in msg

    def test_returns_none_on_unparseable_output(self, monkeypatch):
        monkeypatch.setattr(
            vc.subprocess, "run",
            lambda *a, **k: _completed(stdout="totally unrelated text"),
        )
        version, msg = vc.parse_current_version()
        assert version is None
        assert "unable to parse" in msg

    def test_returns_none_on_subprocess_exception(self, monkeypatch):
        def _boom(*a, **k):
            raise FileNotFoundError("[Errno 2] multica: command not found")

        monkeypatch.setattr(vc.subprocess, "run", _boom)
        version, msg = vc.parse_current_version()
        assert version is None
        assert "command not found" in msg


# ---------------------------------------------------------------------------
# http_get_json / fetch_releases: mock the GitHub API call
# ---------------------------------------------------------------------------

class TestHttpGetJson:
    def test_success_returns_parsed_json(self, monkeypatch):
        payload = [{"tag_name": "v0.3.12"}, {"tag_name": "v0.3.11"}]
        monkeypatch.setattr(
            vc.urllib.request, "urlopen",
            lambda req, timeout: _FakeResponse(json.dumps(payload).encode()),
        )
        ok, data = vc.http_get_json("https://api.github.com/repos/x/y/releases")
        assert ok is True
        assert data == payload

    def test_http_error_returns_false_with_status(self, monkeypatch):
        def _raise(*a, **k):
            raise urllib.error.HTTPError(
                url="https://api.github.com/repos/x/y/releases",
                code=403, msg="Forbidden", hdrs=None,
                fp=io.BytesIO(b"rate limited"),
            )

        monkeypatch.setattr(vc.urllib.request, "urlopen", _raise)
        ok, err = vc.http_get_json("https://api.github.com/repos/x/y/releases")
        assert ok is False
        assert "403" in err

    def test_url_error_returns_false_with_reason(self, monkeypatch):
        def _raise(*a, **k):
            raise urllib.error.URLError("Connection refused")

        monkeypatch.setattr(vc.urllib.request, "urlopen", _raise)
        ok, err = vc.http_get_json("https://api.github.com/repos/x/y/releases")
        assert ok is False
        assert "Connection refused" in err

    def test_json_decode_error_returns_false(self, monkeypatch):
        monkeypatch.setattr(
            vc.urllib.request, "urlopen",
            lambda req, timeout: _FakeResponse(b"<<<not json>>>"),
        )
        ok, err = vc.http_get_json("https://api.github.com/repos/x/y/releases")
        assert ok is False
        assert "JSON decode" in err


class TestFetchReleases:
    def test_wraps_http_get_json_and_returns_list(self, monkeypatch):
        payload = [{"tag_name": "v0.3.12"}]
        captured = {}

        def _fake_urlopen(req, timeout):
            captured["url"] = req.full_url
            captured["per_page"] = "per_page=15" in req.full_url
            return _FakeResponse(json.dumps(payload).encode())

        monkeypatch.setattr(vc.urllib.request, "urlopen", _fake_urlopen)
        ok, data = vc.fetch_releases(per_page=15)
        assert ok is True
        assert data == payload
        assert "releases" in captured["url"]
        assert captured["per_page"] is True

    def test_propagates_fetch_failure(self, monkeypatch):
        def _raise(*a, **k):
            raise urllib.error.URLError("offline")

        monkeypatch.setattr(vc.urllib.request, "urlopen", _raise)
        ok, err = vc.fetch_releases()
        assert ok is False
        assert "offline" in err


# ---------------------------------------------------------------------------
# post_report_comment: dry-run safety
# ---------------------------------------------------------------------------

class TestPostReportComment:
    def test_dry_run_never_posts(self):
        result = vc.post_report_comment("issue-123", "## report", dry_run=True)
        assert result["posted"] is False
        assert result["reason"] == "dry_run"

    def test_no_issue_id_does_not_post(self):
        result = vc.post_report_comment("", "## report", dry_run=False)
        assert result["posted"] is False
        assert result["reason"] == "no_issue_id"

    def test_posts_via_multica_cli_when_not_dry_run(self, monkeypatch):
        called = {}

        def _fake_stdin_cmd(cmd, content, timeout):
            called["cmd"] = cmd
            called["content"] = content
            return True, "comment-id-abc"

        monkeypatch.setattr(vc, "multica_stdin_cmd", _fake_stdin_cmd)
        result = vc.post_report_comment("issue-123", "## report", dry_run=False)
        assert result["posted"] is True
        assert result["issue_id"] == "issue-123"
        assert "--content-stdin" in called["cmd"]

    def test_cli_error_is_captured(self, monkeypatch):
        monkeypatch.setattr(
            vc, "multica_stdin_cmd",
            lambda cmd, content, timeout: (False, "boom"),
        )
        result = vc.post_report_comment("issue-123", "## report", dry_run=False)
        assert result["posted"] is False
        assert result["reason"] == "cli_error"
        assert result["error"] == "boom"


# ---------------------------------------------------------------------------
# main() pipeline: both boundaries mocked -> deterministic dry-run coverage
# ---------------------------------------------------------------------------

def _release(tag, body):
    return {"tag_name": tag, "name": tag, "published_at": "2026-05-28T10:00:00Z", "body": body}


class TestMainPipeline:
    def test_no_newer_versions(self, monkeypatch, capsys):
        monkeypatch.setattr(vc, "parse_current_version", lambda: ("0.3.20", "multica 0.3.20"))
        monkeypatch.setattr(vc, "fetch_releases", lambda per_page=20: (True, []))
        _set_args()
        vc.main()

        data = json.loads(capsys.readouterr().out)
        assert data["summary"]["current_version"] == "0.3.20"
        assert data["summary"]["newer_versions_count"] == 0
        assert data["summary"]["newer_version_tags"] == []
        assert data["summary"]["dry_run"] is True
        assert data["comment_result"]["reason"] == "dry_run"
        assert "当前已是最新版本" in data["markdown_report"]

    def test_filters_and_sorts_newer_versions(self, monkeypatch, capsys):
        # current 0.3.20; GitHub returns older + newer, out of order.
        releases = [
            _release("v0.3.19", "* old commit\n"),
            _release("v0.3.22", "* 2222222 feat(api): newer thing (#9)\n"),
            _release("v0.3.21", "* 1111111 fix(ui): a fix (#8)\n"),
        ]
        monkeypatch.setattr(vc, "parse_current_version", lambda: ("0.3.20", "multica 0.3.20"))
        monkeypatch.setattr(vc, "fetch_releases", lambda per_page=20: (True, releases))
        _set_args()

        vc.main()

        data = json.loads(capsys.readouterr().out)
        # 0.3.19 filtered out (not newer); 0.3.21/0.3.22 kept and sorted ascending.
        assert data["summary"]["newer_versions_count"] == 2
        assert data["summary"]["newer_version_tags"] == ["v0.3.21", "v0.3.22"]
        report = data["markdown_report"]
        assert "v0.3.21" in report and "v0.3.22" in report
        assert "v0.3.19" not in report

    def test_version_parse_failure_emits_error_json(self, monkeypatch, capsys):
        monkeypatch.setattr(vc, "parse_current_version", lambda: (None, "multica: command not found"))
        _set_args()
        vc.main()

        data = json.loads(capsys.readouterr().out)
        assert "error" in data
        assert "command not found" in data["error"]
        assert any("phase1_version_parse_failed" in line for line in data["processing_log"])

    def test_fetch_failure_emits_error_json(self, monkeypatch, capsys):
        monkeypatch.setattr(vc, "parse_current_version", lambda: ("0.3.20", "multica 0.3.20"))
        monkeypatch.setattr(vc, "fetch_releases", lambda per_page=20: (False, "HTTP 403: rate limited"))
        _set_args()
        vc.main()

        data = json.loads(capsys.readouterr().out)
        assert "error" in data
        assert "403" in data["error"]
        assert data["current_version"] == "0.3.20"

    def test_dry_run_never_invokes_multica_comment(self, monkeypatch, capsys):
        # If dry-run is honored, post_report_comment must short-circuit and the
        # CLI helper must never be called.
        def _fail_if_called(*a, **k):
            raise AssertionError("multica_stdin_cmd must not be called in dry-run")

        monkeypatch.setattr(vc, "multica_stdin_cmd", _fail_if_called)
        monkeypatch.setattr(vc, "parse_current_version", lambda: ("0.3.20", "multica 0.3.20"))
        monkeypatch.setattr(vc, "fetch_releases",
                            lambda per_page=20: (True, [_release("v0.3.21", "* feat: x\n")]))
        _set_args(dry_run=True, issue_id="issue-999")
        vc.main()

        data = json.loads(capsys.readouterr().out)
        assert data["summary"]["dry_run"] is True
        assert data["comment_result"]["posted"] is False
        assert data["comment_result"]["reason"] == "dry_run"

    def test_markdown_mode_prints_report_not_json(self, monkeypatch, capsys):
        monkeypatch.setattr(vc, "parse_current_version", lambda: ("0.3.20", "multica 0.3.20"))
        monkeypatch.setattr(vc, "fetch_releases", lambda per_page=20: (True, []))
        _set_args(output_json=False)
        vc.main()

        out = capsys.readouterr().out
        assert "## Multica 版本更新分析报告" in out
        with pytest.raises(json.JSONDecodeError):
            json.loads(out)
