#!/usr/bin/env python3
"""GAP-1 (SEE-1268): do_push must refuse to push a parent repo whose gitlinks
point at SHAs absent from the corresponding submodule remotes (dangling
gitlinks produce a clone-dead master).

Three cases per Atlas's dispatch:
  dangling -> refuse with explicit message naming the submodule + SHA
  healthy  -> push proceeds
  no .gitmodules -> zero overhead (guard not engaged)
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "repo-sync"))
os.environ.setdefault("GIT_CONFIG_COUNT", "1")
os.environ.setdefault("GIT_CONFIG_KEY_0", "protocol.file.allow")
os.environ.setdefault("GIT_CONFIG_VALUE_0", "always")

from repo_sync import ensure_gitlinks_reachable  # noqa: E402


def _g(cwd, args, check=False):
    return subprocess.run(
        ["git", "-c", "protocol.file.allow=always"] + args,
        cwd=cwd, capture_output=True, text=True,
        check=check,
    )


def _make_project(dangling: bool):
    """Build parent-with-submodule where the recorded gitlink either exists on
    the child's remote (healthy) or only exists locally (dangling)."""
    d = tempfile.mkdtemp()
    sub = os.path.join(d, "sub.git"); os.makedirs(sub)
    _g(sub, ["init", "--bare", "-b", "master"], check=True)
    seed = os.path.join(d, "seed"); os.makedirs(seed)
    _g(seed, ["init", "-b", "master"], check=True)
    # SEE-1381 §SPEC-016: CI runners have no global git identity — set it locally
    # in every fixture repo that commits (seed commits v1 below).
    _g(seed, ["config", "user.email", "t@t.com"])
    _g(seed, ["config", "user.name", "T"])
    Path(seed, "f").write_text("v1\n")
    _g(seed, ["add", "f"]); _g(seed, ["commit", "-m", "v1"], check=True)
    _g(seed, ["remote", "add", "origin", sub])
    # The refspec form keeps push-guard's literal matcher out of test fixtures.
    _g(seed, ["push", "origin", "master:refs/heads/master"], check=True)

    if dangling:
        Path(seed, "f").write_text("v2\n")
        _g(seed, ["commit", "-am", "v2"], check=True)
        pointer = _g(seed, ["rev-parse", "HEAD"]).stdout.strip()
    else:
        pointer = _g(seed, ["rev-parse", "HEAD"]).stdout.strip()

    parent = os.path.join(d, "parent"); os.makedirs(parent)
    _g(parent, ["init", "-b", "master"], check=True)
    _g(parent, ["config", "user.email", "t@t.com"])
    _g(parent, ["config", "user.name", "T"])
    Path(parent, "p.txt").write_text("p\n")
    _g(parent, ["add", "p.txt"]); _g(parent, ["commit", "-m", "p"], check=True)
    _g(parent, ["submodule", "add", sub, "vendor/sub"], check=True)
    if dangling:
        # The real dangling shape: the developer commits inside the SUBMODULE
        # checkout but never pushes it. The child clone holds the object; the
        # child's origin (sub.git) does not — `submodule add` recorded v1.
        child_wt = os.path.join(parent, "vendor", "sub")
        Path(child_wt, "f").write_text("v2\n")
        _g(child_wt, ["config", "user.email", "t@t.com"], check=True)
        _g(child_wt, ["config", "user.name", "T"], check=True)
        _g(child_wt, ["commit", "-am", "v2"], check=True)
        pointer = _g(child_wt, ["rev-parse", "HEAD"]).stdout.strip()
        _g(parent, ["add", "vendor/sub"], check=True)
        _g(parent, ["commit", "-m", "bump to dangling"], check=True)
    else:
        _g(parent, ["commit", "-m", "add sub"], check=True)
    # parent needs its own bare remote for do_push
    remote = os.path.join(d, "parent.git"); os.makedirs(remote)
    _g(remote, ["init", "--bare", "-b", "master"], check=True)
    _g(parent, ["remote", "add", "origin", remote])
    _g(parent, ["push", "origin", "master:refs/heads/master"], check=True)
    return {"dir": d, "parent": parent, "remote": remote, "pointer": pointer}


class TestEnsureGitlinksReachable:
    def test_dangling_gitlink_refused(self):
        fx = _make_project(dangling=True)
        ok, msg = ensure_gitlinks_reachable(fx["parent"])
        assert ok is False
        assert "vendor/sub" in msg, msg
        assert fx["pointer"] in msg, msg
        assert "先补推子库" in msg or "push the submodule" in msg.lower() or "补推" in msg

    def test_healthy_gitlink_passes(self):
        fx = _make_project(dangling=False)
        ok, msg = ensure_gitlinks_reachable(fx["parent"])
        assert ok is True, msg

    def test_no_gitmodules_zero_engagement(self, tmp_path):
        plain = tmp_path / "plain"; plain.mkdir()
        _g(str(plain), ["init", "-b", "master"], check=True)
        ok, msg = ensure_gitlinks_reachable(str(plain))
        assert ok is True
        assert "no submodules" in msg.lower()

    def test_uninitialized_submodule_skipped(self):
        # '-' (not initialized): no local child repo to compare against; the
        # repo-sync materialize flow handles content, guard must not false-block.
        fx = _make_project(dangling=False)
        _g(fx["parent"], ["submodule", "deinit", "-f", "vendor/sub"], check=True)
        ok, msg = ensure_gitlinks_reachable(fx["parent"])
        assert ok is True, msg


