"""Unit tests for SEE-1482 wrapper platform-mirror fallback materialization.

Background: in agent shells, direct git-over-HTTPS to GitHub can be cut at the
TLS egress layer (SEE-1482: 100% `gnutls_handshake() failed` on clone, while
TCP connect succeeds). The SEE-1460 materialization step then hard-fails every
scheduled patrol run. The platform mirror cache (Multica daemon layout
`<workspaces-root>/.repos/<workspace-id>/github.com+tadki+godot-mcp.git`,
a bare repo containing the pinned commit) stays reachable.

§SPEC-1482-1: when the direct `git submodule update --init --recursive`
fails, the wrapper retries ONCE through the platform mirror via a
per-invocation `url.<mirror>.insteadOf=<submodule-url>` rewrite, still
materializing the exact pinned gitlink (git's content addressing enforces
this: a mirror missing the pinned commit fails the update).

§SPEC-1482-2: the fallback must not weaken redline criteria — the redline
non-empty post-check runs on BOTH paths, and the fallback path leaves the
pinned checkout byte-identical (same SHA, clean submodule status).

§SPEC-1482-3: the guard does not regress — when the mirror is unavailable or
the mirror retry fails too, the wrapper exits non-zero with the explicit
redline JSON error; the Python sweep is never invoked.

Constraint (Atlas tasking): the fallback is scoped to the wrapper's own git
invocation — it must NEVER write global git config, repo-local insteadOf
config, or `.gitmodules`.

The real wrapper is copied into a scratch script_dir (with a scratch
configs/kol.json) exactly like the SEE-1460 suite; `python3` on PATH is a
stub that only logs its invocation, so no test ever runs the real sweep.
"""

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
WRAPPER_SRC = REPO_ROOT / "autopilots" / "architecture_sweep.sh"
COMMON_ENV_SRC = REPO_ROOT / "autopilots" / "lib" / "common_env.sh"

REPO_NAME = "Acme-KOL"
REDLINE_DIR = "addons/godot_mcp"
# Direct-clone failure simulated by an https-shaped URL that refuses
# instantly (127.0.0.1:1: no DNS, no network). MUST be https-shaped: the
# submodule helper applies url.insteadOf rewrites to remote URLs only, and
# the production submodule URL (github.com/...) is exactly this shape.
DIRECT_URL = "https://127.0.0.1:1/nonexistent-see1482/subrepo.git"
DEAD_MIRROR_ROOT = "/nonexistent-see1482-mirror-root"


def _git(*args, cwd):
    subprocess.run(
        ["git", "-C", str(cwd)] + list(args),
        check=True,
        capture_output=True,
    )


def _git_out(*args, cwd):
    # rstrip only: `git submodule status` LEADS with a state char (' ' when
    # in sync) that the pinned-checkout assertion must see.
    return subprocess.run(
        ["git", "-C", str(cwd)] + list(args),
        check=True,
        capture_output=True,
        text=True,
    ).stdout.rstrip("\n")


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


def _seed_pair(base):
    """Parent repo whose redline gitlink pins a real subrepo commit, while
    .gitmodules advertises DIRECT_URL (unreachable) — the SEE-1482 shape:
    pinned object exists only in the mirror, direct fetch cannot succeed."""
    _sub, s1 = _seed_subrepo(base)
    parent = _init_repo(base / REPO_NAME)
    _write(
        parent / ".gitmodules",
        f'[submodule "{REDLINE_DIR}"]\n'
        f"\tpath = {REDLINE_DIR}\n"
        f"\turl = {DIRECT_URL}\n",
    )
    _git("update-index", "--add", "--cacheinfo", f"160000,{s1},{REDLINE_DIR}", cwd=parent)
    _git("add", ".gitmodules", cwd=parent)
    _write(parent / "README.md", "# fixture\n")
    _git("add", "README.md", cwd=parent)
    _git("commit", "-q", "-m", "register unmaterialized submodule", cwd=parent)
    return parent, s1


def _seed_parent(base, sub_url):
    """Parent repo with a reachable sub_url (SEE-1460-style, direct success)."""
    _sub, s1 = _seed_subrepo(base)
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


