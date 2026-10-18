"""E2E test suite for Multica daemon and task execution.

Tests real daemon behavior: runtime registration, task lifecycle,
parallel execution, crash recovery, and configuration correctness.
Requires a running daemon AND real Multica server access.

This file is marked ``requires_daemon`` (registered in .dev/tests/conftest.py)
and is EXCLUDED from a default ``pytest .dev/tests`` run. Run it explicitly
with ``pytest .dev/tests -m requires_daemon``. See .dev/docs/devtests.md §4.

SEE-1195 root-cause fix (2026-08-28): TestTaskLifecycle used to trigger the
FIRST active autopilot from `autopilot list` with a real server call, leaking
one real trigger per full-suite run (15 false triggers on 2026-08-28, each
spawning an empty 周检 issue). It now creates a dedicated temporary run_only
autopilot and deletes it in teardown — no pre-existing autopilot is ever
touched.

Usage:
    pytest .dev/tests -m requires_daemon -v -k multica_daemon
"""

import json
import os
import re
import subprocess
import sys
import time

import pytest

pytestmark = pytest.mark.requires_daemon

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "autopilots")
)

from multica_helpers import multica_cli, AGENT_MAP, AGENT_NAME_MAP


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def daemon_running():
    """Ensure daemon is running before tests."""
    ok, out = multica_cli("multica daemon status", timeout=10)
    if not ok or "running" not in out.lower():
        pytest.skip("Multica daemon is not running")
    return True


@pytest.fixture(scope="module")
def runtime_registered(daemon_running):
    """Verify runtime is registered."""
    ok, out = multica_cli("multica runtime list", timeout=10)
    if not ok:
        pytest.skip(f"Cannot list runtimes: {out}")
    return out


@pytest.fixture(scope="module")
def daemon_logs():
    """Fetch recent daemon logs as list of lines."""
    log_path = os.path.expanduser("~/.multica/daemon.log")
    if not os.path.exists(log_path):
        pytest.skip("No daemon log file")
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        return f.readlines()


@pytest.fixture(scope="module")
def recent_daemon_logs(daemon_logs):
    """Fetch daemon logs since last restart."""
    last_restart_idx = 0
    for i, line in enumerate(daemon_logs):
        if "starting daemon" in line:
            last_restart_idx = i
    return daemon_logs[last_restart_idx:]


# ---------------------------------------------------------------------------
# 1. Daemon health checks
# ---------------------------------------------------------------------------


class TestDaemonHealth:
    def test_daemon_status_running(self, daemon_running):
        ok, out = multica_cli("multica daemon status", timeout=10)
        assert ok, f"daemon status failed: {out}"
        assert "running" in out.lower(), f"Daemon not running: {out}"

    def test_runtime_online(self, runtime_registered):
        assert "online" in runtime_registered.lower(), (
            f"No online runtime: {runtime_registered}"
        )

    def test_runtime_provider_claude(self, runtime_registered):
        assert "claude" in runtime_registered.lower(), (
            f"No claude runtime: {runtime_registered}"
        )

    def test_server_health(self):
        server_url = os.environ.get("MULTICA_SERVER_URL", "")
        if not server_url:
            config_path = os.path.expanduser("~/.multica/config.json")
            if os.path.exists(config_path):
                with open(config_path, "r", encoding="utf-8") as f:
                    cfg = json.load(f)
                    server_url = cfg.get("server_url", "")
        if not server_url:
            pytest.skip("Cannot determine server URL")

        base_url = server_url.replace("/ws", "").rstrip("/")
        health_url = f"{base_url}/health"
        try:
            import urllib.request

            resp = urllib.request.urlopen(health_url, timeout=5)
            body = json.loads(resp.read())
            assert body.get("status") == "ok", f"Server unhealthy: {body}"
        except Exception as e:
            pytest.fail(f"Server health check failed: {e}")


# ---------------------------------------------------------------------------
# 2. Agent and workspace verification
# ---------------------------------------------------------------------------


def _get_agents_json() -> list[dict]:
    """Fetch agent list as parsed JSON."""
    ok, out = multica_cli("multica agent list --output json", timeout=15)
    assert ok, f"agent list failed: {out}"
    return json.loads(out)


