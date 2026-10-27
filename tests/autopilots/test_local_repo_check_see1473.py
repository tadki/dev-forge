"""Regression tests for SEE-1473: local_repo_check.py workspace-root
resolution collapse + orphan-branch '+' marker pollution.

Defect A (§SPEC-001): _default_workspace_root() rule 1 accepted any existing
$MULTICA_WORKSPACES_ROOT/<ws_id> directory, so the legacy leftover directory
short-circuited resolution while the live platform root held 71 real worktrees
scanned as 1 (SEE-1472 forensics). Pinned here:
  - a hollow candidate (no task slots) must not short-circuit resolution;
  - rule 1 still accepts a candidate that really holds task slots;
  - the rule-2 walk-up honors the documented ``workdir/`` slot marker.

R2 (§SPEC-009): resolution now prefers the daemon-injected env (Tier-0,
``MULTICA_TASK_CONFIG_ROOT`` two levels up under strict
``MULTICA_TASK_WORKSPACES_ROOT`` containment); the fallback chain keeps the
``$MULTICA_WORKSPACES_ROOT × $MULTICA_WORKSPACE_ID`` composition + walk-up,
and the R1 ``seed-<last-12>`` name-derivation candidate is retired (decoupling
directive: no hardcoded platform layout knowledge).

Defect B (§SPEC-002): agent/* branch listing painted git position markers
(``+`` for branches checked out in a linked worktree) that survived the old
``lstrip("* ")`` and made every worktree-attached branch look orphaned
(production: 44 false orphans, cleanup permanently 0). Pinned here with a
real bare-repo sandbox: one attached branch, one detached-HEAD worktree
(production reality — it must neither pollute nor protect any branch), one
true pushed orphan and one never-pushed orphan, asserted in dry-run (list
only) and non-dry-run (list + cleaned == 1); plus the empty-agent-branch
no-op contract (cleaned == 0) and the `*` current-branch-marker hygiene at
the helper level.

§SPEC-012: orphan cleanup triages by remote reachability — a never-pushed
orphan (no same-name remote ref, tip contained in no remote branch) is
retained and reported in ``orphan_branches_never_pushed`` instead of being
``branch -D``'d; pushed orphans clean as before.

Safety: every git write happens inside pytest tmp_path sandboxes; the script
is invoked with MULTICA_WORKSPACE_ID stripped and MULTICA_BARE_REPOS_ROOT
pointed at the sandbox, and the sandbox tests assert the resolved bare_repo
stays inside the sandbox — no production repo can ever be resolved.
"""

import json
import os
import shutil
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

SCRIPT = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "autopilots", "local_repo_check.py"
))

# id-shaped ws_id for the interface-composition fallback candidate
WS_ID = "dead0000-0000-0000-0000-123456789abc"


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
        # R2 Tier-0 isolation: this class pins the derived-chain behavior, so
        # the daemon-injected env (present in every agent run) must not
        # pre-empt resolution before the chain under test is reached.
        monkeypatch.delenv("MULTICA_TASK_CONFIG_ROOT", raising=False)
        monkeypatch.delenv("MULTICA_TASK_WORKSPACES_ROOT", raising=False)
        monkeypatch.setenv("MULTICA_WORKSPACES_ROOT", str(self.fake_root))
        monkeypatch.setenv("MULTICA_WORKSPACE_ID", WS_ID)
        self.monkeypatch = monkeypatch

    def test_hollow_legacy_dir_does_not_short_circuit(self):
        """A candidate that merely exists (no task slots at all) must not
        short-circuit resolution — rule 2 gets its chance instead. Pinned as
        a zero-influence equivalence: resolution with the hollow legacy dir
        present must be identical to resolution with it absent. Pre-fix code
        returned the hollow dir here; a resolution that collapses to ""
        instead must also fail this equivalence (it differs from the
        legacy-absent walk-up result)."""
        (self.legacy / "junk").mkdir(parents=True)
        with_hollow = _import_lrc()._default_workspace_root()
        shutil.rmtree(self.legacy)
        without_legacy = _import_lrc()._default_workspace_root()
        assert with_hollow == without_legacy
        assert with_hollow != str(self.legacy)

    def test_rule1_still_accepts_candidate_with_task_slots(self):
        """Non-regression: the $MULTICA_WORKSPACES_ROOT × $MULTICA_WORKSPACE_ID
        interface-composition candidate stays valid when it really holds task
        slots (the only rule-1 candidate since R2 retired the seed- name
        derivation)."""
        _make_slot(self.legacy, "slot1")
        resolved = _import_lrc()._default_workspace_root()
        assert resolved == str(self.legacy)

    def test_rule2_walkup_accepts_workdir_marker(self, tmp_path):
        """Rule 2 must honor the documented workdir/ slot marker. Pure-sandbox
        mirror of the real slot chain (<seed-root>/<slot>/workdir/<repo>): a
        slot carrying ONLY workdir/ (no .gc_meta.json — the state of any
        running slot) must still resolve, independent of where this checkout
        lives. Pre-fix walk-up only accepted .gc_meta.json and returned ""
        here (SEE-1473 defect A, rule-2 half)."""
        slot = tmp_path / "fake-seed-root" / "slot-1"
        slot.mkdir(parents=True)
        (slot / "workdir").mkdir()
        (slot / "workdir" / "repo").mkdir()
        fake_script = (
            slot / "workdir" / "repo" / "autopilots" / "local_repo_check.py"
        )
        self.monkeypatch.setenv("MULTICA_WORKSPACES_ROOT", "/nonexistent-root")
        self.monkeypatch.setattr(
            _import_lrc(), "__file__", str(fake_script)
        )
        resolved = _import_lrc()._default_workspace_root()
        assert resolved == str(tmp_path / "fake-seed-root")

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


