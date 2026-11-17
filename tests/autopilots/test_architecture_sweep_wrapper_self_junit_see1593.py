"""SEE-1593 §SPEC-001 — L1 self-produced GUT junit in the wrapper.

Route A2 (Owner ruling 2026-11-17): on an L1 round the wrapper runs a full
GUT pass inside the patrol checkout *before* the Python sweep, so the GUT
dimension consumes a junit that shares the sweep's HEAD — no sibling-slot
(GC-volatile) dependency, no platform autopilot config change.

Pinned contract:
- L1 (flag OR UTC Monday), non-dry-run, non-fast, kill-switch off -> run
  ``godot --headless --import`` then ``tests/run_tests.sh --all`` in the
  located patrol repo, producing ``tests/reports/junit_report.xml``.
- Any other round -> no GUT invocation at all.
- Import failure / run failure / timeout is recorded explicitly to stderr and
  NEVER aborts the sweep: the Python layer still runs and surfaces the
  missing input (GUT_UNVERIFIED / escalation). No swallowed errors.

The wrapper + common_env are copied into a scratch script_dir with a scratch
kol.json. ``python3``, ``godot`` and ``date`` on PATH are stubs, so no real
sweep or real GUT run ever happens here.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
WRAPPER_SRC = REPO_ROOT / "autopilots" / "architecture_sweep.sh"
COMMON_ENV_SRC = REPO_ROOT / "autopilots" / "lib" / "common_env.sh"

REPO_NAME = "Acme-KOL"
REDLINE_DIR = "addons/godot_mcp"


def _write(path, content):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(content, encoding="utf-8")


def _git(*args, cwd):
    subprocess.run(["git", "-C", str(cwd)] + list(args), check=True,
                   capture_output=True)


def _make_patrol_repo(ws):
    """A minimal patrol checkout: git repo + materialized redline + runner."""
    repo = ws / REPO_NAME
    repo.mkdir(parents=True)
    _git("init", "-q", "-b", "main", cwd=repo)
    _write(repo / REDLINE_DIR / "keep.txt", "redline\n")
    _write(repo / ".gutconfig.json", json.dumps({
        "dirs": ["res://tests/unit/"],
        "junit_xml_file": "res://tests/reports/junit_report.xml",
        "junit_xml_timestamp": False,
    }))
    _write(repo / "tests" / "reports" / ".gitkeep", "")
    # Same shape as the real runner: cd to repo root, exec "$GODOT".
    _write(repo / "tests" / "run_tests.sh",
           '#!/usr/bin/env bash\ncd "$(dirname "$0")/.."\n'
           '"${GODOT:-godot}" --headless --path "$(pwd)" '
           '--script res://addons/gut/gut_cmdln.gd -gdir=res://tests/unit/ -gexit\n')
    _git("add", "-A", cwd=repo)
    _git("commit", "-q", "-m", "fixture", cwd=repo)
    return repo


def _stub_bin(tmp_path):
    """python3 (logs + exit 0), godot (env-driven), date (fixed weekday)."""
    bin_dir = tmp_path / "stubbin"
    bin_dir.mkdir()

    py = bin_dir / "python3"
    py.write_text(
        "#!/usr/bin/env bash\n"
        'printf \'py %s\\n\' "$*" >> "$STUB_LOG"\n'
        "exit 0\n", encoding="utf-8")
    py.chmod(0o755)

    godot = bin_dir / "godot"
    godot.write_text(
        "#!/usr/bin/env bash\n"
        'printf \'godot %s\\n\' "$*" >> "$STUB_LOG"\n'
        'case " $* " in\n'
        '  *" --import "*)\n'
        '    exit "${STUB_IMPORT_RC:-0}"\n'
        '    ;;\n'
        'esac\n'
        'if [ -n "${STUB_RUN_SLEEP:-}" ]; then sleep "$STUB_RUN_SLEEP"; fi\n'
        'if [ "${STUB_RUN_RC:-0}" != "0" ]; then exit "$STUB_RUN_RC"; fi\n'
        'path=""\n'
        'prev=""\n'
        'for a in "$@"; do\n'
        '  [ "$prev" = "--path" ] && path="$a"\n'
        '  prev="$a"\n'
        'done\n'
        'if [ -n "$path" ] && [ "${STUB_NO_JUNIT:-0}" != "1" ]; then\n'
        '  mkdir -p "$path/tests/reports"\n'
        '  n="${STUB_JUNIT_CASES:-3}"\n'
        '  { echo "<testsuite>"; i=0;\n'
        '    while [ "$i" -lt "$n" ]; do\n'
        '      echo "<testcase name=\\"t$i\\" classname=\\"tests/unit/test_x.gd\\">";\n'
        '      i=$((i+1));\n'
        '    done; echo "</testsuite>"; } > "$path/tests/reports/junit_report.xml"\n'
        'fi\n'
        'exit 0\n', encoding="utf-8")
    godot.chmod(0o755)

    date = bin_dir / "date"
    date.write_text(
        "#!/usr/bin/env bash\n"
        'printf \'%s\\n\' "${STUB_WEEKDAY:-1}"\n', encoding="utf-8")
    date.chmod(0o755)

    return {"bin": bin_dir, "log": tmp_path / "stub_calls.log"}


def _install_script_dir(tmp_path):
    script_dir = tmp_path / "script_dir"
    (script_dir / "lib").mkdir(parents=True, exist_ok=True)
    (script_dir / "configs").mkdir(exist_ok=True)
    shutil.copy(WRAPPER_SRC, script_dir / "architecture_sweep.sh")
    shutil.copy(COMMON_ENV_SRC, script_dir / "lib" / "common_env.sh")
    _write(script_dir / "configs" / "kol.json", json.dumps({
        "target": "kol", "repo_name": REPO_NAME, "redline_dir": REDLINE_DIR,
    }))
    return script_dir


@pytest.fixture()
def env(tmp_path):
    ws = tmp_path / "ws"
    ws.mkdir()
    repo = _make_patrol_repo(ws)
    stub = _stub_bin(tmp_path)
    script_dir = _install_script_dir(tmp_path)
    cwd = tmp_path / "run_cwd"
    cwd.mkdir()
    return {"ws": ws, "repo": repo, "stub": stub,
            "script_dir": script_dir, "cwd": cwd}


def _run(env, extra_args=None, env_extra=None):
    proc_env = os.environ.copy()
    proc_env.pop("KILL_SWITCH", None)
    proc_env.pop("DRY_RUN", None)
    proc_env.pop("ARCH_SWEEP_L1", None)
    proc_env["PATH"] = f"{env['stub']['bin']}{os.pathsep}{proc_env['PATH']}"
    proc_env["STUB_LOG"] = str(env["stub"]["log"])
    proc_env["GODOT"] = str(env["stub"]["bin"] / "godot")
    proc_env.update(env_extra or {})
    args = [str(env["script_dir"] / "architecture_sweep.sh")]
    args.extend(extra_args or [])
    args.append(str(env["ws"]))
    return subprocess.run(["bash", *args], capture_output=True, text=True,
                          cwd=str(env["cwd"]), env=proc_env, timeout=120)


def _log(env):
    p = env["stub"]["log"]
    return p.read_text(encoding="utf-8") if p.is_file() else ""


def _godot_lines(env, needle):
    return [line for line in _log(env).splitlines()
            if line.startswith("godot ") and needle in line]


# =============================================================================
# When the batch runs
# =============================================================================


def test_l1_flag_runs_import_and_full_gut(env):
    proc = _run(env, extra_args=["--l1"], env_extra={"STUB_WEEKDAY": "2"})
    assert proc.returncode == 0, proc.stderr
    assert _godot_lines(env, "--import"), "import step must run on L1"
    assert _godot_lines(env, "-gdir"), "full GUT run must run on L1"
    junit = env["repo"] / "tests" / "reports" / "junit_report.xml"
    assert junit.is_file(), "L1 must produce the junit the Python layer reads"
    assert "py " in _log(env) and "architecture_sweep.py" in _log(env)


def test_utc_monday_alone_runs_gut(env):
    proc = _run(env, env_extra={"STUB_WEEKDAY": "1"})
    assert proc.returncode == 0, proc.stderr
    assert _godot_lines(env, "-gdir")


def test_non_l1_round_skips_gut(env):
    proc = _run(env, env_extra={"STUB_WEEKDAY": "2"})
    assert proc.returncode == 0, proc.stderr
    assert _godot_lines(env, "") == [], "non-L1 must not run GUT"
    assert "architecture_sweep.py" in _log(env)  # static sweep still runs


def test_dry_run_skips_gut(env):
    proc = _run(env, extra_args=["--l1", "--dry-run"])
    assert proc.returncode == 0, proc.stderr
    assert _godot_lines(env, "") == []
    assert "--dry-run" in _log(env)


def test_fast_skips_gut(env):
    proc = _run(env, extra_args=["--l1", "--fast"])
    assert proc.returncode == 0, proc.stderr
    assert _godot_lines(env, "") == []
    assert "--fast" in _log(env)


def test_kill_switch_env_skips_gut(env):
    proc = _run(env, extra_args=["--l1"], env_extra={"KILL_SWITCH": "true"})
    assert proc.returncode == 0, proc.stderr
    assert _godot_lines(env, "") == []


def test_paused_file_skips_gut(env, tmp_path):
    paused = tmp_path / "DISABLED"
    paused.write_text("", encoding="utf-8")
    proc = _run(env, extra_args=["--l1"],
                env_extra={"DEV_FORGE_PAUSED_FILE": str(paused)})
    assert proc.returncode == 0, proc.stderr
    assert _godot_lines(env, "") == []


# =============================================================================
# Non-blocking, explicit failure paths
# =============================================================================


def test_gut_run_failure_is_explicit_but_non_blocking(env):
    proc = _run(env, extra_args=["--l1"], env_extra={"STUB_RUN_RC": "3"})
    assert proc.returncode == 0, proc.stderr
    assert "gut" in proc.stderr.lower() and "fail" in proc.stderr.lower()
    assert "architecture_sweep.py" in _log(env), "sweep must still run"


def test_gut_timeout_is_explicit_but_non_blocking(env):
    proc = _run(env, extra_args=["--l1"], env_extra={
        "STUB_RUN_SLEEP": "5", "ARCH_SWEEP_GUT_TIMEOUT_SECONDS": "1",
    })
    assert proc.returncode == 0, proc.stderr
    assert "timed out" in proc.stderr.lower()
    assert "architecture_sweep.py" in _log(env)


def test_import_failure_skips_run_but_keeps_sweep(env):
    proc = _run(env, extra_args=["--l1"], env_extra={"STUB_IMPORT_RC": "2"})
    assert proc.returncode == 0, proc.stderr
    assert "import" in proc.stderr.lower() and "fail" in proc.stderr.lower()
    assert _godot_lines(env, "--import")
    assert not _godot_lines(env, "-gdir"), "run must not start after import failure"
    assert "architecture_sweep.py" in _log(env)


def test_success_without_junit_is_explicit(env):
    # Run exits 0 but produces no report: that must be surfaced loudly rather
    # than passing as a clean verified round.
    proc = _run(env, extra_args=["--l1"], env_extra={"STUB_NO_JUNIT": "1"})
    assert proc.returncode == 0, proc.stderr
    assert "junit" in proc.stderr.lower()
    assert "architecture_sweep.py" in _log(env)
