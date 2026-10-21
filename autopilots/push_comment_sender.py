#!/usr/bin/env python3
"""Push comment sender module for issue_status_check.py.

Sends push/reminder comments to issues based on classification results.
Extracted as a separate module to keep issue_status_check.py under 800 lines.

Templates include <!-- push_reminder --> marker for identification by
count_push_reminders(), ensuring only push comments are counted (not
result-reporting comments).
"""

import json
import os
import re
import sys

# Add autopilots/ (repo-relative) to path for multica_helpers import
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from multica_helpers import AGENT_MAP, ATLAS_ID, multica_stdin_cmd
import time as _time

# --- Constants ---

PUSH_MARKER = "<!-- push_reminder -->"

# Terminal statuses — never send push comments to these issues
SKIP_STATUSES = frozenset({"in_review", "done", "cancelled"})

# SEE-956 H3: no_assignee pings are rate-limited to once per cooldown so a
# lingering unassigned issue does not spam @Atlas on every cron run.
NO_ASSIGNEE_PING_COOLDOWN_HOURS = 24


def _is_within_hours(timestamp_str: str, hours: float) -> bool:
    """Return True if an RFC3339/ISO8601 timestamp is within ``hours`` of now."""
    if not timestamp_str or hours <= 0:
        return False
    try:
        from datetime import datetime, timezone, timedelta
        dt = datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
        cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
        return dt > cutoff
    except (ValueError, TypeError):
        return False

# Content markers for identifying push comments (new marker + legacy phrases)
PUSH_CONTENT_MARKERS: list[str] = [
    PUSH_MARKER,
    "请确认本 Issue",
    "本 Issue 已停滞",
    "本 Issue 无 assignee",
]

# --- Comment Templates ---

PUSH_TEMPLATE_NEED_PUSH_FIRST = (
    "{mention_target} 请确认本 Issue 当前处理状态。\n\n"
    "本 Issue 当前状态为 **{status}**，已有一段时间未更新。"
    "请立即选择以下动作之一执行：\n\n"
    "1. **开始处理** — 若本 Issue 仍在你的队列中但尚未启动，"
    "请立即开始处理业务任务。\n"
    "2. **@下一环节成员流转** — 若你已完成当前环节的工作，"
    "请使用 @mention 格式主动 @ 下一环节负责人进行交接。\n"
    "3. **立即变更 Issue 状态** — 若状态已过时，"
    "请执行 `multica issue status {issue_id} {suggested_status}` "
    "更新为正确状态。\n\n"
    "请勿静默完成，必须主动通知下一环节负责人。\n"
    + PUSH_MARKER
)

PUSH_TEMPLATE_NEED_PUSH_SECOND = (
    "{mention_target} 本 Issue 已多次催促仍未推进，请立即处理。\n\n"
    "本 Issue 当前状态为 **{status}**，这是第 {push_count_display} 次催促。"
    "请立即选择以下动作之一执行：\n\n"
    "1. **开始处理** — 若本 Issue 仍在你的队列中但尚未启动，"
    "请立即开始处理业务任务。\n"
    "2. **@下一环节成员流转** — 若你已完成当前环节的工作，"
    "请使用 @mention 格式主动 @ 下一环节负责人进行交接。\n"
    "3. **立即变更 Issue 状态** — 若状态已过时，"
    "请执行 `multica issue status {issue_id} {suggested_status}` "
    "更新为正确状态。\n\n"
    "若无法推进，请回复说明阻塞原因，"
    "否则将进一步升级处理。\n"
    + PUSH_MARKER
)

PUSH_TEMPLATE_DECISION = (
    "{mention_target} 本 Issue 已停滞，现需强制推进决策。\n\n"
    "前置上下文：\n"
    "- 已发出 {push_count} 次催促，仍未推进\n"
    "- 当前状态：{status}\n"
    "- 最新 run 状态：{latest_run_status}\n"
    "- 分类原因：{decision_reason}\n\n"
    "请选择以下动作之一：\n"
    "1. **若工作已完成** — "
    "执行 `multica issue status {issue_id} in_review` 更新状态\n"
    "2. **@下一环节负责人接手** — 使用 @mention 通知下一环节\n"
    "3. **需人工介入** — 回复说明阻塞原因\n\n"
    "若无法判断，"
    "将升级给 [@Atlas](mention://agent/{atlas_id}) 处理。\n"
    + PUSH_MARKER
)

