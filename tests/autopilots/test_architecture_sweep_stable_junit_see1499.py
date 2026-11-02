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
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

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


# =============================================================================
# §SPEC-B1 护栏 5 — shared 7-day window: boundary verdicts + helper consultation
# (ages are LITERAL days, never derived from JUNIT_MAX_AGE_DAYS, so the
# window's VALUE is pinned behaviourally against silent drift; the helper is
# patched so the boundary is deterministic — no microsecond clock race)
# =============================================================================


class TestSharedWindowBoundary:
    def _resolve_with_patched_age(self, monkeypatch, tmp_path, patched_age):
        repo = _make_repo(tmp_path)
        stable = _stable_junit(str(tmp_path / "stable" / "kol_junit_report.xml"),
                               400, age_seconds=0.0)
        calls = []

        def _fake_age(mtime_epoch):
            calls.append(mtime_epoch)
            return patched_age

        monkeypatch.setattr(sweep, "_junit_age_days", _fake_age)
        path, source = sweep._resolve_junit_source(
            str(repo), GUTCONFIG, "", 3, stable_path=stable
        )
        return stable, path, source, calls

    def test_age_6_5_days_is_fresh(self, monkeypatch, tmp_path):
        stable, path, source, _ = self._resolve_with_patched_age(
            monkeypatch, tmp_path, 6.5)
        assert path == stable
        assert source == f"stable:{stable}"

    def test_age_exactly_7_days_is_fresh(self, monkeypatch, tmp_path):
        # Boundary: the shared comparison is `age > JUNIT_MAX_AGE_DAYS` (stale),
        # so age == window is fresh. Pins `>` against a `>=` regression.
        stable, path, source, _ = self._resolve_with_patched_age(
            monkeypatch, tmp_path, 7.0)
        assert path == stable
        assert source == f"stable:{stable}"

    def test_age_7_5_days_is_stale(self, monkeypatch, tmp_path):
        # A window enlarged past 7 (e.g. 8) would call 7.5 days fresh — the
        # stale verdict at a literal 7.5 pins the window's documented value.
        stable, path, source, _ = self._resolve_with_patched_age(
            monkeypatch, tmp_path, 7.5)
        assert path == ""
        assert source == f"stable:{stable}"

    def test_stale_verdict_comes_from_shared_helper(self, monkeypatch, tmp_path):
        # A patched helper returning a stale age must decide the verdict even
        # though the artifact is fresh on disk: the stable tier consults the
        # shared arithmetic and never re-derives its own.
        stable, path, source, calls = self._resolve_with_patched_age(
            monkeypatch, tmp_path, 100.0)
        assert calls, "stable tier must consult _junit_age_days"
        assert path == ""
        assert source == f"stable:{stable}"


# =============================================================================
# §SPEC-B1 护栏 6 — CLI/env > config composition wired through main()
# =============================================================================


class _StubLock:
    """Drop-in for PidFileLock / WorkspaceMutex: acquires, releases, no I/O."""

    def __init__(self, *_args, **_kwargs):
        pass

    def acquire(self):
        return True

    def release(self):
        pass


