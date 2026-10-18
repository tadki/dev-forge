"""Unit tests for SEE-1226 architecture_sweep detector fixes.

Covers two detector-side defects triaged in the 2026-09-01 escalation:
- check_gut_silent_skip S1: cross-slot junit aggregation (mtime-newest,
  7-day freshness), unit-unified expected (`func test_*`) vs actual
  (`<testcase>`), and source-slot/mtime recorded in metrics.
- check_gamestate_mirror: UNIQUE effect handler write sites exempted
  (`_on_unique_*` naming + UniqueEffectRegistry.register registration),
  while D4 semantics (sync functions only exempt for their own field) and
  real direct writes stay flagged.
"""

import os
import sys
import time

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

import architecture_sweep as sweep


GUTCONFIG = {
    "dirs": ["res://tests/unit/"],
    "junit_xml_file": "res://tests/reports/junit_report.xml",
    "junit_xml_timestamp": True,
}


def _write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def _make_repo(tmp_path, gutconfig=GUTCONFIG):
    repo = tmp_path / "repo" / "KingOfLikes-Godot"
    _write(str(repo / ".gutconfig.json"), __import__("json").dumps(gutconfig))
    return repo


def _make_workspace(tmp_path, repo):
    """Layout: <ws>/<slot>/workdir/KingOfLikes-Godot."""
    ws = tmp_path / "ws"
    slot = ws / "seed-9999-abc123" / "workdir"
    slot.mkdir(parents=True, exist_ok=True)
    (slot / "KingOfLikes-Godot").symlink_to(repo) if False else None
    return ws


def _junit_xml(n_cases):
    # classname mirrors GUT's real format: the emitting script's repo path.
    cases = "\n".join(
        f'<testcase name="t{i}" classname="tests/unit/test_x.gd">'
        for i in range(n_cases)
    )
    return f"<testsuite>\n{cases}\n</testsuite>"


def _junit_xml_with_dirs(dir_cases):
    """dir_cases: {classname_prefix: n_cases}; classname mirrors GUT's script-path format."""
    cases = []
    for prefix, n in dir_cases.items():
        for i in range(n):
            cases.append(f'<testcase name="t{i}" classname="{prefix}/test_x.gd">')
    return "<testsuite>\n" + "\n".join(cases) + "\n</testsuite>"


# =============================================================================
# check_gut_silent_skip — S1 cross-slot aggregation
# =============================================================================


