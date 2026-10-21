#!/usr/bin/env python3
"""Agent Watchdog: detect and rerun tasks killed by idle_watchdog.

Scans all workspace agents for failed/cancelled tasks, identifies those
killed by Multica's idle_watchdog (status=failed, error contains
"idle watchdog"), and re-enqueues them via `multica issue rerun`.

Usage:
    python autopilots/agent_watchdog.py --dry-run
    python autopilots/agent_watchdog.py --no-dry-run \\
        --execution-issue-id <uuid>
"""

import argparse
import json
import os
import signal
import sys
import tempfile
from datetime import datetime, timezone

# Add autopilots/ (repo-relative) to path for module imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from multica_helpers import (
    multica_cli,
    multica_stdin_cmd,
    PidFileLock,
    WorkspaceMutex,
    WATCHDOG_STATE_FILE,
    AGENT_NAME_MAP,
)
from watchdog_state import WatchdogState
from watchdog_report import (
    generate_json_report,
    generate_comment_markdown,
    post_report_comment,
    REPORT_MARKER,
)

# --- Constants ---

MAX_ERRORS_RATIO = 0.3
CHEKKY_AGENT_ID = "b2384294-919a-4a91-9f35-2c45848577aa"
IDLE_WATCHDOG_ERROR_PATTERN = "idle watchdog"
MIN_CANCELLED_DURATION_MIN = 25

# Issues in a terminal or waiting state must not be auto-rerun by the watchdog
# (SEE-956 C5). Previously only "done" was skipped, so cancelled / blocked /
# wont_fix issues could be pointlessly re-enqueued.
NO_RERUN_ISSUE_STATUSES = {"done", "cancelled", "blocked", "wont_fix"}


# --- Argument parsing ---


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Agent Watchdog: detect and rerun idle_watchdog-killed tasks"
    )
    parser.add_argument(
        "--dry-run", action="store_true", default=True, dest="dry_run",
        help="Dry run mode (default: enabled)",
    )
    parser.add_argument(
        "--no-dry-run", action="store_false", dest="dry_run",
        help="Disable dry-run mode",
    )
    parser.add_argument("--max-restarts-per-hour", default=3, type=int)
    parser.add_argument(
        "--exclude-agents", default="Atlas",
        help="Comma-separated agent names to exclude. Atlas is excluded by default "
             "because it is the CodingTeam orchestrator (never a rerun target).",
    )
    parser.add_argument("--execution-issue-id", default="",
                        help="Issue ID to post report comment on")
    parser.add_argument("--alert-issue-id", default="",
                        help="Issue ID to send Kill Switch alert on")
    parser.add_argument("--pid-file",
                        default=os.path.join(tempfile.gettempdir(), "agent_watchdog.pid"))
    parser.add_argument(
        "--state-file", default=WATCHDOG_STATE_FILE,
        help="Persistent restart-state file. Defaults to ~/.multica/watchdog_state.json "
             "so the sliding-window count survives reboots (SEE-956 C6).",
    )
    parser.add_argument("--kill-switch", default="false")
    parser.add_argument("--self-agent-id", default=CHEKKY_AGENT_ID)
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


# --- Helper functions ---


def _parse_ts(ts: str) -> datetime:
    """Parse RFC 3339 / ISO 8601 timestamp string."""
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, TypeError, AttributeError):
        return datetime.min.replace(tzinfo=timezone.utc)


def _calculate_duration_minutes(task: dict) -> float:
    """Calculate task duration in minutes from started_at to ended_at."""
    started = _parse_ts(task.get("started_at", ""))
    ended_str = task.get("ended_at") or task.get("completed_at")
    ended = _parse_ts(ended_str) if ended_str else datetime.now(timezone.utc)
    if started == datetime.min.replace(tzinfo=timezone.utc):
        return 0.0
    return max(0.0, (ended - started).total_seconds() / 60.0)


def _is_idle_watchdog_kill(task: dict) -> bool:
    """Check if task was killed by idle_watchdog (status=failed, error contains pattern)."""
    return (
        task.get("status") == "failed"
        and IDLE_WATCHDOG_ERROR_PATTERN in (task.get("error") or "").lower()
    )


def _is_long_cancelled(task: dict) -> bool:
    """Check if task was a long-running manually cancelled task (>=25min)."""
    if task.get("status") != "cancelled" or task.get("error") is not None:
        return False
    return _calculate_duration_minutes(task) >= MIN_CANCELLED_DURATION_MIN


# --- Phase functions ---