class TestMainCliEnvOverConfig:
    @pytest.fixture(autouse=True)
    def _restore_module_globals(self):
        saved_limit = sweep.MAX_FILE_LINES
        saved_fields = list(sweep.GAMESTATE_MIRROR_FIELDS)
        saved_stable = sweep.JUNIT_STABLE_PATH
        saved_errors = sweep._phase_error_count
        yield
        sweep.MAX_FILE_LINES = saved_limit
        sweep.GAMESTATE_MIRROR_FIELDS[:] = saved_fields
        sweep.JUNIT_STABLE_PATH = saved_stable
        sweep._phase_error_count = saved_errors

    def _run_main(self, monkeypatch, tmp_path, cfg, cli_flag=None, env_val=None):
        """Run the real main() with the process boundary mocked out; capture
        the junit_stable_path that reaches _run_l1_checks. No filesystem or
        state writes outside tmp_path (locks, baseline, heartbeat all stubbed).
        """
        captured = {}
        cfg_path = tmp_path / "cfg.json"
        cfg_path.write_text(json.dumps(cfg), encoding="utf-8")
        repo = tmp_path / "repo"
        repo.mkdir()

        monkeypatch.setattr(sweep, "PidFileLock", _StubLock)
        monkeypatch.setattr(sweep, "WorkspaceMutex", _StubLock)
        monkeypatch.setattr(
            sweep, "_sweep_context",
            lambda _args: (str(tmp_path / "ws"), "cafe", True, False, True, False))
        monkeypatch.setattr(sweep, "_locate_repo_root",
                            lambda _ws, _h: str(repo))
        monkeypatch.setattr(sweep, "find_gd_files", lambda *_a, **_k: [])
        monkeypatch.setattr(sweep, "_run_l0_checks", lambda *_a, **_k: (0, []))

        def _fake_l1(repo_root, workspace_root, run_l1, fast_mode, findings,
                     metrics, junit_stable_path=""):
            captured["junit_stable_path"] = junit_stable_path

        monkeypatch.setattr(sweep, "_run_l1_checks", _fake_l1)
        monkeypatch.setattr(sweep, "load_known_findings", lambda: set())
        monkeypatch.setattr(sweep, "ensure_dir", lambda *_a, **_k: None)
        monkeypatch.setattr(sweep, "write_baseline", lambda *_a, **_k: None)
        monkeypatch.setattr(sweep, "write_heartbeat", lambda *_a, **_k: None)
        monkeypatch.setattr(sweep, "build_report", lambda *_a, **_k: {})
        monkeypatch.setattr(sweep, "print_report", lambda *_a, **_k: None)
        monkeypatch.setattr(sweep, "_write_report_file", lambda *_a, **_k: None)
        monkeypatch.setattr(sweep, "_phase_error_count", 0)

        argv = ["architecture_sweep.py", "--config", str(cfg_path)]
        # parse_args evaluates the --workspace-root default eagerly (env var
        # first, then a CWD walk-up that logs an error when nothing matches).
        # Pin the env branch so the walk-up never runs: hermetic in /tmp, and
        # independent of whatever slots happen to exist on the host.
        monkeypatch.setenv("MULTICA_WORKSPACE_ROOT", str(tmp_path / "ws"))
        if cli_flag is not None:
            argv += ["--junit-stable-path", cli_flag]
        if env_val is not None:
            monkeypatch.setenv("ARCH_SWEEP_JUNIT_STABLE_PATH", env_val)
        else:
            monkeypatch.delenv("ARCH_SWEEP_JUNIT_STABLE_PATH", raising=False)
        monkeypatch.setattr(sys, "argv", argv)
        with pytest.raises(SystemExit) as exc:
            sweep.main()
        return exc.value.code, captured

    def test_cli_flag_wins_over_config(self, monkeypatch, tmp_path):
        code, captured = self._run_main(
            monkeypatch, tmp_path,
            cfg={"junit_stable_path": "/cfg/from-config.xml"},
            cli_flag="/cli/flag.xml")
        assert code == 0
        assert captured["junit_stable_path"] == "/cli/flag.xml"

    def test_config_value_used_when_no_cli(self, monkeypatch, tmp_path):
        code, captured = self._run_main(
            monkeypatch, tmp_path,
            cfg={"junit_stable_path": "/cfg/from-config.xml"})
        assert code == 0
        assert captured["junit_stable_path"] == "/cfg/from-config.xml"

    def test_cli_flag_wins_over_env(self, monkeypatch, tmp_path):
        code, captured = self._run_main(
            monkeypatch, tmp_path, cfg={},
            cli_flag="/cli/flag.xml", env_val="/env/from-env.xml")
        assert code == 0
        assert captured["junit_stable_path"] == "/cli/flag.xml"

    def test_cli_flag_used_when_config_unset(self, monkeypatch, tmp_path):
        # CLI must survive an empty config (an `and` composition would yield
        # "" here and silently drop an explicitly requested stable source).
        code, captured = self._run_main(
            monkeypatch, tmp_path, cfg={}, cli_flag="/cli/flag.xml")
        assert code == 0
        assert captured["junit_stable_path"] == "/cli/flag.xml"


# =============================================================================
# §SPEC-B1 护栏 7 — L1 wiring forwards the stable path to the GUT check
# =============================================================================


class TestL1WiringPassthrough:
    def test_run_l1_forwards_junit_stable_path(self, monkeypatch, tmp_path):
        captured = {}

        def _fake_gut(repo_root, workspace_root, junit_stable_path=""):
            captured["junit_stable_path"] = junit_stable_path
            return [], {}

        monkeypatch.setattr(sweep, "check_gut_silent_skip", _fake_gut)
        monkeypatch.setattr(sweep, "check_test_to_code_ratio", lambda _repo: {})
        sweep._run_l1_checks(str(tmp_path), "", True, False, [], {},
                             junit_stable_path="/pinned.xml")
        assert captured["junit_stable_path"] == "/pinned.xml"