PUSH_TEMPLATE_NO_ASSIGNEE = (
    "[@Atlas](mention://agent/{atlas_id}) "
    "本 Issue 无 assignee 且无评论者，请指派负责人。\n\n"
    "- Issue: {identifier_link}\n"
    "- 当前状态：{status}\n"
    + PUSH_MARKER
)

KILL_SWITCH_ALERT_TEMPLATE = (
    "[@Atlas](mention://agent/{atlas_id}) "
    "⚠️ Kill Switch 已自动触发，Issue Status Check 系统已降级为纯输出模式（不发送催促评论）。\n\n"
    "触发阶段：{trigger_phase}\n"
    "触发时间：{timestamp}\n\n"
    "请检查系统状态并手动重置：`--kill-switch=false`\n"
    + PUSH_MARKER
)


# --- Helper functions ---


def _run_shell(cmd: str, timeout: int = 15) -> str:
    """Run a multica CLI command and return stdout (stripped). Returns empty string on failure."""
    import shlex
    import subprocess
    try:
        args = shlex.split(cmd) if isinstance(cmd, str) else cmd
        r = subprocess.run(
            args, shell=False, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout,
        )
        return r.stdout.strip()
    except Exception:
        return ""


def is_issue_in_terminal_status(issue_id: str, processing_log: list) -> bool:
    """Re-check issue status before sending a push comment.

    Guards against the race where an issue transitions to in_review/done/cancelled
    between Phase 1 (scan) and Phase 5 (send).
    """
    raw = _run_shell(f"multica issue get {issue_id} --output json")
    if not raw:
        # If we can't confirm, assume NOT terminal (safer to skip but log it)
        processing_log.append(
            f"phase5_status_reconfirm_failed: issue={issue_id} "
            f"assuming_not_terminal"
        )
        return False
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        processing_log.append(
            f"phase5_status_reconfirm_parse_error: issue={issue_id}"
        )
        return False
    current_status = data.get("status", "")
    if current_status in SKIP_STATUSES:
        processing_log.append(
            f"phase5_status_skip: issue={issue_id} current_status={current_status}"
        )
        return True
    return False


def resolve_mention_target(entry: dict) -> tuple[str, str]:
    """Resolve the mention target for a push comment.

    Priority chain:
    1. Has assignee -> @assignee
    2. No assignee but has non-self commenter -> @latest_commenter
    3. No assignee and no commenter -> @Atlas

    Returns (mention_link, mention_target_id).
    """
    assignee_id = entry.get("assignee_id", "")
    latest_commenter_id = entry.get("latest_commenter_id", "")
    atlas_mention = AGENT_MAP.get(ATLAS_ID, "[@Atlas]")

    if assignee_id:
        return (AGENT_MAP.get(assignee_id, atlas_mention), assignee_id)

    if latest_commenter_id:
        return (AGENT_MAP.get(latest_commenter_id, atlas_mention), latest_commenter_id)

    return (atlas_mention, ATLAS_ID)


def extract_mention_name(mention_link: str) -> str:
    """Extract display name from a mention link like [@Atlas](mention://...)."""
    match = re.match(r"\[@(\w+)\]", mention_link)
    if match:
        return match.group(1)
    return "Atlas"


def suggest_next_status(current_status: str) -> str:
    """Suggest a reasonable next status for the push template."""
    mapping: dict[str, str] = {
        "todo": "in_progress",
        "in_progress": "in_review",
        "in_review": "done",
        "blocked": "in_progress",
    }
    return mapping.get(current_status, "in_review")


def build_identifier_link(identifier: str, issue_id: str) -> str:
    """Build the issue mention link like [SEE-175](mention://issue/<uuid>)."""
    return f"[{identifier}](mention://issue/{issue_id})"


