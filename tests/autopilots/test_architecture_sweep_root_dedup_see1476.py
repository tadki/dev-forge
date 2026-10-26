"""Unit tests for SEE-1476 architecture_sweep fixes.

Two defects from the 2026-10-26 L1 escalation (GUT_SILENT_SKIP false error):
- _default_workspace_root: a residual directory that merely contains a
  ``workdir/`` subdir (no target repo) must not qualify as a slot — it used
  to push the detected workspace root one level too high, blinding the
  cross-slot junit scan (4 consecutive Mondays of false GUT_SILENT_SKIP
  errors since 2026-09-21). Resolution failure is surfaced (logged, empty)
  instead of silently guessing CWD (SEE-1128 precedent).
- D1 per-directory GUT_SILENT_SKIP findings encode the dir into their dedup
  key so they can never collide with the global
  ``.gutconfig.json:0:GUT_SILENT_SKIP:error`` baseline key — a real
  whole-directory skip must reach new_findings and the escalation path.
"""

import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

import architecture_sweep as sweep


def _write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


# =============================================================================
# SPEC-1476-1 — workspace root detection
# =============================================================================


class TestSlotHostsRepo:
    def test_residual_workdir_only_dir_rejected(self, tmp_path):
        stray = tmp_path / "see-1330-1d8c3931e9a3" / "workdir"
        stray.mkdir(parents=True)
        _write(str(stray / "reply-scope-review.md"), "x")
        assert sweep._slot_hosts_repo(str(tmp_path / "see-1330-1d8c3931e9a3")) is False

    def test_slot_with_repo_in_workdir_accepted(self, tmp_path):
        slot = tmp_path / "see-1111-aaa" / "workdir" / "KingOfLikes-Godot"
        slot.mkdir(parents=True)
        assert sweep._slot_hosts_repo(str(tmp_path / "see-1111-aaa")) is True

    def test_slot_with_repo_direct_accepted(self, tmp_path):
        slot = tmp_path / "see-2222-bbb" / "KingOfLikes-Godot"
        slot.mkdir(parents=True)
        assert sweep._slot_hosts_repo(str(tmp_path / "see-2222-bbb")) is True


class TestDefaultWorkspaceRoot:
    @pytest.fixture(autouse=True)
    def _isolate(self, monkeypatch):
        # Keep the ambient MULTICA_WORKSPACE_ROOT and the real
        # ~/.multica/workspaces out of the resolution.
        monkeypatch.delenv("MULTICA_WORKSPACE_ROOT", raising=False)
        self._logged = []
        monkeypatch.setattr(sweep, "log_error", lambda msg: self._logged.append(msg))

    def _walk_from(self, monkeypatch, cwd):
        monkeypatch.chdir(cwd)
        return sweep._default_workspace_root()

    def test_residual_workdir_dir_does_not_raise_root(self, tmp_path, monkeypatch):
        # Mirrors the production layout: a stray <name>/workdir at the outer
        # level plus real slots nested one level deeper under a seed dir.
        stray = tmp_path / "see-1330-1d8c3931e9a3" / "workdir"
        stray.mkdir(parents=True)
        _write(str(stray / "reply-scope-review.md"), "x")
        seed = tmp_path / "seed-478690824e46"
        repo = seed / "see-1468-50c542fc6663" / "workdir" / "KingOfLikes-Godot"
        repo.mkdir(parents=True)
        cwd = seed / "see-1468-50c542fc6663" / "workdir" / "dev-forge"
        cwd.mkdir(parents=True)
        # Pre-fix, the stray <name>/workdir form lifted the root to tmp_path
        # and the cross-slot scan saw 0 slots; the seed level must win.
        root = self._walk_from(monkeypatch, cwd)
        assert root == str(seed)
        assert self._logged == []

    def test_no_slot_anywhere_returns_empty_and_logs(self, tmp_path, monkeypatch):
        cwd = tmp_path / "lonely" / "workdir" / "dev-forge"
        cwd.mkdir(parents=True)
        # Fallback 2 (~/.multica/workspaces) must miss too: point expanduser
        # at a nonexistent location inside tmp.
        monkeypatch.setattr(
            sweep.os.path, "expanduser", lambda p: str(tmp_path / "no-home" / p)
        )
        root = self._walk_from(monkeypatch, cwd)
        assert root == ""
        assert len(self._logged) == 1
        assert "MULTICA_WORKSPACE_ROOT" in self._logged[0]

    def test_env_var_fallback_still_honoured(self, tmp_path, monkeypatch):
        cwd = tmp_path / "lonely" / "workdir" / "dev-forge"
        cwd.mkdir(parents=True)
        env_root = tmp_path / "explicit-ws-root"
        env_root.mkdir()
        monkeypatch.setenv("MULTICA_WORKSPACE_ROOT", str(env_root))
        root = self._walk_from(monkeypatch, cwd)
        assert root == str(env_root)
        assert self._logged == []

    def test_valid_slot_still_detected_after_fix(self, tmp_path, monkeypatch):
        seed = tmp_path / "seed-478690824e46"
        repo = seed / "see-1007-abc" / "workdir" / "KingOfLikes-Godot"
        repo.mkdir(parents=True)
        cwd = seed / "see-1007-abc" / "workdir" / "dev-forge"
        cwd.mkdir(parents=True)
        root = self._walk_from(monkeypatch, cwd)
        assert root == str(seed)


