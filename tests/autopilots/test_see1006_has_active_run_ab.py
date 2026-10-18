"""A/B test for SEE-1006: old whitelist-based has_active_run vs new non-terminal guard.

Old behavior: only "running" / "queued" counted as active. This let the "dispatched"
state (runtime has claimed a task but the process has not started yet) slip through
and cause nudges on issues that were already being handled.

New behavior: any run whose status is not terminal (completed / failed / cancelled)
counts as active, so dispatched runs correctly block the nudge.
"""

import os
import sys
from datetime import datetime, timedelta, timezone

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "autopilots"))


# Old implementation as it existed before the fix.
def old_has_active_run(runs) -> bool:
    return any(r.get("status") in ("running", "queued") for r in runs)


# The fixed implementation is imported from the source module.
from issue_status_check import has_active_run as new_has_active_run


# SEE-1414 added a staleness filter to the new implementation: non-terminal
# runs older than STALE_RUN_AGE_HOURS no longer count. Fixtures must therefore
# use recent timestamps or the age filter (intentionally) skips them.
_NOW = datetime.now(timezone.utc)


def _recent(hours_ago: float = 1.0) -> str:
    return (_NOW - timedelta(hours=hours_ago)).isoformat()


# Inputs where old and new behavior diverge (the bug).
# Old whitelist only accepts running/queued; any non-terminal-but-not-whitelisted
# state (e.g. dispatched) is misclassified as inactive.
DIVERGENT_CASES = [
    # single dispatched run
    [{"status": "dispatched"}],
    # mixed: latest terminal, older dispatched
    [{"status": "completed", "created_at": _recent(2.0)},
     {"status": "dispatched", "created_at": _recent(1.0)}],
    # failed + dispatched
    [{"status": "failed", "created_at": _recent(2.0)},
     {"status": "dispatched", "created_at": _recent(1.0)}],
    # cancelled + dispatched
    [{"status": "cancelled", "created_at": _recent(2.0)},
     {"status": "dispatched", "created_at": _recent(1.0)}],
]


# Inputs where old and new behavior agree (regression safety).
AGREED_ACTIVE_CASES = [
    [{"status": "running"}],
    [{"status": "queued"}],
    [{"status": "running"}, {"status": "queued"}],
]

AGREED_INACTIVE_CASES = [
    [],
    [{"status": "completed"}],
    [{"status": "failed"}],
    [{"status": "cancelled"}],
    [{"status": "completed"}, {"status": "failed"}, {"status": "cancelled"}],
    [{"status": ""}],
    [{"id": "task-1"}],  # missing status field
]


@pytest.mark.abtest
class TestOldVsNewHasActiveRun:
    """A/B assertions proving the fix resolves the dispatched-state bug."""

    def test_old_whitelist_misclassifies_dispatched_as_inactive(self):
        """Reproduce the bug: old whitelist returns False for dispatched runs."""
        for runs in DIVERGENT_CASES:
            assert old_has_active_run(runs) is False, (
                f"Old implementation should have returned False for {runs}"
            )

    def test_new_non_terminal_guard_classifies_dispatched_as_active(self):
        """Fix: new implementation returns True for dispatched runs."""
        for runs in DIVERGENT_CASES:
            assert new_has_active_run(runs) is True, (
                f"New implementation should have returned True for {runs}"
            )

    def test_old_whitelist_still_agrees_on_running_and_queued(self):
        """Old whitelist and new guard both see running/queued as active."""
        for runs in AGREED_ACTIVE_CASES:
            assert old_has_active_run(runs) is True
            assert new_has_active_run(runs) is True

    def test_old_whitelist_still_agrees_on_terminal_and_missing(self):
        """Old whitelist and new guard both see terminal/missing as inactive."""
        for runs in AGREED_INACTIVE_CASES:
            assert old_has_active_run(runs) is False
            assert new_has_active_run(runs) is False

    def test_see1414_stale_filter_skips_aged_non_terminal_runs(self):
        """SEE-1414: non-terminal runs older than the watchdog horizon don't count.

        This is an INTENTIONAL divergence from the old whitelist (which ignored
        created_at entirely): the stale filter prevents stalled run records from
        blocking nudges forever. Aged queued runs show the split explicitly.
        """
        aged_queued = [{"status": "queued", "created_at": _recent(25.0)}]
        assert old_has_active_run(aged_queued) is True
        assert new_has_active_run(aged_queued) is False
        # Recent non-terminal runs still count (the filter is age-gated only).
        fresh_dispatched = [{"status": "dispatched", "created_at": _recent(0.5)}]
        assert old_has_active_run(fresh_dispatched) is False
        assert new_has_active_run(fresh_dispatched) is True