def fetch_agents(
    exclude_names: list[str], self_agent_id: str, processing_log: list[str],
) -> list[dict]:
    """Phase 1: Get agent list, filter out excluded and self."""
    ok, raw = multica_cli("multica agent list --output json")
    if not ok:
        processing_log.append(f"phase1_agent_list_failed: {raw}")
        return []

    try:
        agents = json.loads(raw)
    except json.JSONDecodeError:
        processing_log.append("phase1_agent_list_json_error")
        return []

    exclude_ids = set()
    for name in exclude_names:
        aid = AGENT_NAME_MAP.get(name.lower())
        if aid:
            exclude_ids.add(aid)
    exclude_ids.add(self_agent_id)

    filtered = [
        {"id": a["id"], "name": a["name"], "status": a.get("status", "")}
        for a in agents
        if a.get("id") not in exclude_ids
    ]
    processing_log.append(f"phase1_complete: agents={len(agents)} after_filter={len(filtered)}")
    return filtered


def get_failed_runs(
    agents: list[dict], processing_log: list[str],
) -> list[dict]:
    """Phase 2: For each agent, fetch failed/cancelled tasks."""
    all_tasks: list[dict] = []
    for agent in agents:
        agent_id = agent["id"]
        agent_name = agent["name"]
        ok, raw = multica_cli(f"multica agent tasks {agent_id} --output json")
        if not ok:
            processing_log.append(f"phase2_tasks_failed: agent={agent_name} error={raw}")
            continue
        try:
            tasks = json.loads(raw)
        except json.JSONDecodeError:
            processing_log.append(f"phase2_tasks_json_error: agent={agent_name}")
            continue

        for t in tasks:
            if t.get("status") not in ("failed", "cancelled"):
                continue
            all_tasks.append({
                "task_id": t["id"],
                "agent_id": agent_id,
                "agent_name": agent_name,
                "issue_id": t.get("issue_id", ""),
                "status": t.get("status", ""),
                "error": t.get("error"),
                "started_at": t.get("started_at", ""),
                "ended_at": t.get("ended_at") or t.get("completed_at", ""),
            })

    processing_log.append(f"phase2_complete: failed_runs={len(all_tasks)}")
    return all_tasks


def _fetch_issue_info(issue_id: str, processing_log: list[str]) -> dict:
    """Fetch issue details via multica CLI."""
    ok, raw = multica_cli(f"multica issue get {issue_id} --output json", timeout=10)
    if not ok:
        processing_log.append(f"fetch_issue_info_failed: issue={issue_id} error={raw}")
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        processing_log.append(f"fetch_issue_info_json_error: issue={issue_id}")
        return {}


def _fetch_issue_runs(issue_id: str, processing_log: list[str]) -> list[dict]:
    """Fetch issue run history via multica CLI, ordered by time descending."""
    ok, raw = multica_cli(f"multica issue runs {issue_id} --output json", timeout=10)
    if not ok:
        processing_log.append(f"fetch_issue_runs_failed: issue={issue_id} error={raw}")
        return []
    try:
        runs = json.loads(raw)
        return runs if isinstance(runs, list) else []
    except json.JSONDecodeError:
        processing_log.append(f"fetch_issue_runs_json_error: issue={issue_id}")
        return []


def detect_idle_watchdog_kills(
    failed_runs: list[dict], processing_log: list[str],
) -> list[dict]:
    """Phase 3: Identify idle_watchdog-killed tasks via three-level filtering."""
    # Level 1: Pattern matching
    candidates: list[dict] = []
    for task in failed_runs:
        if _is_idle_watchdog_kill(task):
            candidates.append({**task, "detection_method": "idle_watchdog_error"})
        elif _is_long_cancelled(task):
            candidates.append({**task, "detection_method": "long_cancelled"})
        else:
            processing_log.append(
                f"phase3_skip_pattern: task={task['task_id']} "
                f"status={task.get('status')} error_match=false"
            )

    if not candidates:
        processing_log.append("phase3_complete: kills=0 (no candidates)")
        return []

    # Level 2 & 3: Verify each candidate is latest run and issue not done
    approved_kills: list[dict] = []
    issue_cache: dict[str, tuple[dict, list[dict]]] = {}

    for task in candidates:
        issue_id = task.get("issue_id", "")
        if not issue_id:
            processing_log.append(f"phase3_skip: task={task['task_id']} no_issue_id")
            continue

        if issue_id not in issue_cache:
            issue_info = _fetch_issue_info(issue_id, processing_log)
            issue_runs = _fetch_issue_runs(issue_id, processing_log)
            issue_cache[issue_id] = (issue_info, issue_runs)
        else:
            issue_info, issue_runs = issue_cache[issue_id]

        # Level 2: Must be the latest run
        if issue_runs:
            latest_run_id = issue_runs[0].get("id", "")
            if task["task_id"] != latest_run_id:
                task["skip_reason"] = "not_latest_run"
                processing_log.append(
                    f"phase3_skip: task={task['task_id']} not_latest_run"
                )
                continue

        # Level 3: Issue must not be in a terminal / waiting state (SEE-956 C5)
        issue_status = issue_info.get("status", "")
        if issue_status in NO_RERUN_ISSUE_STATUSES:
            task["skip_reason"] = f"issue_{issue_status}"
            processing_log.append(
                f"phase3_skip: task={task['task_id']} issue_status={issue_status}"
            )
            continue

        task["issue_status"] = issue_status
        task["duration_minutes"] = _calculate_duration_minutes(task)
        approved_kills.append(task)
        processing_log.append(
            f"kill_detected: agent={task['agent_name']} "
            f"issue={issue_id} method={task['detection_method']} "
            f"duration={task['duration_minutes']:.1f}min"
        )

    processing_log.append(f"phase3_complete: kills={len(approved_kills)}")
    return approved_kills


