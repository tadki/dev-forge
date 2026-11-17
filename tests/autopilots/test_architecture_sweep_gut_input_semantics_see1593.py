"""SEE-1593 GUT dimension: input semantics, honest metrics, no-input escalation.

Background (issue SEE-1593): the L1 GUT dimension read its junit only from
GC-volatile sibling-slot artifacts, so when the platform reclaimed the slot
the dimension silently went blind and reported ``GUT_SILENT_SKIP:error``
"no junit report found" — an input-availability failure masquerading as a
product defect. The fix (route A2) has the patrol produce its own junit, and
this module pins the Python-side semantics:

§SPEC-002 — split the two meanings:
  * no junit input at all  -> ``GUT_UNVERIFIED`` (warn): "input missing, not
    a product signal";
  * junit present but zero executed / global below tolerance / a whole
    directory missing or short -> ``GUT_SILENT_SKIP`` (error, D1 semantics
    and dedup keys unchanged);
  * a configured-but-missing/stale stable source stays a hard error
    (SEE-1499 fail-loud contract is NOT relaxed by the split).

§SPEC-003 — metrics honesty: no junit resolves -> ``junit_source="none"``;
``gut_verified`` is written only by L1 rounds (True iff a junit was read with
actual > 0), never fabricated false by an L0 round.

§SPEC-004 — consecutive no-input escalation: an L1 round whose previous L1
round was also unverified escalates ``GUT_UNVERIFIED`` to ``error`` and names
the streak. ``--dry-run`` writes no state.
"""

import hashlib
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

import architecture_sweep as sweep


GUTCONFIG = {
    "dirs": ["res://tests/unit/", "res://tests/aidomain/"],
    "junit_xml_file": "res://tests/reports/junit_report.xml",
    "junit_xml_timestamp": False,
}


def _write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def _make_repo(tmp_path, unit_funcs=10, aidomain_funcs=5):
    repo = tmp_path / "repo" / "KingOfLikes-Godot"
    _write(str(repo / ".gutconfig.json"), json.dumps(GUTCONFIG))
    _write(str(repo / "tests" / "unit" / "test_u.gd"),
           "func test_x() -> void:\n\tpass\n" * unit_funcs)
    _write(str(repo / "tests" / "aidomain" / "test_a.gd"),
           "func test_x() -> void:\n\tpass\n" * aidomain_funcs)
    return repo


def _junit_xml(cases_by_dir):
    cases = []
    for prefix, n in cases_by_dir.items():
        for i in range(n):
            cases.append(f'<testcase name="t{i}" classname="{prefix}/test_x.gd">')
    return "<testsuite>\n" + "\n".join(cases) + "\n</testsuite>"


def _write_junit(repo, cases_by_dir):
    _write(str(repo / "tests" / "reports" / "junit_report.xml"),
           _junit_xml(cases_by_dir))


@pytest.fixture(autouse=True)
def _isolate_state(tmp_path, monkeypatch):
    """Never read or write the machine's real arch-patrol state."""
    monkeypatch.setattr(sweep, "REPORT_FILE", str(tmp_path / "arch" / "last_report.json"))
    monkeypatch.setattr(sweep, "BASELINE_FILE", str(tmp_path / "arch" / "baseline.jsonl"))
    yield


def _write_prev_report(metrics):
    os.makedirs(os.path.dirname(sweep.REPORT_FILE), exist_ok=True)
    with open(sweep.REPORT_FILE, "w", encoding="utf-8") as f:
        json.dump({"summary": {"metrics": metrics}}, f)


# =============================================================================
# §SPEC-002 — semantic split
# =============================================================================


class TestSemanticSplit:
    def test_no_junit_is_gut_unverified_warn_not_silent_skip(self, tmp_path):
        repo = _make_repo(tmp_path)  # no junit anywhere
        findings, _ = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        assert [f for f in findings if f["rule_id"] == "GUT_SILENT_SKIP"] == []
        unverified = [f for f in findings if f["rule_id"] == "GUT_UNVERIFIED"]
        assert len(unverified) == 1
        assert unverified[0]["severity"] == "warn"
        msg = unverified[0]["message"].lower()
        assert "input missing" in msg or "unverified" in msg
        assert unverified[0]["file"] == ".gutconfig.json"

    def test_zero_execution_report_is_silent_skip_error(self, tmp_path):
        repo = _make_repo(tmp_path)
        _write_junit(repo, {})  # report present, nothing executed
        findings, metrics = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        assert metrics["actual_tests"] == 0
        silent = [f for f in findings if f["rule_id"] == "GUT_SILENT_SKIP"]
        assert len(silent) == 1
        assert silent[0]["severity"] == "error"
        assert [f for f in findings if f["rule_id"] == "GUT_UNVERIFIED"] == []

    def test_global_shortfall_is_silent_skip_error(self, tmp_path):
        repo = _make_repo(tmp_path)  # expected 15, threshold 14
        _write_junit(repo, {"tests/unit": 1})
        findings, _ = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        silent = [f for f in findings if f["rule_id"] == "GUT_SILENT_SKIP"
                  and "(dir)" not in f["message"]]
        assert len(silent) == 1
        assert silent[0]["severity"] == "error"

    def test_whole_dir_missing_keeps_dir_level_error(self, tmp_path):
        repo = _make_repo(tmp_path)  # unit 10 + aidomain 5; global 15 >= threshold 14
        _write_junit(repo, {"tests/unit": 15})
        findings, _ = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        dir_findings = [f for f in findings if "(dir)" in f["message"]]
        assert len(dir_findings) == 1
        assert dir_findings[0]["rule_id"] == "GUT_SILENT_SKIP"
        assert dir_findings[0]["severity"] == "error"
        assert "tests/aidomain" in dir_findings[0]["message"]

    def test_configured_stable_miss_stays_error_not_unverified(self, tmp_path, monkeypatch):
        logged = []
        monkeypatch.setattr(sweep, "log_error", lambda msg: logged.append(msg))
        repo = _make_repo(tmp_path)
        missing = str(tmp_path / "absent" / "kol.xml")
        findings, metrics = sweep.check_gut_silent_skip(
            str(repo), "", junit_stable_path=missing
        )
        assert logged, "stable-miss must log_error (SEE-1499 fail-loud)"
        assert metrics["junit_source"] == f"stable:{missing}"
        silent = [f for f in findings if f["rule_id"] == "GUT_SILENT_SKIP"]
        assert len(silent) == 1
        assert silent[0]["severity"] == "error"
        assert [f for f in findings if f["rule_id"] == "GUT_UNVERIFIED"] == []


