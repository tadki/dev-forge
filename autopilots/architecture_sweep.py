#!/usr/bin/env python3
"""Architecture Sweep — daily static architecture patrol for KingOfLikes-Godot.

Read-only static inspection. Never writes to shared branches, worktrees, or
project files. All state lives under ~/.multica/arch-patrol/.

Implements SEE-1180 Thread 1 plan-debate converged dimensions:
  L0 (daily): deprecated bridges, SEE-* comments, gdlint increment, >800-line
              files, >50-line functions, autoload reference matrix, GameState
              mirror-field direct assignment, blacklist function calls,
              redline hash (addons/godot_mcp/).
  L1 (weekly): GUT silent-skip detection, test-to-code ratio, dependency
              matrix trend, compat-bridge trend.
  Anti-fatigue: baseline-diff, dedup key (file:line + rule_id + severity),
              heartbeat, rolling-ledger draft (no auto-@).

Exit codes: 0=success, 1=error, 2=partial failure (some checks failed).
"""

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

# Reuse shared lock/CLI patterns from multica_helpers (same directory).
# SEE-1440: Kill Switch 默认值统一由 kill_switch 单源给出（paused 文件 + env）。
from kill_switch import kill_switch_default
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from multica_helpers import (
    PidFileLock,
    WorkspaceMutex,
    log_error as _log_error_orig,
    multica_cli,
)
# SEE-1470 Track A: guard_pending 日检（ledger 2026-09 SPEC-001）生产接线——
# 扫描口径单源于同目录 guard_pending.py，sweep 只消费其 scan()。
from guard_pending import scan as scan_guard_pendings

# ---------------------------------------------------------------------------
# Exit-code discipline (SEE-1109): any phase failure bumps _phase_error_count;
# top-level exits non-zero so the scheduler never sees a silent success.
# ---------------------------------------------------------------------------
_phase_error_count = 0


def log_error(msg: str) -> None:
    global _phase_error_count
    _phase_error_count += 1
    _log_error_orig(f"[arch-sweep] {msg}")


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MULTICA_HOME = os.path.expanduser(os.environ.get("MULTICA_HOME", "~/.multica"))
ARCH_PATROL_HOME = os.path.join(MULTICA_HOME, "arch-patrol")
BASELINE_FILE = os.path.join(ARCH_PATROL_HOME, "baseline.jsonl")
HEARTBEAT_FILE = os.path.join(ARCH_PATROL_HOME, "heartbeat.jsonl")
REDLINE_MANIFEST = os.path.join(ARCH_PATROL_HOME, "redline.manifest")
# Sidecar recording the addons/godot_mcp gitlink pointer at manifest
# generation time (SEE-1289/SEE-1332). Keys: {"pointer": <sha>, "generated_at": <iso>}.
REDLINE_POINTER_FILE = os.path.join(ARCH_PATROL_HOME, "redline.pointer")
REPORT_FILE = os.path.join(ARCH_PATROL_HOME, "last_report.json")

# Severity levels (higher = more urgent).
SEVERITY_INFO = "info"
SEVERITY_WARN = "warn"
SEVERITY_ERROR = "error"
SEVERITY_CRITICAL = "critical"

# Dedup key format: file:line + rule_id + severity
DEDUP_KEY_FMT = "{file}:{line}:{rule_id}:{severity}"

# Blacklist function calls that should never appear in business .gd code.
BLACKLIST_FUNCTIONS = [
    "OS.execute",
    "OS.shell_open",
    "OS.kill",
    "get_tree().quit",
    "SceneTree.quit",
]

# Path-level exemptions from BLACKLIST_FUNCTION checks (exact repo-relative
# paths, same skip mechanism as the addons/、tests/ prefixes below).
# scenes/ui/title_screen/title_screen.gd: the title-screen "退出游戏" button
# (SEE-1228) is the only legitimate user-initiated quit entry point —
# get_tree().quit there is by design (SEE-1395, Leader ruling).
BLACKLIST_EXEMPT_PATHS = {
    "scenes/ui/title_screen/title_screen.gd",
}

# GameState fields that must go through their setters (emit state_changed).
# Direct assignment bypasses the signal and is a red-line violation.
GAMESTATE_MIRROR_FIELDS = [
    "player_level",
    "gold",
    "total_likes",
    "total_clicks",
]

# Files/dirs excluded from all checks (matched as path-segment prefixes).
EXCLUDED_DIRS = {
    ".godot",
    ".git",
    "tests/reports",
    "__pycache__",
    ".venv",
    "venv",
    "env",
}

# Path-prefix exclusions (applied against the repo-relative path).
# addons/gut is a vendored test framework — its style is not ours to enforce.
# addons/godot_mcp is the vendored redline area (hash-checked separately).
EXCLUDED_PREFIXES = (
    "addons/gut/",
    "addons/godot_mcp/",
)

# File size thresholds (coding-style red lines).
MAX_FILE_LINES = 800
MAX_FUNC_LINES = 50

# SEE-1430c O1：红线常量可经 --config 覆盖（默认 configs/kol.json）。缺省/读取
# 失败时保持上方硬编码值 = 行为完全兼容。检测语义不变，仅常量来源变化。
DEFAULT_CONFIG_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "configs", "kol.json"
)


def apply_config(path: str) -> None:
    """Override the red-line constants from a target config (best-effort).

    Only two surfaces are wired (per SEE-1430c O1): `max_file_lines` and
    `forbidden_identifiers`. Any read/parse failure leaves the built-in
    defaults untouched (behaviour-compatible).
    """
    global MAX_FILE_LINES, GAMESTATE_MIRROR_FIELDS
    try:
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return
    if not isinstance(cfg, dict):
        return
    limit = cfg.get("max_file_lines")
    if isinstance(limit, int) and limit > 0:
        MAX_FILE_LINES = limit
    forbidden = cfg.get("forbidden_identifiers")
    if isinstance(forbidden, list) and all(isinstance(x, str) for x in forbidden):
        GAMESTATE_MIRROR_FIELDS = list(forbidden)


# S1 (SEE-1226): cross-slot junit aggregation freshness window, aligned with
# the weekly L1 cadence.
JUNIT_MAX_AGE_DAYS = 7

# Tolerance applied to the expected/actual comparison. Expected counts
# `func test_*` declarations while actual counts executed junit <testcase>
# entries — the same unit, but a sweep whose junit predates a just-merged
# test PR would false-positive on `actual < expected`. 5% absorbs that skew
# while still catching a partial run that executes far fewer tests.
GUT_PARTIAL_RUN_TOLERANCE = 0.95

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def _default_workspace_root() -> str:
    """Auto-detect the Multica workspace root (D8: no hardcoded machine path).

    Strategy, mirroring local_repo_check.find_bare_repo_path's multi-level
    fallback: a workspace root is a directory whose children look like
    ``<hash>/workdir/<repo>/`` slots. Walk up from CWD to the highest ancestor
    that contains at least one such slot, falling back to
    ``MULTICA_WORKSPACE_ROOT`` then ``~/.multica/workspaces``.
    """
    cwd = os.path.abspath(os.getcwd())
    best = ""
    current = cwd
    while current:
        try:
            has_slot = any(
                os.path.isdir(os.path.join(current, name, "workdir"))
                for name in os.listdir(current)
            )
        except OSError:
            has_slot = False
        if has_slot:
            best = current
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    if best:
        return best
    # Fallback 1: explicit env var pointing at the workspace root.
    env_root = os.environ.get("MULTICA_WORKSPACE_ROOT", "")
    if env_root and os.path.isdir(env_root):
        return env_root
    # Fallback 2: standard Multica workspace parent (matches local_repo_check).
    home_ws = os.path.expanduser("~/.multica/workspaces")
    if os.path.isdir(home_ws):
        return home_ws
    return cwd


