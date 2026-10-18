#!/usr/bin/env python3
"""SEE-1285 AC-FWD-003: SessionStart [gitlink-sync] hint — content & format.

The hook helper (bash, tested here by invoking the real script) reads the
daemon state.json and renders exactly ONE line per submodule:
  synced form:  [gitlink-sync] vendor/sub: 8d51b13→bd8f99a 已自动同步（CI 绿）
  blocked form: [gitlink-sync] vendor/sub: ← 落后中（gate 1 未过：CI 结论未知），详见 daemon 日志
Missing / corrupt state.json → NO output at all (silent skip), rc 0.
"""

import os
import subprocess
import json
from pathlib import Path

import pytest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LIB = os.path.join(REPO, "claude-hooks", "scripts", "lib", "gitlink-sync-hint.sh")


def run_hint(state_payload: str | None, tmp: str) -> tuple[int, str, str]:
    env = dict(os.environ)
    if state_payload is None:
        state_path = os.path.join(tmp, "does-not-exist.json")
    else:
        state_path = os.path.join(tmp, "repo-sync-state.json")
        Path(state_path).write_text(state_payload, encoding="utf-8")
    env["GITLINK_SYNC_STATE_FILE"] = state_path
    r = subprocess.run(
        ["bash", LIB],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=15, env=env,
    )
    return r.returncode, r.stdout, r.stderr


class TestHintLib:
    def test_synced_form(self, tmp_path):
        state = {
            "timestamp": "2026-09-11T08:00:00Z",
            "forward": {
                "addons/godot_mcp": {
                    "status": "forwarded", "target_sha": "bd8f99a51b0a5a9941da27",
                    "from_sha": "8d51b133d10c17de0eafa0d14c93dc86d1d080cefd",
                }
            },
        }
        rc, out, err = run_hint(json.dumps(state), str(tmp_path))
        assert rc == 0, err
        assert out.strip() == (
            "[gitlink-sync] addons/godot_mcp: 8d51b133d10c→bd8f99a51b0a 已自动同步（CI 绿）"
        ), out

    def test_blocked_form_gate1_unknown(self, tmp_path):
        state = {
            "timestamp": "2026-09-11T08:00:00Z",
            "forward": {
                "addons/godot_mcp": {
                    "status": "blocked", "gate": "gate1",
                    "gate1_conclusion": "unknown", "target": "d189b5e586d9f71b",
                }
            },
        }
        rc, out, err = run_hint(json.dumps(state), str(tmp_path))
        assert rc == 0, err
        assert "[gitlink-sync]" in out
        assert "落后" in out and "gate1" in out, out
        assert len(out.strip().splitlines()) == 1

    def test_blocked_form_gate1_fail(self, tmp_path):
        state = {
            "timestamp": "2026-09-11T08:00:00Z",
            "forward": {
                "addons/godot_mcp": {
                    "status": "blocked", "gate": "gate1",
                    "gate1_conclusion": "fail",
                }
            },
        }
        rc, out, err = run_hint(json.dumps(state), str(tmp_path))
        assert rc == 0
        assert "CI 红" in out, out

    def test_gate3_blocked_names_interval(self, tmp_path):
        state = {
            "timestamp": "2026-09-11T08:00:00Z",
            "forward": {
                "addons/godot_mcp": {"status": "blocked", "gate": "gate3"}
            },
        }
        rc, out, _ = run_hint(json.dumps(state), str(tmp_path))
        assert "区间" in out, out

    def test_missing_state_silent_skip(self, tmp_path):
        rc, out, err = run_hint(None, str(tmp_path))
        assert rc == 0
        assert out.strip() == "" and err.strip() == ""

    def test_corrupt_state_silent_skip(self, tmp_path):
        rc, out, err = run_hint("{not json!!", str(tmp_path))
        assert rc == 0
        assert out.strip() == "" and err.strip() == ""

    def test_empty_state_silent_skip(self, tmp_path):
        rc, out, err = run_hint("{}", str(tmp_path))
        assert rc == 0
        assert out.strip() == "" and err.strip() == ""

    def test_no_blocked_or_forwarded_entries_no_output(self, tmp_path):
        state = {"forward": {"addons/godot_mcp": {"status": "synced"}}}
        rc, out, _ = run_hint(json.dumps(state), str(tmp_path))
        assert rc == 0
        assert out.strip() == ""

    def test_integration_repo_checkout_hook_sources_lib(self):
        """The hint must actually reach the SessionStart path: repo-checkout.sh
        sources the lib and its output_hint wrapper can carry the line."""
        hook = Path(REPO, "claude-hooks/scripts/repo-checkout.sh").read_text(encoding="utf-8")
        assert "gitlink-sync-hint.sh" in hook
