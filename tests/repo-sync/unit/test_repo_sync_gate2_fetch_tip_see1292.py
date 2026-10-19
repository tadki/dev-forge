"""SEE-1292 e2e: gate2 false-dangling fix — fetch-tip-before-ancestry-reprobe.

Owner directive (2026-09-12 23:47Z): real e2e across the regular workflow
shapes before proceeding. All scenarios run REAL git operations against local
bare remotes (fixture pattern reused from the SEE-1285 hardener); no mocks
except E5/E6 transport failures which are modeled by unreachable/broken URLs.

Scenario map (E1..E6) — see the report comment on SEE-1292.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

# SEE-1381 §SPEC-016: repo root from file location (CI has no /mnt/d mount).
REPO_SYNC_DIR = str(Path(__file__).resolve().parents[2] / "repo-sync")
sys.path.insert(0, REPO_SYNC_DIR)

from repo_sync import _sha_reachable_via_tips  # noqa: E402


def _g(cwd: str, args: list[str], check: bool = False) -> subprocess.CompletedProcess:
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise AssertionError(f"git {args} failed in {cwd}: {r.stderr}")
    return r


def build_fixture(d: str, *, squash_landing: bool) -> dict:
    """Bare child remote with c0←c1 (+ optional squashed landing c2'), parent
    pinned at c0 with the child worktree materialized ONLY up to its pin.

    squash_landing=True models the production case: the remote main tip is a
    squash commit (new root, unrelated history to c0/c1) that is NOT in the
    child's local object store.
    """
    sub = os.path.join(d, "sub.git"); os.makedirs(sub)
    _g(sub, ["init", "--bare", "-b", "master"], check=True)
    seed = os.path.join(d, "seed"); os.makedirs(seed)
    _g(seed, ["init", "-b", "master"], check=True)
    _g(seed, ["config", "user.email", "t@t.com"])
    _g(seed, ["config", "user.name", "T"])

    def commit(name: str) -> str:
        Path(seed, name).write_text(f"{name}\n")
        _g(seed, ["add", "."], check=True)
        _g(seed, ["commit", "-m", name], check=True)
        return _g(seed, ["rev-parse", "HEAD"]).stdout.strip()

    sha0 = commit("c0")
    head = commit("c1")
    _g(seed, ["remote", "add", "origin", sub], check=True)
    _g(seed, ["push", "origin", "master:refs/heads/master"], check=True)

    landing = head
    if squash_landing:
        # Production shape (SEE-1292): the fork main receives PR squash-merges,
        # so the new remote tip IS a true descendant of the pinned sha (linear
        # history) but its commit object exists only on the remote — the child
        # worktree's last materialize predates it. Build that descendant in a
        # second clone (its own object store), push it, and leave the child's
        # local store WITHOUT it.
        sq = os.path.join(d, "squash"); os.makedirs(sq)
        _g(sq, ["clone", "--quiet", sub, sq], check=True)
        _g(sq, ["config", "user.email", "t@t.com"])
        _g(sq, ["config", "user.name", "T"])
        Path(sq, "c2").write_text("c2\n")
        _g(sq, ["add", "."], check=True)
        _g(sq, ["commit", "-m", "c2 (squash-landed PR)"], check=True)
        landing = _g(sq, ["rev-parse", "HEAD"]).stdout.strip()
        _g(sq, ["push", "origin", "master:refs/heads/master"], check=True)

    parent = os.path.join(d, "parent"); os.makedirs(parent)
    _g(parent, ["init", "-b", "master"], check=True)
    _g(parent, ["config", "user.email", "t@t.com"])
    _g(parent, ["config", "user.name", "T"])
    Path(parent, "p").write_text("p\n")
    _g(parent, ["add", "."], check=True)
    _g(parent, ["commit", "-m", "p"], check=True)
    cw = os.path.join(parent, "vendor", "sub")
    os.makedirs(cw)
    _g(cw, ["init"], check=True)
    _g(cw, ["remote", "add", "origin", sub], check=True)
    # Production shape: child materialized at the OLD pin; remote master has
    # moved on (squash-rewrite). Fetch must be pinned to the old tip — a full
    # `fetch origin` would follow the rewritten master and pull the landing
    # commit, defeating the scenario.
    _g(cw, ["fetch", "origin", f"{sha0}:refs/remotes/origin/pin"], check=True)
    _g(cw, ["checkout", "--detach", sha0], check=True)
    _g(parent, ["add", "vendor/sub"], check=True)

    return {
        "sub": sub, "seed": seed, "parent": parent, "cw": cw,
        "pinned": sha0, "head": head, "landing": landing,
    }


def test_e1_squash_landing_not_in_child_store():
    """Production repro: new remote tip (squash commit) absent from child's
    object store → fix must fetch the tip and answer True; pre-fix answer
    was False (false-dangling)."""
    import tempfile
    d = tempfile.mkdtemp(prefix="see1292-e1-")
    fx = build_fixture(d, squash_landing=True)
    # Sanity: landing commit absent from child store pre-check.
    r = _g(fx["cw"], ["cat-file", "-t", fx["landing"]])
    assert r.returncode != 0, "fixture broken: landing already local"
    got = _sha_reachable_via_tips(
        fx["cw"], fx["sub"], fx["pinned"], 30)
    assert got is True, "E1 FAIL: squash-landing tip misjudged as dangling"


def test_e2_genuine_dangling_stays_false():
    import tempfile
    d = tempfile.mkdtemp(prefix="see1292-e2-")
    fx = build_fixture(d, squash_landing=False)
    orphan = os.path.join(d, "orphan"); os.makedirs(orphan)
    _g(orphan, ["init", "-b", "master"], check=True)
    _g(orphan, ["config", "user.email", "t@t.com"])
    _g(orphan, ["config", "user.name", "T"])
    Path(orphan, "x").write_text("x\n")
    _g(orphan, ["add", "."], check=True)
    _g(orphan, ["commit", "-m", "orphan"], check=True)
    orphan_sha = _g(orphan, ["rev-parse", "HEAD"]).stdout.strip()
    got = _sha_reachable_via_tips(fx["cw"], fx["sub"], orphan_sha, 30)
    assert got is False, "E2 FAIL: dangling sha must stay fail-close"


def test_e3_fast_forward_tip():
    import tempfile
    d = tempfile.mkdtemp(prefix="see1292-e3-")
    fx = build_fixture(d, squash_landing=False)
    # Advance remote by one more commit on top of c1.
    _g(fx["seed"], ["checkout", "-q", "master"], check=True)
    Path(fx["seed"], "c2").write_text("c2\n")
    _g(fx["seed"], ["add", "."], check=True)
    _g(fx["seed"], ["commit", "-m", "c2"], check=True)
    new_head = _g(fx["seed"], ["rev-parse", "HEAD"]).stdout.strip()
    _g(fx["seed"], ["push", "origin", "master:refs/heads/master"], check=True)
    got = _sha_reachable_via_tips(fx["cw"], fx["sub"], fx["pinned"], 30)
    assert got is True, "E3 FAIL: ff tip broke reachability"
    assert new_head != fx["head"]


def test_e4_tip_equals_sha():
    import tempfile
    d = tempfile.mkdtemp(prefix="see1292-e4-")
    fx = build_fixture(d, squash_landing=False)
    got = _sha_reachable_via_tips(fx["cw"], fx["sub"], fx["head"], 30)
    assert got is True, "E4 FAIL: tip==sha case broke"


def test_e5_unreachable_remote_stays_open():
    import tempfile
    d = tempfile.mkdtemp(prefix="see1292-e5-")
    fx = build_fixture(d, squash_landing=False)
    got = _sha_reachable_via_tips(
        fx["cw"], "https://invalid.invalid/nope.git", fx["pinned"], 10)
    assert got is True, "E5 FAIL: unreachable remote must not be a dangling verdict"


def test_e6_fetch_tip_failure_stays_fail_close():
    import tempfile
    d = tempfile.mkdtemp(prefix="see1292-e6-")
    fx = build_fixture(d, squash_landing=True)
    # Corrupt the bare remote's alternates-free object for landing? Instead:
    # point reachability at a URL that serves ls-remote but rejects fetch —
    # emulate with a local http-less trick: use a bare repo whose master we
    # then strip via replace? Simplest real-world shape: make url a directory
    # that ls-remote can read but fetch of the tip cannot complete (dangling
    # tip in remote is not servable). Use a SECOND bare remote for ls-remote
    # that contains a ref pointing to an object it does not serve.
    ghost = os.path.join(d, "ghost.git"); os.makedirs(ghost)
    _g(ghost, ["init", "--bare", "-b", "master"], check=True)
    # Plant a ref to an object the repo cannot serve: push from a repo then
    # delete the object is not possible for bare; instead use a ref file to a
    # fabricated sha (allowed: refs are plain files).
    fake_sha = "1" * 40
    with open(os.path.join(ghost, "refs", "heads", "master"), "w") as f:
        f.write(fake_sha + "\n")
    got = _sha_reachable_via_tips(fx["cw"], ghost, fx["pinned"], 30)
    # ls-remote lists fake tip; fetch fails → per fix, fetch failure → fail-close.
    assert got is False, "E6 FAIL: fetch-tip failure must stay fail-close"
