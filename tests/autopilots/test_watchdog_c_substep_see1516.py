"""§SPEC-009/011/013 (SEE-1516 substep C2a/C4/C6): watchdog 报告查重 / 手动取消
不重入队 / self-agent-id 单源 + wrapper 条件透传。
"""

import argparse
import os
import shutil
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
COMMON_ENV_SRC = REPO_ROOT / "autopilots" / "lib" / "common_env.sh"
WRAPPER_SRC = REPO_ROOT / "autopilots" / "agent_watchdog.sh"

import agent_watchdog as aw  # noqa: E402
import watchdog_report as wr  # noqa: E402


# --- C2a: 报告 marker 查重, 命中改 edit ---------------------------------------


def test_find_marker_comment_hits(monkeypatch):
    calls = []

    def fake_cli(cmd, timeout=30):
        calls.append(cmd)
        return True, '[{"id":"c-9","revision":3,"content":"x <!-- agent_watchdog_report -->"}]'

    monkeypatch.setattr(wr, "multica_cli", fake_cli)
    hit = wr.find_marker_comment("issue-1", [])
    assert hit == {"id": "c-9", "revision": 3}
    assert calls and "comment list issue-1" in calls[0]


def test_find_marker_comment_none(monkeypatch):
    monkeypatch.setattr(wr, "multica_cli",
                        lambda cmd, timeout=30: (True, '[{"id":"c-1","revision":1,"content":"no marker"}]'))
    assert wr.find_marker_comment("issue-1", []) is None


def test_find_marker_comment_query_failure_none(monkeypatch):
    log = []
    monkeypatch.setattr(wr, "multica_cli",
                        lambda cmd, timeout=30: (False, "boom"))
    assert wr.find_marker_comment("issue-1", log) is None
    assert any("report_dedup_list_failed" in line for line in log), log


def test_post_report_updates_existing(monkeypatch):
    monkeypatch.setattr(wr, "find_marker_comment",
                        lambda iid, log: {"id": "c-9", "revision": 3})
    sent = []

    def fake_stdin(cmd, content, timeout=30):
        sent.append((cmd, content))
        return True, "ok"

    monkeypatch.setattr(wr, "multica_stdin_cmd", fake_stdin)
    log = []
    result = wr.post_report_comment("issue-1", "body v2", False, log)
    assert result["sent"] is True and result.get("updated") is True
    cmd, content = sent[0]
    assert "comment update c-9" in cmd and "--expected-revision 3" in cmd
    assert content == "body v2"
    assert any("report_comment_updated" in line for line in log)


def test_post_report_adds_when_no_marker(monkeypatch):
    monkeypatch.setattr(wr, "find_marker_comment", lambda iid, log: None)
    with patch.object(wr, "multica_stdin_cmd", return_value=(True, "ok")) as m:
        result = wr.post_report_comment("issue-1", "body", False, [])
    assert result["sent"] is True and "updated" not in result
    assert "comment add issue-1" in m.call_args[0][0]


# --- C4: long_cancelled 仅报告不 rerun -----------------------------------------


def _mk_task(task_id, status, error, started_at, ended_at):
    return dict(task_id=task_id, agent_id="agent-a", agent_name="A",
                issue_id="issue-x", status=status, error=error,
                started_at=started_at, ended_at=ended_at)


def _ts(minutes_ago):
    from datetime import datetime, timedelta, timezone
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)).isoformat()


