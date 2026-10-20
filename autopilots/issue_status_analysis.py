"""Pure analysis helpers for the issue-status patrol (SEE-1440 module split).

issue_status_check.py exceeded the 800-line self-check limit; this module
carries the stateless analysis helpers (push-reminder counting, commenter/run
classification, grace window, completeness scoring) so the orchestrator stays
under the limit. Zero behavior change: issue_status_check re-exports these
names, so existing `from issue_status_check import X` callers (tests included)
keep working.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from push_comment_sender import PUSH_CONTENT_MARKERS


def count_push_reminders(comments, self_id):
    """Count push/reminder comments authored by the autopilot agent itself.

    Only counts comments identified as push reminders (containing push markers),
    not all self-authored comments such as result reports.
    """
    push_count = 0
    for c in comments:
        if c.get("author_id") == self_id:
            content = c.get("content", "")
            for marker in PUSH_CONTENT_MARKERS:
                if marker in content:
                    push_count += 1
                    break
    return push_count


def get_latest_push_reminder_time(comments, self_id):
    """Return the created_at timestamp of the latest self-authored push reminder.

    Used for 24h rate-limiting of no_assignee pings (SEE-956 H3).
    """
    for c in reversed(comments):
        if c.get("author_id") != self_id:
            continue
        content = c.get("content", "")
        for marker in PUSH_CONTENT_MARKERS:
            if marker in content:
                return c.get("created_at", "")
    return ""


def get_latest_commenter(comments, self_id):
    """Get the latest non-self commenter for push targeting."""
    for c in reversed(comments):
        author_id = c.get("author_id", "")
        if author_id == self_id:
            continue
        return {
            "author_id": author_id,
            "author_type": c.get("author_type", ""),
            "created_at": c.get("created_at", ""),
        }
    return None


def is_within_grace_period(created_at_str, grace_minutes):
    """Check if an issue was created within the grace period.

    Returns True if the issue's created_at timestamp is within grace_minutes
    of the current UTC time. Handles RFC 3339 / ISO 8601 timestamps.
    """
    if not created_at_str or grace_minutes <= 0:
        return False
    from datetime import datetime, timezone, timedelta
    dt = _parse_utc(created_at_str)
    if dt is None:
        return False
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=grace_minutes)
    return dt > cutoff


def has_assignee_recent_activity(comments, assignee_id, threshold_minutes):
    """Check if the assignee has posted a comment within the threshold period."""
    if not assignee_id or not comments:
        return False
    for c in reversed(comments):
        author_id = c.get("author_id", "")
        if author_id != assignee_id:
            continue
        created_at = c.get("created_at", "")
        if is_within_grace_period(created_at, threshold_minutes):
            return True
    return False


def get_latest_run_status(runs):
    """Determine the status of the most recent run, sorted by created_at descending."""
    if not runs:
        return "none"
    sorted_runs = sorted(runs, key=lambda r: r.get("created_at", ""), reverse=True)
    return sorted_runs[0].get("status", "unknown")


def _parse_utc(ts: str):
    """Parse an RFC 3339 timestamp to aware UTC datetime, or None."""
    if not ts:
        return None
    try:
        from datetime import datetime
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


# A run is "active" (blocks nudging) unless it has reached a terminal state.
# Covers queued / dispatched / running and any future non-terminal state per
# the task lifecycle in .dev/docs/multica/official/tasks.md.
TERMINAL_RUN_STATUSES = frozenset({"completed", "failed", "cancelled"})

# Non-terminal runs older than this are ignored by has_active_run: a run stuck
# in queued/running past the watchdog horizon is a stalled record (its agent
# process is gone or the run was superseded), and letting it block nudging
# forever defeats the patrol's purpose. A genuinely long run past this age is
# expected to have posted progress or completed; the watchdog handles those
# separately via completed_stale.
STALE_RUN_AGE_HOURS = 6


def has_active_run(runs) -> bool:
    """Check if any run (not just the latest) is in a non-terminal state.

    A run counts as active when its status is not completed/failed/cancelled
    (e.g. queued, dispatched, running). Any of those means a runtime or agent
    is responsible for the issue, so a push reminder would be redundant.
    Missing/empty status is treated as not active (defensive against malformed data).

    Runs older than STALE_RUN_AGE_HOURS are excluded: a non-terminal run that
    old is a stalled record (its process is gone or it was superseded), and
    letting it block nudging forever defeats the patrol. Age is measured from
    created_at (dispatched_at/started_at may be absent on queued runs).
    """
    from datetime import datetime, timezone, timedelta

    stale_cutoff = datetime.now(timezone.utc) - timedelta(hours=STALE_RUN_AGE_HOURS)
    for r in runs:
        status = r.get("status", "")
        if not status or status in TERMINAL_RUN_STATUSES:
            continue
        created = _parse_utc(r.get("created_at", ""))
        if created is not None and created < stale_cutoff:
            continue
        return True
    return False


# Markers that indicate a real acceptance/spec section rather than a stub.
_PLACEHOLDER_SPEC_MARKERS = (
    "- [ ]", "- [x]", "验收", "acceptance", "验收标准", "todo:",
)


def completeness_score(title, description):
    """Score an issue's completeness on a 0-100 scale (SEE-956 H2).

    A higher score means a more completely-specified issue. Scores below
    PLACEHOLDER_THRESHOLD are treated as placeholder issues.
    """
    score = 0
    desc = (description or "").strip()
    title_s = (title or "").strip()

    if title_s:
        score += 20
        if len(title_s) >= 10:
            score += 10

    if desc:
        score += 30
        if len(desc) >= 50:
            score += 20
        lowered = desc.lower()
        if any(m in lowered for m in _PLACEHOLDER_SPEC_MARKERS):
            score += 20

    return min(score, 100)
