#!/usr/bin/env python3
"""Issue status inspection script for Multica Autopilot.

Scans issues across all statuses, collects metadata, counts push reminders,
checks run states, and outputs structured JSON for agent decision-making.

Can be run directly on Windows without bash:
    python autopilots/issue_status_check.py [--dry-run] [--no-dry-run] [--verbose] [--grace-period-minutes N]

Uses atomic OS-level file locking (fcntl.flock on Unix, msvcrt.locking on Windows)
to prevent TOCTOU race conditions in PID file lock acquisition.
"""

import argparse
import json
import subprocess
import sys
import os
import time
import signal
import tempfile

# Add autopilots/ (repo-relative) to path for module imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from push_comment_sender import send_push_comments, send_kill_switch_alert
from multica_helpers import AGENT_MAP, PidFileLock, WorkspaceMutex, multica_cli
from kill_switch import kill_switch_default
from issue_status_analysis import (
    STALE_RUN_AGE_HOURS,  # noqa: F401 — re-export (tests import from here)
    completeness_score,
    count_push_reminders,
    get_latest_commenter,
    get_latest_push_reminder_time,
    get_latest_run_status,
    has_active_run,
    has_assignee_recent_activity,
    is_within_grace_period,
)


# --- Argument parsing ---

def parse_args():
    parser = argparse.ArgumentParser(
        description="Issue status inspection script for Multica Autopilot"
    )
    parser.add_argument(
        "--dry-run", action="store_true", default=True, dest="dry_run",
        help="Dry run mode (default: enabled)"
    )
    parser.add_argument(
        "--no-dry-run", action="store_false", dest="dry_run",
        help="Disable dry-run mode (execute real operations)"
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Verbose mode"
    )
    parser.add_argument(
        "--self-agent-id", default="b2384294-919a-4a91-9f35-2c45848577aa",
        help="Self agent ID (default: %(default)s)"
    )
    parser.add_argument(
        "--kill-switch", default=kill_switch_default(),
        help="Kill switch: true/false (default: %(default)s; paused 文件或 KILL_SWITCH env 命中即 true)"
    )
    parser.add_argument(
        "--pid-file",
        default=os.path.join(tempfile.gettempdir(), "issue_status_check.pid"),
        help="PID file path (default: %(default)s)"
    )
    parser.add_argument(
        "--lock-timeout", default="300", type=int,
        help="Lock timeout in seconds (default: %(default)s)"
    )
    parser.add_argument(
        "--alert-issue-id", default="",
        help="Issue ID to send Kill Switch alert comment on (default: none)"
    )
    parser.add_argument(
        "--grace-period-minutes", default=10, type=int,
        help="Grace period in minutes: issues created within this window are skipped "
             "and not pushed (default: %(default)s)"
    )
    return parser.parse_args()


# --- Module-level variables (defaults; updated at runtime) ---

dry_run = True
verbose = False
self_agent_id = "b2384294-919a-4a91-9f35-2c45848577aa"
alert_issue_id = ""
state = {"kill_switch": False}
pid_file = ""

ENCODING = "utf-8"
ERRORS = "replace"
TIMEOUT = 30

GRACE_PERIOD_MINUTES = 10

# Only comments within this window are considered "active" for contributor checks
COMMENT_ACTIVITY_THRESHOLD_MINUTES = 20


STATUSES = ["todo", "in_progress", "blocked"]
PUSH_THRESHOLD = 2

MAX_ISSUES_PER_STATUS = 200
MAX_ERRORS_RATIO = 0.3


# --- Helper functions ---

def run(cmd, fallback="", timeout=TIMEOUT):
    """Thin wrapper over multica_helpers.multica_cli with SEE-956 H8 retry semantics.

    Preserves the legacy signature (returns stdout or fallback) so callers do
    not change. Transient CLI failures now get exponential backoff instead of
    silently falling back, which is the whole point of SEE-1224 #3.
    """
    ok, out = multica_cli(cmd, timeout=timeout)
    return out if ok else fallback


