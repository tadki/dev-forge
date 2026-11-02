"""Unit tests for SEE-1499 architecture_sweep stable junit source (§SPEC-B1).

Background: the GUT dimension's junit resolution relied on GC-volatile
sibling-slot artifacts — the platform daemon reclaims done-issue slots
regardless of any retention note, which orphaned the SEE-1476 §5
verification window's junit product. The fix adds an operator-designated
stable source: sweep config key ``junit_stable_path``, env
``ARCH_SWEEP_JUNIT_STABLE_PATH``, or ``--junit-stable-path``.

Priority semantics under test (§SPEC-B1):
- A fresh stable-path hit wins over BOTH the local read and the
  sibling-slot scan — explicit configuration is deterministic; no
  "newest wins" ambiguity across sources.
- A configured-but-missing or configured-but-stale source surfaces loudly
  (log_error + empty junit path → GUT_SILENT_SKIP error finding) and NEVER
  falls back to local/slot artifacts (SEE-1128: a loud unresolved source
  beats a quietly wrong one).
- Unconfigured behaviour is unchanged (legacy local → cross-slot chain).
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

import architecture_sweep as sweep


GUTCONFIG = {
    "dirs": ["res://tests/unit/"],
    "junit_xml_file": "res://tests/reports/junit_report.xml",
    "junit_xml_timestamp": False,
}

DAY = 86400.0


def _write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def _make_repo(tmp_path):
    repo = tmp_path / "repo" / "KingOfLikes-Godot"
    _write(str(repo / ".gutconfig.json"), json.dumps(GUTCONFIG))
    for i in range(3):
        _write(str(repo / "tests" / "unit" / f"test_a{i}.gd"),
               "func test_one() -> void:\n\tpass\n")
    return repo


def _junit_xml(n_cases):
    cases = "\n".join(
        f'<testcase name="t{i}" classname="tests/unit/test_x.gd">'
        for i in range(n_cases)
    )
    return f"<testsuite>\n{cases}\n</testsuite>"


def _slot_junit(ws_root, slot_name, n_cases, age_seconds=0.0):
    """Layout: <ws>/<slot>/workdir/KingOfLikes-Godot/tests/reports/*.xml."""
    reports = os.path.join(ws_root, slot_name, "workdir", "KingOfLikes-Godot",
                           "tests", "reports")
    path = os.path.join(reports, "junit_report.xml")
    _write(path, _junit_xml(n_cases))
    if age_seconds:
        t = time.time() - age_seconds
        os.utime(path, (t, t))
    return path


def _stable_junit(path, n_cases, age_seconds=0.0):
    _write(path, _junit_xml(n_cases))
    if age_seconds:
        t = time.time() - age_seconds
        os.utime(path, (t, t))
    return path


def _error_delta(fn):
    """log_error bumps the module-global phase error counter; measure the delta."""
    before = sweep._phase_error_count
    result = fn()
    return result, sweep._phase_error_count - before


# =============================================================================
# §SPEC-B1 护栏 1 — stable path hit takes priority over slot scan / local read
# =============================================================================


class TestStablePathHitPriority:
    def test_stable_hit_wins_over_newer_slot_scan(self, tmp_path):
        repo = _make_repo(tmp_path)
        ws = tmp_path / "ws"
        ws.mkdir()
        # The sibling-slot product is NEWER than the stable one — recency
        # must not matter: explicit configuration wins.
        _slot_junit(str(ws), "seed-1111-aaaa", 500, age_seconds=0.0)
        stable = _stable_junit(str(tmp_path / "stable" / "kol_junit_report.xml"),
                               400, age_seconds=DAY)
        path, source = sweep._resolve_junit_source(
            str(repo), GUTCONFIG, str(ws), 3, stable_path=stable
        )
        assert path == stable
        assert source == f"stable:{stable}"

    def test_stable_hit_wins_over_local_read(self, tmp_path):
        repo = _make_repo(tmp_path)
        _write(str(repo / "tests" / "reports" / "junit_report.xml"),
               _junit_xml(700))
        stable = _stable_junit(str(tmp_path / "stable" / "kol_junit_report.xml"),
                               400, age_seconds=DAY)
        path, source = sweep._resolve_junit_source(
            str(repo), GUTCONFIG, "", 3, stable_path=stable
        )
        assert path == stable
        assert source == f"stable:{stable}"

    def test_stable_hit_inside_max_age_window_is_fresh(self, tmp_path):
        repo = _make_repo(tmp_path)
        # Two minutes inside the 7-day window: the exact boundary is shared
        # with the S1 cross-slot tier (`age <= JUNIT_MAX_AGE_DAYS`) and is
        # deliberately not asserted at the microsecond-racy edge here.
        stable = _stable_junit(str(tmp_path / "stable" / "kol_junit_report.xml"),
                               400, age_seconds=sweep.JUNIT_MAX_AGE_DAYS * DAY - 120)
        path, source = sweep._resolve_junit_source(
            str(repo), GUTCONFIG, "", 3, stable_path=stable
        )
        assert path == stable
        assert source == f"stable:{stable}"

    def test_end_to_end_stable_hit_zero_findings(self, tmp_path):
        repo = _make_repo(tmp_path)
        ws = tmp_path / "ws"
        ws.mkdir()
        _slot_junit(str(ws), "seed-2222-bbbb", 500)
        stable = _stable_junit(str(tmp_path / "stable" / "kol_junit_report.xml"),
                               3, age_seconds=0.0)
        findings, metrics = sweep.check_gut_silent_skip(str(repo), str(ws),
                                                        junit_stable_path=stable)
        assert findings == []
        assert metrics["actual_tests"] == 3
        assert metrics["junit_source"] == f"stable:{stable}"
        assert metrics["junit_mtime"]


# =============================================================================
# §SPEC-B1 护栏 2 — missing/stale stable source surfaces loudly, no fallback
# =============================================================================


class TestStablePathFailureLoud:
    def test_missing_stable_never_falls_back_to_slot_scan(self, tmp_path):
        repo = _make_repo(tmp_path)
        ws = tmp_path / "ws"
        ws.mkdir()
        # A fresh, plausibly-full sibling-slot product exists — it must NOT
        # be silently selected when the configured stable source is missing.
        _slot_junit(str(ws), "seed-3333-cccc", 500)
        missing = str(tmp_path / "stable" / "kol_junit_report.xml")
        (path, source), delta = _error_delta(
            lambda: sweep._resolve_junit_source(
                str(repo), GUTCONFIG, str(ws), 3, stable_path=missing
            )
        )
        assert path == ""
        assert source == f"stable:{missing}"
        assert delta == 1  # exactly one loud log_error

    def test_missing_stable_never_falls_back_to_local_read(self, tmp_path):
        repo = _make_repo(tmp_path)
        _write(str(repo / "tests" / "reports" / "junit_report.xml"),
               _junit_xml(700))
        missing = str(tmp_path / "stable" / "kol_junit_report.xml")
        (path, source), delta = _error_delta(
            lambda: sweep._resolve_junit_source(
                str(repo), GUTCONFIG, "", 3, stable_path=missing
            )
        )
        assert path == ""
        assert source == f"stable:{missing}"
        assert delta == 1

    def test_stale_stable_never_falls_back_to_slot_scan(self, tmp_path):
        repo = _make_repo(tmp_path)
        ws = tmp_path / "ws"
        ws.mkdir()
        _slot_junit(str(ws), "seed-4444-dddd", 500)
        stale = _stable_junit(str(tmp_path / "stable" / "kol_junit_report.xml"),
                              400, age_seconds=(sweep.JUNIT_MAX_AGE_DAYS + 1) * DAY)
        (path, source), delta = _error_delta(
            lambda: sweep._resolve_junit_source(
                str(repo), GUTCONFIG, str(ws), 3, stable_path=stale
            )
        )
        assert path == ""
        assert source == f"stable:{stale}"
        assert delta == 1

    def test_missing_stable_end_to_end_emits_gut_error_finding(self, tmp_path):
        repo = _make_repo(tmp_path)
        ws = tmp_path / "ws"
        ws.mkdir()
        _slot_junit(str(ws), "seed-5555-eeee", 500)
        missing = str(tmp_path / "stable" / "kol_junit_report.xml")
        findings, metrics = sweep.check_gut_silent_skip(str(repo), str(ws),
                                                        junit_stable_path=missing)
        assert metrics["actual_tests"] == 0
        assert metrics["junit_source"] == f"stable:{missing}"
        gut_errors = [f for f in findings
                      if f["rule_id"] == "GUT_SILENT_SKIP"
                      and f["severity"] == sweep.SEVERITY_ERROR]
        assert gut_errors, "configured-but-missing stable source must surface, not silently scan slots"


# =============================================================================
# Unconfigured behaviour — legacy local → cross-slot chain unchanged
# =============================================================================


class TestUnconfiguredBehaviourUnchanged:
    def test_local_wins_when_stable_unconfigured(self, tmp_path):
        repo = _make_repo(tmp_path)
        local = str(repo / "tests" / "reports" / "junit_report.xml")
        _write(local, _junit_xml(3))
        path, source = sweep._resolve_junit_source(str(repo), GUTCONFIG, "", 3)
        assert path == local
        assert source == "local"

    def test_slot_fallback_when_stable_unconfigured(self, tmp_path):
        repo = _make_repo(tmp_path)
        ws = tmp_path / "ws"
        ws.mkdir()
        junit = _slot_junit(str(ws), "seed-6666-ffff", 500)
        path, source = sweep._resolve_junit_source(str(repo), GUTCONFIG, str(ws), 3)
        assert path == junit
        assert source == "slot:seed-6666-ffff"

    def test_empty_string_stable_path_is_feature_off(self, tmp_path):
        repo = _make_repo(tmp_path)
        local = str(repo / "tests" / "reports" / "junit_report.xml")
        _write(local, _junit_xml(3))
        path, source = sweep._resolve_junit_source(
            str(repo), GUTCONFIG, "", 3, stable_path=""
        )
        assert source == "local"


# =============================================================================
# Config surfaces — apply_config wiring + argparse env default
# =============================================================================


class TestConfigSurfaces:
    def test_apply_config_wires_junit_stable_path(self, tmp_path, monkeypatch):
        monkeypatch.setattr(sweep, "JUNIT_STABLE_PATH", "")
        cfg = tmp_path / "cfg.json"
        cfg.write_text(json.dumps({"junit_stable_path": "/data/junit/kol.xml"}),
                       encoding="utf-8")
        sweep.apply_config(str(cfg))
        assert sweep.JUNIT_STABLE_PATH == "/data/junit/kol.xml"

    def test_apply_config_missing_key_keeps_default(self, tmp_path, monkeypatch):
        monkeypatch.setattr(sweep, "JUNIT_STABLE_PATH", "")
        cfg = tmp_path / "cfg.json"
        cfg.write_text(json.dumps({"max_file_lines": 800}), encoding="utf-8")
        sweep.apply_config(str(cfg))
        assert sweep.JUNIT_STABLE_PATH == ""

    def test_apply_config_invalid_type_ignored(self, tmp_path, monkeypatch):
        monkeypatch.setattr(sweep, "JUNIT_STABLE_PATH", "")
        cfg = tmp_path / "cfg.json"
        cfg.write_text(json.dumps({"junit_stable_path": 42}), encoding="utf-8")
        sweep.apply_config(str(cfg))
        assert sweep.JUNIT_STABLE_PATH == ""

    def test_cli_flag_parsed(self, monkeypatch):
        monkeypatch.setenv("ARCH_SWEEP_JUNIT_STABLE_PATH", "")
        monkeypatch.setattr(sys, "argv",
                            ["architecture_sweep.py",
                             "--junit-stable-path", "/data/junit/kol.xml"])
        args = sweep.parse_args()
        assert args.junit_stable_path == "/data/junit/kol.xml"

    def test_env_default_picked_up(self, monkeypatch):
        monkeypatch.setenv("ARCH_SWEEP_JUNIT_STABLE_PATH", "/env/junit/kol.xml")
        monkeypatch.setattr(sys, "argv", ["architecture_sweep.py"])
        args = sweep.parse_args()
        assert args.junit_stable_path == "/env/junit/kol.xml"

    def test_default_empty_without_flag_or_env(self, monkeypatch):
        monkeypatch.delenv("ARCH_SWEEP_JUNIT_STABLE_PATH", raising=False)
        monkeypatch.setattr(sys, "argv", ["architecture_sweep.py"])
        args = sweep.parse_args()
        assert args.junit_stable_path == ""