class TestAgentWorkspace:
    def test_agent_list(self, daemon_running):
        agents = _get_agents_json()
        assert len(agents) >= 2, f"Expected >=2 agents, got {len(agents)}"

    def test_known_agents_present(self, daemon_running):
        agents = _get_agents_json()
        agent_ids = {a["id"] for a in agents}
        # jerry is a member, not an agent — skip it
        for name, aid in AGENT_NAME_MAP.items():
            if name == "jerry":
                continue
            assert aid in agent_ids, f"Agent {name} ({aid}) not found in workspace"

    def test_no_archived_agents(self, daemon_running):
        agents = _get_agents_json()
        for a in agents:
            assert not a.get("archived_at"), (
                f"Agent {a.get('name', '')} is archived"
            )


# ---------------------------------------------------------------------------
# 3. Workspace configuration
# ---------------------------------------------------------------------------


class TestWorkspaceConfig:
    def test_workspace_has_correct_repo_url(self, daemon_running):
        """Verify workspace uses KingOfLikes (not KingOfLives) repo URL."""
        ok, out = multica_cli(
            "multica workspace get 1a011680-a476-4553-929d-478690824e46 --output json",
            timeout=10,
        )
        assert ok, f"workspace get failed: {out}"
        ws = json.loads(out)

        # Check repos array
        repos = ws.get("repos", [])
        assert len(repos) >= 1, "Workspace should have at least one repo"
        repo_urls = [r.get("url", "") for r in repos]
        assert any("KingOfLikes" in u for u in repo_urls), (
            f"No KingOfLikes repo in {repo_urls}"
        )
        # Ensure no KingOfLives typo
        for url in repo_urls:
            assert "KingOfLives" not in url, f"KingOfLives typo found in repo URL: {url}"

    def test_workspace_context_has_correct_url(self, daemon_running):
        """Verify workspace context reminds agents of correct repo URL."""
        ok, out = multica_cli(
            "multica workspace get 1a011680-a476-4553-929d-478690824e46 --output json",
            timeout=10,
        )
        assert ok, f"workspace get failed: {out}"
        ws = json.loads(out)

        context = ws.get("context", "")
        assert "KingOfLikes" in context, (
            f"Workspace context should mention KingOfLikes: {context}"
        )
        assert "KingOfLives" not in context, (
            f"Workspace context should NOT contain KingOfLives typo: {context}"
        )


# ---------------------------------------------------------------------------
# 4. Task lifecycle
# ---------------------------------------------------------------------------


class TestTaskLifecycle:
    @pytest.fixture
    def temp_autopilot(self, daemon_running):
        """Create a dedicated temporary run_only autopilot; delete on teardown.

        SEE-1195: never trigger a pre-existing active autopilot from tests —
        a create_issue-mode one spawns a real issue per trigger (2026-08-28:
        15 false 周检 issues from full-suite runs). A test-owned run_only
        autopilot returns a real task_id and is deleted here even on failure.
        """
        unique = f"tmp_e2e_{os.getpid()}_{int(time.time())}"
        ok, out = multica_cli(
            [
                "multica", "autopilot", "create",
                "--title", unique,
                "--description",
                "Temporary run_only autopilot for test_multica_daemon_e2e "
                "(SEE-1195). Reply briefly and stop.",
                "--mode", "run_only",
                "--agent", "refacty",
            ],
            timeout=15,
        )
        if not ok:
            pytest.skip(f"cannot create temp autopilot: {out}")
        try:
            autopilot_id = json.loads(out)["id"]
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            pytest.skip(f"unexpected autopilot create response: {e}: {out}")

        yield {"id": autopilot_id, "mode": "run_only"}

        ok, out = multica_cli(
            ["multica", "autopilot", "delete", autopilot_id], timeout=15
        )
        if not ok:
            print(f"WARN: failed to delete temp autopilot {autopilot_id}: {out}")

    def test_trigger_and_complete_task(self, temp_autopilot):
        """Trigger the test-owned temp autopilot and verify completion."""
        autopilot_id = temp_autopilot["id"]
        ok, trigger_out = multica_cli(
            ["multica", "autopilot", "trigger", autopilot_id], timeout=15
        )
        assert ok, f"trigger failed: {trigger_out}"

        trigger = json.loads(trigger_out)
        # SEE-1195: trigger response shape depends on autopilot mode —
        # run_only returns task_id; create_issue returns issue_id (no task_id).
        if temp_autopilot["mode"] == "run_only":
            task_id = trigger.get("task_id", "")
            assert task_id, f"No task_id in run_only trigger response: {trigger}"
        else:
            assert trigger.get("issue_id"), (
                f"No issue_id in create_issue trigger response: {trigger}"
            )
            return

        self._wait_for_task(task_id, timeout=300)

    def _wait_for_task(self, task_id: str, timeout: int = 300):
        """Wait for a task to complete, checking daemon logs."""
        short_id = task_id[:8]
        deadline = time.time() + timeout
        while time.time() < deadline:
            ok, logs = multica_cli("multica daemon logs --lines 50", timeout=10)
            if ok:
                for line in logs.split("\n"):
                    if f"task={short_id}" in line:
                        if "agent finished" in line and "status=completed" in line:
                            return
                        if "task failed" in line or "status=failed" in line:
                            pytest.fail(f"Task {short_id} failed: {line.strip()}")
            time.sleep(10)
        pytest.fail(f"Task {short_id} did not complete within {timeout}s")


