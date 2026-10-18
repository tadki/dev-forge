"""Unit tests for SEE-1332 redline gitlink-bump classification.

Deterministic machine criterion (§SPEC-001): a REDLINE_NEW / REDLINE_MODIFIED
hit on addons/godot_mcp/ is a "compliant gitlink bump artifact" iff the
working file's git blob sha equals the blob recorded in the fork commit
pinned by the parent repo HEAD; a REDLINE_DELETED hit is an artifact iff the
pinned fork commit no longer ships the file. Anything else — including an
unavailable gitlink — stays a critical finding (fail closed), so direct
edits to the vendored redline area are never masked (§SPEC-002).

Fixtures build a synthetic parent repo whose addons/godot_mcp is a real git
repo registered as a 160000 gitlink, advanced s1 -> s2, with a stale manifest
snapshot of s1 (the SEE-1285/1325/1328 incident shape).
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


A1, A2, B1, N2 = "alpha-one\n", "alpha-two\n", "beta-one\n", "new-two\n"


@pytest.fixture()
def bumped_repo(tmp_path):
    """Parent repo pinning gitlink s2 while its manifest snapshot is stale (s1)."""
    base = tmp_path / "fixture"
    sub = base / "subrepo"
    sub.mkdir(parents=True)
    _git("init", "-q", "-b", "main", cwd=sub)
    _git("config", "user.email", "t@t.dev", cwd=sub)
    _git("config", "user.name", "t", cwd=sub)
    _write(str(sub / "a.txt"), A1)
    _write(str(sub / "dir" / "b.txt"), B1)
    _git("add", "-A", cwd=sub)
    _git("commit", "-q", "-m", "s1", cwd=sub)
    s1 = _git_out("rev-parse", "HEAD", cwd=sub)

    # Fork advance: same-key modify (a.txt), fork-added file (new.txt),
    # fork-removed file (dir/b.txt) — covers NEW/MODIFIED/DELETED shapes.
    _write(str(sub / "a.txt"), A2)
    _write(str(sub / "new.txt"), N2)
    os.remove(str(sub / "dir" / "b.txt"))
    _git("add", "-A", cwd=sub)
    _git("commit", "-q", "-m", "s2", cwd=sub)
    s2 = _git_out("rev-parse", "HEAD", cwd=sub)

    parent = base / "parent"
    parent.mkdir(parents=True)
    _git("init", "-q", "-b", "main", cwd=parent)
    _git("config", "user.email", "t@t.dev", cwd=parent)
    _git("config", "user.name", "t", cwd=parent)
    addon = parent / "addons" / "godot_mcp"
    _git("clone", "-q", str(sub), str(addon), cwd=parent)
    _git("update-index", "--add", "--cacheinfo", f"160000,{s2},addons/godot_mcp", cwd=parent)
    _write(str(parent / "README.md"), "# fixture\n")
    _git("add", "README.md", cwd=parent)
    _git("commit", "-q", "-m", "pin s2", cwd=parent)

    # Stale manifest snapshot = s1-era tree (pre-bump), the incident shape.
    stale = {
        "addons/godot_mcp/a.txt": _sha256(A1),
        "addons/godot_mcp/dir/b.txt": _sha256(B1),
    }
    return parent, stale, s1, s2


@pytest.fixture()
def patrol(tmp_path, monkeypatch):
    """Isolated ARCH_PATROL state files for the sweep module."""
    home = tmp_path / "arch-patrol"
    home.mkdir()
    monkeypatch.setattr(sweep, "REDLINE_MANIFEST", str(home / "redline.manifest"))
    monkeypatch.setattr(sweep, "REDLINE_POINTER_FILE", str(home / "redline.pointer"))
    return home


def _store_manifest(stale):
    with open(sweep.REDLINE_MANIFEST, "w", encoding="utf-8") as f:
        json.dump(stale, f)


def _critical_rules(findings):
    return [f["rule_id"] for f in findings if f["severity"] == sweep.SEVERITY_CRITICAL]


# ---------------------------------------------------------------------------
# §SPEC-001: gitlink bump artifacts are not critical findings
# ---------------------------------------------------------------------------


def test_pure_bump_artifacts_downgraded(patrol, bumped_repo):
    parent, stale, s1, s2 = bumped_repo
    _store_manifest(stale)
    # Incident shape: the sidecar still records the pre-bump pointer.
    with open(sweep.REDLINE_POINTER_FILE, "w", encoding="utf-8") as f:
        json.dump({"pointer": s1, "generated_at": "2026-09-12T00:00:00+00:00"}, f)

    findings = sweep.check_redline(str(parent), dry_run=True)

    assert _critical_rules(findings) == []
    resets = [f for f in findings if f["rule_id"] == "REDLINE_BASELINE_RESET"]
    assert len(resets) == 1
    # LOW-fix message contract: names the pinned gitlink only, sidecar-agnostic.
    assert s2[:12] in resets[0]["message"]


def test_fork_removed_file_is_artifact_not_redline_deleted(patrol, bumped_repo):
    """dir/b.txt was removed in the fork advance: no REDLINE_DELETED critical."""
    parent, stale, s1, s2 = bumped_repo
    _store_manifest(stale)

    findings = sweep.check_redline(str(parent), dry_run=True)

    assert "REDLINE_DELETED" not in _critical_rules(findings)


def test_reset_persists_manifest_and_pointer(patrol, bumped_repo):
    parent, stale, s1, s2 = bumped_repo
    _store_manifest(stale)

    findings = sweep.check_redline(str(parent), dry_run=False)

    refreshed = json.loads(_read(sweep.REDLINE_MANIFEST))
    assert refreshed == sweep.compute_redline_manifest(str(parent))
    pointer = json.loads(_read(sweep.REDLINE_POINTER_FILE))
    assert pointer["pointer"] == s2


# ---------------------------------------------------------------------------
# §SPEC-002: direct edits to the redline area stay critical
# ---------------------------------------------------------------------------


def test_direct_edit_still_critical(patrol, bumped_repo):
    """Tamper one file beyond the pinned fork commit: REDLINE_MODIFIED critical."""
    parent, stale, s1, s2 = bumped_repo
    _store_manifest(json.loads(json.dumps(sweep.compute_redline_manifest(str(parent)))))
    tampered = parent / "addons" / "godot_mcp" / "a.txt"
    _write(str(tampered), "locally-tampered\n")

    findings = sweep.check_redline(str(parent), dry_run=True)

    assert _critical_rules(findings) == ["REDLINE_MODIFIED"]
    modified = [f for f in findings if f["rule_id"] == "REDLINE_MODIFIED"]
    assert modified[0]["file"] == "addons/godot_mcp/a.txt"
    assert not [f for f in findings if f["rule_id"] == "REDLINE_BASELINE_RESET"]


def test_direct_edit_blocks_manifest_reset(patrol, bumped_repo):
    """With a real violation the manifest must not be re-blessed."""
    parent, stale, s1, s2 = bumped_repo
    _store_manifest(stale)
    _write(str(parent / "addons" / "godot_mcp" / "a.txt"), "locally-tampered\n")
    before = _read(sweep.REDLINE_MANIFEST)

    sweep.check_redline(str(parent), dry_run=False)

    assert _read(sweep.REDLINE_MANIFEST) == before


def test_mixed_bump_and_edit_reports_only_direct_edit(patrol, bumped_repo):
    """s1->s2 churn plus one local tamper: only the tamper is critical."""
    parent, stale, s1, s2 = bumped_repo
    _store_manifest(stale)
    _write(str(parent / "addons" / "godot_mcp" / "new.txt"), "local-new-content\n")

    findings = sweep.check_redline(str(parent), dry_run=True)

    # new.txt is absent from the stale manifest, so the raw shape is NEW.
    assert _critical_rules(findings) == ["REDLINE_NEW"]
    assert findings[0]["file"] == "addons/godot_mcp/new.txt"


def test_local_new_file_not_in_fork_commit_stays_critical(patrol, bumped_repo):
    """A locally authored file absent from the pinned commit: REDLINE_NEW."""
    parent, stale, s1, s2 = bumped_repo
    _store_manifest(json.loads(json.dumps(sweep.compute_redline_manifest(str(parent)))))
    _write(str(parent / "addons" / "godot_mcp" / "rogue.txt"), "rogue\n")

    findings = sweep.check_redline(str(parent), dry_run=True)

    assert _critical_rules(findings) == ["REDLINE_NEW"]
    assert findings[0]["file"] == "addons/godot_mcp/rogue.txt"


# ---------------------------------------------------------------------------
# Fail-closed bias
# ---------------------------------------------------------------------------


def test_unavailable_gitlink_fails_closed(patrol, bumped_repo, monkeypatch):
    """No gitlink info -> every raw hit stays critical (never swallowed)."""
    parent, stale, s1, s2 = bumped_repo
    _store_manifest(stale)
    monkeypatch.setattr(sweep, "_gitlink_pointer", lambda repo_root: "")

    findings = sweep.check_redline(str(parent), dry_run=True)

    rules = sorted(_critical_rules(findings))
    assert rules == ["REDLINE_DELETED", "REDLINE_MODIFIED", "REDLINE_NEW"]
    assert not [f for f in findings if f["rule_id"] == "REDLINE_BASELINE_RESET"]


def test_git_blob_sha_matches_hash_object(bumped_repo, tmp_path):
    """_git_blob_sha oracle: agrees with `git hash-object`."""
    parent, _stale, _s1, _s2 = bumped_repo
    probe = tmp_path / "probe.txt"
    _write(str(probe), A2)

    expected = _git_out("hash-object", str(probe), cwd=parent)
    assert sweep._git_blob_sha(str(probe)) == expected


def test_git_blob_sha_unreadable_file_is_empty(tmp_path):
    assert sweep._git_blob_sha(str(tmp_path / "missing.txt")) == ""


def test_compute_manifest_excludes_git_pointer_file(tmp_path):
    """HIGH-1 (SEE-1289): the submodule .git pointer file is plumbing, not
    addon content, and must not enter the manifest."""
    repo = tmp_path / "repo"
    addon = repo / "addons" / "godot_mcp"
    _write(str(addon / "x.txt"), "x\n")
    _write(str(addon / ".git"), "gitdir: /somewhere\n")

    manifest = sweep.compute_redline_manifest(str(repo))

    assert list(manifest) == ["addons/godot_mcp/x.txt"]


# ---------------------------------------------------------------------------
# LOW fix: the pointer sidecar is audit bookkeeping, never a message-input
# dependency — the reset message must not branch on a (possibly absent)
# sidecar read.
# ---------------------------------------------------------------------------


def test_reset_message_does_not_depend_on_sidecar(patrol, bumped_repo):
    """Absent sidecar and stale sidecar both yield a reset message naming the
    pinned gitlink; the sidecar read can no longer change the message."""
    parent, stale, s1, s2 = bumped_repo

    # Absent sidecar (no prior state at all).
    _store_manifest(stale)
    absent_msg = [
        f["message"]
        for f in sweep.check_redline(str(parent), dry_run=True)
        if f["rule_id"] == "REDLINE_BASELINE_RESET"
    ][0]
    assert s2[:12] in absent_msg

    # Stale sidecar recording the pre-bump pointer s1: the message must stay
    # byte-identical — a sidecar condition cannot leak into the message.
    _store_manifest(stale)
    with open(sweep.REDLINE_POINTER_FILE, "w", encoding="utf-8") as f:
        json.dump({"pointer": s1, "generated_at": "2026-09-12T00:00:00+00:00"}, f)
    stale_msg = [
        f["message"]
        for f in sweep.check_redline(str(parent), dry_run=True)
        if f["rule_id"] == "REDLINE_BASELINE_RESET"
    ][0]
    assert stale_msg == absent_msg


def test_reset_still_updates_sidecar_as_bookkeeping(patrol, bumped_repo):
    """Sidecar write survives the simplification: it records the gitlink at
    manifest (re)generation time for audit, first-run and reset alike."""
    parent, stale, s1, s2 = bumped_repo
    _store_manifest(stale)

    sweep.check_redline(str(parent), dry_run=False)

    pointer = json.loads(_read(sweep.REDLINE_POINTER_FILE))
    assert pointer["pointer"] == s2