# =============================================================================
# §SPEC-003 — metrics honesty
# =============================================================================


class TestMetricsHonesty:
    def test_no_junit_reports_source_none(self, tmp_path):
        repo = _make_repo(tmp_path)
        _, metrics = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        assert metrics["junit_source"] == "none"
        assert metrics["gut_verified"] is False

    def test_local_junit_reports_local_and_verified(self, tmp_path):
        repo = _make_repo(tmp_path)
        _write_junit(repo, {"tests/unit": 10, "tests/aidomain": 5})
        _, metrics = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        assert metrics["junit_source"] == "local"
        assert metrics["gut_verified"] is True
        assert metrics["gut_unverified_streak"] == 0

    def test_l0_round_writes_no_gut_metric(self, tmp_path):
        repo = _make_repo(tmp_path)
        metrics = {}
        sweep._run_l1_checks(str(repo), "", run_l1=False, fast_mode=False,
                             all_findings=[], metrics=metrics)
        assert "gut_verified" not in metrics
        assert "junit_source" not in metrics


# =============================================================================
# §SPEC-004 — consecutive no-input escalation
# =============================================================================


class TestConsecutiveEscalation:
    def test_first_unverified_round_is_warn_streak_one(self, tmp_path):
        repo = _make_repo(tmp_path)  # no history, no junit
        findings, metrics = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        assert metrics["gut_unverified_streak"] == 1
        unverified = [f for f in findings if f["rule_id"] == "GUT_UNVERIFIED"]
        assert len(unverified) == 1
        assert unverified[0]["severity"] == "warn"

    def test_second_consecutive_unverified_escalates_to_error(self, tmp_path):
        repo = _make_repo(tmp_path)
        _write_prev_report({"gut_verified": False, "gut_unverified_streak": 1})
        findings, metrics = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        assert metrics["gut_unverified_streak"] == 2
        unverified = [f for f in findings if f["rule_id"] == "GUT_UNVERIFIED"]
        assert len(unverified) == 1
        assert unverified[0]["severity"] == "error"
        assert "2" in unverified[0]["message"]

    def test_verified_previous_round_resets_streak(self, tmp_path):
        repo = _make_repo(tmp_path)
        _write_prev_report({"gut_verified": True, "gut_unverified_streak": 0})
        findings, metrics = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        assert metrics["gut_unverified_streak"] == 1
        unverified = [f for f in findings if f["rule_id"] == "GUT_UNVERIFIED"]
        assert unverified[0]["severity"] == "warn"

    def test_baseline_history_survives_intervening_l0_rounds(self, tmp_path):
        # last_report.json is overwritten by every daily L0 run, so the
        # previous L1 state must also be recoverable from the append-only
        # baseline ledger.
        repo = _make_repo(tmp_path)
        _write_prev_report({"files_over_800": 1})  # last run was L0
        os.makedirs(os.path.dirname(sweep.BASELINE_FILE), exist_ok=True)
        with open(sweep.BASELINE_FILE, "w", encoding="utf-8") as f:
            f.write(json.dumps({
                "ts": "2026-11-16T20:00:00+00:00",
                "metrics": {"gut_verified": False, "gut_unverified_streak": 1},
                "findings": [],
            }) + "\n")
        findings, metrics = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        assert metrics["gut_unverified_streak"] == 2
        unverified = [f for f in findings if f["rule_id"] == "GUT_UNVERIFIED"]
        assert unverified[0]["severity"] == "error"

    def test_verified_round_clears_streak_with_prior_unverified(self, tmp_path):
        repo = _make_repo(tmp_path)
        _write_junit(repo, {"tests/unit": 10, "tests/aidomain": 5})
        _write_prev_report({"gut_verified": False, "gut_unverified_streak": 3})
        findings, metrics = sweep.check_gut_silent_skip(str(repo), "", junit_stable_path="")
        assert metrics["gut_verified"] is True
        assert metrics["gut_unverified_streak"] == 0
        assert findings == []


# =============================================================================
# §SPEC-004 — dry-run writes no state
# =============================================================================


def _sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


class TestDryRunWritesNoState:
    def test_report_and_baseline_unchanged_on_dry_run(self, tmp_path):
        report_path = sweep.REPORT_FILE
        baseline_path = sweep.BASELINE_FILE
        os.makedirs(os.path.dirname(report_path), exist_ok=True)
        with open(report_path, "w", encoding="utf-8") as f:
            f.write('{"summary": {"metrics": {}}')
        with open(baseline_path, "w", encoding="utf-8") as f:
            f.write('{"metrics": {}}\n')
        before = (_sha256(report_path), _sha256(baseline_path))

        sweep._write_report_file({"summary": {"metrics": {}}}, dry_run=True)
        sweep.write_baseline({"gut_verified": False}, [], dry_run=True)

        after = (_sha256(report_path), _sha256(baseline_path))
        assert before == after