class TestGutSilentSkipS1:
    def _setup_local_and_counts(self, repo):
        _write(str(repo / "tests" / "unit" / "test_a.gd"),
               "func test_one() -> void:\n\tpass\nfunc test_two() -> void:\n\tpass\n")
        _write(str(repo / "tests" / "unit" / "test_b.gd"),
               "func test_three() -> void:\n\tpass\n")

    def test_expected_counts_test_funcs_not_files(self, tmp_path):
        repo = _make_repo(tmp_path)
        self._setup_local_and_counts(repo)
        findings, metrics = sweep.check_gut_silent_skip(str(repo))
        # 2 funcs in test_a + 1 in test_b = 3 (NOT 2 files).
        assert metrics["expected_tests"] == 3

    def test_local_junit_preferred(self, tmp_path):
        repo = _make_repo(tmp_path)
        self._setup_local_and_counts(repo)
        _write(str(repo / "tests" / "reports" / "junit_report_1.0.xml"),
               _junit_xml(10))
        ws = tmp_path / "ws"
        ws.mkdir()
        # A newer cross-slot product exists but local must win.
        cross = ws / "slot-x" / "workdir" / "KingOfLikes-Godot" / "tests" / "reports"
        _write(str(cross / "junit_report_2.0.xml"), _junit_xml(999))
        findings, metrics = sweep.check_gut_silent_skip(str(repo), str(ws))
        assert findings == []
        assert metrics["actual_tests"] == 10
        assert metrics["junit_source"] == "local"

    def test_cross_slot_fallback_when_local_empty(self, tmp_path):
        repo = _make_repo(tmp_path)
        self._setup_local_and_counts(repo)
        ws = tmp_path / "ws"
        cross = ws / "seed-8888-def456" / "workdir" / "KingOfLikes-Godot" / "tests" / "reports"
        _write(str(cross / "junit_report_1788253530.7.xml"), _junit_xml(5))
        findings, metrics = sweep.check_gut_silent_skip(str(repo), str(ws))
        assert findings == []
        assert metrics["actual_tests"] == 5
        assert metrics["junit_source"] == "slot:seed-8888-def456"
        assert metrics["junit_mtime"] != ""

    def test_cross_slot_picks_newest_mtime(self, tmp_path):
        repo = _make_repo(tmp_path)
        self._setup_local_and_counts(repo)
        ws = tmp_path / "ws"
        old = ws / "slot-old" / "workdir" / "KingOfLikes-Godot" / "tests" / "reports"
        new = ws / "slot-new" / "KingOfLikes-Godot" / "tests" / "reports"
        _write(str(old / "junit_report_1.0.xml"), _junit_xml(1))
        _write(str(new / "junit_report_2.0.xml"), _junit_xml(7))
        past = time.time() - 100
        os.utime(str(old / "junit_report_1.0.xml"), (past, past))
        findings, metrics = sweep.check_gut_silent_skip(str(repo), str(ws))
        assert metrics["actual_tests"] == 7
        assert metrics["junit_source"] == "slot:slot-new"

    def test_stale_cross_slot_junit_not_used(self, tmp_path):
        repo = _make_repo(tmp_path)
        self._setup_local_and_counts(repo)
        ws = tmp_path / "ws"
        cross = ws / "slot-stale" / "workdir" / "KingOfLikes-Godot" / "tests" / "reports"
        _write(str(cross / "junit_report_1.0.xml"), _junit_xml(50))
        old = time.time() - (sweep.JUNIT_MAX_AGE_DAYS + 1) * 86400
        os.utime(str(cross / "junit_report_1.0.xml"), (old, old))
        findings, metrics = sweep.check_gut_silent_skip(str(repo), str(ws))
        # Stale product must NOT satisfy the check → finding fires.
        assert len(findings) == 1
        assert findings[0]["rule_id"] == "GUT_SILENT_SKIP"
        assert metrics["actual_tests"] == 0

    def test_cross_slot_prefers_newest_full_run_over_probe(self, tmp_path):
        repo = _make_repo(tmp_path)
        # Build a repo with 5 test funcs so threshold = int(5*0.95) = 4.
        _write(str(repo / "tests" / "unit" / "test_a.gd"),
               "func test_1() -> void:\n\tpass\nfunc test_2() -> void:\n\tpass\n"
               "func test_3() -> void:\n\tpass\nfunc test_4() -> void:\n\tpass\n"
               "func test_5() -> void:\n\tpass\n")
        ws = tmp_path / "ws"
        # An older near-full report (5 cases) and a newer probe (3 cases).
        full = ws / "slot-a" / "workdir" / "KingOfLikes-Godot" / "tests" / "reports"
        probe = ws / "slot-b" / "workdir" / "KingOfLikes-Godot" / "tests" / "reports"
        _write(str(full / "junit_report_1.0.xml"), _junit_xml(5))
        _write(str(probe / "junit_report_2.0.xml"), _junit_xml(3))
        now = time.time()
        os.utime(str(full / "junit_report_1.0.xml"), (now - 100, now - 100))
        os.utime(str(probe / "junit_report_2.0.xml"), (now, now))
        findings, metrics = sweep.check_gut_silent_skip(str(repo), str(ws))
        # The near-full report (5 >= threshold 4) wins over the newer probe.
        assert metrics["actual_tests"] == 5
        assert metrics["junit_source"] == "slot:slot-a"
        assert findings == []

    def test_partial_run_below_tolerance_fires(self, tmp_path):
        repo = _make_repo(tmp_path)
        self._setup_local_and_counts(repo)
        _write(str(repo / "tests" / "reports" / "junit_report_1.0.xml"),
               _junit_xml(1))
        findings, metrics = sweep.check_gut_silent_skip(str(repo))
        # expected=3, actual=1 < 3*0.95 → partial-run finding (global and dir
        # level both fire on the same 1-of-3 shortfall).
        assert len(findings) == 2
        assert "expected 3 tests" in findings[0]["message"]

    def test_within_tolerance_does_not_fire(self, tmp_path):
        repo = _make_repo(tmp_path)
        self._setup_local_and_counts(repo)
        _write(str(repo / "tests" / "reports" / "junit_report_1.0.xml"),
               _junit_xml(3))
        findings, _ = sweep.check_gut_silent_skip(str(repo))
        assert findings == []


# =============================================================================
# check_gut_silent_skip — D1 per-directory validation
# =============================================================================


MULTI_DIR_GUTCONFIG = {
    "dirs": [
        "res://tests/unit/",
        "res://tests/aidomain/",
    ],
    "junit_xml_file": "res://tests/reports/junit_report.xml",
    "junit_xml_timestamp": True,
}