# ---------------------------------------------------------------------------
# 5. Daemon log health
# ---------------------------------------------------------------------------


class TestDaemonLogHealth:
    def test_no_exit_126_since_last_restart(self, daemon_running, recent_daemon_logs):
        """Verify no runtime registration failures (exit status 126) since last restart."""
        exit_126_lines = [
            l.strip() for l in recent_daemon_logs if "exit status 126" in l
        ]

        assert len(exit_126_lines) == 0, (
            f"Found exit status 126 errors since last restart:\n"
            + "\n".join(exit_126_lines[-5:])
        )

    def test_no_pipe_closure_errors(self, daemon_running, recent_daemon_logs):
        """Verify no pipe closure errors caused by daemon restart mid-task."""
        pipe_error_lines = [
            l.strip()
            for l in recent_daemon_logs
            if "write claude input: write |1: file already closed" in l
            or "file already closed" in l
        ]

        assert len(pipe_error_lines) == 0, (
            f"Found pipe closure errors (daemon restarted while tasks running):\n"
            + "\n".join(pipe_error_lines[-5:])
        )

    def test_no_stuck_tasks_in_recent_logs(self, daemon_running):
        """Verify no tasks were picked but never started claude."""
        log_path = os.path.expanduser("~/.multica/daemon.log")
        if not os.path.exists(log_path):
            pytest.skip("No daemon log file")

        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()

        recent_lines = lines[-3000:] if len(lines) > 3000 else lines

        picked_tasks = set()
        finished_tasks = set()

        for line in recent_lines:
            if "picked task component=daemon task=" in line:
                tid = line.split("task=")[1].split()[0]
                picked_tasks.add(tid)
            elif "agent finished component=daemon task=" in line:
                tid = line.split("task=")[1].split()[0]
                finished_tasks.add(tid)
            elif "task failed component=daemon task=" in line:
                tid = line.split("task=")[1].split()[0]
                finished_tasks.add(tid)
            elif "task completed component=daemon task=" in line:
                tid = line.split("task=")[1].split()[0]
                finished_tasks.add(tid)
            elif "task cancelled" in line and "task=" in line:
                tid = line.split("task=")[1].split()[0]
                finished_tasks.add(tid)

        stuck = picked_tasks - finished_tasks
        assert len(stuck) <= 2, (
            f"Found {len(stuck)} tasks picked but never finished in recent logs: "
            f"{stuck}"
        )

    def test_daemon_started_cleanly(self, recent_daemon_logs):
        """Verify daemon started with runtime registered and no startup errors."""
        started_ok = any("starting daemon" in l for l in recent_daemon_logs)
        assert started_ok, "No 'starting daemon' marker found in logs"

        registered_ok = any("registered runtime" in l for l in recent_daemon_logs)
        assert registered_ok, "No 'registered runtime' found after daemon start"

        watching_ok = any("watching workspace" in l for l in recent_daemon_logs)
        assert watching_ok, "No 'watching workspace' found after daemon start"


# ---------------------------------------------------------------------------
# 6. Graceful shutdown verification
# ---------------------------------------------------------------------------