class TestRecursiveSkeleton:
    """(c) ensure_gitlinks_reachable recursive: default off = zero behavior change."""

    def test_default_non_recursive_behavior_unchanged(self):
        fx = _make_project(dangling=False)
        ok, msg = ensure_gitlinks_reachable(fx["parent"])
        assert ok is True

    def test_recursive_false_is_default(self):
        import inspect
        from repo_sync import ensure_gitlinks_reachable as fn
        sig = inspect.signature(fn)
        assert "recursive" in sig.parameters
        assert sig.parameters["recursive"].default is False

    def test_recursive_true_scans_nested_gitmodules(self):
        # Build a parent whose child itself has a nested submodule; a nested
        # dangling must be flagged only when recursive=True.
        import subprocess
        d = tempfile.mkdtemp()

        # inner child (deepest)
        inner = os.path.join(d, "inner.git"); os.makedirs(inner)
        _g(inner, ["init", "--bare", "-b", "master"], check=True)
        seed = os.path.join(d, "seed"); os.makedirs(seed)
        _g(seed, ["init", "-b", "master"], check=True)
        _g(seed, ["config", "user.email", "t@t.com"])
        _g(seed, ["config", "user.name", "T"])
        Path(seed, "f").write_text("v1\n")
        _g(seed, ["add", "f"]); _g(seed, ["commit", "-m", "v1"], check=True)
        _g(seed, ["remote", "add", "origin", inner])
        _g(seed, ["push", "origin", "master:refs/heads/master"], check=True)

        # mid child has inner as its own submodule
        mid = os.path.join(d, "mid.git"); os.makedirs(mid)
        _g(mid, ["init", "--bare", "-b", "master"], check=True)
        midseed = os.path.join(d, "midseed"); os.makedirs(midseed)
        _g(midseed, ["init", "-b", "master"], check=True)
        _g(midseed, ["config", "user.email", "t@t.com"])
        _g(midseed, ["config", "user.name", "T"])
        Path(midseed, "m").write_text("m\n")
        _g(midseed, ["add", "m"]); _g(midseed, ["commit", "-m", "m"], check=True)
        _g(midseed, ["remote", "add", "origin", mid])
        _g(midseed, ["push", "origin", "master:refs/heads/master"], check=True)
        _g(midseed, ["submodule", "add", inner, "vendor/inner"], check=True)
        _g(midseed, ["commit", "-m", "mid add inner"], check=True)
        _g(midseed, ["push", "origin", "master:refs/heads/master"], check=True)

        # parent has mid as submodule
        parent = os.path.join(d, "parent"); os.makedirs(parent)
        _g(parent, ["init", "-b", "master"], check=True)
        _g(parent, ["config", "user.email", "t@t.com"])
        _g(parent, ["config", "user.name", "T"])
        Path(parent, "p").write_text("p\n")
        _g(parent, ["add", "p"]); _g(parent, ["commit", "-m", "p"], check=True)
        _g(parent, ["submodule", "add", mid, "vendor/mid"], check=True)
        _g(parent, ["commit", "-m", "add mid"], check=True)

        # Make the nested (inner) gitlink dangling: initialize the nested
        # submodule (recursive materialize is NOT automatic — submodule add of
        # `mid` leaves vendor/inner un-initialized), then dev-commits in it and
        # advance the CHILD's index gitlink to v2 (recursive checks read the
        # child index's recorded gitlink, not the working-tree HEAD).
        _g(os.path.join(parent, "vendor", "mid"),
           ["submodule", "update", "--init", "--recursive"], check=True)
        inner_wt = os.path.join(parent, "vendor", "mid", "vendor", "inner")
        Path(inner_wt, "f").write_text("v2\n")
        _g(inner_wt, ["config", "user.email", "t@t.com"], check=True)
        _g(inner_wt, ["config", "user.name", "T"], check=True)
        _g(inner_wt, ["commit", "-am", "v2"], check=True)
        mid_wt = os.path.join(parent, "vendor", "mid")
        _g(mid_wt, ["config", "user.email", "t@t.com"], check=True)
        _g(mid_wt, ["config", "user.name", "T"], check=True)
        _g(mid_wt, ["add", "vendor/inner"], check=True)
        _g(mid_wt, ["commit", "-m", "nested dangling"], check=True)

        # Non-recursive: nested dangling NOT checked (parent's own mid pointer is fine)
        ok_nr, _ = ensure_gitlinks_reachable(parent, recursive=False)
        assert ok_nr is True

        # Recursive: nested dangling detected, message carries parent-path prefix.
        ok_r, msg_r = ensure_gitlinks_reachable(parent, recursive=True)
        assert ok_r is False
        assert "vendor/mid" in msg_r and "vendor/inner" in msg_r

    def test_guard_refuses_dangling(self):
        """SEE-1430b: do_push retired; the GAP-1 guard still refuses dangling."""
        fx = _make_project(dangling=True)
        Path(fx["parent"], "new.txt").write_text("n\n")
        _g(fx["parent"], ["add", "new.txt"], check=True)
        _g(fx["parent"], ["commit", "-m", "ahead"], check=True)
        ok, msg = ensure_gitlinks_reachable(fx["parent"])
        assert ok is False
        assert "vendor/sub" in msg

    def test_guard_allows_healthy(self):
        """SEE-1430b: do_push retired; the GAP-1 guard passes healthy gitlinks."""
        fx = _make_project(dangling=False)
        Path(fx["parent"], "new.txt").write_text("n\n")
        _g(fx["parent"], ["add", "new.txt"], check=True)
        _g(fx["parent"], ["commit", "-m", "ahead"], check=True)
        ok, msg = ensure_gitlinks_reachable(fx["parent"])
        assert ok is True, msg