class TestGutSilentSkipPerDirectory:
    def _make_multi_dir_repo(self, tmp_path, unit_funcs=10, aidomain_funcs=5):
        repo = _make_repo(tmp_path, MULTI_DIR_GUTCONFIG)
        _write(str(repo / "tests" / "unit" / "test_u.gd"),
               "func test_x() -> void:\n\tpass\n" * unit_funcs)
        _write(str(repo / "tests" / "aidomain" / "test_a.gd"),
               "func test_x() -> void:\n\tpass\n" * aidomain_funcs)
        return repo

    def test_whole_dir_missing_fires(self, tmp_path):
        # The core D1 defect: aidomain (5 funcs) contributes 0 testcases while
        # unit over-delivers (15 parametrized cases from 10 funcs), so the
        # GLOBAL total passes (15 >= int(15*0.95)=14) and would mask the skip.
        # The dir-level finding must still fire for aidomain alone.
        repo = self._make_multi_dir_repo(tmp_path)  # unit=10, aidomain=5
        junit = _junit_xml_with_dirs({"tests/unit": 15})
        _write(str(repo / "tests" / "reports" / "junit_report_1.0.xml"), junit)
        findings, metrics = sweep.check_gut_silent_skip(str(repo))
        # Global check passes: 15 actual >= 14 threshold.
        global_findings = [f for f in findings if "(dir)" not in f["message"]]
        assert global_findings == []
        # Dir check fires for aidomain only.
        dir_findings = [f for f in findings if "(dir)" in f["message"]]
        assert len(dir_findings) == 1
        assert "tests/aidomain/" in dir_findings[0]["message"]
        assert "expected 5 tests, junit reports 0 executed" in dir_findings[0]["message"]
        assert metrics["actual_tests"] == 15

    def test_single_dir_shortfall_beyond_tolerance_fires(self, tmp_path):
        # aidomain declares 20 funcs but junit attributes only 10 (50% < 95%)
        # while unit is fully covered. The static expected side can't be
        # padded, so the global partial finding also fires — the assertion
        # targets the dir finding with its own counts.
        repo = _make_repo(tmp_path, MULTI_DIR_GUTCONFIG)
        _write(str(repo / "tests" / "unit" / "test_u.gd"),
               "func test_x() -> void:\n\tpass\n" * 10)
        _write(str(repo / "tests" / "aidomain" / "test_a.gd"),
               "func test_x() -> void:\n\tpass\n" * 20)
        junit = _junit_xml_with_dirs({"tests/unit": 10, "tests/aidomain": 10})
        _write(str(repo / "tests" / "reports" / "junit_report_1.0.xml"), junit)
        findings, _ = sweep.check_gut_silent_skip(str(repo))
        dir_findings = [f for f in findings if "(dir)" in f["message"]]
        assert len(dir_findings) == 1
        assert "tests/aidomain/" in dir_findings[0]["message"]
        assert "expected 20 tests, junit reports 10 executed" in dir_findings[0]["message"]

    def test_mixed_dirs_within_tolerance_pass(self, tmp_path):
        repo = self._make_multi_dir_repo(tmp_path, unit_funcs=20, aidomain_funcs=10)
        junit = _junit_xml_with_dirs(
            {"tests/unit": 20, "tests/aidomain": 10, "tests/other": 3}
        )
        _write(str(repo / "tests" / "reports" / "junit_report_1.0.xml"), junit)
        findings, metrics = sweep.check_gut_silent_skip(str(repo))
        # Both dirs at full count; 3 unattributed cases don't mask anything.
        assert findings == []
        assert metrics["actual_tests"] == 33
        assert metrics["expected_tests"] == 30

    def test_dir_finding_names_dir_and_both_counts(self, tmp_path):
        repo = self._make_multi_dir_repo(tmp_path)  # unit=10, aidomain=5
        junit = _junit_xml_with_dirs({"tests/unit": 10})
        _write(str(repo / "tests" / "reports" / "junit_report_1.0.xml"), junit)
        findings, _ = sweep.check_gut_silent_skip(str(repo))
        dir_findings = [f for f in findings if "(dir)" in f["message"]]
        assert dir_findings
        msg = dir_findings[0]["message"]
        assert "tests/aidomain" in msg
        assert "expected 5" in msg
        assert "reports 0" in msg
        assert dir_findings[0]["rule_id"] == "GUT_SILENT_SKIP"

    def test_dirs_missing_on_disk_are_skipped(self, tmp_path):
        # aidomain dir absent from the repo: no static funcs, no junit cases;
        # must not produce a dir finding.
        repo = _make_repo(tmp_path, MULTI_DIR_GUTCONFIG)
        _write(str(repo / "tests" / "unit" / "test_u.gd"),
               "func test_x() -> void:\n\tpass\n" * 5)
        junit = _junit_xml_with_dirs({"tests/unit": 5})
        _write(str(repo / "tests" / "reports" / "junit_report_1.0.xml"), junit)
        findings, metrics = sweep.check_gut_silent_skip(str(repo))
        assert findings == []
        assert metrics["expected_tests"] == 5