def apply_restart_limits(
    stuck_tasks: list[dict],
    state: WatchdogState,
    max_per_hour: int,
    processing_log: list[str],
) -> tuple[list[dict], list[dict]]:
    """Phase 4: Apply rate-limit checks."""
    approved: list[dict] = []
    skipped: list[dict] = []

    for task in stuck_tasks:
        issue_id = task.get("issue_id", "")
        if state.check_restart_limit(issue_id, max_per_hour):
            approved.append(task)
        else:
            count = state.get_restart_count(issue_id)
            task["skip_reason"] = f"rate_limit: {count}/{max_per_hour} restarts in 1h"
            skipped.append(task)
            processing_log.append(f"phase4_skip: issue={issue_id} restarts={count}/{max_per_hour}")

    return approved, skipped


def execute_reruns(
    approved_tasks: list[dict],
    state: WatchdogState,
    dry_run: bool,
    processing_log: list[str],
    max_per_hour: int = 3,
) -> list[dict]:
    """Phase 5: Execute rerun for approved tasks.

    The rate-limit gate, rerun, and record are wrapped in ``state.lock()`` so the
    check-then-act window is atomic across concurrent watchdog instances (SEE-956
    H11). Phase 4's ``apply_restart_limits`` is an advisory pre-filter; this is
    the authoritative gate, re-checked under the lock.
    """
    results: list[dict] = []
    for task in approved_tasks:
        issue_id = task.get("issue_id", "")
        task_id = task.get("task_id", "")
        failed_agent_id = task.get("agent_id", "")
        entry: dict = {
            "issue_id": issue_id,
            "task_id": task_id,
            "agent_name": task.get("agent_name", ""),
            "success": False,
            "dry_run": dry_run,
            "error": None,
        }

        if dry_run:
            entry["success"] = True
            processing_log.append(f"phase5_dry_run: issue={issue_id}")
            results.append(entry)
            continue

        # Fix SEE-750: sync assignee to failed agent before rerun to avoid
        # mis-dispatching to a stale assignee (e.g. owner delegated via
        # @mention without updating issue assignee).
        original_assignee: str | None = None
        if failed_agent_id:
            info = _fetch_issue_info(issue_id, processing_log)
            original_assignee = info.get("assignee_id")
            if original_assignee and original_assignee != failed_agent_id:
                multica_cli(
                    f"multica issue update {issue_id} --assignee-id {failed_agent_id}"
                )
                processing_log.append(
                    f"phase5_assignee_sync: issue={issue_id} "
                    f"from={original_assignee} to={failed_agent_id}"
                )

        try:
            # Atomic rate-limit gate + rerun + record (SEE-956 H11). The lock
            # makes check→rerun→record one critical section, so two concurrent
            # watchdog instances cannot both pass the cap and double-record.
            with state.lock():
                if not state.check_restart_limit(issue_id, max_per_hour):
                    count = state.get_restart_count(issue_id)
                    entry["error"] = f"rate_limit: {count}/{max_per_hour} restarts in 1h"
                    processing_log.append(
                        f"phase5_skip_rate_limit: issue={issue_id} restarts={count}/{max_per_hour}"
                    )
                else:
                    ok, out = multica_cli(f"multica issue rerun {issue_id}")
                    entry["success"] = ok
                    entry["error"] = None if ok else out
                    if ok:
                        state.record_restart(issue_id, task_id)
                        processing_log.append(f"phase5_rerun_ok: issue={issue_id}")
                    else:
                        processing_log.append(
                            f"phase5_rerun_fail: issue={issue_id} error={out}"
                        )
        finally:
            # Restore original assignee if we changed it
            if original_assignee and original_assignee != failed_agent_id:
                multica_cli(
                    f"multica issue update {issue_id} --assignee-id {original_assignee}"
                )
                processing_log.append(
                    f"phase5_assignee_restore: issue={issue_id} "
                    f"to={original_assignee}"
                )

        results.append(entry)
    return results


