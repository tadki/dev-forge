"""Unit tests for watchdog_state.py — state management and rate limiting."""

import json
import os
import sys
from datetime import datetime, timezone, timedelta

import pytest

# Add .dev/autopilots to path for module imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

from watchdog_state import WatchdogState


class TestWatchdogStateLoad:
    def test_load_valid_state(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        data = {"restarts": [{"issue_id": "i1", "task_id": "t1", "timestamp": now}]}
        with open(state_file, "w") as f:
            json.dump(data, f)
        state = WatchdogState(state_file)
        assert len(state.records) == 1

    def test_load_missing_file_creates_empty(self, tmp_path):
        state_file = str(tmp_path / "nonexistent.json")
        state = WatchdogState(state_file)
        assert state.records == []

    def test_load_corrupted_json(self, tmp_path):
        state_file = str(tmp_path / "bad.json")
        with open(state_file, "w") as f:
            f.write("}{not valid json")
        state = WatchdogState(state_file)
        assert state.records == []

    def test_load_empty_file(self, tmp_path):
        state_file = str(tmp_path / "empty.json")
        with open(state_file, "w") as f:
            f.write("")
        state = WatchdogState(state_file)
        assert state.records == []


class TestCleanupExpired:
    def test_removes_old_records(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        old_ts = (datetime.now(timezone.utc) - timedelta(hours=2)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        recent_ts = (datetime.now(timezone.utc) - timedelta(minutes=10)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        state.records = [
            {"issue_id": "i1", "task_id": "t1", "timestamp": old_ts},
            {"issue_id": "i2", "task_id": "t2", "timestamp": recent_ts},
        ]
        state.cleanup_expired(window_hours=1)
        assert len(state.records) == 1
        assert state.records[0]["issue_id"] == "i2"

    def test_keeps_all_within_window(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        recent_ts = (datetime.now(timezone.utc) - timedelta(minutes=30)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        state.records = [
            {"issue_id": f"i{n}", "task_id": f"t{n}", "timestamp": recent_ts}
            for n in range(5)
        ]
        state.cleanup_expired(window_hours=1)
        assert len(state.records) == 5

    def test_removes_all_expired(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        old_ts = (datetime.now(timezone.utc) - timedelta(hours=5)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        state.records = [
            {"issue_id": "i1", "task_id": "t1", "timestamp": old_ts},
        ]
        state.cleanup_expired(window_hours=1)
        assert len(state.records) == 0


class TestCheckRestartLimit:
    def test_allows_when_under_limit(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        assert state.check_restart_limit("issue-1", 3) is True

    def test_blocks_when_at_limit(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        for i in range(3):
            state.record_restart("issue-1", f"task-{i}")
        assert state.check_restart_limit("issue-1", 3) is False

    def test_allows_different_issue_after_limit(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        for i in range(3):
            state.record_restart("issue-1", f"task-{i}")
        # Different issue should still be allowed
        assert state.check_restart_limit("issue-2", 3) is True

    def test_expired_restarts_dont_count(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        old_ts = (datetime.now(timezone.utc) - timedelta(hours=2)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        # Manually inject old records
        state.records = [
            {"issue_id": "issue-1", "task_id": f"t-{i}", "timestamp": old_ts}
            for i in range(5)
        ]
        assert state.check_restart_limit("issue-1", 3) is True


class TestRecordRestart:
    def test_records_and_saves(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        state.record_restart("issue-1", "task-1")
        assert len(state.records) == 1
        assert state.records[0]["issue_id"] == "issue-1"
        assert state.records[0]["task_id"] == "task-1"
        assert state.records[0]["timestamp"] is not None

        # Verify persistence
        state2 = WatchdogState(state_file)
        assert len(state2.records) == 1

    def test_multiple_records_accumulate(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        for i in range(5):
            state.record_restart(f"issue-{i}", f"task-{i}")
        assert len(state.records) == 5


class TestGetRestartCount:
    def test_zero_for_new_issue(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        assert state.get_restart_count("issue-new") == 0

    def test_counts_within_window(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        for i in range(3):
            state.record_restart("issue-1", f"task-{i}")
        assert state.get_restart_count("issue-1") == 3

    def test_ignores_expired_records(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        old_ts = (datetime.now(timezone.utc) - timedelta(hours=2)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        state.records = [
            {"issue_id": "issue-1", "task_id": "t-old", "timestamp": old_ts}
        ]
        state.record_restart("issue-1", "t-new")
        assert state.get_restart_count("issue-1") == 1
