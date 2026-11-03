"""Report generation for agent_watchdog.py — JSON output and Markdown issue comments."""

import json
import os
import sys

# Add autopilots/ (repo-relative) to path for multica_helpers import
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from multica_helpers import AGENT_MAP, multica_cli, multica_stdin_cmd, utc_now_iso


REPORT_MARKER = "<!-- agent_watchdog_report -->"


def find_marker_comment(issue_id: str, processing_log: list[str]) -> dict | None:
    """在既有评论中查找 REPORT_MARKER 报告 (§SPEC-009 / 69823a273535)。

    返回 {id, revision} 供 edit 复用; 查询失败/无命中返回 None (失败显式记
    processing_log, 不静默 — 查询失败退回 add 语义, 至多多一条评论而非丢报告)。
    """
    ok, raw = multica_cli(
        f"multica issue comment list {issue_id} --output json", timeout=15)
    if not ok:
        processing_log.append(
            f"report_dedup_list_failed: issue={issue_id} error={raw}")
        return None
    try:
        comments = json.loads(raw)
    except json.JSONDecodeError:
        processing_log.append(f"report_dedup_list_json_error: issue={issue_id}")
        return None
    if isinstance(comments, dict):
        comments = comments.get("comments", [])
    if not isinstance(comments, list):
        return None
    for c in comments:
        if isinstance(c, dict) and REPORT_MARKER in (c.get("content") or ""):
            return {"id": c.get("id"), "revision": c.get("revision")}
    return None


def generate_json_report(
    agents_scanned: list[dict],
    scanned_tasks: list[dict],
    idle_watchdog_kills: list[dict],
    rerun_results: list[dict],
    skipped_tasks: list[dict],
    processing_log: list[str],
    dry_run: bool,
    kill_switch: bool,
    total_errors: int,
) -> dict:
    """Generate terminal JSON output structure."""
    summary = {
        "timestamp": utc_now_iso(),
        "dry_run": dry_run,
        "kill_switch": kill_switch,
        "total_agents_scanned": len(agents_scanned),
        "total_scanned_tasks": len(scanned_tasks),
        "idle_watchdog_kills": len(idle_watchdog_kills),
        "reruns_executed": sum(1 for r in rerun_results if r.get("success")),
        "reruns_skipped_limit": len(skipped_tasks),
        "errors": total_errors,
    }
    return {
        "summary": summary,
        "agents_scanned": agents_scanned,
        "scanned_tasks": scanned_tasks,
        "idle_watchdog_kills": idle_watchdog_kills,
        "rerun_results": rerun_results,
        "skipped_tasks": skipped_tasks,
        "processing_log": processing_log,
    }


def generate_comment_markdown(report: dict, verbose: bool = False) -> str:
    """Generate Markdown content for issue comment report."""
    s = report["summary"]
    lines = [
        "## Agent Watchdog 巡检报告",
        "",
        "| 指标 | 值 |",
        "|------|-----|",
        f"| 扫描时间 | {s['timestamp']} |",
        f"| 模式 | {'Dry-Run' if s['dry_run'] else '执行模式'} |",
        f"| 扫描 Agent 数 | {s['total_agents_scanned']} |",
        f"| 扫描 Task 数 | {s['total_scanned_tasks']} |",
        f"| Idle Watchdog 检测数 | {s['idle_watchdog_kills']} |",
        f"| 执行 Rerun 数 | {s['reruns_executed']} |",
        f"| Kill Switch | {'✅ 已触发' if s['kill_switch'] else '❌ 未触发'} |",
        "",
        "### Idle Watchdog 终止任务详情",
        "",
        "| Agent | Issue | 检测方式 | Rerun |",
        "|-------|-------|----------|-------|",
    ]

    for task in report["idle_watchdog_kills"]:
        issue_link = _issue_link(task.get("issue_id"), task.get("issue_identifier", ""))
        detection = task.get("detection_method", "N/A")
        if task.get("duration_minutes"):
            detection += f" ({task['duration_minutes']:.0f}min)"
        rerun_tag = "dry-run 跳过" if s["dry_run"] else "已执行 rerun"
        lines.append(
            f"| {task.get('agent_name', '?')} | {issue_link} | {detection} "
            f"| {rerun_tag} |"
        )

    if not report["idle_watchdog_kills"]:
        lines.append("| — | — | — | 无命中任务 |")

    lines.extend([
        "",
        "### 已跳过（频率限制）",
        "",
        "| Issue | 原因 |",
        "|-------|------|",
    ])

    for skipped in report["skipped_tasks"]:
        issue_link = _issue_link(skipped.get("issue_id"), skipped.get("issue_identifier", ""))
        lines.append(f"| {issue_link} | {skipped.get('skip_reason', '?')} |")

    if not report["skipped_tasks"]:
        lines.append("| — | 无 |")

    if verbose and report["processing_log"]:
        lines.extend([
            "",
            "### 处理日志",
            "",
            "```",
        ])
        for log in report["processing_log"]:
            lines.append(log)
        lines.append("```")

    lines.extend(["", f"---\n*{REPORT_MARKER}*"])
    return "\n".join(lines)


def post_report_comment(
    issue_id: str,
    content: str,
    dry_run: bool,
    processing_log: list[str],
) -> dict:
    """Send report comment to the specified issue (marker 查重, 命中改 edit)。"""
    result = {"issue_id": issue_id, "sent": False, "dry_run": dry_run}
    if not issue_id or dry_run:
        return result

    # §SPEC-009: 同 marker 已有报告 → 更新该条, 不重复追加 (原每轮 add 累积)
    prior = find_marker_comment(issue_id, processing_log)
    if prior and prior.get("id") and isinstance(prior.get("revision"), int):
        cmd = (f"multica issue comment update {prior['id']} --content-stdin "
               f"--expected-revision {prior['revision']}")
        ok, out = multica_stdin_cmd(cmd, content, timeout=15)
        result["sent"] = ok
        result["updated"] = True
        result["comment_id"] = prior["id"]
        result["error"] = None if ok else out
        processing_log.append(
            f"report_comment_{'updated' if ok else 'update_failed'}: "
            f"issue={issue_id} comment={prior['id']}")
        return result

    base_cmd = f"multica issue comment add {issue_id} --content-stdin"
    ok, out = multica_stdin_cmd(base_cmd, content, timeout=15)
    result["sent"] = ok
    result["error"] = None if ok else out
    processing_log.append(
        f"report_comment_{'sent' if ok else 'failed'}: issue={issue_id}"
    )
    return result


def _issue_link(issue_id: str, identifier: str) -> str:
    """Build issue mention link like [SEE-123](mention://issue/<uuid>)."""
    if not issue_id:
        return "—"
    display = identifier if identifier else issue_id[:8]
    return f"[{display}](mention://issue/{issue_id})"
