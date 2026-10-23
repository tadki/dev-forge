"""Unit tests for SEE-1460 wrapper-layer submodule materialization.

§SPEC-1460-A: architecture_sweep.sh must locate the patrol repo the same way
architecture_sweep.py does (workspace root + configs/kol.json `repo_name`,
mirroring _locate_repo_root's ladder) and run
`git submodule update --init --recursive` BEFORE invoking the Python sweep —
restoring redline coverage on the autopilot checkout path (SEE-1459: five
consecutive `redline=skipped_uninitialized` runs).

§SPEC-1460-B: materialization failure is FATAL — non-zero exit plus an
explicit error message, never a silent downgrade into the
REDLINE_SKIPPED_UNINITIALIZED skip (SEE-1434 decision 1: the Python-side skip
guard remains the in-script fallback; the wrapper shell layer owns the
write-side materialization action).

§SPEC-1460-C: on success the wrapper passes through to architecture_sweep.py
(stubbed here); the Python layer itself stays untouched — the SEE-1434 guard
suite keeps asserting the skip semantics against the real module.

The real wrapper is copied into a scratch script_dir (with a scratch
configs/kol.json) so tests control `repo_name` without touching the repo's
own config. `python3` on PATH is a stub that only logs its invocation, so no
test ever runs the real sweep.
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
WRAPPER_SRC = REPO_ROOT / "autopilots" / "architecture_sweep.sh"
COMMON_ENV_SRC = REPO_ROOT / "autopilots" / "lib" / "common_env.sh"

REPO_NAME = "Acme-KOL"
REDLINE_DIR = "addons/godot_mcp"


def _git(*args, cwd):
    subprocess.run(
        ["git", "-C", str(cwd)] + list(args),
        check=True,
        capture_output=True,
    )


def _git_out(*args, cwd):
    return subprocess.run(
        ["git", "-C", str(cwd)] + list(args),
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _write(path, content):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(content, encoding="utf-8")


def _init_repo(path):
    """Create an empty git repo at `path` with a fixed identity; returns path."""
    path.mkdir(parents=True)
    _git("init", "-q", "-b", "main", cwd=path)
    _git("config", "user.email", "t@t.dev", cwd=path)
    _git("config", "user.name", "t", cwd=path)
    return path


def _seed_subrepo(base, empty_tree=False):
    """Sub repo holding one committed file (or an empty tree); returns (path, head)."""
    sub = _init_repo(base / "subrepo")
    if not empty_tree:
        _write(sub / "a.txt", "a-one\n")
        _git("add", "-A", cwd=sub)
    _git("commit", "-q", "--allow-empty", "-m", "s1", cwd=sub)
    return sub, _git_out("rev-parse", "HEAD", cwd=sub)


def _seed_parent(base, sub_url, empty_tree=False):
    """Parent repo with a registered-but-unmaterialized addons/godot_mcp gitlink."""
    _sub, s1 = _seed_subrepo(base, empty_tree=empty_tree)
    parent = _init_repo(base / REPO_NAME)
    _write(
        parent / ".gitmodules",
        f'[submodule "{REDLINE_DIR}"]\n'
        f"\tpath = {REDLINE_DIR}\n"
        f"\turl = {sub_url}\n",
    )
    _git("update-index", "--add", "--cacheinfo", f"160000,{s1},{REDLINE_DIR}", cwd=parent)
    _git("add", ".gitmodules", cwd=parent)
    _write(parent / "README.md", "# fixture\n")
    _git("add", "README.md", cwd=parent)
    _git("commit", "-q", "-m", "register unmaterialized submodule", cwd=parent)
    return parent


@pytest.fixture()
def stub_env(tmp_path):
    """A stub `python3` that logs its args and exits 0 (first on PATH)."""
    bin_dir = tmp_path / "stubbin"
    bin_dir.mkdir()
    log = tmp_path / "stub_calls.log"
    stub = bin_dir / "python3"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        'printf \'%s\\n\' "$*" >> "$STUB_LOG"\n'
        "exit 0\n",
        encoding="utf-8",
    )
    stub.chmod(0o755)
    return {"bin": bin_dir, "log": log}


def _install_script_dir(tmp_path, config):
    """Copy the real wrapper + common_env into a scratch dir with a scratch kol.json."""
    script_dir = tmp_path / "script_dir"
    (script_dir / "lib").mkdir(parents=True, exist_ok=True)
    (script_dir / "configs").mkdir(exist_ok=True)
    shutil.copy(WRAPPER_SRC, script_dir / "architecture_sweep.sh")
    shutil.copy(COMMON_ENV_SRC, script_dir / "lib" / "common_env.sh")
    _write(script_dir / "configs" / "kol.json", json.dumps(config))
    return script_dir


def _run_wrapper(script_dir, workspace_root, stub_env, cwd, env_extra=None):
    env = os.environ.copy()
    env["PATH"] = f"{stub_env['bin']}{os.pathsep}{env['PATH']}"
    env["STUB_LOG"] = str(stub_env["log"])
    env.update(env_extra or {})
    return subprocess.run(
        ["bash", str(script_dir / "architecture_sweep.sh"), str(workspace_root)],
        capture_output=True,
        text=True,
        cwd=str(cwd),
        env=env,
        timeout=120,
    )


def _read(path):
    return Path(path).read_text(encoding="utf-8")


@pytest.fixture()
def run_env(tmp_path, stub_env):
    """Neutral CWD + scratch script_dir with the standard kol.json."""
    cwd = tmp_path / "run_cwd"
    cwd.mkdir()
    config = {"target": "kol", "repo_name": REPO_NAME, "redline_dir": REDLINE_DIR}
    script_dir = _install_script_dir(tmp_path, config)
    return {"cwd": cwd, "script_dir": script_dir, "stub": stub_env}


# ---------------------------------------------------------------------------
# §SPEC-1460-A: materialize before the sweep, resolving the repo via kol.json
# ---------------------------------------------------------------------------


def test_materializes_uninitialized_gitlink_before_python(run_env, tmp_path):
    ws = tmp_path / "ws"
    parent = _seed_parent(ws, sub_url=f"file://{ws}/subrepo")
    assert not (parent / REDLINE_DIR).exists()  # precondition: unmaterialized

    proc = _run_wrapper(run_env["script_dir"], ws, run_env["stub"], run_env["cwd"])

    assert proc.returncode == 0, proc.stderr
    assert (parent / REDLINE_DIR / "a.txt").is_file()
    # The Python sweep only runs after materialization succeeded.
    stub_calls = run_env["stub"]["log"]
    assert stub_calls.is_file() and "architecture_sweep.py" in _read(stub_calls)


def test_repo_resolution_uses_kol_json_repo_name_not_hardcoded(run_env, tmp_path):
    ws = tmp_path / "ws"
    parent = _seed_parent(ws, sub_url=f"file://{ws}/subrepo")
    # Decoy: a hardcoded KingOfLikes-Godot lookup would find (and fail on) this.
    decoy = ws / "KingOfLikes-Godot"
    decoy.mkdir()

    proc = _run_wrapper(run_env["script_dir"], ws, run_env["stub"], run_env["cwd"])

    assert proc.returncode == 0, proc.stderr
    assert (parent / REDLINE_DIR / "a.txt").is_file()
    assert not any(decoy.iterdir())  # decoy untouched
    status = _git_out("submodule", "status", cwd=parent)
    assert not status.startswith("-")  # no leading '-' = materialized


def test_arch_sweep_config_override_is_honored(run_env, stub_env, tmp_path):
    ws = tmp_path / "ws"
    parent = _seed_parent(ws, sub_url=f"file://{ws}/subrepo")
    script_dir = _install_script_dir(
        tmp_path,
        {"target": "kol", "repo_name": "Wrong-Name", "redline_dir": REDLINE_DIR},
    )
    override = tmp_path / "override-kol.json"
    _write(override, json.dumps({"repo_name": REPO_NAME, "redline_dir": REDLINE_DIR}))

    proc = _run_wrapper(
        script_dir,
        ws,
        stub_env,
        run_env["cwd"],
        env_extra={"ARCH_SWEEP_CONFIG": str(override)},
    )

    assert proc.returncode == 0, proc.stderr
    assert (parent / REDLINE_DIR / "a.txt").is_file()


def test_rerun_on_materialized_repo_is_noop_success(run_env, stub_env, tmp_path):
    ws = tmp_path / "ws"
    parent = _seed_parent(ws, sub_url=f"file://{ws}/subrepo")

    first = _run_wrapper(run_env["script_dir"], ws, stub_env, run_env["cwd"])
    assert first.returncode == 0, first.stderr
    calls_after_first = _read(stub_env["log"]).count("\n")

    second = _run_wrapper(run_env["script_dir"], ws, stub_env, run_env["cwd"])

    assert second.returncode == 0, second.stderr
    assert (parent / REDLINE_DIR / "a.txt").is_file()
    assert _read(stub_env["log"]).count("\n") == calls_after_first + 1


# ---------------------------------------------------------------------------
# §SPEC-1460-B: every materialization failure path is explicit and fatal
# ---------------------------------------------------------------------------


def test_submodule_update_failure_is_fatal(run_env, tmp_path):
    ws = tmp_path / "ws"
    # Local path that does not exist: clone fails deterministically, offline.
    _seed_parent(ws, sub_url="/nonexistent-see1460/subrepo.git")

    proc = _run_wrapper(run_env["script_dir"], ws, run_env["stub"], run_env["cwd"])

    assert proc.returncode != 0
    assert "submodule" in proc.stderr.lower()
    assert not run_env["stub"]["log"].exists()  # sweep never invoked


def test_repo_not_found_is_fatal(run_env, tmp_path):
    ws = tmp_path / "empty-ws"
    ws.mkdir()

    proc = _run_wrapper(run_env["script_dir"], ws, run_env["stub"], run_env["cwd"])

    assert proc.returncode != 0
    assert REPO_NAME in proc.stderr
    assert "submodule" in proc.stderr.lower()
    assert not run_env["stub"]["log"].exists()


def test_empty_redline_dir_after_update_is_fatal(run_env, tmp_path):
    ws = tmp_path / "ws"
    # Pinned commit has an empty tree: update "succeeds" but materializes nothing.
    _seed_parent(ws, sub_url=f"file://{ws}/subrepo", empty_tree=True)

    proc = _run_wrapper(run_env["script_dir"], ws, run_env["stub"], run_env["cwd"])

    assert proc.returncode != 0
    assert "empty" in proc.stderr.lower()
    assert not run_env["stub"]["log"].exists()


def test_missing_config_is_fatal(run_env, tmp_path):
    ws = tmp_path / "ws"
    _seed_parent(ws, sub_url=f"file://{ws}/subrepo")
    (run_env["script_dir"] / "configs" / "kol.json").unlink()

    proc = _run_wrapper(run_env["script_dir"], ws, run_env["stub"], run_env["cwd"])

    assert proc.returncode != 0
    assert "kol.json" in proc.stderr
    assert not run_env["stub"]["log"].exists()


# ---------------------------------------------------------------------------
# §SPEC-1460-C: Python layer untouched (sanity: real sweep module unmodified
# semantics are owned by test_architecture_sweep_submodule_guard_see1434.py;
# here we only pin the wrapper→python contract surface).
# ---------------------------------------------------------------------------


def test_wrapper_passes_workspace_root_through_to_python(run_env, tmp_path):
    ws = tmp_path / "ws"
    _seed_parent(ws, sub_url=f"file://{ws}/subrepo")

    proc = _run_wrapper(run_env["script_dir"], ws, run_env["stub"], run_env["cwd"])

    assert proc.returncode == 0, proc.stderr
    stub_args = _read(run_env["stub"]["log"])
    assert f"--workspace-root {ws}" in stub_args
    assert "architecture_sweep.py" in stub_args


def test_python_layer_has_no_materialization_code():
    """Guard the layer split: architecture_sweep.py must NOT gain a
    submodule-update call — materialization lives only in the wrapper."""
    sweep_src = (REPO_ROOT / "autopilots" / "architecture_sweep.py").read_text(
        encoding="utf-8"
    )
    assert "submodule" in sweep_src  # the SEE-1434 skip guard mentions it
    assert "submodule', 'update'" not in sweep_src
    assert '"update", "--init"' not in sweep_src
