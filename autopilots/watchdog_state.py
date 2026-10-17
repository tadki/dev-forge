"""State management for agent_watchdog.py — tracks restart history for rate limiting."""

import json
import os
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta

try:
    import fcntl
except ImportError:  # Windows has no fcntl; locking degrades to no-op.
    fcntl = None


class WatchdogState:
    """Manages restart history with sliding-window rate limiting.

    Concurrency (SEE-956 C6/H11): the standalone read/write methods below operate
    on in-memory state and are safe for single-process use. The rate-limit gate
    that agent_watchdog uses to decide whether to rerun must instead go through
    :meth:`lock` (exclusive flock) wrapping :meth:`check_restart_limit` and
    :meth:`record_restart`, so that two concurrent watchdog instances cannot both
    pass the limit and double-record
    (the original check-then-act race that let an Nth+1 restart slip through).
    """

    def __init__(self, state_file: str) -> None:
        self.state_file = state_file
        self.lock_file = state_file + ".lock"
        self.records: list[dict] = []
        self._load()

    def _load(self) -> None:
        if not os.path.isfile(self.state_file):
            return
        try:
            with open(self.state_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            self.records = data.get("restarts", [])
        except (json.JSONDecodeError, OSError):
            self.records = []

    def _save(self) -> None:
        """Persist records atomically (SEE-956 C6).

        Writes a temp file in the same directory as the state file, then
        ``os.replace``-renames it into place. Same directory is what makes the
        rename a single atomic operation on POSIX, so a crash mid-write cannot
        leave a half-written state file that :meth:`_load` would silently treat
        as empty (which would wipe the rate-limit window and defeat C6/H11).
        """
        directory = os.path.dirname(self.state_file) or "."
        try:
            os.makedirs(directory, exist_ok=True)
        except OSError:
            return
        try:
            fd, tmp_path = tempfile.mkstemp(
                dir=directory, prefix=".watchdog_state.", suffix=".tmp"
            )
        except OSError:
            return
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump({"restarts": self.records}, f, indent=2, ensure_ascii=False)
            os.replace(tmp_path, self.state_file)
        except OSError:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    def cleanup_expired(self, window_hours: int = 1) -> None:
        """Remove records older than the rate-limit window."""
        cutoff = datetime.now(timezone.utc) - timedelta(hours=window_hours)
        self.records = [
            r for r in self.records
            if self._parse_ts(r.get("timestamp", "")) > cutoff
        ]

    def check_restart_limit(self, issue_id: str, max_per_hour: int) -> bool:
        """Check if an issue is within the hourly restart limit.

        Returns True if a restart is allowed, False if the limit has been reached.
        """
        cutoff = datetime.now(timezone.utc) - timedelta(hours=1)
        count = sum(
            1 for r in self.records
            if r.get("issue_id") == issue_id
            and self._parse_ts(r.get("timestamp", "")) > cutoff
        )
        return count < max_per_hour

    def record_restart(self, issue_id: str, task_id: str) -> None:
        """Record a restart event."""
        self.records.append({
            "issue_id": issue_id,
            "task_id": task_id,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })
        self._save()

    def get_restart_count(self, issue_id: str) -> int:
        """Get current restart count for an issue in the sliding window."""
        cutoff = datetime.now(timezone.utc) - timedelta(hours=1)
        return sum(
            1 for r in self.records
            if r.get("issue_id") == issue_id
            and self._parse_ts(r.get("timestamp", "")) > cutoff
        )

    @contextmanager
    def lock(self):
        """Exclusive inter-process lock around a critical section (SEE-956 C6).

        Reloads state fresh on entry, cleans expired records, and flushes on exit.
        The lock file is a sidecar (``<state_file>.lock``); the state file itself
        is persisted atomically inside :meth:`_save` (temp file + ``os.replace``).
        On Windows (no fcntl) this degrades to a no-op so single-process behavior
        is unchanged.
        """
        if fcntl is None:
            self.cleanup_expired()
            yield self
            self._save()
            return
        os.makedirs(os.path.dirname(self.lock_file) or ".", exist_ok=True)
        fd = os.open(self.lock_file, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)  # block until exclusive
            self._load()
            self.cleanup_expired()
            yield self
            self._save()
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(fd)
            except OSError:
                pass

    @staticmethod
    def _parse_ts(ts: str) -> datetime:
        """Parse RFC 3339 / ISO 8601 timestamp string to UTC datetime."""
        try:
            return datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except (ValueError, TypeError, AttributeError):
            return datetime.min.replace(tzinfo=timezone.utc)