def determine_push_action(category: str, entry: dict) -> tuple[str, str]:
    """Determine push action type and select the appropriate template.

    Returns (action_name, template_string).
    """
    push_count = entry.get("push_count", 0)

    if category == "no_assignee":
        return ("no_assignee", PUSH_TEMPLATE_NO_ASSIGNEE)

    if category == "need_push_decision":
        return ("need_push_decision", PUSH_TEMPLATE_DECISION)

    if category == "need_push":
        if push_count == 0:
            return ("need_push_first", PUSH_TEMPLATE_NEED_PUSH_FIRST)
        return ("need_push_second", PUSH_TEMPLATE_NEED_PUSH_SECOND)

    return ("need_push_first", PUSH_TEMPLATE_NEED_PUSH_FIRST)


def render_push_template(template: str, entry: dict, mention_target: str) -> str:
    """Render a push comment template with issue context data."""
    context = {
        "mention_target": mention_target,
        "status": entry.get("status", ""),
        "issue_id": entry.get("id", ""),
        "suggested_status": suggest_next_status(entry.get("status", "")),
        "push_count": str(entry.get("push_count", 0)),
        "push_count_display": str(entry.get("push_count", 0) + 1),
        "latest_run_status": entry.get("latest_run_status", "unknown"),
        "decision_reason": entry.get("decision_reason", ""),
        "atlas_id": ATLAS_ID,
        "identifier_link": build_identifier_link(
            entry.get("identifier", ""), entry.get("id", "")
        ),
    }
    return template.format(**context)


def send_push_comments(
    categories: dict,
    processing_log: list,
    state: dict,
    dry_run: bool = False,
    max_errors_ratio: float = 0.3,
) -> dict:
    """Phase 5: Send push comments to classified issues.

    In dry-run mode: computes push_actions with sent=False, no actual sending.
    In non-dry-run, non-kill-switch mode: sends comments via multica_stdin_cmd.
    Tracks errors and triggers kill_switch if error ratio exceeds threshold.

    Returns dict with push_actions list and push_actions_summary.
    """
def _send_push_comment(issue_id: str, comment_content: str, identifier: str,
                       action: str, mention_target_name: str, processing_log: list) -> tuple:
    base_cmd = f"multica issue comment add {issue_id} --content-stdin"
    ok, out = multica_stdin_cmd(base_cmd, comment_content)
    if ok:
        processing_log.append(
            f"phase5_push_sent: issue={identifier} "
            f"action={action} target={mention_target_name}"
        )
    else:
        processing_log.append(
            f"phase5_push_failed: issue={identifier} "
            f"action={action} error={out}"
        )
    return ok, out


def _no_assignee_rate_limited(entry: dict, action: str, should_send: bool,
                              identifier: str, processing_log: list) -> bool:
    # SEE-956 H3: rate-limit no_assignee pings to one per cooldown.
    # If we already pinged within the window, skip silently.
    if (
        should_send
        and action == "no_assignee"
        and _is_within_hours(
            entry.get("latest_push_reminder_at", ""),
            NO_ASSIGNEE_PING_COOLDOWN_HOURS,
        )
    ):
        processing_log.append(
            f"phase5_no_assignee_rate_limited: issue={identifier} "
            f"cooldown_hours={NO_ASSIGNEE_PING_COOLDOWN_HOURS}"
        )
        return True
    return False


def _check_error_ratio(state: dict, error_count: int, total_attempted: int,
                       max_errors_ratio: float, processing_log: list) -> bool:
    # Kill Switch: check error ratio after each send attempt
    if total_attempted > 0:
        ratio = error_count / total_attempted
        if ratio > max_errors_ratio:
            state["kill_switch"] = True
            processing_log.append(
                f"kill_switch_triggered_phase5: "
                f"error_ratio={ratio:.2f} "
                f"exceeds max={max_errors_ratio}"
            )
            return True
    return False


