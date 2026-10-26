"""Regression tests for SEE-1473: local_repo_check.py workspace-root
resolution collapse + orphan-branch '+' marker pollution.

Defect A (§SPEC-001): _default_workspace_root() rule 1 accepted any existing
$MULTICA_WORKSPACES_ROOT/<ws_id> directory, so the legacy leftover directory
short-circuited resolution even though the live platform root is the migrated
``seed-<last-12-of-ws_id>`` layout (SEE-1472 forensics: 71 real worktrees
scanned as 1). Pinned here:
  - a legacy-layout candidate must never outrank the current seed layout,
    even when it holds stale slot markers;
  - a hollow candidate (no task slots) must not short-circuit resolution;
  - rule 1 still accepts a candidate that really holds task slots;
  - the rule-2 walk-up honors the documented ``workdir/`` slot marker.

Defect B (§SPEC-002): agent/* branch listing painted git position markers
(``+`` for branches checked out in a linked worktree) that survived the old
``lstrip("* ")`` and made every worktree-attached branch look orphaned
(production: 44 false orphans, cleanup permanently 0). Pinned here with a
real bare-repo sandbox: one attached branch + one true orphan, asserted in
dry-run (list only) and non-dry-run (list + cleaned == 1).

Safety: every git write happens inside pytest tmp_path sandboxes; the script
is invoked with MULTICA_WORKSPACE_ID stripped and MULTICA_BARE_REPOS_ROOT
pointed at the sandbox, and the sandbox tests assert the resolved bare_repo
stays inside the sandbox — no production repo can ever be resolved.
"""

import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

SCRIPT = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "autopilots", "local_repo_check.py"
))

# id-shaped ws_id whose last 12 chars ("123456789abc") drive the seed- name
WS_ID = "dead0000-0000-0000-0000-123456789abc"
SEED_ROOT_NAME = "seed-123456789abc"


def _import_lrc():
    import local_repo_check as lrc
    return lrc


def _make_slot(parent, name="slot1", with_meta=True, with_workdir=True):
    """Create a task-slot directory carrying the marker files the resolver
    looks for (mirrors the Multica slot layout: .gc_meta.json and/or workdir/)."""
    slot = parent / name
    slot.mkdir(parents=True)
    if with_meta:
        (slot / ".gc_meta.json").write_text('{"issue_id": ""}', encoding="utf-8")
    if with_workdir:
        (slot / "workdir").mkdir()
    return slot


# ---------------------------------------------------------------------------
# Defect A: workspace root resolution (SEE-1473 §SPEC-001)
# ---------------------------------------------------------------------------