def fetch_issues_by_status(status, processing_log):
    """Phase 1: Fetch all issues for a given status with pagination."""
    all_issues = []
    offset = 0
    limit = 100

    while True:
        cmd = f"multica issue list --status {status} --limit {limit} --offset {offset} --output json"
        raw = run(cmd)
        if not raw:
            processing_log.append(f"phase1_fetch_failed: status={status} offset={offset}")
            break

        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            processing_log.append(f"phase1_json_parse_error: status={status} offset={offset}")
            break

        items = data.get("issues", []) if isinstance(data, dict) else data
        if isinstance(items, list):
            all_issues.extend(items)

        if len(all_issues) > MAX_ISSUES_PER_STATUS:
            state["kill_switch"] = True
            processing_log.append(
                f"kill_switch_triggered: status={status} count={len(all_issues)} exceeds max={MAX_ISSUES_PER_STATUS}"
            )
            break

        if isinstance(data, dict) and data.get("has_more", False):
            offset += limit
        else:
            break

    return all_issues


def fetch_issue_comments(issue_id, processing_log):
    """Phase 2: Fetch all comments for an issue."""
    cmd = f"multica issue comment list {issue_id} --output json"
    raw = run(cmd, timeout=15)
    if not raw:
        processing_log.append(f"phase2_comment_fetch_failed: issue={issue_id}")
        return []

    # Strip "Showing X of Y comments." prefix line if present
    lines = raw.strip().splitlines()
    json_start = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") or stripped.startswith("{"):
            json_start = i
            break
    json_raw = "\n".join(lines[json_start:]) if json_start < len(lines) else raw

    try:
        data = json.loads(json_raw)
    except json.JSONDecodeError:
        processing_log.append(f"phase2_comment_json_error: issue={issue_id}")
        return []

    comments = data if isinstance(data, list) else data.get("comments", [])
    return comments if isinstance(comments, list) else []


def fetch_issue_runs(issue_id, processing_log):
    """Phase 2: Fetch runs for an issue."""
    cmd = f"multica issue runs {issue_id} --output json"
    raw = run(cmd, timeout=15)
    if not raw:
        processing_log.append(f"phase2_runs_fetch_failed: issue={issue_id}")
        return []

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        processing_log.append(f"phase2_runs_json_error: issue={issue_id}")
        return []

    return data if isinstance(data, list) else []


def fetch_issue_detail(issue_id, processing_log):
    """Phase 2: Fetch full issue details."""
    cmd = f"multica issue get {issue_id} --output json"
    raw = run(cmd, timeout=15)
    if not raw:
        processing_log.append(f"phase2_detail_fetch_failed: issue={issue_id}")
        return None

    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        processing_log.append(f"phase2_detail_json_error: issue={issue_id}")
        return None


def validate_agent_map(processing_log):
    """Phase 0: Validate AGENT_MAP against live agent and member lists.

    Agent IDs (mention://agent/) are validated against multica agent list.
    Member IDs (mention://member/) are validated against workspace members.
    Mismatches are logged and counted as errors (may trigger Kill Switch).
    Returns the number of mismatches found.
    """
    # Split AGENT_MAP into agent IDs and member IDs by mention URL pattern
    agent_ids_in_map = set()
    member_ids_in_map = set()
    for map_id, mention in AGENT_MAP.items():
        if "mention://agent/" in mention:
            agent_ids_in_map.add(map_id)
        elif "mention://member/" in mention:
            member_ids_in_map.add(map_id)

    mismatch_count = 0

    # Validate agent IDs against multica agent list
    cmd = "multica agent list --output json"
    raw = run(cmd)
    if not raw:
        processing_log.append("phase0_agent_list_fetch_failed")
    else:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            processing_log.append("phase0_agent_list_json_error")
            data = None

        if data is not None:
            agents = data if isinstance(data, list) else data.get("agents", [])
            live_agent_ids = set()
            for agent in agents:
                agent_id = agent.get("id", "")
                agent_name = agent.get("name", "?")
                live_agent_ids.add(agent_id)
                if agent_id not in agent_ids_in_map:
                    mismatch_count += 1
                    processing_log.append(
                        f"phase0_agent_map_mismatch: id={agent_id} name={agent_name} "
                        f"missing_from_agent_map"
                    )

            for map_id in agent_ids_in_map:
                if map_id not in live_agent_ids:
                    mismatch_count += 1
                    processing_log.append(
                        f"phase0_agent_map_mismatch: id={map_id} in_agent_map_but_not_live_agent"
                    )

    # Validate member IDs against workspace members list
    cmd = "multica workspace member list --output json"
    raw = run(cmd)
    if not raw:
        processing_log.append("phase0_member_list_fetch_failed")
    else:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            processing_log.append("phase0_member_list_json_error")
            data = None

        if data is not None:
            members = data if isinstance(data, list) else data.get("members", [])
            live_member_ids = set()
            for member in members:
                # member mention links use user_id, not workspace-specific id
                member_id = member.get("user_id", "") or member.get("id", "")
                member_name = member.get("name", "?")
                live_member_ids.add(member_id)
                if member_id not in member_ids_in_map:
                    mismatch_count += 1
                    processing_log.append(
                        f"phase0_member_map_mismatch: id={member_id} name={member_name} "
                        f"missing_from_member_map"
                    )

            for map_id in member_ids_in_map:
                if map_id not in live_member_ids:
                    mismatch_count += 1
                    processing_log.append(
                        f"phase0_member_map_mismatch: id={map_id} in_member_map_but_not_live_member"
                    )

    if mismatch_count > 0:
        processing_log.append(
            f"phase0_agent_map_check: mismatches={mismatch_count}"
        )

    return mismatch_count


def reconfirm_issue_status(issue_id, expected_status, processing_log):
    """Phase 3/4: Re-confirm issue status before decision (race condition guard)."""
    detail = fetch_issue_detail(issue_id, processing_log)
    if detail is None:
        processing_log.append(f"reconfirm_failed: issue={issue_id}")
        return expected_status
    actual = detail.get("status", "")
    if actual != expected_status:
        processing_log.append(
            f"race_detected: issue={issue_id} expected={expected_status} actual={actual}"
        )
    return actual


STALE_RUN_HOURS = 4

# SEE-956 H1/H2: placeholder issue detection.
# Issues scoring below PLACEHOLDER_THRESHOLD are considered "placeholder"
# (e.g. a title with no real description) and are routed to a separate
# `placeholder` bucket so they do not trigger no_assignee pings.
PLACEHOLDER_THRESHOLD = 40


def classify_issue(issue, push_count, latest_commenter, latest_run_status,
                   reconfirmed_status, runs, processing_log, comments=None):
    """Phase 3/4: Classify an issue into a decision category."""
    # Completed/cancelled/in_review issues should never be pushed or classified as running
    if reconfirmed_status in ("done", "cancelled", "in_review"):
        return None, None

    assignee_id = issue.get("assignee_id")
    assignee_type = issue.get("assignee_type")
    # Guard: only mark as running if issue is not already completed
    # Uses has_active_run to check ALL runs for running/queued status
    has_running_run = (
        has_active_run(runs)
        and reconfirmed_status not in ("done", "cancelled")
    )
    has_other_contributor = False
    if latest_commenter is not None:
        other_author_id = latest_commenter.get("author_id", "")
        # Only counts as "other contributor" if commenter is different from assignee
        is_different_from_assignee = (other_author_id != assignee_id) if assignee_id else True
        # Only counts if comment is recent (within activity threshold)
        comment_created_at = latest_commenter.get("created_at", "")
        is_recent = is_within_grace_period(comment_created_at, COMMENT_ACTIVITY_THRESHOLD_MINUTES)
        has_other_contributor = is_different_from_assignee and is_recent

    # Check if assignee has recent self-activity (even when has_other_contributor is False)
    assignee_recent = has_assignee_recent_activity(
        comments, assignee_id, COMMENT_ACTIVITY_THRESHOLD_MINUTES
    ) if comments else False

    # Check for completed_stale: latest run completed > N hours ago but issue not done
    completed_stale = False
    if latest_run_status == "completed" and runs:
        sorted_runs = sorted(runs, key=lambda r: r.get("created_at", ""), reverse=True)
        completed_at = sorted_runs[0].get("completed_at", "")
        if completed_at:
            try:
                from datetime import datetime, timezone, timedelta
                dt = datetime.fromisoformat(completed_at.replace("Z", "+00:00"))
                stale_cutoff = datetime.now(timezone.utc) - timedelta(hours=STALE_RUN_HOURS)
                if dt < stale_cutoff and reconfirmed_status not in ("done", "cancelled"):
                    completed_stale = True
            except (ValueError, TypeError) as e:
                processing_log.append(
                    f"completed_at_parse_error: "
                    f"issue={issue.get('identifier', issue.get('id', '?'))} "
                    f"completed_at={completed_at} error={e}"
                )
        else:
            processing_log.append(
                f"completed_at_missing: "
                f"issue={issue.get('identifier', issue.get('id', '?'))} "
                f"run_status=completed but completed_at field absent"
            )

    if has_running_run:
        decision = "running"
        reason = "has_running_run"
    elif push_count >= PUSH_THRESHOLD:
        decision = "need_push_decision"
        reason = f"push_count={push_count} >= threshold={PUSH_THRESHOLD}"
    elif push_count > 0:
        decision = "need_push"
        reason = f"push_count={push_count} < threshold={PUSH_THRESHOLD}"
    elif completed_stale:
        decision = "need_push_decision"
        reason = "completed_run_stale"
    elif not assignee_id and not latest_commenter:
        # SEE-956 H1: placeholder issues (low completeness score) are routed
        # to a separate bucket instead of no_assignee so they don't ping
        # Atlas for what is essentially an empty/unspecified issue.
        score = issue.get("completeness_score")
        if score is not None and score < PLACEHOLDER_THRESHOLD:
            decision = "placeholder"
            reason = f"placeholder_low_completeness_score={score}"
        else:
            decision = "no_assignee"
            reason = "no_assignee_and_no_commenters"
    elif not assignee_id and latest_commenter:
        decision = "need_push"
        reason = "no_assignee_but_has_commenter"
    elif assignee_id and has_other_contributor:
        # Other agent/member is genuinely active on this issue — visible but not pushed
        decision = "active"
        reason = "other_contributor_active"
    elif assignee_id and assignee_recent:
        # Assignee recently self-commented — treat as active, not stale
        decision = "active"
        reason = "assignee_recently_active"
    else:
        decision = "need_push"
        reason = "assigned_but_stale"

    if verbose:
        processing_log.append(
            f"decision: issue={issue.get('identifier', issue.get('id', '?'))} "
            f"decision={decision} reason={reason} "
            f"assignee={assignee_id or 'none'} "
            f"push_count={push_count} run_status={latest_run_status} "
            f"reconfirmed_status={reconfirmed_status}"
        )

    entry = {
        "id": issue.get("id", ""),
        "identifier": issue.get("identifier", ""),
        "title": issue.get("title", ""),
        "status": reconfirmed_status,
        "assignee_id": assignee_id or "",
        "assignee_type": assignee_type or "",
        "push_count": push_count,
        "latest_run_status": latest_run_status,
        "decision": decision,
        "decision_reason": reason,
    }

    # SEE-956 H2: surface the completeness score when it was computed.
    score = issue.get("completeness_score")
    if score is not None:
        entry["completeness_score"] = score

    # SEE-956 H3: pass through the latest push reminder timestamp so
    # push_comment_sender can apply the 24h no_assignee cooldown.
    latest_push_at = issue.get("latest_push_reminder_at")
    if latest_push_at:
        entry["latest_push_reminder_at"] = latest_push_at

    if latest_commenter:
        entry["latest_commenter_id"] = latest_commenter.get("author_id", "")
        entry["latest_commenter_type"] = latest_commenter.get("author_type", "")

    return decision, entry


def main():
    processing_log = []
    categories = {
        "grace_period": [],
        "need_push": [],
        "need_push_decision": [],
        "running": [],
        "active": [],
        "no_assignee": [],
        "placeholder": [],  # SEE-956 H1: low-completeness issues, never pinged
        "errors": [],
    }

    # Phase 0: Validate AGENT_MAP consistency against live agent list
    initial_kill_switch = state["kill_switch"]
    agent_map_mismatches = validate_agent_map(processing_log)
    for _ in range(agent_map_mismatches):
        categories["errors"].append({
            "id": "",
            "identifier": "",
            "error": "agent_map_mismatch",
        })

    # Phase 1: Collect issues across all target statuses
    all_issues = []
    status_counts = {}
    for status in STATUSES:
        issues = fetch_issues_by_status(status, processing_log)
        all_issues.extend(issues)
        status_counts[status] = len(issues)

    processing_log.append(
        f"phase1_complete: total_issues={len(all_issues)} "
        + " ".join(f"{s}={status_counts[s]}" for s in STATUSES)
    )

    # Phase 2: Enrich each issue with comments, runs, and detail
    for issue in all_issues:
        issue_id = issue.get("id", "")
        identifier = issue.get("identifier", "")
        expected_status = issue.get("status", "")

        # Fetch detail (re-fetch for fresh data)
        detail = fetch_issue_detail(issue_id, processing_log)
        if detail is None:
            categories["errors"].append({
                "id": issue_id,
                "identifier": identifier,
                "error": "detail_fetch_failed",
            })
            if verbose:
                processing_log.append(f"error: issue={identifier} detail_fetch_failed")
            continue

        # Fetch comments first (needed for latest_push_reminder_at)
        comments = fetch_issue_comments(issue_id, processing_log)
        push_count = count_push_reminders(comments, self_agent_id)
        latest_commenter = get_latest_commenter(comments, self_agent_id)
        # SEE-956 H3: 24h rate-limit for no_assignee pings.
        latest_push_reminder_at = get_latest_push_reminder_time(
            comments, self_agent_id
        )

        # Use detail data as canonical source
        enriched = {
            "id": detail.get("id", issue_id),
            "identifier": detail.get("identifier", identifier),
            "title": detail.get("title", ""),
            "status": detail.get("status", expected_status),
            "assignee_id": detail.get("assignee_id"),
            "assignee_type": detail.get("assignee_type"),
            # SEE-956 H1/H2: completeness score from title+description drives
            # placeholder classification.
            "completeness_score": completeness_score(
                detail.get("title", ""), detail.get("description", "")
            ),
            # SEE-956 H3: timestamp of our latest push reminder, for 24h
            # rate-limiting of no_assignee pings in push_comment_sender.
            "latest_push_reminder_at": latest_push_reminder_at,
        }

        # Fetch runs
        runs = fetch_issue_runs(issue_id, processing_log)
        latest_run_status = get_latest_run_status(runs)

        # Grace period check: skip issues created within the grace window
        created_at = detail.get("created_at", "")
        if is_within_grace_period(created_at, GRACE_PERIOD_MINUTES):
            categories["grace_period"].append({
                "id": enriched["id"],
                "identifier": enriched["identifier"],
                "title": enriched["title"],
                "status": enriched["status"],
                "assignee_id": enriched["assignee_id"] or "",
                "assignee_type": enriched["assignee_type"] or "",
                "created_at": created_at,
            })
            if verbose:
                processing_log.append(
                    f"grace_period: issue={enriched['identifier']} "
                    f"created_at={created_at} grace_minutes={GRACE_PERIOD_MINUTES}"
                )
            continue

        # Phase 3/4: Re-confirm status (race condition guard)
        reconfirmed_status = enriched["status"]
        if not dry_run and not state["kill_switch"]:
            reconfirmed_status = reconfirm_issue_status(
                issue_id, enriched["status"], processing_log
            )

        # Phase 3/4: Classify
        decision, entry = classify_issue(
            enriched, push_count, latest_commenter, latest_run_status,
            reconfirmed_status, runs, processing_log, comments=comments
        )
        if decision is None:
            # done/cancelled issues are skipped
            continue
        categories[decision].append(entry)

    # Kill switch check: if error ratio too high, downgrade
    total_processed = sum(len(v) for v in categories.values())
    error_ratio = len(categories["errors"]) / max(total_processed, 1)
    if error_ratio > MAX_ERRORS_RATIO:
        state["kill_switch"] = True
        processing_log.append(
            f"kill_switch_triggered: error_ratio={error_ratio:.2f} exceeds max={MAX_ERRORS_RATIO}"
        )

    # Phase 5: Send push comments (computes actions in all modes; sends only
    # in non-dry-run, non-kill-switch mode)
    push_result = send_push_comments(
        categories, processing_log, state,
        dry_run=dry_run, max_errors_ratio=MAX_ERRORS_RATIO,
    )

    # Phase 6: Kill Switch alert — if auto-triggered during this run,
    # send an @Atlas alert comment on the configured alert issue
    kill_switch_alert = None
    if (
        not initial_kill_switch
        and state["kill_switch"]
        and alert_issue_id
        and not dry_run
    ):
        kill_switch_alert = send_kill_switch_alert(
            alert_issue_id=alert_issue_id,
            trigger_phase="phase1_or_phase5",
            processing_log=processing_log,
            state=state,
        )

    # Summary
    summary = {
        "total_issues": len(all_issues),
        "status_counts": status_counts,
        "category_counts": {k: len(v) for k, v in categories.items()},
        "dry_run": dry_run,
        "kill_switch": state["kill_switch"],
        "self_agent_id": self_agent_id,
        "push_threshold": PUSH_THRESHOLD,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    result = {}
    for k, v in categories.items():
        result[k] = v
    result["processing_log"] = processing_log if verbose else []
    result["summary"] = summary
    result["push_actions"] = push_result["push_actions"]
    result["push_actions_summary"] = push_result["push_actions_summary"]
    if kill_switch_alert:
        result["kill_switch_alert"] = kill_switch_alert

    print(json.dumps(result, indent=2, ensure_ascii=False))


# Cleanup is handled by PidFileLock.__exit__; signal handlers only need to
# trigger the same `finally` unwind path so the lock releases cleanly.
def _exit_with_signal(sig, frame):
    sys.exit(128 + sig)


if __name__ == "__main__":
    args = parse_args()

    dry_run = args.dry_run
    verbose = args.verbose
    self_agent_id = args.self_agent_id
    alert_issue_id = args.alert_issue_id
    grace_period_minutes = args.grace_period_minutes
    state["kill_switch"] = args.kill_switch.lower() == "true"
    pid_file = args.pid_file

    GRACE_PERIOD_MINUTES = grace_period_minutes

    # SEE-956 H10+L3: workspace-level advisory mutex so this autopilot does
    # not run concurrently with other autopilots that touch the same workspace.
    # PidFileLock is a context manager: it acquires on __enter__ (exiting on
    # contention) and releases the flock + removes the PID file on __exit__.
    workspace_mutex = WorkspaceMutex(label="issue_status_check")
    workspace_mutex.acquire()

    signal.signal(signal.SIGINT, _exit_with_signal)
    if sys.platform != "win32":
        signal.signal(signal.SIGTERM, _exit_with_signal)

    try:
        with PidFileLock(pid_file):
            main()
    finally:
        workspace_mutex.release()