def test_main_excludes_long_cancelled_from_rerun(monkeypatch):
    """long_cancelled 进 skipped/report、不进 rerun；idle_watchdog 正常 approve。"""
    idle = _mk_task("t1", "failed", "force-stopped by idle watchdog", _ts(30), _ts(5))
    idle["detection_method"] = "idle_watchdog_error"
    manual = _mk_task("t2", "cancelled", None, _ts(40), _ts(5))
    manual["detection_method"] = "long_cancelled"

    class FakeState:
        def cleanup_expired(self):
            pass

        def check_restart_limit(self, issue_id, cap):
            return True

        def get_restart_count(self, issue_id):
            return 0

    monkeypatch.setattr(aw, "WatchdogState", lambda path: FakeState())
    monkeypatch.setattr(aw, "enrich_issue_identifiers", lambda *a: None)

    rerun_seen = []

    def fake_execute(approved, state, dry_run, log, cap):
        rerun_seen.append([t["task_id"] for t in approved])
        return []

    monkeypatch.setattr(aw, "execute_reruns", fake_execute)

    args = argparse.Namespace(
        dry_run=False, exclude_agents="Atlas", self_agent_id="self",
        execution_issue_id="", alert_issue_id="", verbose=True,
        kill_switch="false", max_restarts_per_hour=3, state_file="/tmp/x.json",
        pid_file="/tmp/x.pid")
    monkeypatch.setattr(aw, "fetch_agents", lambda *a: [])
    monkeypatch.setattr(aw, "get_failed_runs", lambda agents, log: [idle, manual])
    monkeypatch.setattr(aw, "detect_idle_watchdog_kills",
                        lambda failed, log: [idle, manual])

    import io, contextlib
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        aw.main(args)

    assert rerun_seen and rerun_seen[0] == ["t1"], rerun_seen  # 手动取消未进 rerun
    data = out.getvalue()
    # 报告有记录: skipped 含 manual_cancel_report_only
    assert "manual_cancel_report_only" in out.getvalue()
    report = __import__("json").loads(data)
    skipped_reasons = [s.get("skip_reason") for s in report["skipped_tasks"]]
    assert "manual_cancel_report_only" in skipped_reasons


# --- C6: --self-agent-id 单源 / --kill-switch 单源 / wrapper -------------------


def test_self_agent_default_no_hardcode(monkeypatch):
    monkeypatch.delenv("WATCHDOG_SELF_AGENT_ID", raising=False)
    monkeypatch.delenv("SELF_AGENT_ID", raising=False)
    assert aw.resolve_default_self_agent() == ""
    monkeypatch.setenv("WATCHDOG_SELF_AGENT_ID", "agent-uuid-x")
    assert aw.resolve_default_self_agent() == "agent-uuid-x"
    monkeypatch.delenv("WATCHDOG_SELF_AGENT_ID")
    monkeypatch.setenv("SELF_AGENT_ID", "agent-uuid-y")
    assert aw.resolve_default_self_agent() == "agent-uuid-y"


def test_kill_switch_default_uses_single_source(monkeypatch):
    import sys
    monkeypatch.setenv("KILL_SWITCH", "true")
    monkeypatch.setattr(sys, "argv", ["agent_watchdog.py", "--dry-run"])
    assert aw.parse_args().kill_switch == "true"


def test_no_chekky_constant_in_module():
    import inspect
    src = inspect.getsource(aw)
    assert "CHEKKY_AGENT_ID" not in src


@pytest.fixture(params=["env_unset", "env_true", "env_false"])
def wrapper_ctx(tmp_path, request):
    bin_dir = tmp_path / "stubbin"
    bin_dir.mkdir()
    log = tmp_path / "stub_calls.log"
    stub = bin_dir / "python3"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        'printf \'%s\\n\' "$*" >> "$STUB_LOG"\n'
        "exit 0\n", encoding="utf-8")
    stub.chmod(0o755)
    script_dir = tmp_path / "script_dir"
    (script_dir / "lib").mkdir(parents=True)
    shutil.copy(COMMON_ENV_SRC, script_dir / "lib" / "common_env.sh")
    shutil.copy(WRAPPER_SRC, script_dir / "agent_watchdog.sh")

    env = os.environ.copy()
    env.pop("KILL_SWITCH", None)
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["STUB_LOG"] = str(log)
    if request.param == "env_true":
        env["KILL_SWITCH"] = "true"
    elif request.param == "env_false":
        env["KILL_SWITCH"] = "false"
    proc = subprocess.run(["bash", str(script_dir / "agent_watchdog.sh")],
                          capture_output=True, text=True, env=env, timeout=60)
    args = Path(log).read_text(encoding="utf-8") if log.exists() else ""
    return request.param, proc, args


def test_wrapper_kill_switch_passthrough(wrapper_ctx):
    mode, proc, args = wrapper_ctx
    assert proc.returncode == 0, proc.stderr
    if mode == "env_unset":
        assert "--kill-switch" not in args
    elif mode == "env_true":
        assert "--kill-switch true" in args
    else:
        assert "--kill-switch false" in args