class TestWorkspaceRootResolution:
    @pytest.fixture(autouse=True)
    def _ws_env(self, monkeypatch, tmp_path):
        self.fake_root = tmp_path / "workspaces"
        self.fake_root.mkdir()
        self.legacy = self.fake_root / WS_ID
        self.current = self.fake_root / SEED_ROOT_NAME
        monkeypatch.setenv("MULTICA_WORKSPACES_ROOT", str(self.fake_root))
        monkeypatch.setenv("MULTICA_WORKSPACE_ID", WS_ID)
        self.monkeypatch = monkeypatch

    def test_legacy_layout_never_outranks_current_seed_layout(self):
        """Mirror of the real machine state (SEE-1472): the legacy <ws_id>
        directory still exists and even holds a stale slot with full markers,
        while live slots live under the seed-<last12> root. The legacy
        leftover must not win; resolution must hit the current layout."""
        _make_slot(self.legacy, "5d621003")
        _make_slot(self.current, "see-0001")
        resolved = _import_lrc()._default_workspace_root()
        assert resolved == str(self.current)
        assert resolved != str(self.legacy)

    def test_hollow_legacy_dir_does_not_short_circuit(self):
        """A candidate that merely exists (no task slots at all) must not
        short-circuit resolution — rule 2 gets its chance instead."""
        (self.legacy / "junk").mkdir(parents=True)
        resolved = _import_lrc()._default_workspace_root()
        assert resolved != str(self.legacy)

    def test_rule1_still_accepts_candidate_with_task_slots(self):
        """Non-regression: a legacy-layout candidate with real slots remains
        valid when no current-layout root exists."""
        _make_slot(self.legacy, "slot1")
        resolved = _import_lrc()._default_workspace_root()
        assert resolved == str(self.legacy)

    def test_rule2_walkup_accepts_workdir_marker(self):
        """Rule 2 must honor the documented workdir/ slot marker. Live-machine
        evidence (this checkout lives in <seed-root>/<slot>/workdir/<repo>):
        with rule 1 hollowed out, walk-up still finds the real seed root."""
        real_seed = os.path.expanduser("~/multica_workspaces/seed-478690824e46")
        if not os.path.isdir(real_seed):
            pytest.skip("real seed workspace root not available")
        self.monkeypatch.setenv("MULTICA_WORKSPACES_ROOT", "/nonexistent-root")
        resolved = _import_lrc()._default_workspace_root()
        assert resolved == real_seed

    def test_rule3_returns_empty_when_nothing_matches(self, tmp_path, monkeypatch):
        """Script deployed outside any slot chain (e.g. a bare main clone):
        rule 1 misses and rule 2 walks to the filesystem root without a hit,
        so resolution must fail fast with an empty string."""
        monkeypatch.setenv("MULTICA_WORKSPACES_ROOT", "/nonexistent-root")
        fake_script = tmp_path / "deploy" / "autopilots" / "local_repo_check.py"
        monkeypatch.setattr(_import_lrc(), "__file__", str(fake_script))
        assert _import_lrc()._default_workspace_root() == ""

    def test_rule2_walkup_breaks_at_filesystem_root(self, monkeypatch):
        """Walk-up starting near the filesystem root must terminate via the
        parent==cursor guard instead of looping forever."""
        monkeypatch.setenv("MULTICA_WORKSPACES_ROOT", "/nonexistent-root")
        monkeypatch.setattr(_import_lrc(), "__file__", "/x/autopilots/lrc.py")
        assert _import_lrc()._default_workspace_root() == ""


@pytest.mark.skipif(
    not hasattr(_import_lrc(), "_has_task_slots"),
    reason="_has_task_slots helper introduced with the SEE-1473 fix",
)
class TestHasTaskSlotsMarkerMatrix:
    """Direct unit coverage of the rule-1 candidate validation."""

    def test_marker_matrix(self, tmp_path):
        lrc = _import_lrc()
        missing = tmp_path / "missing"
        assert lrc._has_task_slots(str(missing)) is False

        root = tmp_path / "root"
        root.mkdir()
        assert lrc._has_task_slots(str(root)) is False

        _make_slot(root, "s1", with_meta=False)  # workdir/ marker only
        assert lrc._has_task_slots(str(root)) is True

        root2 = tmp_path / "root2"
        root2.mkdir()
        _make_slot(root2, "s2", with_workdir=False)  # .gc_meta.json marker only
        assert lrc._has_task_slots(str(root2)) is True

        plain = tmp_path / "plain"
        plain.mkdir()
        (plain / "file.txt").write_text("x", encoding="utf-8")
        assert lrc._has_task_slots(str(plain)) is False


# ---------------------------------------------------------------------------
# Defect B: orphan branch '+' marker pollution (SEE-1473 §SPEC-002)
# ---------------------------------------------------------------------------


def _git(*args, cwd=None):
    return subprocess.run(
        ["git", *args], cwd=str(cwd) if cwd else None, check=True,
        capture_output=True, text=True, timeout=30,
    )


def _bare_branches(bare):
    out = _git("branch", "--list", "agent/*", "--format=%(refname:short)",
               cwd=bare).stdout
    return set(out.split())


def _build_orphan_sandbox(tmp_path):
    """Bare-repo sandbox where agent/test/attached is checked out in a linked
    worktree (git paints it '+') and agent/test/orphan is a true orphan.
    Returns (sandbox_dir, bare, ws_root); ws_root is empty so the scan phase
    has nothing to delete and Phase 2 goes down the silent path."""
    sandbox_dir = tmp_path / "see1473"
    bare_root = sandbox_dir / "bareroot" / "wsbox"
    bare_root.mkdir(parents=True)
    bare = bare_root / "origin.git"
    _git("init", "-q", "--bare", bare)

    seed = sandbox_dir / "seed"
    _git("init", "-q", seed)
    _git("remote", "add", "origin", str(bare), cwd=seed)
    _git("commit", "--allow-empty", "-q", "-m", "init", cwd=seed)
    _git("branch", "agent/test/attached", cwd=seed)
    _git("push", "-q", "origin", "agent/test/attached", cwd=seed)
    _git("branch", "agent/test/orphan", cwd=seed)
    _git("push", "-q", "origin", "agent/test/orphan", cwd=seed)
    _git("worktree", "add", str(sandbox_dir / "wt-attached"),
         "agent/test/attached", cwd=bare)

    ws_root = sandbox_dir / "wsbox"
    ws_root.mkdir()
    return sandbox_dir, bare, ws_root