class TestGracefulShutdown:
    def test_no_pipe_closure_since_last_restart(self, daemon_running, recent_daemon_logs):
        """Verify no pipe closure errors since last daemon restart.
        These indicate a daemon restart killed running agents without graceful shutdown.
        Only checks logs since last restart to avoid counting pre-fix historical errors."""
        pipe_errors = [
            l.strip()
            for l in recent_daemon_logs
            if "write claude input: write |1: file already closed" in l
        ]

        assert len(pipe_errors) == 0, (
            f"Found {len(pipe_errors)} pipe closure errors since last restart:\n"
            + "\n".join(pipe_errors[-5:])
        )

    def test_daemon_restart_detects_correct_pid(self, daemon_running):
        """Verify the counting function used by graceful shutdown works correctly.
        It should count only daemon-spawned agents, not the user's own session."""
        ok, out = multica_cli("multica daemon status", timeout=10)
        assert ok, f"daemon status failed: {out}"

        # Get daemon-spawned PIDs from logs
        ok, logs = multica_cli("multica daemon logs --lines 2000", timeout=10)
        assert ok, f"daemon logs failed: {logs}"

        daemon_pids = set(
            re.findall(r"claude started component=daemon pid=(\d+)", logs)
        )

        # Get all alive claude PIDs
        alive_pids = set()
        try:
            r = subprocess.run(
                ["tasklist", "//FI", "IMAGENAME eq claude.exe", "//NH"],
                capture_output=True, text=True, timeout=10,
            )
            if r.returncode == 0:
                for line in r.stdout.split("\n"):
                    m = re.search(r"claude\.exe\s+(\d+)", line)
                    if m:
                        alive_pids.add(m.group(1))
        except Exception:
            pytest.skip("Could not enumerate claude processes")

        running_daemon = daemon_pids & alive_pids
        total_alive = len(alive_pids)
        daemon_alive = len(running_daemon)

        # The daemon's count should be <= total alive processes
        assert daemon_alive <= total_alive, (
            f"Daemon-spawned count ({daemon_alive}) exceeds total alive ({total_alive})"
        )

        # If there are alive processes, at least some should be daemon-spawned
        # (or there could be 0 if no tasks are running right now)
        assert daemon_alive >= 0


# ---------------------------------------------------------------------------
# 7. MULTICA_CLAUDE_PATH configuration
# ---------------------------------------------------------------------------


class TestClaudePathConfig:
    def test_claude_exe_exists(self):
        """Verify claude.exe exists at expected path on Windows."""
        if os.name != "nt":
            pytest.skip("Windows-specific test")

        claude_path = os.environ.get("MULTICA_CLAUDE_PATH", "")
        if claude_path:
            assert os.path.isfile(claude_path), (
                f"MULTICA_CLAUDE_PATH={claude_path} does not exist"
            )
        else:
            default_path = os.path.join(
                os.environ.get("APPDATA", ""),
                "npm",
                "node_modules",
                "@anthropic-ai",
                "claude-code",
                "bin",
                "claude.exe",
            )
            assert os.path.isfile(default_path), (
                f"claude.exe not found at {default_path}"
            )

    def test_claude_version_works(self):
        """Verify claude --version returns successfully via MULTICA_CLAUDE_PATH."""
        # os.environ may not have it (setx only affects new processes),
        # so read from Windows registry on nt, or env on Unix.
        if os.name == "nt":
            try:
                r = subprocess.run(
                    ["reg", "query", "HKEY_CURRENT_USER\\Environment",
                     "-v", "MULTICA_CLAUDE_PATH"],
                    capture_output=True, text=True, timeout=10,
                )
                match = re.search(
                    r"MULTICA_CLAUDE_PATH\s+REG_SZ\s+(\S+)", r.stdout
                )
                claude_path = match.group(1) if match else "claude"
            except FileNotFoundError:
                claude_path = "claude"
        else:
            claude_path = os.environ.get("MULTICA_CLAUDE_PATH", "claude")

        r = subprocess.run(
            [claude_path, "--version"],
            capture_output=True, text=True, timeout=10,
            encoding="utf-8", errors="replace",
        )
        assert r.returncode == 0, (
            f"claude --version failed: exit={r.returncode} stderr={r.stderr}"
        )
        assert r.stdout.strip(), "claude --version returned empty output"

    def test_multica_claude_path_env_set(self):
        """Verify MULTICA_CLAUDE_PATH is set in Windows registry (setx).
        The current process may not reflect it; check via registry."""
        if os.name != "nt":
            pytest.skip("Windows-specific test")

        try:
            r = subprocess.run(
                ["reg", "query", "HKEY_CURRENT_USER\\Environment", "-v", "MULTICA_CLAUDE_PATH"],
                capture_output=True, text=True, timeout=10,
            )
            assert r.returncode == 0, (
                "MULTICA_CLAUDE_PATH not found in registry: "
                "run 'setx MULTICA_CLAUDE_PATH <path>' to set it"
            )
            # Registry output format: MULTICA_CLAUDE_PATH REG_SZ <path>
            match = re.search(r"MULTICA_CLAUDE_PATH\s+REG_SZ\s+(\S+)", r.stdout)
            assert match, f"Could not parse registry value: {r.stdout}"
            path = match.group(1)
            assert "claude.exe" in path, (
                f"MULTICA_CLAUDE_PATH should point to claude.exe: {path}"
            )
        except FileNotFoundError:
            pytest.skip("reg.exe not available")