def enrich_issue_identifiers(
    tasks: list[dict], processing_log: list[str],
) -> None:
    """Enrich task entries with issue identifiers and status."""
    for task in tasks:
        issue_id = task.get("issue_id", "")
        if not issue_id:
            continue
        # Skip if already enriched (e.g. from Phase 3)
        if task.get("issue_identifier") and task.get("issue_status"):
            continue
        ok, raw = multica_cli(f"multica issue get {issue_id} --output json", timeout=10)
        if ok:
            try:
                data = json.loads(raw)
                task["issue_identifier"] = data.get("identifier", "")
                task["issue_title"] = data.get("title", "")
                task["issue_status"] = data.get("status", "")
            except json.JSONDecodeError:
                pass


# --- Main ---


def _execute_phase5_reruns(approved, watchdog_state, args, kill_switch, processing_log):
    # Phase 5: Execute reruns (skip if kill switch active)
    if kill_switch:
        rerun_results = [
            {"issue_id": t.get("issue_id", ""), "task_id": t.get("task_id", ""),
             "agent_name": t.get("agent_name", ""), "success": False,
             "dry_run": args.dry_run, "error": "kill_switch_active"}
            for t in approved
        ]
        processing_log.append("phase5_skipped: kill_switch_active")
    else:
        rerun_results = execute_reruns(
            approved, watchdog_state, args.dry_run, processing_log,
            args.max_restarts_per_hour,
        )
    return rerun_results


def _auto_kill_switch(rerun_results, processing_log) -> tuple:
    # Kill switch auto-detect
    total_ops = len(rerun_results)
    error_count = sum(
        1 for r in rerun_results
        if not r.get("success") and not r.get("dry_run") and r.get("error") != "kill_switch_active"
    )
    if total_ops > 0:
        error_ratio = error_count / total_ops
        if error_ratio > MAX_ERRORS_RATIO:
            processing_log.append(f"kill_switch_triggered: error_ratio={error_ratio:.2f}")
            return True, error_count
    return False, error_count


def main(args: argparse.Namespace) -> None:
    processing_log: list[str] = []
    kill_switch = args.kill_switch.lower() == "true"

    # Phase 1
    exclude_names = [n.strip() for n in args.exclude_agents.split(",") if n.strip()]
    agents = fetch_agents(exclude_names, args.self_agent_id, processing_log)

    # Phase 2: Scan for failed/cancelled runs
    failed_runs = get_failed_runs(agents, processing_log)

    # Phase 3: Detect idle_watchdog kills
    idle_watchdog_kills = detect_idle_watchdog_kills(failed_runs, processing_log)

    enrich_issue_identifiers(idle_watchdog_kills, processing_log)

    # Phase 4: Rate limiting
    watchdog_state = WatchdogState(args.state_file)
    watchdog_state.cleanup_expired()
    approved, skipped = apply_restart_limits(
        idle_watchdog_kills, watchdog_state, args.max_restarts_per_hour, processing_log,
    )

    rerun_results = _execute_phase5_reruns(
        approved, watchdog_state, args, kill_switch, processing_log,
    )
    kill_switch, error_count = _auto_kill_switch(rerun_results, processing_log)

    # Phase 6: Report
    report = generate_json_report(
        agents_scanned=[{"id": a["id"], "name": a["name"]} for a in agents],
        scanned_tasks=failed_runs,
        idle_watchdog_kills=idle_watchdog_kills,
        rerun_results=rerun_results,
        skipped_tasks=skipped,
        processing_log=processing_log if args.verbose else [],
        dry_run=args.dry_run,
        kill_switch=kill_switch,
        total_errors=error_count,
    )
    print(json.dumps(report, indent=2, ensure_ascii=False))

    # Post comment report
    if args.execution_issue_id:
        markdown = generate_comment_markdown(report, verbose=args.verbose)
        post_report_comment(
            args.execution_issue_id, markdown, args.dry_run, processing_log,
        )

    # Kill switch alert
    if kill_switch and args.alert_issue_id and not args.dry_run:
        alert = (
            "[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) "
            "Kill Switch triggered, Agent Watchdog degraded.\n\n"
            f"Time: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
            f"{REPORT_MARKER}"
        )
        multica_stdin_cmd(
            f"multica issue comment add {args.alert_issue_id} --content-stdin",
            alert,
        )


if __name__ == "__main__":
    args = parse_args()

    with PidFileLock(args.pid_file):
        with WorkspaceMutex(label="agent_watchdog"):
            signal.signal(signal.SIGINT, lambda s, f: sys.exit(128 + s))
            if sys.platform != "win32":
                signal.signal(signal.SIGTERM, lambda s, f: sys.exit(128 + s))
            main(args)