class TestOrphanBranchPlusMarker:
    """Bare-repo sandbox: agent/test/attached is checked out in a linked
    worktree (git paints it '+'), agent/test/orphan is a true orphan."""

    @pytest.fixture
    def sandbox(self, tmp_path):
        sandbox_dir, bare, ws_root = _build_orphan_sandbox(tmp_path)
        return {"dir": str(sandbox_dir), "bare": str(bare), "ws_root": str(ws_root)}

    def _run(self, sandbox, *extra_args):
        env = os.environ.copy()
        # Safety rails: ws_id falls back to basename(ws_root)="wsbox", so the
        # bare-repo fallback resolves <sandbox>/bareroot/wsbox — never any
        # production repo (the legacy default path needs the live ws_id env).
        env.pop("MULTICA_WORKSPACE_ID", None)
        env["MULTICA_BARE_REPOS_ROOT"] = str(
            os.path.join(os.path.dirname(sandbox["ws_root"]), "bareroot")
        )
        env["EXECUTION_ISSUE_ID"] = ""
        env["PYTHONPATH"] = os.path.dirname(SCRIPT)
        return subprocess.run(
            [sys.executable, SCRIPT,
             "--workspace-root", sandbox["ws_root"], *extra_args],
            env=env, capture_output=True, text=True, timeout=60,
        )

    def test_dry_run_orphan_list_only_true_orphans(self, sandbox):
        result = self._run(sandbox, "--dry-run")
        assert result.returncode == 0, result.stderr
        data = json.loads(result.stdout)
        assert data["bare_repo"], "bare repo must resolve inside the sandbox"
        assert data["bare_repo"].startswith(sandbox["dir"]), data["bare_repo"]
        # The '+'-painted attached branch must NOT be misjudged as orphan.
        assert data["orphan_branches_list"] == ["agent/test/orphan"]
        # Dry-run suppressed indicator contract (SEE-1224 #4) preserved.
        assert data["orphan_branches_cleaned"] == -1
        # Dry-run must not touch any branch.
        assert _bare_branches(sandbox["bare"]) == {
            "agent/test/attached", "agent/test/orphan",
        }

    def test_non_dry_run_cleans_only_true_orphan(self, sandbox):
        result = self._run(sandbox, "--kill-switch", "false")
        assert result.returncode == 0, result.stderr
        data = json.loads(result.stdout)
        assert data["bare_repo"].startswith(sandbox["dir"]), data["bare_repo"]
        assert data["orphan_branches_list"] == ["agent/test/orphan"]
        assert data["orphan_branches_cleaned"] == 1
        # The true orphan is gone; the worktree-attached branch survives.
        assert "agent/test/orphan" not in _bare_branches(sandbox["bare"])
        assert "agent/test/attached" in _bare_branches(sandbox["bare"])
        wt_attached = os.path.join(sandbox["dir"], "wt-attached")
        assert os.path.isdir(wt_attached), "attached worktree must be untouched"


@pytest.mark.skipif(
    not hasattr(_import_lrc(), "_list_agent_branches"),
    reason="_list_agent_branches helper introduced with the SEE-1473 fix",
)
class TestListAgentBranchesInProcess:
    """In-process coverage of the marker-free branch listing: the '+-painted'
    attached branch must come back as a clean short name."""

    def test_returns_clean_short_names_for_attached_and_orphan(self, tmp_path):
        _, bare, _ = _build_orphan_sandbox(tmp_path)
        branches = _import_lrc()._list_agent_branches(str(bare))
        assert branches == ["agent/test/attached", "agent/test/orphan"]

    def test_empty_bare_repo_returns_empty_list(self, tmp_path):
        bare = tmp_path / "empty.git"
        _git("init", "-q", "--bare", bare)
        assert _import_lrc()._list_agent_branches(str(bare)) == []
