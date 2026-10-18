#!/usr/bin/env python3
"""Multica version release inspection script for Autopilot.

Fetches GitHub releases for multica-ai/multica, compares against the
locally installed version, and generates a structured changelog report.

Can be run directly on Windows without bash:
    python autopilots/version_check.py [--dry-run] [--no-dry-run] [--verbose]
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error

# Add autopilots/ (repo-relative) to path for module imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from multica_helpers import PidFileLock, WorkspaceMutex, multica_stdin_cmd

# --- Constants ---

GITHUB_OWNER = "multica-ai"
GITHUB_REPO = "multica"
GITHUB_API_BASE = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}"

ENCODING = "utf-8"
ERRORS = "replace"
TIMEOUT = 30
HTTP_TIMEOUT = 30

# --- Argument parsing ---


def parse_args():
    parser = argparse.ArgumentParser(
        description="Multica version release inspection script for Autopilot"
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
        "--self-agent-id", default="a5c250e8-7257-466e-b45a-03f995c7206c",
        help="Self agent ID (default: %(default)s)"
    )
    parser.add_argument(
        "--kill-switch", default="false",
        help="Kill switch: true/false (default: %(default)s)"
    )
    parser.add_argument(
        "--pid-file",
        default=os.path.join(tempfile.gettempdir(), "version_check.pid"),
        help="PID file path (default: %(default)s)"
    )
    parser.add_argument(
        "--lock-timeout", default="300", type=int,
        help="Lock timeout in seconds (default: %(default)s)"
    )
    parser.add_argument(
        "--issue-id", default="",
        help="Issue ID to post the report comment on (default: none)"
    )
    parser.add_argument(
        "--output-json", action="store_true",
        help="Output raw JSON result to stdout (default: pretty markdown summary)"
    )
    parser.add_argument(
        "--max-releases", default=20, type=int,
        help="Maximum releases to fetch from GitHub (default: %(default)s)"
    )
    return parser.parse_args()


# --- Version parsing ---


def parse_current_version():
    """Parse the current multica version from `multica version` output."""
    try:
        r = subprocess.run(
            ["multica", "version"],
            shell=False, capture_output=True, text=True,
            encoding=ENCODING, errors=ERRORS, timeout=TIMEOUT,
        )
        if r.returncode != 0:
            return None, r.stderr.strip() if r.stderr else f"exit {r.returncode}"
        stdout = r.stdout.strip()
        # Expected: "multica 0.3.8 (commit: e351f898, built: 2026-05-25T12:30:29Z)"
        m = re.search(r"multica\s+(\d+\.\d+\.\d+)", stdout)
        if m:
            return m.group(1), stdout
        return None, f"unable to parse version from: {stdout}"
    except Exception as e:
        return None, str(e)


def semver_to_tuple(version_str):
    """Convert 'x.y.z' to (x, y, z) tuple for comparison."""
    try:
        parts = version_str.lstrip("v").split(".")
        return tuple(int(p) for p in parts[:3])
    except (ValueError, AttributeError):
        return (0, 0, 0)


# --- GitHub API ---


def http_get_json(url, timeout=HTTP_TIMEOUT):
    """Fetch JSON from a URL. Returns (success, data_or_error)."""
    try:
        req = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": "multica-autopilot-version-check",
            },
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return True, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:500]
        return False, f"HTTP {e.code}: {body}"
    except urllib.error.URLError as e:
        return False, f"URL error: {e.reason}"
    except json.JSONDecodeError as e:
        return False, f"JSON decode error: {e}"
    except Exception as e:
        return False, str(e)


def fetch_releases(per_page=20):
    """Fetch releases from GitHub API."""
    url = f"{GITHUB_API_BASE}/releases?per_page={per_page}"
    return http_get_json(url)


def fetch_release(tag):
    """Fetch a specific release by tag."""
    url = f"{GITHUB_API_BASE}/releases/tags/{tag}"
    return http_get_json(url)


# --- Changelog parsing ---


def parse_changelog_entries(body):
    """Parse changelog body into individual entries.

    Returns list of dicts with keys: commit_hash, ticket, type, description.
    """
    entries = []
    if not body:
        return entries

    # Match lines like:
    # * 5aa4fb7 MUL-2760: feat(i18n): add Korean locale support (#3369)
    # * fa076d3 MUL-2778 feat(agent): wire mcp_config through OpenClaw runtime (#3450)
    pattern = re.compile(
        r"^\*\s+([0-9a-fA-F]+)\s+"           # commit hash
        r"(?:([A-Z]+-\d+):?\s+)?"           # optional ticket
        r"(?:([a-z]+)\(([^)]+)\):\s+)?"    # optional type(scope):
        r"(.+?)"                             # description
        r"(?:\s*\(#\d+\))?\s*$",           # optional PR ref
        re.MULTILINE,
    )

    for m in pattern.finditer(body):
        entries.append({
            "commit_hash": m.group(1)[:7],
            "ticket": m.group(2) or "",
            "change_type": m.group(3) or "",
            "scope": m.group(4) or "",
            "description": m.group(5).strip(),
            "raw": m.group(0).strip(),
        })

    # Fallback: if no structured entries found, split by bullet points
    if not entries:
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("* ") or line.startswith("- "):
                desc = line[2:].strip()
                entries.append({
                    "commit_hash": "",
                    "ticket": "",
                    "change_type": "",
                    "scope": "",
                    "description": desc,
                    "raw": line,
                })

    return entries


def classify_entry(entry):
    """Classify entry into category based on change type."""
    ctype = entry.get("change_type", "").lower()
    if ctype in ("feat", "feature"):
        return "feature"
    if ctype in ("fix", "bugfix"):
        return "fix"
    if ctype in ("chore", "deps"):
        return "chore"
    if ctype in ("docs", "doc"):
        return "docs"
    if ctype in ("perf", "performance"):
        return "performance"
    if ctype in ("refactor", "test", "ci"):
        return ctype
    return "other"


def analyze_version(release, processing_log):
    """Analyze a single release and return structured data."""
    tag = release.get("tag_name", "")
    body = release.get("body", "")
    published = release.get("published_at", "")
    name = release.get("name", "")

    entries = parse_changelog_entries(body)

    # Categorize by change type
    categories = {}
    for entry in entries:
        cat = classify_entry(entry)
        categories.setdefault(cat, []).append(entry)

    processing_log.append(
        f"analyzed {tag}: entries={len(entries)}"
    )

    return {
        "tag": tag,
        "name": name,
        "published_at": published,
        "entry_count": len(entries),
        "entries": entries,
        "categories": categories,
    }


# --- Report generation ---

CATEGORY_LABELS = {
    "feature": "新功能",
    "fix": "修复",
    "performance": "性能",
    "refactor": "重构",
    "chore": "杂项",
    "docs": "文档",
    "test": "测试",
    "ci": "CI",
    "other": "其他",
}

# Display order for categories
CATEGORY_ORDER = ("feature", "fix", "performance", "refactor", "chore", "docs", "test", "ci", "other")


def generate_markdown_report(current_version, newer_versions, processing_log):
    """Generate a markdown report string."""
    lines = []
    lines.append("## Multica 版本更新分析报告")
    lines.append("")
    lines.append(f"- **当前运行版本**: `{current_version}`")
    lines.append(f"- **检测时间**: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}")
    lines.append(f"- **检测到的更新版本数**: {len(newer_versions)}")
    lines.append("")

    if not newer_versions:
        lines.append("当前已是最新版本，无需升级。")
        return "\n".join(lines)

    total_entries = sum(v["entry_count"] for v in newer_versions)

    # --- Part 1: Version summary by change type ---
    lines.append("---")
    lines.append("## 分版本更新摘要")
    lines.append("")

    for ver in newer_versions:
        tag = ver["tag"]
        published = ver["published_at"][:10] if ver["published_at"] else "unknown"
        categories = ver.get("categories", {})

        lines.append(f"### {tag} ({published})")
        lines.append("")

        if categories:
            for cat in CATEGORY_ORDER:
                if cat in categories:
                    label = CATEGORY_LABELS.get(cat, cat)
                    lines.append(f"**{label}:**")
                    for e in categories[cat]:
                        scope = f"`{e['scope']}` " if e.get("scope") else ""
                        ticket = f"[{e['ticket']}] " if e.get("ticket") else ""
                        lines.append(f"- {ticket}{scope}{e['description']}")
                    lines.append("")
        else:
            lines.append("_无结构化更新记录。_")
            lines.append("")

    # --- Part 2: Full changelog ---
    lines.append("---")
    lines.append("## 完整更新历史")
    lines.append("")

    for ver in newer_versions:
        tag = ver["tag"]
        published = ver["published_at"][:10] if ver["published_at"] else "unknown"
        entries = ver["entries"]
        lines.append(f"### {tag} ({published})")
        lines.append("")
        if entries:
            for e in entries:
                scope = f"`{e['scope']}` " if e.get("scope") else ""
                ticket = f"[{e['ticket']}] " if e.get("ticket") else ""
                ctype = f"`{e['change_type']}` " if e.get("change_type") else ""
                lines.append(f"- {ctype}{ticket}{scope}{e['description']}")
        else:
            lines.append("_无结构化更新记录。_")
        lines.append("")

    lines.append("---")
    lines.append("")
    lines.append(
        "*本报告由 Autopilot `version_check` 自动生成。*"
    )

    return "\n".join(lines)


# --- Issue comment posting ---


def post_report_comment(issue_id, content, dry_run=True):
    """Post the report as a comment on the specified issue."""
    if dry_run:
        return {
            "posted": False,
            "reason": "dry_run",
            "issue_id": issue_id,
        }

    if not issue_id:
        return {
            "posted": False,
            "reason": "no_issue_id",
        }

    success, output = multica_stdin_cmd(
        ["multica", "issue", "comment", "add", issue_id, "--content-stdin"],
        content,
        timeout=TIMEOUT,
    )
    if success:
        return {
            "posted": True,
            "issue_id": issue_id,
            "output": output,
        }
    else:
        return {
            "posted": False,
            "reason": "cli_error",
            "error": output,
        }


# --- Main ---


def main():
    processing_log = []

    # Phase 1: Get current version
    current_version, version_output = parse_current_version()
    if current_version is None:
        processing_log.append(f"phase1_version_parse_failed: {version_output}")
        result = {
            "error": f"Failed to parse current version: {version_output}",
            "processing_log": processing_log,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return

    processing_log.append(f"phase1_current_version: {current_version}")
    current_tuple = semver_to_tuple(current_version)

    # Phase 2: Fetch releases from GitHub
    success, releases_data = fetch_releases(args.max_releases)
    if not success:
        processing_log.append(f"phase2_fetch_failed: {releases_data}")
        result = {
            "error": f"Failed to fetch releases: {releases_data}",
            "current_version": current_version,
            "processing_log": processing_log,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return

    releases = releases_data if isinstance(releases_data, list) else []
    processing_log.append(f"phase2_releases_fetched: {len(releases)}")

    # Phase 3: Filter newer versions and analyze
    newer_versions = []
    for rel in releases:
        tag = rel.get("tag_name", "")
        ver_tuple = semver_to_tuple(tag)
        if ver_tuple > current_tuple:
            analyzed = analyze_version(rel, processing_log)
            newer_versions.append(analyzed)

    # Sort by version ascending (oldest first)
    newer_versions.sort(key=lambda v: semver_to_tuple(v["tag"]))
    processing_log.append(f"phase3_newer_versions: {len(newer_versions)}")

    # Phase 4: Generate report
    markdown_report = generate_markdown_report(current_version, newer_versions, processing_log)

    # Phase 5: Post comment (if not dry-run)
    comment_result = post_report_comment(args.issue_id, markdown_report, dry_run=args.dry_run)
    if comment_result.get("posted"):
        processing_log.append(f"phase5_comment_posted: issue={args.issue_id}")
    else:
        processing_log.append(
            f"phase5_comment_skipped: reason={comment_result.get('reason')} issue={args.issue_id}"
        )

    # Build structured result
    summary = {
        "current_version": current_version,
        "newer_versions_count": len(newer_versions),
        "newer_version_tags": [v["tag"] for v in newer_versions],
        "dry_run": args.dry_run,
        "kill_switch": args.kill_switch.lower() == "true",
        "issue_id": args.issue_id,
        "comment_posted": comment_result.get("posted", False),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    result = {
        "summary": summary,
        "versions": newer_versions,
        "processing_log": processing_log if args.verbose else [],
        "markdown_report": markdown_report,
        "comment_result": comment_result,
    }

    if args.output_json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(markdown_report)


if __name__ == "__main__":
    args = parse_args()

    # Acquire PID file lock
    lock = PidFileLock(args.pid_file)
    if not lock.acquire():
        sys.exit(1)

    # SEE-956 H10+L3: workspace-level advisory mutex to serialize autopilots.
    workspace_mutex = WorkspaceMutex(label="version_check")
    workspace_mutex.acquire()

    # Signal cleanup
    def _cleanup(sig=None, frame=None):
        workspace_mutex.release()
        lock.release()
        if sig is not None:
            sys.exit(128 + sig)

    signal.signal(signal.SIGINT, _cleanup)
    if sys.platform != "win32":
        signal.signal(signal.SIGTERM, _cleanup)

    try:
        main()
    finally:
        workspace_mutex.release()
        lock.release()