# =============================================================================
# check_gamestate_mirror — UNIQUE effect handler exemption
# =============================================================================


class TestGamestateMirrorHandlerExemption:
    def _check(self, tmp_path, content, filename="autoload/x.gd"):
        repo = tmp_path
        _write(str(repo / filename), content)
        return sweep.check_gamestate_mirror(str(repo), [filename])

    HANDLER = (
        "extends Node\n"
        "func _ready() -> void:\n"
        "\tUniqueEffectRegistry.register(&\"unique_click_count\", _on_unique_click_count)\n"
        "\n"
        "func _on_unique_click_count(instance: EffectInstance) -> void:\n"
        "\tGameState.total_clicks += int(instance.current_value)\n"
    )

    def test_registered_handler_write_exempt(self, tmp_path):
        findings = self._check(tmp_path, self.HANDLER)
        assert findings == []

    def test_unregistered_write_still_flagged(self, tmp_path):
        content = (
            "extends Node\n"
            "func do_stuff() -> void:\n"
            "\tGameState.total_clicks += 1\n"
        )
        findings = self._check(tmp_path, content)
        assert len(findings) == 1
        assert findings[0]["rule_id"] == "GAMESTATE_MIRROR_DIRECT"
        assert findings[0]["line"] == 3

    def test_on_unique_naming_exempt_even_without_register(self, tmp_path):
        content = (
            "extends Node\n"
            "func _on_unique_likes_total(instance: EffectInstance) -> void:\n"
            "\tGameState.total_likes += int(instance.current_value)\n"
        )
        findings = self._check(tmp_path, content)
        assert findings == []

    def test_dispatch_wrapper_fallback_exempt(self, tmp_path):
        content = (
            "extends Node\n"
            "func _apply_click_count_via_effect(count: int) -> void:\n"
            "\tif not is_instance_valid(EffectManager):\n"
            "\t\tGameState.total_clicks += count\n"
            "\t\treturn\n"
            "\tEffectManager.apply_effect_with_value(\"s\", \"player\", &\"e\", count)\n"
        )
        findings = self._check(tmp_path, content)
        assert findings == []

    def test_random_func_named_via_effect_not_exempt(self, tmp_path):
        content = (
            "extends Node\n"
            "func _apply_something_via_effect_and_quit() -> void:\n"
            "\tGameState.gold += 5\n"
        )
        findings = self._check(tmp_path, content)
        assert len(findings) == 1

    def test_sync_writer_for_own_field_still_exempt(self, tmp_path):
        content = (
            "extends Node\n"
            "func _sync_total_likes_to_game_state() -> void:\n"
            "\tGameState.total_likes = 5\n"
        )
        findings = self._check(tmp_path, content)
        assert findings == []

    def test_sync_writer_touching_other_field_still_flagged(self, tmp_path):
        # D4: a sync function writing a DIFFERENT mirror field is a violation.
        content = (
            "extends Node\n"
            "func _sync_total_likes_to_game_state() -> void:\n"
            "\tGameState.total_clicks = 5\n"
        )
        findings = self._check(tmp_path, content)
        assert len(findings) == 1
        assert findings[0]["line"] == 3

    def test_real_write_sites_in_like_heart_manager_exempt(self, tmp_path):
        # Mirror of autoload/like_heart_manager.gd:104/:120 — the two
        # baseline findings this exemption targets.
        content = (
            "extends Node\n"
            "func _ready() -> void:\n"
            "\tUniqueEffectRegistry.register(&\"unique_click_count\", _on_unique_click_count)\n"
            "\n"
            "func _apply_click_count_via_effect(count: int) -> void:\n"
            "\tif not is_instance_valid(UniqueEffectRegistry) or not is_instance_valid(EffectManager):\n"
            "\t\tGameState.total_clicks += count\n"
            "\t\treturn\n"
            "\tEffectManager.apply_effect_with_value(\"heart_click\", \"player\", &\"unique_click_count\", float(count))\n"
            "\n"
            "func _on_unique_click_count(instance: EffectInstance) -> void:\n"
            "\tGameState.total_clicks += int(instance.current_value)\n"
        )
        findings = self._check(tmp_path, content, filename="autoload/like_heart_manager.gd")
        assert findings == []