def parse_args():
    parser = argparse.ArgumentParser(
        description="Architecture Sweep — static architecture patrol for KingOfLikes-Godot"
    )
    # D8: no hardcoded machine path. Default is derived from the current working
    # directory: walk up to the nearest directory containing worktree slots
    # (a directory holding <hash>/workdir/<repo>); fall back to MULTICA_WORKSPACE_ROOT.
    parser.add_argument(
        "--workspace-root",
        default=os.environ.get("MULTICA_WORKSPACE_ROOT") or _default_workspace_root(),
        help="Workspace root directory (auto-detected if omitted)",
    )
    parser.add_argument(
        "--current-hash",
        default="",
        help="Current worktree hash to skip (auto-detected if omitted)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview mode: run all checks, write nothing to baseline/heartbeat",
    )
    parser.add_argument(
        "--fast",
        action="store_true",
        help="Fast mode: run only L0 quick checks (skip gdlint, skip L1)",
    )
    parser.add_argument(
        "--l1",
        action="store_true",
        help="Force L1 weekly checks even if not scheduled",
    )
    parser.add_argument(
        "--execution-issue-id",
        default="",
        help="Execution issue ID for reporting",
    )
    parser.add_argument(
        "--kill-switch",
        default=kill_switch_default(),
        help="Kill switch: true/false. When true, suppress baseline/heartbeat "
             "writes (pure read-only output) (default: %(default)s)",
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("ARCH_SWEEP_CONFIG")
        or os.path.join(os.path.dirname(os.path.abspath(__file__)), "configs", "kol.json"),
        help="Patrol target config JSON (default: configs/kol.json next to the script). "
             "Missing/unreadable config falls back to the built-in defaults "
             "(behaviour-compatible).",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def run(cmd, fallback="", timeout=30):
    """Thin wrapper over multica_helpers.multica_cli (SEE-1224 #3).

    Keeps the legacy stdout/fallback signature while gaining unified
    exponential backoff for transient CLI timeouts.
    """
    ok, out = multica_cli(cmd, timeout=timeout)
    return out if ok else fallback


def run_ok(cmd, timeout=30):
    """Thin wrapper over multica_helpers.multica_cli returning (ok, stdout)."""
    return multica_cli(cmd, timeout=timeout)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def append_jsonl(path: str, record: dict) -> None:
    ensure_dir(os.path.dirname(path))
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def read_jsonl(path: str) -> list[dict]:
    if not os.path.isfile(path):
        return []
    records = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return records


def dedup_key(file: str, line: int, rule_id: str, severity: str) -> str:
    return DEDUP_KEY_FMT.format(file=file, line=line, rule_id=rule_id, severity=severity)


# ---------------------------------------------------------------------------
# Baseline / heartbeat / dedup state
# ---------------------------------------------------------------------------


def load_baseline() -> dict:
    """Merge baseline records: gdlint_warnings are unioned across all records
    so a warning seen once is never re-reported (D5: read full history, not
    just the last line). Scalar metrics take the latest value."""
    records = read_jsonl(BASELINE_FILE)
    if not records:
        return {}
    merged = {}
    gdlint_warnings = {}
    for rec in records:
        metrics = rec.get("metrics", {})
        for k, v in metrics.items():
            if k == "gdlint_warnings" and isinstance(v, dict):
                gdlint_warnings.update(v)
            else:
                merged[k] = v
    if gdlint_warnings:
        merged["gdlint_warnings"] = gdlint_warnings
    return merged


def load_known_findings() -> set[str]:
    """Return set of dedup keys already reported across ALL baseline records
    (D5: read the full history, not just the last line)."""
    records = read_jsonl(BASELINE_FILE)
    known = set()
    for rec in records:
        known.update(rec.get("findings", []))
    return known


def write_baseline(metrics: dict, findings: list[str], dry_run: bool) -> None:
    if dry_run:
        return
    record = {
        "ts": now_iso(),
        "metrics": metrics,
        "findings": findings,
    }
    append_jsonl(BASELINE_FILE, record)


def build_heartbeat_summary(total_findings: int, new_findings: int, redline_skipped: bool = False) -> str:
    """Compose the heartbeat summary line. A redline skip (SEE-1434) is always
    surfaced so a missing-coverage run is distinguishable from a clean run."""
    summary = f"findings={total_findings} new={new_findings}"
    if redline_skipped:
        summary += " redline=skipped_uninitialized"
    return summary


def write_heartbeat(status: str, summary: str, dry_run: bool) -> None:
    if dry_run:
        return
    record = {
        "ts": now_iso(),
        "status": status,
        "summary": summary,
    }
    append_jsonl(HEARTBEAT_FILE, record)


# ---------------------------------------------------------------------------
# Redline manifest (addons/godot_mcp/)
# ---------------------------------------------------------------------------


def compute_redline_manifest(repo_root: str) -> dict:
    """Compute SHA256 manifest for addons/godot_mcp/. Returns {relpath: sha256}.

    Excludes `.git` (SEE-1289 HIGH-1): the submodule checkout's gitdir pointer
    embeds the host worktree name, so hashing it makes the baseline
    non-portable across worktrees. `.git` is git plumbing, not addon content.
    """
    addon_dir = os.path.join(repo_root, "addons", "godot_mcp")
    manifest = {}
    if not os.path.isdir(addon_dir):
        return manifest
    for root, dirs, files in os.walk(addon_dir):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            if name == ".git":
                continue
            fp = os.path.join(root, name)
            rel = os.path.relpath(fp, repo_root)
            try:
                with open(fp, "rb") as f:
                    manifest[rel] = hashlib.sha256(f.read()).hexdigest()
            except OSError:
                manifest[rel] = "ERROR"
    return manifest


def load_redline_manifest() -> dict:
    """Load the stored redline manifest. Returns {relpath: sha256} or {}."""
    if not os.path.isfile(REDLINE_MANIFEST):
        return {}
    try:
        with open(REDLINE_MANIFEST, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError, OSError):
        return {}


def save_redline_manifest(manifest: dict, dry_run: bool) -> None:
    if dry_run:
        return
    ensure_dir(os.path.dirname(REDLINE_MANIFEST))
    with open(REDLINE_MANIFEST, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)


def _git_blob_sha(fp: str) -> str:
    """Git blob object sha1 of a working-tree file ("" when unreadable).

    The empty-string failure keeps unreadable files real violations: no blob
    sha ever equals "", so the fail-closed comparison never matches.
    """
    try:
        with open(fp, "rb") as f:
            data = f.read()
    except OSError:
        return ""
    return hashlib.sha1(b"blob %d\x00" % len(data) + data).hexdigest()


def _gitlink_pointer(repo_root: str) -> str:
    """Return the addons/godot_mcp gitlink SHA pinned by parent HEAD, or "".

    Reads the committed tree entry only — never touches the submodule
    worktree, honoring the vendored-addon red line.
    """
    try:
        out = subprocess.run(
            ["git", "-C", repo_root, "rev-parse", "HEAD:addons/godot_mcp"],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


def _submodule_materialized(repo_root: str) -> str:
    """Classify the addons/godot_mcp gitlink materialization state (SEE-1434).

    Returns "yes" (child worktree populated), "no" (registered gitlink whose
    disk directory is missing or holds no files — the plain `multica repo
    checkout` state), or "unknown" (detection itself failed). Only a
    git-positive "no" may skip the redline comparison; "unknown" fails closed
    so a broken detector can never silently drop redline coverage.
    """
    addon_dir = os.path.join(repo_root, "addons", "godot_mcp")
    try:
        out = subprocess.run(
            ["git", "-C", repo_root, "ls-files", "-s", "addons/godot_mcp"],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        registered = out.stdout.strip().startswith("160000")
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    if not registered:
        return "yes"  # not a submodule at all: nothing to skip
    if not os.path.isdir(addon_dir):
        return "no"
    try:
        has_content = any(os.scandir(addon_dir))
    except OSError:
        return "unknown"
    return "yes" if has_content else "no"


def _save_pointer(pointer: str, dry_run: bool) -> None:
    """Record the gitlink at manifest (re)generation time (audit bookkeeping).

    Write-only by design (SEE-1332 LOW fix): nothing in the sweep reads this
    back — the deterministic criterion sources the pinned commit from parent
    HEAD directly, so a missing or stale sidecar can never influence
    classification or reporting.
    """
    if dry_run or not pointer:
        return
    ensure_dir(os.path.dirname(REDLINE_POINTER_FILE))
    with open(REDLINE_POINTER_FILE, "w", encoding="utf-8") as f:
        json.dump(
            {"pointer": pointer, "generated_at": datetime.now(timezone.utc).isoformat()},
            f,
            indent=2,
            ensure_ascii=False,
        )


def _gitlink_blob_map(repo_root: str, pointer: str) -> dict:
    """Map {addon-relpath: git blob sha1} for the pinned fork commit.

    §SPEC-001 deterministic criterion source: a working file is a compliant
    gitlink-bump artifact iff its blob sha equals the entry recorded here.
    Any failure to resolve the pinned tree (no gitlink, git unavailable,
    pruned commit) yields {} and the caller fails closed — raw hits then all
    stay critical rather than being downgraded on guesswork.
    """
    if not pointer:
        return {}
    addon_dir = os.path.join(repo_root, "addons", "godot_mcp")
    try:
        r = subprocess.run(
            ["git", "-C", addon_dir, "ls-tree", "-r", "-z", pointer],
            capture_output=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    if r.returncode != 0:
        return {}
    # ls-tree runs inside the submodule, so paths are addon-relative; re-key
    # to repo-relative paths to match the manifest key space.
    prefix = "addons/godot_mcp/"
    blobs = {}
    for entry in r.stdout.split(b"\0"):
        if not entry:
            continue
        head, _sep, path = entry.partition(b"\t")
        parts = head.split()
        if len(parts) >= 3:
            blobs[prefix + path.decode("utf-8", "replace")] = parts[2].decode("ascii")
    return blobs


def _redline_critical(rule_id: str, rel: str, message: str) -> dict:
    return {
        "rule_id": rule_id,
        "severity": SEVERITY_CRITICAL,
        "file": rel,
        "line": 0,
        "message": message,
    }


def _classify_redline_hits(repo_root: str, stored: dict, current: dict, blob_map: dict) -> tuple:
    """Split raw manifest-vs-tree hits into (real violations, artifact count).

    Per-file deterministic criterion (SEE-1332 §SPEC-001): NEW/MODIFIED is an
    artifact iff the working file's blob sha equals the blob recorded in the
    fork commit pinned by parent HEAD; DELETED is an artifact iff that commit
    no longer ships the file (only provable when the tree was read at all —
    an empty blob_map fails closed, keeping every hit real).
    """
    real = []
    artifacts = 0
    for rel, sha in stored.items():
        if rel not in current:
            if not blob_map or rel in blob_map:
                real.append(
                    _redline_critical("REDLINE_DELETED", rel, f"Redline file deleted: {rel}")
                )
            else:
                artifacts += 1
        elif current[rel] != sha:
            if rel in blob_map and blob_map[rel] == _git_blob_sha(os.path.join(repo_root, rel)):
                artifacts += 1
            else:
                real.append(
                    _redline_critical("REDLINE_MODIFIED", rel, f"Redline file modified: {rel}")
                )
    for rel in current:
        if rel in stored:
            continue
        if rel in blob_map and blob_map[rel] == _git_blob_sha(os.path.join(repo_root, rel)):
            artifacts += 1
        else:
            real.append(_redline_critical("REDLINE_NEW", rel, f"Redline file added: {rel}"))
    return real, artifacts


def _reset_redline_baseline(pointer: str, current: dict, artifacts: int, dry_run: bool) -> dict:
    """Re-bless the working tree as baseline after a pure bump-artifact sweep.

    SEE-1289 family behavior: every raw hit was proven content-identical to
    the pinned fork commit, so the manifest converges to that state and the
    artifacts never re-report. Never called while real violations exist.
    The message names only the pinned gitlink (LOW fix: the sidecar is audit
    bookkeeping written on every reset, never an input to reporting — a
    missing or stale sidecar cannot change what this sweep says).
    """
    save_redline_manifest(current, dry_run)
    _save_pointer(pointer, dry_run)
    return {
        "rule_id": "REDLINE_BASELINE_RESET",
        "severity": SEVERITY_INFO,
        "file": "addons/godot_mcp/",
        "line": 0,
        "message": (
            "redline_baseline_reset: addons/godot_mcp"
            f" baseline re-blessed at gitlink {pointer[:12]}"
            f" ({artifacts} bump artifacts)."
        ),
    }


def _redline_skipped_uninitialized() -> dict:
    """Single explicit downgrade warning for an unmaterialized gitlink (SEE-1434).

    Warn (never critical): coverage is MISSING, not violated — the SEE-1433
    incident showed that comparing against an empty disk tree fabricates one
    critical per stored manifest entry.
    """
    return {
        "rule_id": "REDLINE_SKIPPED_UNINITIALIZED",
        "severity": SEVERITY_WARN,
        "file": "addons/godot_mcp/",
        "line": 0,
        "message": (
            "Redline check skipped: addons/godot_mcp gitlink is NOT materialized "
            "(run `git submodule update --init` to restore redline coverage). "
            "No REDLINE_* findings are trustworthy in this state."
        ),
    }


def check_redline(repo_root: str, dry_run: bool) -> list[dict]:
    """Verify addons/godot_mcp/ hashes against stored manifest. Returns findings.

    SEE-1434 guard: when the gitlink is registered but NOT materialized, the
    disk tree is empty and any comparison would fabricate one REDLINE_DELETED
    per stored entry — skip entirely with a single explicit downgrade warning
    instead, and never touch the stored manifest/pointer.

    SEE-1332: raw hits are classified against the gitlink pinned by parent
    HEAD; compliant bump artifacts (§SPEC-001) are not reported as critical.
    The manifest is re-blessed ONLY when every raw hit was an artifact, so a
    real violation can never be laundered into the baseline (§SPEC-002).
    """
    if _submodule_materialized(repo_root) == "no":
        # Skip is side-effect free: the stored manifest stays as-is so the
        # next materialized run resumes the comparison cleanly.
        return [_redline_skipped_uninitialized()]

    findings = []
    current = compute_redline_manifest(repo_root)
    stored = load_redline_manifest()

    if not stored:
        # First run: store the manifest and report info.
        save_redline_manifest(current, dry_run)
        _save_pointer(_gitlink_pointer(repo_root), dry_run)
        findings.append(
            {
                "rule_id": "REDLINE_INIT",
                "severity": SEVERITY_INFO,
                "file": "addons/godot_mcp/",
                "line": 0,
                "message": "Redline manifest initialized (first run).",
            }
        )
        return findings

    pointer = _gitlink_pointer(repo_root)
    blob_map = _gitlink_blob_map(repo_root, pointer)
    real, artifacts = _classify_redline_hits(repo_root, stored, current, blob_map)
    findings.extend(real)

    if artifacts and not real:
        findings.append(_reset_redline_baseline(pointer, current, artifacts, dry_run))
    return findings


# ---------------------------------------------------------------------------
# L0 checks — syntax-level daily snapshot
# ---------------------------------------------------------------------------


def _is_excluded(rel: str) -> bool:
    return any(rel.startswith(p) for p in EXCLUDED_PREFIXES)


def find_gd_files(repo_root: str, include_tests: bool = False) -> list[str]:
    """Return all .gd files under repo_root, excluding EXCLUDED_DIRS / EXCLUDED_PREFIXES."""
    gd_files = []
    for root, dirs, files in os.walk(repo_root):
        # Prune excluded dirs in-place.
        dirs[:] = [d for d in dirs if d not in EXCLUDED_DIRS]
        for name in files:
            if name.endswith(".gd"):
                rel = os.path.relpath(os.path.join(root, name), repo_root)
                rel_norm = rel.replace(os.sep, "/")
                if _is_excluded(rel_norm):
                    continue
                if not include_tests and rel_norm.startswith("tests/"):
                    continue
                gd_files.append(rel_norm)
    return sorted(gd_files)


def check_deprecated_bridges(repo_root: str, gd_files: list[str]) -> list[dict]:
    """Count @deprecated annotations (compatibility bridges)."""
    findings = []
    pattern = re.compile(r"@deprecated")
    for rel in gd_files:
        fp = os.path.join(repo_root, rel)
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as f:
                for i, line in enumerate(f, 1):
                    if pattern.search(line):
                        findings.append(
                            {
                                "rule_id": "DEPRECATED_BRIDGE",
                                "severity": SEVERITY_WARN,
                                "file": rel,
                                "line": i,
                                "message": f"@deprecated compatibility bridge found",
                            }
                        )
        except OSError:
            log_error(f"Cannot read {rel}")
    return findings


def check_see_comments(repo_root: str, gd_files: list[str]) -> list[dict]:
    """Count SEE-* leftover comments."""
    findings = []
    pattern = re.compile(r"\bSEE-\d+\b")
    for rel in gd_files:
        fp = os.path.join(repo_root, rel)
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as f:
                for i, line in enumerate(f, 1):
                    if pattern.search(line):
                        findings.append(
                            {
                                "rule_id": "SEE_COMMENT",
                                "severity": SEVERITY_INFO,
                                "file": rel,
                                "line": i,
                                "message": f"SEE-* comment leftover",
                            }
                        )
        except OSError:
            log_error(f"Cannot read {rel}")
    return findings


def check_file_length(repo_root: str, gd_files: list[str]) -> list[dict]:
    """Flag files exceeding MAX_FILE_LINES."""
    findings = []
    for rel in gd_files:
        fp = os.path.join(repo_root, rel)
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as f:
                count = sum(1 for _ in f)
            if count > MAX_FILE_LINES:
                findings.append(
                    {
                        "rule_id": "FILE_TOO_LONG",
                        "severity": SEVERITY_WARN,
                        "file": rel,
                        "line": 0,
                        "message": f"File has {count} lines (limit {MAX_FILE_LINES})",
                    }
                )
        except OSError:
            log_error(f"Cannot read {rel}")
    return findings


def check_function_length(repo_root: str, gd_files: list[str]) -> list[dict]:
    """Flag functions exceeding MAX_FUNC_LINES using lightweight heuristic.

    Heuristic: a function starts at a line matching `^func ` or `^static func `
    (D6) and ends at the next `^func `, `^class `, `^signal `, `^var `,
    `^const `, `^static `, `^@` (covers `@onready var` class-level decls), or
    EOF. Line count = end - start.
    """
    findings = []
    func_start = re.compile(r"^(?:static\s+)?func\s+(\w+)")
    block_end = re.compile(r"^(?:(?:static\s+)?func\s+\w+|class\s+\w+|signal\s+|var\s+|const\s+|static\s|@)")
    for rel in gd_files:
        fp = os.path.join(repo_root, rel)
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except OSError:
            log_error(f"Cannot read {rel}")
            continue

        func_name = None
        func_line = 0
        for i, line in enumerate(lines, 1):
            m = func_start.match(line)
            if m:
                if func_name is not None:
                    length = i - func_line
                    if length > MAX_FUNC_LINES:
                        findings.append(
                            {
                                "rule_id": "FUNC_TOO_LONG",
                                "severity": SEVERITY_WARN,
                                "file": rel,
                                "line": func_line,
                                "message": f"Function '{func_name}' has {length} lines (limit {MAX_FUNC_LINES})",
                            }
                        )
                func_name = m.group(1)
                func_line = i
            elif block_end.match(line) and func_name is not None:
                length = i - func_line
                if length > MAX_FUNC_LINES:
                    findings.append(
                        {
                            "rule_id": "FUNC_TOO_LONG",
                            "severity": SEVERITY_WARN,
                            "file": rel,
                            "line": func_line,
                            "message": f"Function '{func_name}' has {length} lines (limit {MAX_FUNC_LINES})",
                        }
                    )
                func_name = None

        # EOF guard.
        if func_name is not None:
            length = len(lines) - func_line + 1
            if length > MAX_FUNC_LINES:
                findings.append(
                    {
                        "rule_id": "FUNC_TOO_LONG",
                        "severity": SEVERITY_WARN,
                        "file": rel,
                        "line": func_line,
                        "message": f"Function '{func_name}' has {length} lines (limit {MAX_FUNC_LINES})",
                    }
                )
    return findings


def _parse_autoload_names(repo_root: str) -> list[str]:
    # Parse autoload names from project.godot.
    project_godot = os.path.join(repo_root, "project.godot")
    autoloads = []
    if os.path.isfile(project_godot):
        with open(project_godot, "r", encoding="utf-8") as f:
            in_autoload = False
            for line in f:
                line = line.strip()
                if line == "[autoload]":
                    in_autoload = True
                    continue
                if line.startswith("["):
                    in_autoload = False
                if in_autoload and "=" in line:
                    name = line.split("=")[0].strip()
                    autoloads.append(name)
    return autoloads


def _build_autoload_ref_map(repo_root: str, gd_files: list[str], autoloads: list[str]) -> dict:
    # For each file, list which autoloads it references.
    ref_map = {}
    for rel in gd_files:
        fp = os.path.join(repo_root, rel)
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
        except OSError:
            continue
        refs = [a for a in autoloads if re.search(rf"\b{re.escape(a)}\b", content)]
        if refs:
            ref_map[rel] = refs
    return ref_map


def check_autoload_references(repo_root: str, gd_files: list[str]) -> list[dict]:
    """Build autoload reference matrix: which autoloads reference which others."""
    autoloads = _parse_autoload_names(repo_root)
    ref_map = _build_autoload_ref_map(repo_root, gd_files, autoloads)

    # Report files that reference many autoloads (potential God Object).
    findings = []
    for rel, refs in ref_map.items():
        if len(refs) >= 5:
            findings.append(
                {
                    "rule_id": "AUTOLOAD_COUPLING",
                    "severity": SEVERITY_WARN,
                    "file": rel,
                    "line": 0,
                    "message": f"References {len(refs)} autoloads: {', '.join(refs[:5])}{'...' if len(refs) > 5 else ''}",
                }
            )

    # Store the full matrix as a metric (not a finding).
    return findings, ref_map


_GAMESTATE_FUNC_START = re.compile(r"^(?:static\s+)?func\s+(\w+)")
# Named `_sync_<field>_to_game_state` (D4: exempts only its own field) and
# the no-arg `_sync_to_game_state` variant (one sanctioned site syncing
# several mirror fields, conventionally marked `## direct-sync`).
_GAMESTATE_SYNC_FUNC = re.compile(r"^_sync_(?:(\w+)_)?to_game_state$")
_GAMESTATE_DIRECT_SYNC_MARKER = re.compile(r"^##\s*direct-sync\b")
_GAMESTATE_HANDLER_FUNC = re.compile(r"^_on_unique_\w+$")
_GAMESTATE_DISPATCH_FUNC = re.compile(r"^_apply_\w+_via_effect$")
_GAMESTATE_REGISTER_CALL = re.compile(
    r"UniqueEffectRegistry\.register\([^)]*,\s*(?:self\.)?(\w+)\s*\)"
)


def _gamestate_sanctioned(field: str, current_func: str, sync_field,
                          registered_handlers: set) -> bool:
    # Sanctioned sync writer: a named `_sync_<field>_to_game_state`
    # exempts only ITS field (D4 — touching any other mirror field
    # is still a violation); the no-arg `_sync_to_game_state`
    # variant ("*") is the single sync site for several fields.
    if sync_field == field or sync_field == "*":
        return True
    # UNIQUE effect handler write site: the registry-dispatched
    # endpoint for its field (SEE-1226 exemption model).
    if _GAMESTATE_HANDLER_FUNC.match(current_func):
        return True
    if current_func in registered_handlers:
        return True
    # apply_effect_with_value dispatch wrapper / its fallback
    # branch: routes the delta to the UNIQUE handler, or credits
    # directly when autoloads are absent (isolated tests).
    if _GAMESTATE_DISPATCH_FUNC.match(current_func):
        return True
    return False


def _gamestate_violations_in_file(repo_root: str, rel: str, field: str, pattern) -> list[dict]:
    fp = os.path.join(repo_root, rel)
    try:
        with open(fp, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        log_error(f"Cannot read {rel}")
        return []
    findings = []
    current_func = ""
    sync_field = None
    registered_handlers = set()
    for i, line in enumerate(lines, 1):
        m = _GAMESTATE_FUNC_START.match(line)
        if m:
            current_func = m.group(1)
            sm = _GAMESTATE_SYNC_FUNC.match(current_func)
            # A no-arg `_sync_to_game_state` syncs several mirror
            # fields from one place — still a single sanctioned sync
            # site (conventionally marked `## direct-sync`), so it
            # exempts every mirror-field write inside it.
            sync_field = (sm.group(1) or "*") if sm else None
        elif _GAMESTATE_DIRECT_SYNC_MARKER.match(line):
            # Docstring marker for the no-arg sync channel; the func
            # line follows within the comment block, so the marker
            # pre-arms the same exemption even if the detector's func
            # tracking ever misses the declaration shape.
            sync_field = "*"
        hm = _GAMESTATE_REGISTER_CALL.search(line)
        if hm:
            registered_handlers.add(hm.group(1))
        if not pattern.search(line):
            continue
        if _gamestate_sanctioned(field, current_func, sync_field, registered_handlers):
            continue
        findings.append(
            {
                "rule_id": "GAMESTATE_MIRROR_DIRECT",
                "severity": SEVERITY_ERROR,
                "file": rel,
                "line": i,
                "message": f"Direct assignment to GameState.{field} bypasses state_changed signal (in func '{current_func}')",
            }
        )
    return findings


def check_gamestate_mirror(repo_root: str, gd_files: list[str]) -> list[dict]:
    """Flag direct assignment to GameState mirror fields (bypasses state_changed).

    Two sanctioned writer classes are exempt:
      - Sync functions named `_sync_<field>_to_game_state` — but ONLY for the
        mirror field named in the function (D4). Writing a DIFFERENT mirror
        field inside a sync function is still a violation, since the bypass
        exists regardless of which function does it. The no-arg variant
        `_sync_to_game_state` (several mirror fields synced from one site) is
        also sanctioned: it is still a single sync writer by construction.
      - UNIQUE effect handlers (SEE-1226): an effect pipeline handler IS the
        sanctioned endpoint write for its field — `UniqueEffectRegistry
        .register(<id>, self._on_unique_x)` funnels every delta through the
        handler, so `_on_unique_*` is a single-writer site by construction.
        The `apply_effect_with_value` dispatch wrapper and its autoload-absent
        fallback (the `EconomyManager._apply_likes_delta_via_effect` shape)
        carry the same single-writer invariant: they route to the handler, or
        in isolated-test mode credit the same singleton-internal path.
    """
    findings = []
    for field in GAMESTATE_MIRROR_FIELDS:
        # Match `GameState.field =`, `+=`, `-=`, `*=`, `/=` — but NOT `==`.
        pattern = re.compile(rf"GameState\.{field}\s*(\+|-|\*|/)?=[^=]")
        for rel in gd_files:
            findings.extend(_gamestate_violations_in_file(repo_root, rel, field, pattern))
    return findings


def check_blacklist_functions(repo_root: str, gd_files: list[str]) -> list[dict]:
    """Flag calls to blacklisted functions in business code.

    D3: ignore matches inside comments (lines whose `#` precedes the match) and
    inside string literals (single/double quotes on the same line) so a mention
    in prose or a string does not count as a real call.
    """
    findings = []
    comment_pat = re.compile(r"#")
    string_pat = re.compile(r"[\"']")
    for func in BLACKLIST_FUNCTIONS:
        pattern = re.compile(rf"\b{re.escape(func)}\b")
        for rel in gd_files:
            # Skip addons and tests for blacklist checks (legitimate use),
            # plus path-level exemptions (see BLACKLIST_EXEMPT_PATHS).
            if (
                rel.startswith("addons/")
                or rel.startswith("tests/")
                or rel in BLACKLIST_EXEMPT_PATHS
            ):
                continue
            fp = os.path.join(repo_root, rel)
            try:
                with open(fp, "r", encoding="utf-8", errors="replace") as f:
                    for i, line in enumerate(f, 1):
                        m = pattern.search(line)
                        if not m:
                            continue
                        # Skip if the match sits after a `#` (comment).
                        comment_m = comment_pat.search(line)
                        if comment_m is not None and comment_m.start() < m.start():
                            continue
                        # Skip if the match sits inside a string literal.
                        # Count quotes before the match; an odd count means the
                        # token is inside a `"..."`/`'...'` literal.
                        if len(string_pat.findall(line[: m.start()])) % 2 == 1:
                            continue
                        findings.append(
                            {
                                "rule_id": "BLACKLIST_FUNCTION",
                                "severity": SEVERITY_ERROR,
                                "file": rel,
                                "line": i,
                                "message": f"Blacklisted function call: {func}",
                            }
                        )
            except OSError:
                log_error(f"Cannot read {rel}")
    return findings


def check_guard_pending(repo_root: str) -> list[dict]:
    """Guard-pending 日检（SEE-1470 Track A，ledger 2026-09 SPEC-001 口径）。

    扫描 repo_root/tests/ 下未带 Track-D 标识的 pending(...) 站点（分类规则
    单源于 guard_pending.py）。扫描面缺失（无 tests/）按零站点处理——目标仓
    无测试树不是违规；文件不可读由底层显式报错，不让整个 sweep 静默转绿。
    """
    try:
        result = scan_guard_pendings(Path(repo_root))
    except RuntimeError as exc:
        log_error(str(exc))
        return []
    findings = []
    for rel, hits in result["by_file"].items():
        for line, snippet in hits:
            findings.append(
                {
                    "rule_id": "GUARD_PENDING",
                    "severity": SEVERITY_ERROR,
                    "file": rel,
                    "line": line,
                    "message": f"Guard pending (silent-skip fallback): {snippet}",
                }
            )
    return findings


def check_gdlint_increment(repo_root: str, gd_files: list[str], dry_run: bool) -> list[dict]:
    """Run gdlint and report new warnings relative to baseline.

    D1: gdlint 4.x has no --config flag — it auto-discovers gdlintrc/.gdlintrc
    by walking up from the process CWD, so we run it with CWD=repo_root.
    gdlint exits 0 when no problems are found and 1 when problems exist
    (SEE-1109: a non-zero rc is the real warning signal and must be checked
    explicitly rather than ignored). Warnings are parsed from stderr in the
    `path:line: Error: message (rule)` format and diffed against the baseline.
    dry_run only suppresses baseline writes (handled by the caller) — the
    check itself always runs.
    """
    findings = []

    # Build file list for gdlint.
    file_args = [os.path.join(repo_root, f) for f in gd_files]
    if not file_args:
        return findings

    try:
        cmd = ["gdlint"] + file_args
        r = subprocess.run(
            cmd,
            shell=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
            cwd=repo_root,
        )
        stdout = r.stdout or ""
        stderr = r.stderr or ""
    except FileNotFoundError:
        log_error("gdlint not found; skipping gdlint increment check")
        return findings
    except subprocess.TimeoutExpired:
        log_error("gdlint timed out")
        return findings

    # D1: explicit rc handling. rc==1 means "problems found" (not an error);
    # any other unexpected non-zero rc (e.g. a gdlint crash) is a phase error
    # so the scheduler never sees a silent success (SEE-1109).
    if r.returncode not in (0, 1):
        log_error(f"gdlint exited with unexpected rc={r.returncode}")
        return findings

    # Parse gdlint stderr: "path:line: Error: message (rule-name)"
    current_warnings = {}
    for line in stderr.splitlines():
        m = re.match(r"(.+?):(\d+):\s*(.+)", line)
        if m:
            path, lineno, msg = m.groups()
            rel = os.path.relpath(path, repo_root).replace(os.sep, "/")
            key = f"{rel}:{lineno}"
            current_warnings[key] = msg.strip()

    # Load previous gdlint warnings from baseline (full history union).
    baseline = load_baseline()
    prev_warnings = baseline.get("gdlint_warnings", {})

    # New warnings = in current but not in previous.
    new_warnings = {
        k: v for k, v in current_warnings.items() if k not in prev_warnings
    }

    for key, msg in new_warnings.items():
        rel, lineno = key.rsplit(":", 1)
        findings.append(
            {
                "rule_id": "GDLINT_NEW",
                "severity": SEVERITY_WARN,
                "file": rel,
                "line": int(lineno),
                "message": f"gdlint: {msg}",
            }
        )

    # Store current warnings for next run's diff.
    # (Written into baseline metrics below.)
    return findings, current_warnings


# ---------------------------------------------------------------------------
# L1 checks — weekly static depth
# ---------------------------------------------------------------------------


def _gutconfig_dirs(gutconfig: dict) -> list[str]:
    """Normalize .gutconfig.json `dirs` to repo-relative paths (no res://, no trailing slash)."""
    out = []
    for d in gutconfig.get("dirs", []):
        rel = d.replace("res://", "").strip("/")
        if rel:
            out.append(rel)
    return out


def _count_expected_test_funcs_by_dir(repo_root: str, gutconfig: dict) -> dict[str, int]:
    """Count `func test_*` declarations grouped by configured test dir (D1).

    Same unit as `_count_expected_test_funcs` (test functions, matching junit
    `<testcase>` entries), but per-directory so a whole-dir skip cannot hide
    behind a passing global total. Directories absent on disk are reported
    with an expected count of 0 so the caller can still flag them if the
    junit side shows executions attributed there (or vice versa).
    """
    func_pat = re.compile(r"^\s*(?:static\s+)?func\s+(test_\w+)\s*\(")
    per_dir: dict[str, int] = {}
    for rel_dir in _gutconfig_dirs(gutconfig):
        abs_dir = os.path.join(repo_root, rel_dir)
        count = 0
        if os.path.isdir(abs_dir):
            for root, _dirs, files in os.walk(abs_dir):
                for name in files:
                    if not (name.startswith("test_") and name.endswith(".gd")):
                        continue
                    try:
                        with open(os.path.join(root, name), "r", encoding="utf-8") as f:
                            for line in f:
                                if func_pat.match(line):
                                    count += 1
                    except OSError:
                        log_error(f"Cannot read test file {name}")
        per_dir[rel_dir] = count
    return per_dir


def _count_expected_test_funcs(repo_root: str, gutconfig: dict) -> int:
    """Count `func test_*` declarations across the configured test dirs.

    Unit-unified with the junit `<testcase>` count (S1附带项a, SEE-1226): the
    previous expected metric counted test FILES while actual counted
    testcases — a cross-unit comparison that false-positives whenever a
    partial run's testcase count dips below the file count. Counting test
    functions on the static side puts both numbers on the same scale.
    """
    return sum(_count_expected_test_funcs_by_dir(repo_root, gutconfig).values())


def _attribute_testcases_by_dir(content: str, dirs: list[str]) -> dict[str, int]:
    """Attribute junit <testcase> entries to configured dirs via classname path prefix.

    GUT emits `classname="tests/<subdir>/test_x.gd"` on each testcase, so a
    longest-prefix match against the normalized dir list assigns each case to
    its owning configured directory. Testcases whose classname matches no
    configured dir are returned under the "" key (unattributed) so the caller
    can count them without letting them mask a per-dir shortfall.
    """
    per_dir: dict[str, int] = {d: 0 for d in dirs}
    unattributed = 0
    for m in re.finditer(r'<testcase\b[^>]*\bclassname="([^"]*)"', content):
        classname = m.group(1).strip("/")
        owner = ""
        for d in dirs:
            if classname == d or classname.startswith(d + "/"):
                if len(d) > len(owner):
                    owner = d
        if owner:
            per_dir[owner] += 1
        else:
            unattributed += 1
    per_dir[""] = unattributed
    return per_dir


def _junit_candidates(repo_root: str, gutconfig: dict) -> list[str]:
    """Resolve junit report candidates: explicit path, then glob stem.

    D2: honour junit_xml_file; when junit_xml_timestamp is set the file is
    junit_report_<ts>.xml, so glob the stem for timestamped variants.
    """
    junit_cfg = gutconfig.get("junit_xml_file", "res://tests/reports/junit_report.xml")
    junit_rel = junit_cfg.replace("res://", "")
    junit_base = os.path.join(repo_root, junit_rel)
    junit_timestamped = bool(gutconfig.get("junit_xml_timestamp", False))

    candidates = [junit_base]
    if junit_timestamped and junit_base.endswith(".xml"):
        stem = junit_base[: -len(".xml")]
        candidates.extend(glob.glob(stem + "_*.xml"))
    else:
        candidates.extend(glob.glob(junit_base + "_*.xml"))
    return candidates


def _newest_junit_across_slots(workspace_root: str, junit_rel: str, expected: int) -> tuple[str, int, float]:
    """Pick the best junit across sibling checkout slots (S1).

    The autopilot checks out a clean slot whose tests/reports/ is empty by
    construction (.gitignore drops junit products), so a local-only read can
    never see a real run. QA slots often run per-directory subsets, so the
    newest-mtime file is frequently a small probe (3 testcases) rather than
    the last full run. Rank candidates by "is this plausibly the most recent
    full run": prefer files whose testcase count is within the partial-run
    tolerance of `expected`, then break ties by newest mtime; fall back to
    newest mtime regardless of count when no near-full product exists.

    Returns (path, testcase_count, mtime_epoch) or ("", 0, 0.0).
    """
    reports_dir = os.path.dirname(junit_rel)
    near_full_best = ("", 0, 0.0)  # (path, count, mtime) with count >= expected*tolerance
    newest_best = ("", 0, 0.0)     # (path, count, mtime) regardless of count
    try:
        slot_names = os.listdir(workspace_root)
    except OSError:
        return ("", 0, 0.0)
    threshold = int(expected * GUT_PARTIAL_RUN_TOLERANCE) if expected > 0 else 0
    for name in slot_names:
        for layout in (os.path.join(name, "workdir"), name):
            probe = os.path.join(workspace_root, layout, "KingOfLikes-Godot", reports_dir)
            if not os.path.isdir(probe):
                continue
            try:
                entries = os.listdir(probe)
            except OSError:
                continue
            for fn in entries:
                if not fn.endswith(".xml"):
                    continue
                p = os.path.join(probe, fn)
                try:
                    mtime = os.path.getmtime(p)
                except OSError:
                    continue
                try:
                    with open(p, "r", encoding="utf-8", errors="replace") as f:
                        content = f.read()
                    count = len(re.findall(r"<testcase\b", content))
                except OSError:
                    continue
                if mtime > newest_best[2]:
                    newest_best = (p, count, mtime)
                if count >= threshold and mtime > near_full_best[2]:
                    near_full_best = (p, count, mtime)
    # Prefer the newest "plausibly full" product; else fall back to newest
    # overall so the finding still reflects real (if partial) execution.
    return near_full_best if near_full_best[0] else newest_best


def _gut_load_config(repo_root: str) -> tuple:
    """返回 (config_loaded, gutconfig)：文件缺失或解析失败为 (False, None)。"""
    gutconfig_path = os.path.join(repo_root, ".gutconfig.json")
    if not os.path.isfile(gutconfig_path):
        return False, None
    try:
        with open(gutconfig_path, "r", encoding="utf-8") as f:
            return True, json.load(f)
    except (json.JSONDecodeError, IOError, OSError):
        log_error("Cannot parse .gutconfig.json")
        return False, None


def _resolve_junit_source(repo_root: str, gutconfig: dict, workspace_root: str,
                          expected: int) -> tuple:
    # Resolve the junit report location (local first).
    candidates = _junit_candidates(repo_root, gutconfig)
    junit_rel = gutconfig.get("junit_xml_file", "res://tests/reports/junit_report.xml")
    junit_rel = junit_rel.replace("res://", "")

    junit_path = ""
    for cand in candidates:
        if os.path.isfile(cand):
            junit_path = cand  # local candidates only; glob order is fine

    junit_source_slot = "local"
    if not junit_path and workspace_root and os.path.isdir(workspace_root):
        # S1: clean checkout fallback — best junit across sibling slots,
        # preferring the most recent plausibly-full run (mtime-newest within
        # the partial-run tolerance), falling back to newest overall.
        cross_path, _cross_count, cross_mtime = _newest_junit_across_slots(
            workspace_root, junit_rel, expected
        )
        if cross_path:
            age_days = (datetime.now(timezone.utc).timestamp() - cross_mtime) / 86400.0
            if age_days <= JUNIT_MAX_AGE_DAYS:
                junit_path = cross_path
                slot_top = os.path.relpath(
                    cross_path, workspace_root
                ).replace(os.sep, "/").split("/")[0]
                junit_source_slot = f"slot:{slot_top}"
            else:
                log_error(
                    f"Cross-slot junit found but stale (> {JUNIT_MAX_AGE_DAYS} days)"
                )
    return junit_path, junit_source_slot


def _read_junit_actuals(junit_path: str, expected_by_dir: dict) -> tuple:
    actual = 0
    junit_mtime = ""
    actual_by_dir: dict[str, int] = {}
    if junit_path:
        try:
            with open(junit_path, "r", encoding="utf-8") as f:
                content = f.read()
            # Count <testcase> tags.
            actual = len(re.findall(r"<testcase\b", content))
            actual_by_dir = _attribute_testcases_by_dir(content, list(expected_by_dir))
            mtime = os.path.getmtime(junit_path)
            junit_mtime = (
                datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat()
            )
        except OSError:
            actual = 0
    return actual, actual_by_dir, junit_mtime


def _gut_silent_skip_findings(expected: int, junit_path: str, actual: int,
                              expected_by_dir: dict, actual_by_dir: dict) -> list[dict]:
    findings = []
    # D2: trigger when (a) expected>0 but no junit report exists, or
    # (b) expected>0 and actual==0 (report present but nothing executed), or
    # (c) expected>0 and actual below expected beyond the S1 tolerance
    # (same-unit partial-run detection).
    partial = actual < int(expected * GUT_PARTIAL_RUN_TOLERANCE)
    if expected > 0 and (not junit_path or actual == 0 or partial):
        detail = (
            "no junit report found"
            if not junit_path
            else f"junit reports {actual} executed"
        )
        findings.append(
            {
                "rule_id": "GUT_SILENT_SKIP",
                "severity": SEVERITY_ERROR,
                "file": ".gutconfig.json",
                "line": 0,
                "message": f"GUT silent skip: expected {expected} tests, {detail}",
            }
        )

    # D1 (SEE-1226): per-directory validation. A passing global total can hide
    # a whole configured dir that never ran (e.g. aidomain missing from the
    # junit while other dirs over-deliver), so each dir is checked on its own:
    # actual_dir == 0 → dir missing from the run; 0 < actual_dir < threshold →
    # dir partially run. Only evaluated when a junit report was actually read.
    if junit_path and actual > 0:
        for rel_dir, expected_dir in expected_by_dir.items():
            if expected_dir == 0:
                continue
            actual_dir = actual_by_dir.get(rel_dir, 0)
            threshold_dir = int(expected_dir * GUT_PARTIAL_RUN_TOLERANCE)
            if actual_dir == 0:
                findings.append(
                    {
                        "rule_id": "GUT_SILENT_SKIP",
                        "severity": SEVERITY_ERROR,
                        "file": ".gutconfig.json",
                        "line": 0,
                        "message": (
                            f"GUT silent skip (dir): {rel_dir}/ expected "
                            f"{expected_dir} tests, junit reports 0 executed "
                            f"(whole directory missing from run)"
                        ),
                    }
                )
            elif actual_dir < threshold_dir:
                findings.append(
                    {
                        "rule_id": "GUT_SILENT_SKIP",
                        "severity": SEVERITY_ERROR,
                        "file": ".gutconfig.json",
                        "line": 0,
                        "message": (
                            f"GUT silent skip (dir): {rel_dir}/ expected "
                            f"{expected_dir} tests, junit reports {actual_dir} "
                            f"executed (below 95% per-dir tolerance)"
                        ),
                    }
                )
    return findings


def check_gut_silent_skip(repo_root: str, workspace_root: str = "") -> list[dict]:
    """Compare .gutconfig.json expected test count vs junit actual count.

    D2: the junit path is read from the `junit_xml_file` config key (falling
    back to tests/reports/junit_report.xml), and `junit_xml_timestamp: true`
    produces `junit_report_<ts>.xml` files — resolved via glob on the base
    stem. A missing junit report OR a report with actual==0 (nothing executed)
    is itself a silent-skip signal and triggers a finding.

    S1 (SEE-1226): the sweep runs in a clean checkout slot whose
    tests/reports/ is empty by construction, so when no local report exists
    the check falls back to the newest junit across sibling workspace slots
    (within JUNIT_MAX_AGE_DAYS). expected counts `func test_*` declarations,
    same unit as junit <testcase> entries; a 5% tolerance absorbs junit-older-
    than-HEAD skew without masking a genuinely partial run.
    """
    findings = []
    metrics = {
        "expected_tests": 0,
        "actual_tests": 0,
        "junit_source": "",
        "junit_mtime": "",
    }
    loaded, gutconfig = _gut_load_config(repo_root)
    if not loaded:
        return findings, metrics

    expected_by_dir = _count_expected_test_funcs_by_dir(repo_root, gutconfig)
    expected = sum(expected_by_dir.values())

    junit_path, junit_source_slot = _resolve_junit_source(
        repo_root, gutconfig, workspace_root, expected
    )
    actual, actual_by_dir, junit_mtime = _read_junit_actuals(junit_path, expected_by_dir)

    metrics["junit_source"] = junit_source_slot
    metrics["junit_mtime"] = junit_mtime
    findings = _gut_silent_skip_findings(
        expected, junit_path, actual, expected_by_dir, actual_by_dir
    )

    metrics["expected_tests"] = expected
    metrics["actual_tests"] = actual
    return findings, metrics


def check_test_to_code_ratio(repo_root: str) -> dict:
    """Compute test-to-code ratio (test .gd lines / production .gd lines)."""
    test_lines = 0
    code_lines = 0

    for root, dirs, files in os.walk(repo_root):
        dirs[:] = [d for d in dirs if d not in EXCLUDED_DIRS]
        for name in files:
            if not name.endswith(".gd"):
                continue
            fp = os.path.join(root, name)
            rel = os.path.relpath(fp, repo_root).replace(os.sep, "/")
            if _is_excluded(rel):
                continue
            try:
                with open(fp, "r", encoding="utf-8", errors="replace") as f:
                    count = sum(1 for _ in f)
            except OSError:
                continue
            if rel.startswith("tests/"):
                test_lines += count
            else:
                code_lines += count

    ratio = test_lines / code_lines if code_lines > 0 else 0.0
    return {
        "test_lines": test_lines,
        "code_lines": code_lines,
        "test_to_code_ratio": round(ratio, 3),
    }


# ---------------------------------------------------------------------------
# Report generation
# ---------------------------------------------------------------------------


def build_report(
    findings: list[dict],
    metrics: dict,
    new_findings: list[dict],
    known_keys: set[str],
) -> dict:
    """Build structured JSON report."""
    return {
        "ts": now_iso(),
        "summary": {
            "total_findings": len(findings),
            "new_findings": len(new_findings),
            "metrics": metrics,
        },
        "findings": findings,
        "new_findings": new_findings,
        "known_findings_count": len(known_keys),
        "kill_switch": bool(metrics.get("kill_switch", False)),
    }


def print_report(report: dict) -> None:
    """Print human-readable summary to stderr."""
    s = report["summary"]
    print(
        f"[arch-sweep] ts={report['ts']} findings={s['total_findings']} "
        f"new={s['new_findings']} known={report['known_findings_count']}",
        file=sys.stderr,
    )
    for f in report["new_findings"]:
        print(
            f"  [{f['severity'].upper()}] {f['rule_id']} {f['file']}:{f['line']} — {f['message']}",
            file=sys.stderr,
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def _autodetect_current_hash(current_hash: str, workspace_root: str) -> str:
    # Auto-detect current_hash.
    if not current_hash:
        current_hash = os.environ.get("MULTICA_WORKTREE_HASH", "")
        if not current_hash and workspace_root:
            cwd = os.getcwd()
            ws_root_norm = workspace_root.replace("/", os.sep).replace("\\", os.sep)
            prefix = ws_root_norm + os.sep
            if cwd.startswith(prefix):
                rel = cwd[len(prefix) :]
                current_hash = rel.split(os.sep)[0]
    return current_hash


def _sweep_context(args):
    """解析 (workspace_root, current_hash, dry_run, fast_mode, force_l1, kill_switch)。"""
    workspace_root = args.workspace_root
    current_hash = args.current_hash
    dry_run = args.dry_run
    fast_mode = args.fast
    force_l1 = args.l1
    # SEE-1224 #4: --kill-switch is a read-only fuse. When set, downgrade to
    # pure output by forcing dry_run so baseline/heartbeat/manifest writes
    # (which mutate ~/.multica/arch-patrol/) are suppressed.
    kill_switch = str(args.kill_switch).lower() == "true"
    if kill_switch:
        dry_run = True
    current_hash = _autodetect_current_hash(current_hash, workspace_root)
    return workspace_root, current_hash, dry_run, fast_mode, force_l1, kill_switch


def _repo_candidates(workspace_root: str, current_hash: str) -> list[str]:
    # D8: multi-level fallback instead of a single hardcoded layout — explicit
    # slot path, CWD walk-up, then a scan of workspace_root for any
    # <hash>/workdir/<repo> (or <hash>/<repo>).
    cands = []
    if current_hash:
        cands.append(os.path.join(workspace_root, current_hash, "workdir", "KingOfLikes-Godot"))
        cands.append(os.path.join(workspace_root, current_hash, "KingOfLikes-Godot"))
    cands.append(os.path.join(workspace_root, "workdir", "KingOfLikes-Godot"))
    cands.append(os.path.join(workspace_root, "KingOfLikes-Godot"))
    cwd = os.path.abspath(os.getcwd())
    # Walk up from CWD: a directory containing KingOfLikes-Godot is a repo parent.
    current = cwd
    while current:
        probe = os.path.join(current, "KingOfLikes-Godot")
        if os.path.isdir(probe):
            cands.append(probe)
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    return cands


def _scan_workspace_slots(workspace_root: str) -> str:
    # Last resort: scan workspace_root slots for the repo.
    try:
        for name in sorted(os.listdir(workspace_root)):
            for sub in (
                os.path.join(workspace_root, name, "workdir", "KingOfLikes-Godot"),
                os.path.join(workspace_root, name, "KingOfLikes-Godot"),
            ):
                if os.path.isdir(sub):
                    return sub
    except OSError:
        pass
    return ""


def _locate_repo_root(workspace_root: str, current_hash: str) -> str:
    for cand in _repo_candidates(workspace_root, current_hash):
        if os.path.isdir(cand):
            return cand
    return _scan_workspace_slots(workspace_root)


def _run_l0_checks(repo_root: str, prod_gd, fast_mode: bool, dry_run: bool,
                   all_findings: list, metrics: dict) -> tuple:
    """Redline + L0 checks；返回 (redline_skipped, gdlint_warnings)。"""
    # Redline check (always runs, even in --fast)
    redline_findings = check_redline(repo_root, dry_run)
    all_findings.extend(redline_findings)
    redline_skipped = any(
        f["rule_id"] == "REDLINE_SKIPPED_UNINITIALIZED" for f in redline_findings
    )

    # 1. Deprecated bridges
    dep_findings = check_deprecated_bridges(repo_root, prod_gd)
    all_findings.extend(dep_findings)
    metrics["deprecated_bridges"] = len(dep_findings)

    # 2. SEE-* comments
    see_findings = check_see_comments(repo_root, prod_gd)
    all_findings.extend(see_findings)
    metrics["see_comments"] = len(see_findings)

    # 3. File length
    file_findings = check_file_length(repo_root, prod_gd)
    all_findings.extend(file_findings)
    metrics["files_over_800"] = len(file_findings)

    # 4. Function length
    func_findings = check_function_length(repo_root, prod_gd)
    all_findings.extend(func_findings)
    metrics["funcs_over_50"] = len(func_findings)

    # 5. Autoload reference matrix
    autoload_findings, autoload_matrix = check_autoload_references(repo_root, prod_gd)
    all_findings.extend(autoload_findings)
    metrics["autoload_files_referencing"] = len(autoload_matrix)
    metrics["high_coupling_files"] = len(autoload_findings)

    # 6. GameState mirror direct assignment
    gs_findings = check_gamestate_mirror(repo_root, prod_gd)
    all_findings.extend(gs_findings)
    metrics["gamestate_direct_assignments"] = len(gs_findings)

    # 7. Blacklist functions
    bl_findings = check_blacklist_functions(repo_root, prod_gd)
    all_findings.extend(bl_findings)
    metrics["blacklist_calls"] = len(bl_findings)

    # 8. gdlint increment (skipped in --fast mode)
    gdlint_warnings = {}
    if not fast_mode:
        gdlint_result = check_gdlint_increment(repo_root, prod_gd, dry_run)
        if isinstance(gdlint_result, tuple):
            gdlint_findings, gdlint_warnings = gdlint_result
        else:
            gdlint_findings = gdlint_result
        all_findings.extend(gdlint_findings)
        metrics["gdlint_new_warnings"] = len(gdlint_findings)

    # 9. Guard pending（SEE-1470 Track A：ledger 2026-09 SPEC-001 日检生产接线）
    gp_findings = check_guard_pending(repo_root)
    all_findings.extend(gp_findings)
    metrics["guard_pending"] = len(gp_findings)

    return redline_skipped, gdlint_warnings


def _run_l1_checks(repo_root: str, workspace_root: str, run_l1: bool, fast_mode: bool,
                   all_findings: list, metrics: dict) -> None:
    # L1 checks (weekly or forced)
    if run_l1 and not fast_mode:
        # GUT silent skip (S1: cross-slot junit aggregation)
        gut_result = check_gut_silent_skip(repo_root, workspace_root)
        if isinstance(gut_result, tuple):
            gut_findings, gut_metrics = gut_result
        else:
            gut_findings, gut_metrics = gut_result, {}
        all_findings.extend(gut_findings)
        metrics.update(gut_metrics)

        # Test-to-code ratio
        ratio_metrics = check_test_to_code_ratio(repo_root)
        metrics.update(ratio_metrics)


def _dedup_findings(all_findings: list, known_keys: set) -> tuple:
    # Dedup and baseline-diff
    current_keys = set()
    new_findings = []
    for f in all_findings:
        key = dedup_key(f["file"], f["line"], f["rule_id"], f["severity"])
        current_keys.add(key)
        if key not in known_keys:
            new_findings.append(f)
    return current_keys, new_findings


def _write_report_file(report: dict, dry_run: bool) -> None:
    # Write report to file for external consumption.
    if not dry_run:
        ensure_dir(os.path.dirname(REPORT_FILE))
        with open(REPORT_FILE, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, ensure_ascii=False)


def main() -> int:
    args = parse_args()
    # SEE-1430c O1: wire the patrol target config (falls back to the built-in
    # constants when the file is absent/unreadable — behaviour-compatible).
    apply_config(args.config)

    # Locks: PID (per-script) + workspace mutex (cross-autopilot).
    _pid_lock = PidFileLock(os.path.join(tempfile.gettempdir(), "architecture_sweep.pid"))
    if not _pid_lock.acquire():
        sys.exit(1)
    _ws_mutex = WorkspaceMutex(label="architecture_sweep")
    _ws_mutex.acquire()

    workspace_root, current_hash, dry_run, fast_mode, force_l1, kill_switch = _sweep_context(args)

    repo_root = _locate_repo_root(workspace_root, current_hash)
    if not repo_root:
        log_error(f"Repo root not found under workspace: {workspace_root}")
        _ws_mutex.release()
        _pid_lock.release()
        sys.exit(1)

    # Ensure state directory exists.
    ensure_dir(ARCH_PATROL_HOME)

    # Determine if L1 should run (weekly: Monday or forced).
    run_l1 = force_l1 or datetime.now(timezone.utc).weekday() == 0

    # Collect all .gd files (production + tests for L1 metrics).
    all_gd = find_gd_files(repo_root, include_tests=True)
    prod_gd = [f for f in all_gd if not f.startswith("tests/")]

    all_findings: list = []
    metrics: dict = {}

    redline_skipped, gdlint_warnings = _run_l0_checks(
        repo_root, prod_gd, fast_mode, dry_run, all_findings, metrics)
    _run_l1_checks(repo_root, workspace_root, run_l1, fast_mode, all_findings, metrics)

    known_keys = load_known_findings()
    current_keys, new_findings = _dedup_findings(all_findings, known_keys)

    # Add gdlint warnings to metrics for next run's diff.
    if gdlint_warnings:
        metrics["gdlint_warnings"] = gdlint_warnings

    # Write baseline and heartbeat.
    write_baseline(metrics, list(current_keys), dry_run)
    write_heartbeat(
        "ok" if _phase_error_count == 0 else "error",
        build_heartbeat_summary(len(all_findings), len(new_findings), redline_skipped),
        dry_run,
    )

    if kill_switch:
        metrics["kill_switch"] = True

    # Report
    report = build_report(all_findings, metrics, new_findings, known_keys)
    print(json.dumps(report, indent=2, ensure_ascii=False))
    print_report(report)
    _write_report_file(report, dry_run)

    # Exit code
    _ws_mutex.release()
    _pid_lock.release()

    if _phase_error_count > 0:
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