def _mirror_name(url):
    """Independent re-derivation of the platform cache layout rule:
    scheme/user stripped, ':' and '/' folded to '+'.
    https://github.com/tadki/godot-mcp.git -> github.com+tadki+godot-mcp.git"""
    name = re.sub(r"^(https?|ssh|git|file)://", "", url)
    name = re.sub(r"^[^@/]+@", "", name)
    return name.replace(":", "+").replace("/", "+")


def _seed_mirror(mirror_root, workspace_id, source_repo):
    """Bare-clone `source_repo` into the daemon cache layout
    <mirror_root>/<workspace_id>/<mirror-name>; returns the mirror path."""
    name = _mirror_name(DIRECT_URL)
    mirror = mirror_root / workspace_id / name
    mirror.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "clone", "--quiet", "--bare", str(source_repo), str(mirror)],
        check=True,
        capture_output=True,
    )
    return mirror


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


def _run_wrapper(script_dir, workspace_root, stub_env, cwd, env_extra=None, extra_args=None):
    env = os.environ.copy()
    env.pop("KILL_SWITCH", None)  # deterministic baseline; tests opt in via env_extra
    env["PATH"] = f"{stub_env['bin']}{os.pathsep}{env['PATH']}"
    env["STUB_LOG"] = str(stub_env["log"])
    env.update(env_extra or {})
    wrapper_args = [str(script_dir / "architecture_sweep.sh")]
    wrapper_args.extend(extra_args or [])
    if workspace_root is not None:
        wrapper_args.append(str(workspace_root))
    return subprocess.run(
        ["bash", *wrapper_args],
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
# §SPEC-1482-1: direct failure falls back to the platform mirror, still
# materializing the exact pinned gitlink
# ---------------------------------------------------------------------------


def test_mirror_fallback_materializes_pinned_gitlink_when_direct_fails(
    run_env, stub_env, tmp_path
):
    ws = tmp_path / "ws"
    parent, s1 = _seed_pair(ws)
    mirror_root = tmp_path / "mirror-root"
    _seed_mirror(mirror_root, "ws1", ws / "subrepo")
    assert not (parent / REDLINE_DIR).exists()  # precondition: unmaterialized

    proc = _run_wrapper(
        run_env["script_dir"],
        ws,
        stub_env,
        run_env["cwd"],
        env_extra={"ARCH_SWEEP_MIRROR_ROOT": str(mirror_root)},
    )

    assert proc.returncode == 0, proc.stderr
    assert (parent / REDLINE_DIR / "a.txt").is_file()
    # Leading space = initialized AND checked out at the exact pinned commit
    # (no '+' drift, no '-' unmaterialized): content-addressed match.
    status = _git_out("submodule", "status", cwd=parent)
    assert status.startswith(f" {s1} {REDLINE_DIR}")
    stub_calls = run_env["stub"]["log"]
    assert stub_calls.is_file() and "architecture_sweep.py" in _read(stub_calls)


def test_default_mirror_root_follows_multica_daemon_layout(run_env, stub_env, tmp_path):
    """Without ARCH_SWEEP_MIRROR_ROOT the wrapper must find the mirror under
    the real daemon layout: $MULTICA_TASK_WORKSPACES_ROOT/.repos/<ws-id>/<name>."""
    ws = tmp_path / "ws"
    parent, _s1 = _seed_pair(ws)
    ws_root = tmp_path / "mcroot"
    _seed_mirror(ws_root / ".repos", "ws-def", ws / "subrepo")

    proc = _run_wrapper(
        run_env["script_dir"],
        ws,
        stub_env,
        run_env["cwd"],
        env_extra={
            "MULTICA_TASK_WORKSPACES_ROOT": str(ws_root),
            "MULTICA_WORKSPACE_ID": "ws-def",
        },
    )

    assert proc.returncode == 0, proc.stderr
    assert (parent / REDLINE_DIR / "a.txt").is_file()


def test_direct_success_does_not_require_mirror(run_env, stub_env, tmp_path):
    """When the direct update succeeds the mirror is never consulted — a dead
    mirror root must not affect the healthy path (SEE-1460 behaviour kept)."""
    ws = tmp_path / "ws"
    parent = _seed_parent(ws, sub_url=f"file://{ws}/subrepo")

    proc = _run_wrapper(
        run_env["script_dir"],
        ws,
        stub_env,
        run_env["cwd"],
        env_extra={"ARCH_SWEEP_MIRROR_ROOT": DEAD_MIRROR_ROOT},
    )

    assert proc.returncode == 0, proc.stderr
    assert (parent / REDLINE_DIR / "a.txt").is_file()


# ---------------------------------------------------------------------------
# §SPEC-1482-3: mirror unavailable or content mismatch must NOT be success —
# explicit non-zero exit, redline wording, sweep never invoked
# ---------------------------------------------------------------------------


def test_mirror_unavailable_fails_loud_with_redline_guard(run_env, stub_env, tmp_path):
    ws = tmp_path / "ws"
    _seed_pair(ws)

    proc = _run_wrapper(
        run_env["script_dir"],
        ws,
        stub_env,
        run_env["cwd"],
        env_extra={"ARCH_SWEEP_MIRROR_ROOT": DEAD_MIRROR_ROOT},
    )

    assert proc.returncode != 0
    assert "refusing a redline sweep with an unmaterialized gitlink" in proc.stderr
    assert not run_env["stub"]["log"].exists()  # sweep never invoked


def test_mirror_missing_pinned_commit_fails_loud(run_env, stub_env, tmp_path):
    """Content mismatch cannot pass: the mirror lacks the pinned object, so
    git's own checkout fails — the wrapper must surface that as fatal."""
    ws = tmp_path / "ws"
    parent, _s1 = _seed_pair(ws)
    # Mirror built from a DIFFERENT subrepo (empty tree at a different commit):
    # the pinned commit object is absent from the mirror.
    _other, _other_head = _seed_subrepo(ws / "mirror-src", empty_tree=True)
    mirror_root = tmp_path / "mirror-root"
    _seed_mirror(mirror_root, "ws1", ws / "mirror-src" / "subrepo")

    proc = _run_wrapper(
        run_env["script_dir"],
        ws,
        stub_env,
        run_env["cwd"],
        env_extra={"ARCH_SWEEP_MIRROR_ROOT": str(mirror_root)},
    )

    assert proc.returncode != 0
    assert "platform-mirror" in proc.stderr
    assert not run_env["stub"]["log"].exists()  # sweep never invoked


# ---------------------------------------------------------------------------
# Atlas constraint: fallback scoped to the wrapper's own git invocation —
# never global git config, never repo-local insteadOf, never .gitmodules
# ---------------------------------------------------------------------------


def test_fallback_writes_no_git_config_and_no_gitmodules_change(
    run_env, stub_env, tmp_path
):
    ws = tmp_path / "ws"
    parent, _s1 = _seed_pair(ws)
    mirror_root = tmp_path / "mirror-root"
    _seed_mirror(mirror_root, "ws1", ws / "subrepo")
    global_cfg = tmp_path / "gitconfig"
    global_cfg.write_text("", encoding="utf-8")
    gitmodules_before = (parent / ".gitmodules").read_bytes()

    proc = _run_wrapper(
        run_env["script_dir"],
        ws,
        stub_env,
        run_env["cwd"],
        env_extra={
            "ARCH_SWEEP_MIRROR_ROOT": str(mirror_root),
            "GIT_CONFIG_GLOBAL": str(global_cfg),
        },
    )

    assert proc.returncode == 0, proc.stderr
    assert global_cfg.read_text() == ""  # global config untouched
    local = subprocess.run(
        ["git", "-C", str(parent), "config", "--local", "--get-regexp", r"^url\."],
        capture_output=True,
        text=True,
    )
    assert local.returncode != 0 or local.stdout.strip() == ""  # no insteadOf leak
    assert (parent / ".gitmodules").read_bytes() == gitmodules_before