# =============================================================================
# SPEC-1476-2 — D1 per-dir dedup key distinct from the global key
# =============================================================================


MULTI_DIR_GUTCONFIG = {
    "dirs": [
        "res://tests/unit/",
        "res://tests/aidomain/",
    ],
    "junit_xml_file": "res://tests/reports/junit_report.xml",
    "junit_xml_timestamp": True,
}


def _junit_xml_with_dirs(dir_cases):
    cases = []
    for prefix, n in dir_cases.items():
        for i in range(n):
            cases.append(f'<testcase name="t{i}" classname="{prefix}/test_x.gd">')
    return "<testsuite>\n" + "\n".join(cases) + "\n</testsuite>"


def _make_multi_dir_repo(tmp_path):
    repo = tmp_path / "repo" / "KingOfLikes-Godot"
    _write(str(repo / ".gutconfig.json"), json.dumps(MULTI_DIR_GUTCONFIG))
    _write(str(repo / "tests" / "unit" / "test_u.gd"),
           "func test_x() -> void:\n\tpass\n" * 10)
    _write(str(repo / "tests" / "aidomain" / "test_a.gd"),
           "func test_x() -> void:\n\tpass\n" * 5)
    return repo


class TestDirDedupKey:
    GLOBAL_KEY = ".gutconfig.json:0:GUT_SILENT_SKIP:error"

    def _aidomain_missing_repo(self, tmp_path):
        # SEE-1226 aidomain method: whole-dir skip with the global total
        # passing (unit over-delivers via parametrization).
        repo = _make_multi_dir_repo(tmp_path)
        junit = _junit_xml_with_dirs({"tests/unit": 15})
        _write(str(repo / "tests" / "reports" / "junit_report_1.0.xml"), junit)
        return repo

    def test_per_dir_key_differs_from_global_key(self, tmp_path):
        repo = self._aidomain_missing_repo(tmp_path)
        findings, _ = sweep.check_gut_silent_skip(str(repo))
        dir_findings = [f for f in findings if "(dir)" in f["message"]]
        assert dir_findings, "aidomain whole-dir skip must produce a dir finding"
        dir_key = sweep.dedup_key(
            dir_findings[0]["file"], dir_findings[0]["line"],
            dir_findings[0]["rule_id"], dir_findings[0]["severity"],
        )
        assert dir_key != self.GLOBAL_KEY
        assert "tests/aidomain" in dir_key
        assert "aidomain" in dir_findings[0]["file"]

    def test_dir_finding_reaches_new_findings_despite_global_key_known(
        self, tmp_path
    ):
        # The regression this guards: the global GUT_SILENT_SKIP key sits in
        # the baseline (false positive recorded since 2026-08-31). A real
        # whole-dir skip used to dedup into it and never escalate.
        repo = self._aidomain_missing_repo(tmp_path)
        findings, _ = sweep.check_gut_silent_skip(str(repo))
        known = {self.GLOBAL_KEY}
        current_keys, new_findings = sweep._dedup_findings(findings, known)
        new_dir_findings = [f for f in new_findings if "(dir)" in f["message"]]
        assert len(new_dir_findings) == 1
        assert "tests/aidomain/" in new_dir_findings[0]["message"]
        assert self.GLOBAL_KEY not in current_keys
        assert any("tests/aidomain" in k for k in current_keys)

    def test_global_finding_key_unchanged(self, tmp_path):
        # The global finding keeps its historical key so the baseline cleanup
        # (SPEC-1476-3) targets exactly one stale key.
        repo = _make_multi_dir_repo(tmp_path)
        findings, _ = sweep.check_gut_silent_skip(str(repo))
        assert findings, "expected>0 with no junit must fire the global finding"
        key = sweep.dedup_key(
            findings[0]["file"], findings[0]["line"],
            findings[0]["rule_id"], findings[0]["severity"],
        )
        assert key == self.GLOBAL_KEY