# =============================================================================
# §SPEC-B1 护栏 8 — wrapper layer forwards --junit-stable-path (space + equals
# forms), and OMITS the flag entirely when unset (an empty forward would
# override the sweep config and silently disable a configured stable source).
# Judged via a stub python3 that logs its argv (see1460 pattern); the wrapper
# is copied into a scratch script_dir so the repo's own config is untouched.
# =============================================================================

_WRAPPER_SRC = Path(__file__).resolve().parents[2] / "autopilots" / "architecture_sweep.sh"
_COMMON_ENV_SRC = Path(__file__).resolve().parents[2] / "autopilots" / "lib" / "common_env.sh"


def _seed_plain_repo(path):
    """Minimal git repo satisfying sweep_materialize: repo_name dir present,
    `git submodule update --init --recursive` trivially succeeds (no
    gitmodules), redline dir committed and non-empty."""
    path.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", "-b", "main", str(path)],
                   check=True, capture_output=True)
    for args in (("config", "user.email", "t@t.dev"), ("config", "user.name", "t")):
        subprocess.run(["git", "-C", str(path)] + list(args),
                       check=True, capture_output=True)
    (path / "addons" / "godot_mcp").mkdir(parents=True)
    (path / "addons" / "godot_mcp" / "placeholder.txt").write_text("stub\n",
                                                                   encoding="utf-8")
    (path / "README.md").write_text("# fixture\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(path), "add", "-A"],
                   check=True, capture_output=True)
    subprocess.run(["git", "-C", str(path), "commit", "-q", "-m", "seed"],
                   check=True, capture_output=True)
    return path


def _run_wrapper_capture(tmp_path, extra_args):
    """Copy the real wrapper into a scratch script_dir, stub python3 first on
    PATH, run the wrapper with extra_args + workspace_root; return (proc, log
    text of the python3 invocation)."""
    script_dir = tmp_path / "script_dir"
    (script_dir / "lib").mkdir(parents=True)
    (script_dir / "configs").mkdir()
    shutil.copy(_WRAPPER_SRC, script_dir / "architecture_sweep.sh")
    shutil.copy(_COMMON_ENV_SRC, script_dir / "lib" / "common_env.sh")
    (script_dir / "configs" / "kol.json").write_text(
        json.dumps({"target": "kol", "repo_name": "KingOfLikes-Godot",
                    "redline_dir": "addons/godot_mcp"}),
        encoding="utf-8")

    ws = tmp_path / "ws"
    _seed_plain_repo(ws / "KingOfLikes-Godot")

    bin_dir = tmp_path / "stubbin"
    bin_dir.mkdir()
    log = tmp_path / "stub_calls.log"
    stub = bin_dir / "python3"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\n' \"$*\" >> \"$STUB_LOG\"\n"
        "exit 0\n",
        encoding="utf-8")
    stub.chmod(0o755)

    env = os.environ.copy()
    env.pop("KILL_SWITCH", None)
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["STUB_LOG"] = str(log)
    proc = subprocess.run(
        ["bash", str(script_dir / "architecture_sweep.sh"), *extra_args, str(ws)],
        capture_output=True, text=True, cwd=str(tmp_path), env=env, timeout=120)
    log_text = log.read_text(encoding="utf-8") if log.is_file() else ""
    return proc, log_text


class TestWrapperJunitStablePathForwarding:
    def test_space_form_forwarded(self, tmp_path):
        proc, log_text = _run_wrapper_capture(tmp_path, [
            "--dry-run", "--execution-issue-id", "X",
            "--junit-stable-path", "/p/a.xml"])
        assert proc.returncode == 0, proc.stderr
        assert "--junit-stable-path /p/a.xml" in log_text

    def test_equals_form_forwarded(self, tmp_path):
        proc, log_text = _run_wrapper_capture(tmp_path, [
            "--dry-run", "--execution-issue-id", "X",
            "--junit-stable-path=/p/b.xml"])
        assert proc.returncode == 0, proc.stderr
        assert "--junit-stable-path /p/b.xml" in log_text

    def test_flag_absent_omitted_entirely(self, tmp_path):
        proc, log_text = _run_wrapper_capture(tmp_path, [
            "--dry-run", "--execution-issue-id", "X"])
        assert proc.returncode == 0, proc.stderr
        assert "--junit-stable-path" not in log_text

    def test_empty_equals_form_not_forwarded(self, tmp_path):
        proc, log_text = _run_wrapper_capture(tmp_path, [
            "--dry-run", "--execution-issue-id", "X", "--junit-stable-path="])
        assert proc.returncode == 0, proc.stderr
        assert "--junit-stable-path" not in log_text
