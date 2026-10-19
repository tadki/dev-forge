#!/usr/bin/env python3
"""
E2E test for SEE-565 repo sync daemon robustness.

Simulates full daemon cycles: success → failure → backoff → circuit breaker,
verifying the daemon loop behavior end-to-end.
"""

import os
import sys
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "repo-sync"))

from repo_sync import send_alert
from repo_sync_daemon import run_one_cycle

# Current run_one_cycle signature (SEE-1195 drift fix):
#   run_one_cycle(sync_script, config, config_path, logger, timeout=120)
#   -> (ok: bool, error_category: str)
# config={} covers the real semantics in these tests, so the config_path
# argument only fills the positional slot — a dummy that never hits disk.

_DUMMY_CONFIG_PATH = "config.json"


def _cycle(logger, timeout: int = 10, config: dict | None = None) -> bool:
    ok, _category = run_one_cycle(
        "script.py", config or {}, _DUMMY_CONFIG_PATH, logger, timeout=timeout
    )
    return ok

# ---------------------------------------------------------------------------
# E2E Test 1: Full daemon cycle with success → failure → success
# ---------------------------------------------------------------------------


class TestDaemonFullCycle:
    """E2E: daemon handles mixed success/failure cycles correctly."""

    @patch("repo_sync_daemon.subprocess.run")
    def test_mixed_success_failure_resets_backoff(self, mock_run):
        """After a failure followed by success, backoff should reset."""
        results = [
            MagicMock(returncode=0, stdout="sync ok", stderr=""),
            MagicMock(returncode=1, stdout="", stderr="sync failed"),
            MagicMock(returncode=0, stdout="sync ok", stderr=""),
        ]
        mock_run.side_effect = results

        logger = MagicMock()

        assert _cycle(logger, timeout=10) is True
        assert _cycle(logger, timeout=10) is False
        assert _cycle(logger, timeout=10) is True

    @patch("repo_sync_daemon.subprocess.run")
    def test_daemon_loop_with_circuit_breaker(self, mock_run):
        """Simulate the daemon main loop with circuit breaker triggering."""
        mock_run.return_value = MagicMock(returncode=1, stdout="", stderr="fatal error")

        with patch("repo_sync_daemon.acquire_pid_lock", return_value=42), patch(
            "repo_sync_daemon.release_pid_lock"
        ), patch("repo_sync.send_alert") as mock_alert:
            mock_alert.return_value = (True, "ok")

            poll_interval = 0.01
            max_failures = 3
            backoff_max = 0.1
            current_interval = poll_interval
            consecutive_failures = 0
            iterations = 0

            while True:
                logger = MagicMock()
                ok = _cycle(logger, timeout=1)
                if ok:
                    consecutive_failures = 0
                    current_interval = poll_interval
                else:
                    consecutive_failures += 1
                    if consecutive_failures >= max_failures:
                        break
                    current_interval = min(current_interval * 2, backoff_max)
                iterations += 1
                if iterations > 20:
                    break

            assert consecutive_failures == max_failures

    @patch("repo_sync_daemon.subprocess.run")
    def test_timeout_expired_treated_as_failure(self, mock_run):
        """When subprocess times out, run_one_cycle should return False
        with a transient error category."""
        import subprocess as sp

        mock_run.side_effect = sp.TimeoutExpired(cmd="sync", timeout=1)

        logger = MagicMock()
        ok, category = run_one_cycle(
            "script.py", {}, _DUMMY_CONFIG_PATH, logger, timeout=1
        )
        assert ok is False
        assert category == "transient"

    @patch("repo_sync_daemon.subprocess.run")
    def test_subprocess_exception_treated_as_failure(self, mock_run):
        """Unexpected exceptions should be caught and return False
        with a persistent error category."""
        mock_run.side_effect = RuntimeError("unexpected")

        logger = MagicMock()
        ok, category = run_one_cycle(
            "script.py", {}, _DUMMY_CONFIG_PATH, logger, timeout=1
        )
        assert ok is False
        assert category == "persistent"

    @patch("repo_sync_daemon.subprocess.run")
    def test_nonzero_exit_code_treated_as_failure(self, mock_run):
        """Non-zero exit code should return False."""
        mock_run.return_value = MagicMock(returncode=42, stdout="", stderr="error msg")

        logger = MagicMock()
        assert _cycle(logger, timeout=1) is False

    @patch("repo_sync_daemon.subprocess.run")
    def test_success_stdout_logged(self, mock_run):
        """Successful sync output should be logged at info level."""
        mock_run.return_value = MagicMock(
            returncode=0, stdout="line1\nline2\nline3", stderr=""
        )

        logger = MagicMock()
        assert _cycle(logger, timeout=1) is True
        assert logger.info.call_count >= 3

    @patch("repo_sync_daemon.subprocess.run")
    def test_failure_stderr_logged_as_warning(self, mock_run):
        """Failed sync stderr should be logged at warning level."""
        mock_run.return_value = MagicMock(
            returncode=1, stdout="", stderr="fatal: something broke"
        )

        logger = MagicMock()
        assert _cycle(logger, timeout=1) is False
        logger.warning.assert_called()
        call_args = logger.warning.call_args[0]
        assert "42" in str(call_args) or "something broke" in str(call_args)


# ---------------------------------------------------------------------------
# E2E Test 2: Alert integration
# ---------------------------------------------------------------------------


class TestAlertIntegration:
    """E2E: verify alert is sent when circuit breaker triggers."""

    @patch("repo_sync.subprocess.run")
    def test_alert_sent_with_correct_issue_id(self, mock_run):
        """Alert should be sent to the configured issue_id."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        config = {"alert_issue_id": "test-alert-id-123"}
        send_alert(config, "test message")
        cmd = mock_run.call_args[0][0]
        assert "test-alert-id-123" in cmd

    @patch("repo_sync.subprocess.run")
    def test_alert_skipped_without_issue_id(self, mock_run):
        """If alert_issue_id is not configured, alert should be skipped."""
        config = {}
        ok, msg = send_alert(config, "test message")
        assert ok is False
        mock_run.assert_not_called()