def send_push_comments(
    categories: dict,
    processing_log: list,
    state: dict,
    dry_run: bool = False,
    max_errors_ratio: float = 0.3,
) -> dict:
    """Phase 5: Send push comments to classified issues.

    In dry-run mode: computes push_actions with sent=False, no actual sending.
    In non-dry-run, non-kill-switch mode: sends comments via multica_stdin_cmd.
    Tracks errors and triggers kill_switch if error ratio exceeds threshold.

    Returns dict with push_actions list and push_actions_summary.
    """
    push_actions: list[dict] = []
    sent_count = 0
    failed_count = 0
    skipped_count = 0
    error_count_for_kill_switch = 0
    total_attempted = 0
    kill_switch_triggered = False

    push_categories = ["need_push", "need_push_decision", "no_assignee"]

    for category in push_categories:
        if kill_switch_triggered:
            break
        for entry in categories.get(category, []):
            if kill_switch_triggered:
                break

            issue_id = entry.get("id", "")
            identifier = entry.get("identifier", "")
            identifier_link = build_identifier_link(identifier, issue_id)

            action, template = determine_push_action(category, entry)
            mention_link, mention_target_id = resolve_mention_target(entry)
            mention_target_name = extract_mention_name(mention_link)
            comment_content = render_push_template(template, entry, mention_link)

            should_send = not dry_run and not state.get("kill_switch", False)

            # Race condition guard: re-check status before sending
            if should_send and is_issue_in_terminal_status(issue_id, processing_log):
                should_send = False

            if _no_assignee_rate_limited(entry, action, should_send, identifier, processing_log):
                should_send = False

            if should_send:
                total_attempted += 1
                ok, out = _send_push_comment(
                    issue_id, comment_content, identifier, action,
                    mention_target_name, processing_log,
                )

                if ok:
                    sent_count += 1
                else:
                    failed_count += 1
                    error_count_for_kill_switch += 1

                push_actions.append({
                    "issue_id": issue_id,
                    "identifier": identifier_link,
                    "action": action,
                    "mention_target": mention_target_name,
                    "mention_target_id": mention_target_id,
                    "sent": ok,
                    "error": out if not ok else None,
                })

                if _check_error_ratio(state, error_count_for_kill_switch,
                                      total_attempted, max_errors_ratio, processing_log):
                    kill_switch_triggered = True
            else:
                skipped_count += 1
                push_actions.append({
                    "issue_id": issue_id,
                    "identifier": identifier_link,
                    "action": action,
                    "mention_target": mention_target_name,
                    "mention_target_id": mention_target_id,
                    "sent": False,
                    "dry_run": dry_run,
                    "kill_switch": state.get("kill_switch", False),
                    "error": None,
                })

    # Enforce invariant: total = sent + failed + skipped
    assert sent_count + failed_count + skipped_count == len(push_actions), (
        f"Count invariant broken: sent={sent_count} + failed={failed_count} "
        f"+ skipped={skipped_count} != total={len(push_actions)}"
    )

    summary = {
        "total": sent_count + failed_count + skipped_count,
        "sent": sent_count,
        "failed": failed_count,
        "skipped": skipped_count,
    }

    return {
        "push_actions": push_actions,
        "push_actions_summary": summary,
    }


def send_kill_switch_alert(
    alert_issue_id: str,
    trigger_phase: str,
    processing_log: list,
    state: dict,
) -> dict | None:
    """Phase 6: Send Kill Switch alert comment to @Atlas on the alert issue.

    Only called when Kill Switch was auto-triggered during this run
    (not pre-existing), in non-dry-run mode, with a configured alert_issue_id.

    Returns dict with sent status, or None if skipped.
    """
    timestamp = _time.strftime("%Y-%m-%dT%H:%M:%SZ", _time.gmtime())
    content = KILL_SWITCH_ALERT_TEMPLATE.format(
        atlas_id=ATLAS_ID,
        trigger_phase=trigger_phase,
        timestamp=timestamp,
    )

    base_cmd = f"multica issue comment add {alert_issue_id} --content-stdin"
    ok, out = multica_stdin_cmd(base_cmd, content)

    if ok:
        processing_log.append(
            f"phase6_kill_switch_alert_sent: issue={alert_issue_id}"
        )
    else:
        processing_log.append(
            f"phase6_kill_switch_alert_failed: issue={alert_issue_id} error={out}"
        )

    return {
        "alert_issue_id": alert_issue_id,
        "trigger_phase": trigger_phase,
        "timestamp": timestamp,
        "sent": ok,
        "error": out if not ok else None,
    }
