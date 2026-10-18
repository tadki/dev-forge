"""Unit tests for SEE-1434 redline guard on unmaterialized submodule.

§SPEC-001: when the addons/godot_mcp gitlink is not materialized (the disk
directory is empty — checkout without `git submodule update --init`), the
sweep must SKIP the redline comparison entirely and emit exactly ONE
`REDLINE_SKIPPED_UNINITIALIZED` downgrade warning (severity warn, never
critical). No REDLINE_DELETED/MODIFIED/NEW may be produced for an
unmaterialized path — the SEE-1433 incident shape (979 false criticals).

§SPEC-002: the degraded state must be visible in the heartbeat via the
summary marker (`redline=skipped_uninitialized`).

Fixtures build a parent repo that registers addons/godot_mcp in .gitmodules
AND the index as a 160000 gitlink, but never materializes the child working
tree — the exact state a plain `multica repo checkout` leaves behind.
"""

import hashlib
import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

import architecture_sweep as sweep


def _git(*args, cwd):
    subprocess.run(
        ["git", "-C", str(cwd)] + list(args),
        check=True,
        capture_output=True,
    )


def _git_out(*args, cwd):
    return subprocess.run(
        ["git", "-C", str(cwd)] + list(args),
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def _read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _sha256(content: str) -> str:
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def _init_repo(path):
    """Create an empty git repo at `path` with a fixed identity; returns path."""
    path.mkdir(parents=True)
    _git("init", "-q", "-b", "main", cwd=path)
    _git("config", "user.email", "t@t.dev", cwd=path)
    _git("config", "user.name", "t", cwd=path)
    return path


def _seed_subrepo(base):
    """Fork repo holding one committed file; returns (repo_path, head_sha)."""
    sub = _init_repo(base / "subrepo")
    _write(str(sub / "a.txt"), "a-one\n")
    _git("add", "-A", cwd=sub)
    _git("commit", "-q", "-m", "s1", cwd=sub)
    return sub, _git_out("rev-parse", "HEAD", cwd=sub)


@pytest.fixture()
def unmaterialized_repo(tmp_path):
    """Parent repo with a registered-but-unmaterialized addons/godot_mcp gitlink."""
    base = tmp_path / "fixture"
    _sub, s1 = _seed_subrepo(base)

    parent = _init_repo(base / "parent")
    _write(
        str(parent / ".gitmodules"),
        '[submodule "addons/godot_mcp"]\n'
        "\tpath = addons/godot_mcp\n"
        "\turl = https://example.invalid/godot_mcp.git\n",
    )
    _git("update-index", "--add", "--cacheinfo", f"160000,{s1},addons/godot_mcp", cwd=parent)
    _git("add", ".gitmodules", cwd=parent)
    _write(str(parent / "README.md"), "# fixture\n")
    _git("add", "README.md", cwd=parent)
    _git("commit", "-q", "-m", "register unmaterialized submodule", cwd=parent)
    # Child worktree intentionally NOT materialized: addons/godot_mcp absent.
    return parent, s1


@pytest.fixture()
def patrol(tmp_path, monkeypatch):
    """Isolated ARCH_PATROL state files for the sweep module."""
    home = tmp_path / "arch-patrol"
    home.mkdir()
    monkeypatch.setattr(sweep, "REDLINE_MANIFEST", str(home / "redline.manifest"))
    monkeypatch.setattr(sweep, "REDLINE_POINTER_FILE", str(home / "redline.pointer"))
    return home


def _store_manifest(mapping):
    with open(sweep.REDLINE_MANIFEST, "w", encoding="utf-8") as f:
        json.dump(mapping, f)


def _critical_rules(findings):
    return [f["rule_id"] for f in findings if f["severity"] == sweep.SEVERITY_CRITICAL]


# ---------------------------------------------------------------------------
# §SPEC-001: unmaterialized gitlink -> skip + one downgrade warning
# ---------------------------------------------------------------------------


def test_unmaterialized_skips_comparison_no_critical(patrol, unmaterialized_repo):
    """SEE-1433 incident shape: stale manifest + empty addon dir -> 0 criticals."""
    parent, _s1 = unmaterialized_repo
    _store_manifest({"addons/godot_mcp/a.txt": _sha256("a-one\n")})

    findings = sweep.check_redline(str(parent), dry_run=True)

    assert _critical_rules(findings) == []
    skipped = [f for f in findings if f["rule_id"] == "REDLINE_SKIPPED_UNINITIALIZED"]
    assert len(skipped) == 1
    assert skipped[0]["severity"] == sweep.SEVERITY_WARN
    assert not [
        f
        for f in findings
        if f["rule_id"] in ("REDLINE_DELETED", "REDLINE_MODIFIED", "REDLINE_NEW")
    ]


def test_unmaterialized_finding_targets_submodule_path(patrol, unmaterialized_repo):
    parent, _s1 = unmaterialized_repo
    _store_manifest({"addons/godot_mcp/a.txt": _sha256("a-one\n")})

    findings = sweep.check_redline(str(parent), dry_run=True)

    skipped = [f for f in findings if f["rule_id"] == "REDLINE_SKIPPED_UNINITIALIZED"]
    assert skipped[0]["file"] == "addons/godot_mcp/"


def test_unmaterialized_does_not_rewrite_manifest_or_pointer(patrol, unmaterialized_repo):
    """Skipping must be side-effect free: baseline artifacts stay untouched."""
    parent, s1 = unmaterialized_repo
    _store_manifest({"addons/godot_mcp/a.txt": _sha256("a-one\n")})
    with open(sweep.REDLINE_POINTER_FILE, "w", encoding="utf-8") as f:
        json.dump({"pointer": s1, "generated_at": "2026-10-17T00:00:00+00:00"}, f)
    manifest_before = _read(sweep.REDLINE_MANIFEST)
    pointer_before = _read(sweep.REDLINE_POINTER_FILE)

    sweep.check_redline(str(parent), dry_run=False)

    assert _read(sweep.REDLINE_MANIFEST) == manifest_before
    assert _read(sweep.REDLINE_POINTER_FILE) == pointer_before


def test_unmaterialized_first_run_does_not_initialize_empty_manifest(patrol, unmaterialized_repo):
    """No stored manifest + unmaterialized gitlink: must NOT store an empty
    manifest — that would turn every file into REDLINE_NEW once materialized."""
    parent, _s1 = unmaterialized_repo

    findings = sweep.check_redline(str(parent), dry_run=False)

    assert _critical_rules(findings) == []
    assert len([f for f in findings if f["rule_id"] == "REDLINE_SKIPPED_UNINITIALIZED"]) == 1
    assert not [f for f in findings if f["rule_id"] == "REDLINE_INIT"]
    assert not os.path.isfile(sweep.REDLINE_MANIFEST)


@pytest.fixture()
def materialized_repo(tmp_path):
    """Parent repo whose addons/godot_mcp IS a real materialized submodule clone."""
    base = tmp_path / "mat"
    sub, s1 = _seed_subrepo(base)

    parent = _init_repo(base / "parent")
    addon = parent / "addons" / "godot_mcp"
    _git("clone", "-q", str(sub), str(addon), cwd=parent)
    _git("update-index", "--add", "--cacheinfo", f"160000,{s1},addons/godot_mcp", cwd=parent)
    _write(str(parent / "README.md"), "# fixture\n")
    _git("add", "README.md", cwd=parent)
    _git("commit", "-q", "-m", "pin materialized submodule", cwd=parent)
    return parent, s1


def test_detector_classifies_unmaterialized_as_no(unmaterialized_repo):
    parent, _s1 = unmaterialized_repo
    assert sweep._submodule_materialized(str(parent)) == "no"


def test_detector_classifies_materialized_as_yes(materialized_repo):
    """A materialized submodule (real clone + .gitmodules) is exactly 'yes'.

    Exact (not set-membership): a detector that collapsed healthy states to
    'unknown' or 'no' would break the three-state contract this guard leans on.
    """
    parent, _s1 = materialized_repo
    assert sweep._submodule_materialized(str(parent)) == "yes"


def test_detector_classifies_plain_directory_as_yes(tmp_path):
    """addons/godot_mcp tracked as a plain directory (mode 100644 tree, not a
    160000 gitlink) is 'yes' — there is nothing to skip, comparison must run."""
    base = tmp_path / "plain"
    parent = _init_repo(base / "parent")
    _write(
        str(parent / "addons" / "godot_mcp" / "a.txt"),
        "vendored content\n",
    )
    _git("add", "-A", cwd=parent)
    _git("commit", "-q", "-m", "plain dir, no gitlink", cwd=parent)

    assert sweep._submodule_materialized(str(parent)) == "yes"


def test_detector_classifies_registered_but_empty_dir_as_no(unmaterialized_repo):
    """Registered gitlink + existing-but-EMPTY addons/godot_mcp dir is 'no'.

    Covers the scandir branch (dir present, holds no entries) — distinct from
    the isdir branch (dir absent) exercised by test_detector_classifies_
    unmaterialized_as_no. A detector bug on this path (e.g. any->all, or
    defaulting to 'yes') would re-open the SEE-1433 false-critical hole for
    the empty-directory flavor of unmaterialized checkout.
    """
    parent, _s1 = unmaterialized_repo
    os.makedirs(str(parent / "addons" / "godot_mcp"))

    assert sweep._submodule_materialized(str(parent)) == "no"


def test_detector_git_probe_failure_is_unknown(unmaterialized_repo, monkeypatch):
    """git ls-files failing must yield 'unknown', never a skip-eligible 'no'.

    Fail-closed: a broken detector must keep the comparison running (real
    criticals still possible) rather than silently drop redline coverage.
    """
    parent, _s1 = unmaterialized_repo

    def _boom(*_args, **_kwargs):
        raise OSError("git unavailable")

    monkeypatch.setattr(sweep.subprocess, "run", _boom)

    assert sweep._submodule_materialized(str(parent)) == "unknown"


def test_detector_scandir_failure_is_unknown(unmaterialized_repo, monkeypatch):
    """os.scandir failing on an existing addon dir must yield 'unknown'.

    Exact 'unknown' (not 'no'): 'no' here would skip the comparison based on
    an undetectable state — the exact fail-open this guard forbids.
    """
    parent, _s1 = unmaterialized_repo
    addon_dir = str(parent / "addons" / "godot_mcp")
    os.makedirs(addon_dir)
    real_scandir = os.scandir

    def _scandir_boom(path):
        if str(path) == addon_dir:
            raise OSError("scandir denied")
        return real_scandir(path)

    monkeypatch.setattr(sweep.os, "scandir", _scandir_boom)

    assert sweep._submodule_materialized(str(parent)) == "unknown"


# ---------------------------------------------------------------------------
# §SPEC-002: heartbeat skipped marker
# ---------------------------------------------------------------------------


def test_heartbeat_summary_carries_skipped_marker():
    """Exact equality: kills dropped/reshuffled segments (e.g. losing `new=`,
    swapping total/new) that substring checks would let survive."""
    summary = sweep.build_heartbeat_summary(5, 2, redline_skipped=True)
    assert summary == "findings=5 new=2 redline=skipped_uninitialized"


def test_heartbeat_summary_no_marker_when_materialized():
    summary = sweep.build_heartbeat_summary(5, 2, redline_skipped=False)
    assert summary == "findings=5 new=2"
    assert "redline=skipped_uninitialized" not in summary


# ---------------------------------------------------------------------------
# Fail-closed bias preserved (§SPEC-003 interface): an INDETERMINATE state
# ("unknown") keeps the pre-guard comparison behavior — the skip only fires
# when git positively proves the gitlink is unmaterialized.
# ---------------------------------------------------------------------------


def test_unknown_state_fails_closed(patrol, materialized_repo, monkeypatch):
    """'unknown' classification keeps the pre-guard comparison: a stale
    manifest vs a modified tree still reports criticals (never a silent pass)."""
    parent, _s1 = materialized_repo
    stale = {"addons/godot_mcp/nonexistent.txt": _sha256("gone\n")}
    _store_manifest(stale)
    # The pinned fork commit doesn't ship nonexistent.txt either, so it would
    # classify as an artifact — force an empty blob_map (unresolvable tree)
    # to exercise the fail-closed DELETED path with the 'unknown' state.
    monkeypatch.setattr(sweep, "_submodule_materialized", lambda repo_root: "unknown")
    monkeypatch.setattr(sweep, "_gitlink_blob_map", lambda repo_root, pointer: {})

    findings = sweep.check_redline(str(parent), dry_run=True)

    # Empty blob_map fails closed: DELETED stays critical (the pinned fork
    # commit's tree is unresolvable, so the deletion cannot be proven an
    # artifact); NEW for the real addon file also stays critical.
    assert sorted(_critical_rules(findings)) == ["REDLINE_DELETED", "REDLINE_NEW"]
    assert not [f for f in findings if f["rule_id"] == "REDLINE_SKIPPED_UNINITIALIZED"]


# ---------------------------------------------------------------------------
# Hardening additions: exact skip contract, guard-line polarity, dual-mode
# side-effect freedom.
# ---------------------------------------------------------------------------


def test_skipped_finding_contract_exact(patrol, unmaterialized_repo):
    """The downgrade warning's full contract, pinned exactly.

    severity is the literal 'warn' (never critical, and not merely
    not-critical); line 0 and the submodule path make dedup stable; the
    message must carry the SOP remediation hint so the on-call can act.
    """
    parent, _s1 = unmaterialized_repo
    _store_manifest({"addons/godot_mcp/a.txt": _sha256("a-one\n")})

    findings = sweep.check_redline(str(parent), dry_run=True)

    skipped = [f for f in findings if f["rule_id"] == "REDLINE_SKIPPED_UNINITIALIZED"]
    assert len(skipped) == 1
    f = skipped[0]
    assert f["severity"] == "warn"
    assert f["severity"] == sweep.SEVERITY_WARN
    assert f["severity"] != sweep.SEVERITY_CRITICAL
    assert f["file"] == "addons/godot_mcp/"
    assert f["line"] == 0
    assert "NOT materialized" in f["message"]
    assert "git submodule update --init" in f["message"]


def test_materialized_repo_comparison_still_runs(patrol, materialized_repo):
    """Guard polarity: only a positively-proven 'no' may skip.

    A materialized repo with a tampered addon file (differs from BOTH the
    stored manifest and the pinned fork tree) must still produce a real
    REDLINE_MODIFIED critical — a mutant that flips the guard to skip on
    'yes' (or unconditionally) dies here, not just in the detector unit
    tests.
    """
    parent, _s1 = materialized_repo
    stored = {"addons/godot_mcp/a.txt": _sha256("a-one\n")}
    _store_manifest(stored)
    # Tamper on disk: current sha != stored sha, and disk blob != pinned tree
    # blob, so SEE-1332 artifact classification cannot absorb it.
    _write(str(parent / "addons" / "godot_mcp" / "a.txt"), "tampered\n")

    findings = sweep.check_redline(str(parent), dry_run=True)

    assert "REDLINE_MODIFIED" in _critical_rules(findings)
    assert not [f for f in findings if f["rule_id"] == "REDLINE_SKIPPED_UNINITIALIZED"]


def test_unmaterialized_no_touch_in_dry_run_mode(patrol, unmaterialized_repo):
    """Dry-run + skip: manifest/pointer untouched (real-run twin of
    test_unmaterialized_does_not_rewrite_manifest_or_pointer)."""
    parent, s1 = unmaterialized_repo
    _store_manifest({"addons/godot_mcp/a.txt": _sha256("a-one\n")})
    with open(sweep.REDLINE_POINTER_FILE, "w", encoding="utf-8") as f:
        json.dump({"pointer": s1, "generated_at": "2026-10-17T00:00:00+00:00"}, f)
    manifest_before = _read(sweep.REDLINE_MANIFEST)
    pointer_before = _read(sweep.REDLINE_POINTER_FILE)

    findings = sweep.check_redline(str(parent), dry_run=True)

    assert _critical_rules(findings) == []
    assert _read(sweep.REDLINE_MANIFEST) == manifest_before
    assert _read(sweep.REDLINE_POINTER_FILE) == pointer_before


def test_materialized_first_run_initializes_manifest(patrol, materialized_repo):
    """Materialized first run: REDLINE_INIT + manifest stored — the exact
    behavior the skip path must suppress for unmaterialized repos (twin of
    test_unmaterialized_first_run_does_not_initialize_empty_manifest). No
    test anywhere in tests/ reached this pre-guard branch before hardening."""
    parent, _s1 = materialized_repo

    findings = sweep.check_redline(str(parent), dry_run=False)

    assert [f["rule_id"] for f in findings] == ["REDLINE_INIT"]
    assert _critical_rules(findings) == []
    with open(sweep.REDLINE_MANIFEST, encoding="utf-8") as f:
        stored = json.load(f)
    assert stored == {"addons/godot_mcp/a.txt": _sha256("a-one\n")}