class TestEnvInjectedTier0Resolution:
    """R2 §SPEC-009 three-state contract for the Tier-0 injected env:

    - hit: $MULTICA_TASK_CONFIG_ROOT two levels up wins, validated by
      $MULTICA_TASK_WORKSPACES_ROOT containment — even when the slot carries
      no derivation markers, so ONLY the env can resolve this root (this is
      the case that must fail RED against the R1 code at b4d443a);
    - missing: falls back to the existing derived chain, unchanged;
    - foreign: a value outside the workspaces base (including the
      sibling-prefix trick) is rejected and the chain decides instead."""

    @pytest.fixture(autouse=True)
    def _tier0_env(self, monkeypatch, tmp_path):
        self.base = tmp_path / "workspaces"
        self.base.mkdir()
        self.seed_root = self.base / "seed-cafe12345678"
        self.config = self.seed_root / "see-0001" / "multica-config"
        self.config.mkdir(parents=True)
        monkeypatch.setenv("MULTICA_TASK_WORKSPACES_ROOT", str(self.base))
        monkeypatch.setenv("MULTICA_TASK_CONFIG_ROOT", str(self.config))
        self.monkeypatch = monkeypatch

    def test_tier0_env_hit_resolves_two_levels_up(self):
        # Slot carries ONLY multica-config (no .gc_meta.json / workdir/), so
        # the derived chain cannot claim this root — Tier-0 must resolve it.
        resolved = _import_lrc()._default_workspace_root()
        assert resolved == str(self.seed_root)

    def test_tier0_env_missing_falls_back_to_derived_chain(self):
        self.monkeypatch.delenv("MULTICA_TASK_CONFIG_ROOT", raising=False)
        self.monkeypatch.delenv("MULTICA_TASK_WORKSPACES_ROOT", raising=False)
        self.monkeypatch.setenv("MULTICA_WORKSPACES_ROOT", str(self.base))
        # R2: the fallback candidate is the plain $WORKSPACES_ROOT × $WS_ID
        # interface composition — no seed- name derivation.
        ws_id_dir = self.base / "deadbeefcafe12345678"
        _make_slot(ws_id_dir, "slot2")
        self.monkeypatch.setenv("MULTICA_WORKSPACE_ID", "deadbeefcafe12345678")
        resolved = _import_lrc()._default_workspace_root()
        assert resolved == str(ws_id_dir)

    def test_tier0_foreign_value_rejected_falls_back_to_chain(self):
        # Foreign absolute value outside the base: rejected, the derived
        # chain (rule 1) decides — resolution must never return the foreign
        # root even though the env pointed there.
        self.monkeypatch.setenv(
            "MULTICA_TASK_CONFIG_ROOT", "/outside-domain/multica-config"
        )
        self.monkeypatch.delenv("MULTICA_WORKSPACE_ID", raising=False)
        self.monkeypatch.setenv("MULTICA_WORKSPACES_ROOT", str(self.base))
        self.monkeypatch.setattr(_import_lrc(), "__file__", "/x/autopilots/lrc.py")
        resolved = _import_lrc()._default_workspace_root()
        assert resolved != "/outside-domain"

    def test_tier0_sibling_prefix_base_rejected(self, tmp_path):
        # Containment boundary: a candidate under a sibling base sharing the
        # path prefix (<base>_evil) must NOT pass the containment check —
        # resolution falls through to the derived chain instead.
        evil_root = tmp_path / "workspaces_evil" / "seed-evil0000001"
        evil_config = evil_root / "slot" / "multica-config"
        evil_config.mkdir(parents=True)
        self.monkeypatch.setenv("MULTICA_TASK_CONFIG_ROOT", str(evil_config))
        resolved = _import_lrc()._default_workspace_root()
        assert resolved != str(evil_root)


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
    worktree (git paints it '+'), a detached-HEAD worktree exists (production
    reality: running slots hold detached worktrees), agent/test/orphan is a
    true pushed orphan, and agent/test/never-pushed is a never-pushed orphan
    (its tip is reachable from no remote ref — §SPEC-012 guard subject).
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
    init_sha = _git("rev-parse", "HEAD", cwd=seed).stdout.strip()
    _git("branch", "agent/test/attached", cwd=seed)
    _git("push", "-q", "origin", "agent/test/attached", cwd=seed)
    _git("branch", "agent/test/orphan", cwd=seed)
    _git("push", "-q", "origin", "agent/test/orphan", cwd=seed)
    _git("worktree", "add", str(sandbox_dir / "wt-attached"),
         "agent/test/attached", cwd=bare)
    _git("worktree", "add", "--detach", str(sandbox_dir / "wt-detached"),
         init_sha, cwd=bare)
    # Mirror pushed heads into refs/remotes/origin — a production bare
    # carries remote-tracking refs from its own upstream fetches, and the
    # §SPEC-012 triage reads exactly those. Must precede the never-pushed
    # plant so the mirror stays clean of it.
    _git("fetch", ".", "+refs/heads/*:refs/remotes/origin/*", cwd=bare)
    # Never-pushed orphan: a commit forged directly inside the bare via
    # commit-tree (so the object exists there) that no remote-tracking ref
    # can reach — branch -D on it would orphan the commit (§SPEC-012 hazard).
    init_tree = _git("rev-parse", "agent/test/orphan^{tree}", cwd=bare
                     ).stdout.strip()
    np_sha = _git("commit-tree", init_tree, "-p", init_sha, "-m", "local only",
                  cwd=bare).stdout.strip()
    _git("update-ref", "refs/heads/agent/test/never-pushed", np_sha, cwd=bare)

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
        # SEE-956 WorkspaceMutex lives at $MULTICA_HOME/autopilot_workspace.lock
        # (global): a concurrent patrol instance elsewhere on this machine
        # would stall these subprocess runs into their 60s timeout (false
        # failures). Pin MULTICA_HOME inside the sandbox so the lock — and
        # any other multica state the run touches — stays sandbox-local.
        env["MULTICA_HOME"] = os.path.join(sandbox["dir"], "multica-home")
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
        # Safety rail: exact containment — bare repo resolved inside the
        # sandbox, never a production repo (no sibling-prefix false pass).
        assert data["bare_repo"].startswith(sandbox["dir"] + os.sep), \
            data["bare_repo"]
        # The '+'-painted attached branch must NOT be misjudged as orphan;
        # the detached-HEAD worktree must neither pollute nor protect any
        # agent branch (it contributes no active branch name).
        assert data["orphan_branches_list"] == [
            "agent/test/never-pushed", "agent/test/orphan",
        ]
        # §SPEC-012: the never-pushed orphan is reported in its own field.
        assert data["orphan_branches_never_pushed"] == ["agent/test/never-pushed"]
        # Dry-run suppressed indicator contract (SEE-1224 #4) preserved.
        assert data["orphan_branches_cleaned"] == -1
        # Dry-run must not touch any branch.
        assert _bare_branches(sandbox["bare"]) == {
            "agent/test/attached", "agent/test/orphan", "agent/test/never-pushed",
        }

    def test_non_dry_run_cleans_only_true_orphan(self, sandbox):
        result = self._run(sandbox, "--kill-switch", "false")
        assert result.returncode == 0, result.stderr
        data = json.loads(result.stdout)
        assert data["bare_repo"].startswith(sandbox["dir"] + os.sep), \
            data["bare_repo"]
        assert data["orphan_branches_list"] == [
            "agent/test/never-pushed", "agent/test/orphan",
        ]
        # §SPEC-012 two-state contract: the pushed orphan is cleaned…
        assert data["orphan_branches_cleaned"] == 1
        assert "agent/test/orphan" not in _bare_branches(sandbox["bare"])
        # …while the never-pushed orphan is retained and reported.
        assert data["orphan_branches_never_pushed"] == ["agent/test/never-pushed"]
        assert "agent/test/never-pushed" in _bare_branches(sandbox["bare"])
        # The worktree-attached branch survives.
        assert "agent/test/attached" in _bare_branches(sandbox["bare"])
        wt_attached = os.path.join(sandbox["dir"], "wt-attached")
        assert os.path.isdir(wt_attached), "attached worktree must be untouched"
        wt_detached = os.path.join(sandbox["dir"], "wt-detached")
        assert os.path.isdir(wt_detached), \
            "detached-HEAD worktree must be untouched by orphan cleanup"

    def test_no_agent_branches_is_a_clean_noop(self, tmp_path):
        """Boundary: a bare repo whose branches are all non-agent must yield
        an empty orphan list and a cleaned == 0 no-op in non-dry-run (-1 is
        reserved for suppressed runs), with the ordinary branch untouched."""
        sandbox_dir, bare, ws_root = _build_orphan_sandbox(tmp_path)
        _git("branch", "main", "agent/test/orphan", cwd=bare)
        _git("worktree", "remove", str(sandbox_dir / "wt-attached"), cwd=bare)
        _git("branch", "-D", "agent/test/attached", cwd=bare)
        _git("branch", "-D", "agent/test/orphan", cwd=bare)
        _git("branch", "-D", "agent/test/never-pushed", cwd=bare)
        sandbox = {"dir": str(sandbox_dir), "bare": str(bare),
                   "ws_root": str(ws_root)}
        result = self._run(sandbox, "--kill-switch", "false")
        assert result.returncode == 0, result.stderr
        data = json.loads(result.stdout)
        assert data["orphan_branches_list"] == []
        assert data["orphan_branches_never_pushed"] == []
        assert data["orphan_branches_cleaned"] == 0
        all_branches = set(
            _git("branch", "--format=%(refname:short)", cwd=bare).stdout.split()
        )
        assert all_branches == {"main"}


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
        assert branches == [
            "agent/test/attached", "agent/test/never-pushed", "agent/test/orphan",
        ]

    def test_empty_bare_repo_returns_empty_list(self, tmp_path):
        bare = tmp_path / "empty.git"
        _git("init", "-q", "--bare", bare)
        assert _import_lrc()._list_agent_branches(str(bare)) == []

    def test_bare_head_on_agent_branch_yields_marker_free_names(self, tmp_path):
        """Boundary: bare-repo HEAD pointing at an agent/* branch is exactly
        the state where plain `git branch` paints the `*` current-branch
        marker — the --format listing must stay marker-free there too."""
        _, bare, _ = _build_orphan_sandbox(tmp_path)
        _git("symbolic-ref", "HEAD", "refs/heads/agent/test/attached",
             cwd=bare)
        assert _import_lrc()._list_agent_branches(str(bare)) == [
            "agent/test/attached", "agent/test/never-pushed", "agent/test/orphan",
        ]


