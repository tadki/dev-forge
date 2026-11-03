"""§SPEC-007 (SEE-1516 substep B2, fingerprint 014f65842d53): 发帖路径门控。

version_check.py 曾把 --kill-switch 仅回显进 summary（:460），发帖路径
post_report_comment 只受 dry_run 门控 —— `kill_switch=true + dry_run=false`
照常发评论，Kill Switch 在最危险的发帖出口失效。本套件钉扎：kill-switch
门控与 dry_run 同级；true 时零发帖且 processing_log 留痕。
"""

import argparse
import json

import version_check as vc


def _set_args(**overrides):
    defaults = dict(
        max_releases=20,
        dry_run=False,
        issue_id="issue-999",
        kill_switch="false",
        verbose=True,
        output_json=True,
    )
    defaults.update(overrides)
    vc.args = argparse.Namespace(**defaults)
    return vc.args


def _pipeline(monkeypatch, releases_tag="v0.3.21"):
    monkeypatch.setattr(vc, "parse_current_version", lambda: ("0.3.20", "multica 0.3.20"))
    monkeypatch.setattr(
        vc, "fetch_releases",
        lambda per_page=20: (True, [
            {"tag_name": releases_tag, "name": releases_tag,
             "published_at": "2026-05-28T10:00:00Z", "body": "* feat: x\n"},
        ]),
    )


def _fail_if_called(*a, **k):
    raise AssertionError("multica_stdin_cmd must not be called when kill_switch is on")


# --- post_report_comment 门控（与 dry_run 同级） --------------------------------


def test_kill_switch_blocks_post(monkeypatch):
    monkeypatch.setattr(vc, "multica_stdin_cmd", _fail_if_called)
    result = vc.post_report_comment("issue-123", "## report",
                                    dry_run=False, kill_switch=True)
    assert result["posted"] is False
    assert result["reason"] == "kill_switch"
    assert result["issue_id"] == "issue-123"


def test_kill_switch_false_still_posts(monkeypatch):
    calls = []

    def _fake_cmd(cmd, content, timeout=None):
        calls.append((cmd, content))
        return True, "ok"

    monkeypatch.setattr(vc, "multica_stdin_cmd", _fake_cmd)
    result = vc.post_report_comment("issue-123", "## report",
                                    dry_run=False, kill_switch=False)
    assert result["posted"] is True
    assert len(calls) == 1


def test_dry_run_precedence_unchanged(monkeypatch):
    monkeypatch.setattr(vc, "multica_stdin_cmd", _fail_if_called)
    result = vc.post_report_comment("issue-123", "## report",
                                    dry_run=True, kill_switch=True)
    assert result["reason"] == "dry_run"


# --- main() 端到端：kill_switch=true + dry_run=false → 零发帖且有日志 ----------


def test_main_no_post_and_logged(monkeypatch, capsys):
    _pipeline(monkeypatch)
    monkeypatch.setattr(vc, "multica_stdin_cmd", _fail_if_called)
    _set_args(kill_switch="true", dry_run=False, verbose=True)
    vc.main()

    data = json.loads(capsys.readouterr().out)
    assert data["summary"]["kill_switch"] is True
    assert data["summary"]["comment_posted"] is False
    assert data["comment_result"]["reason"] == "kill_switch"
    assert any(
        "phase5_comment_skipped" in line and "kill_switch" in line
        for line in data["processing_log"]
    ), data["processing_log"]


def test_main_off_switch_still_posts(monkeypatch, capsys):
    _pipeline(monkeypatch)
    calls = []

    def _fake_cmd(cmd, content, timeout=None):
        calls.append(cmd)
        return True, "ok"

    monkeypatch.setattr(vc, "multica_stdin_cmd", _fake_cmd)
    _set_args(kill_switch="false", dry_run=False, verbose=True)
    vc.main()

    data = json.loads(capsys.readouterr().out)
    assert data["summary"]["comment_posted"] is True
    assert any("phase5_comment_posted" in line for line in data["processing_log"])
    assert len(calls) == 1