@pytest.mark.skipif(
    not hasattr(_import_lrc(), "_orphan_remote_reachable"),
    reason="_orphan_remote_reachable helper introduced with §SPEC-012",
)
class TestOrphanRemoteReachable:
    """In-process coverage of the §SPEC-012 triage: an orphan is deletable
    only when its work has reached the remote (same-name ref, or tip contained
    in some remote branch); a never-pushed tip must classify as not reachable
    so the guard retains the branch."""

    def test_same_name_remote_ref_is_reachable(self, tmp_path):
        _, bare, _ = _build_orphan_sandbox(tmp_path)
        assert _import_lrc()._orphan_remote_reachable(
            str(bare), "agent/test/orphan") is True

    def test_tip_contained_in_remote_branch_is_reachable(self, tmp_path):
        # Merged-under-another-name shape (the agent/fronti/6f33d6adbe40
        # production case): branch at a commit that origin already carries.
        _, bare, _ = _build_orphan_sandbox(tmp_path)
        init_sha = _git("rev-parse", "refs/heads/agent/test/orphan",
                        cwd=bare).stdout.strip()
        _git("update-ref", "refs/heads/agent/test/merged-shape", init_sha,
             cwd=bare)
        assert _import_lrc()._orphan_remote_reachable(
            str(bare), "agent/test/merged-shape") is True

    def test_never_pushed_tip_is_not_reachable(self, tmp_path):
        _, bare, _ = _build_orphan_sandbox(tmp_path)
        assert _import_lrc()._orphan_remote_reachable(
            str(bare), "agent/test/never-pushed") is False
