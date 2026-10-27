import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
REPO_NAME = "Acme-KOL"
REDLINE_DIR = "addons/godot_mcp"
DIRECT_URL = "https://127.0.0.1:1/nonexistent-see1482/subrepo.git"
DEAD_MIRROR_ROOT = "/nonexistent-see1482-revy-mirror-root"


def _git(*args, cwd):
    return subprocess.run(
        ["git", "-C", str(cwd), *map(str, args)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.rstrip("\n")


def _write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _init_repo(path):
    path.mkdir(parents=True)
    _git("init", "-q", "-b", "main", cwd=path)
    _git("config", "user.email", "revy@qa.invalid", cwd=path)
    _git("config", "user.name", "Revy QA", cwd=path)
    return path


def _seed_subrepo(base, empty=False):
    sub = _init_repo(base / "subrepo")
    if not empty:
        _write(sub / "a.txt", "pinned-content\n")
        _git("add", "a.txt", cwd=sub)
    _git("commit", "-q", "--allow-empty", "-m", "pinned", cwd=sub)
    return sub, _git("rev-parse", "HEAD", cwd=sub)


def _seed_parent(base, empty=False):
    _sub, pinned = _seed_subrepo(base, empty=empty)
    parent = _init_repo(base / REPO_NAME)
    _write(
        parent / ".gitmodules",
        f'[submodule "{REDLINE_DIR}"]\n'
        f"\tpath = {REDLINE_DIR}\n"
        f"\turl = {DIRECT_URL}\n",
    )
    _git("update-index", "--add", "--cacheinfo", f"160000,{pinned},{REDLINE_DIR}", cwd=parent)
    _git("add", ".gitmodules", cwd=parent)
    _write(parent / "README.md", "# independent QA fixture\n")
    _git("add", "README.md", cwd=parent)
    _git("commit", "-q", "-m", "register gitlink", cwd=parent)
    return parent, pinned


def _seed_mirror(root, source, workspace="revy-ws"):
    mirror = Path(root) / workspace / "127.0.0.1+1+nonexistent-see1482+subrepo.git"
    mirror.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "clone", "--quiet", "--bare", str(source), str(mirror)],
        check=True,
        capture_output=True,
    )
    return mirror


def _install_wrapper(base, ref="e34a70c"):
    script_dir = Path(base) / "script_dir"
    (script_dir / "lib").mkdir(parents=True, exist_ok=True)
    (script_dir / "configs").mkdir(exist_ok=True)
    for relative in ("autopilots/architecture_sweep.sh", "autopilots/lib/common_env.sh"):
        content = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "show", f"{ref}:{relative}"],
            check=True,
            capture_output=True,
        ).stdout
        target = script_dir / Path(relative).relative_to("autopilots")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    _write(
        script_dir / "configs" / "kol.json",
        json.dumps({"target": "kol", "repo_name": REPO_NAME, "redline_dir": REDLINE_DIR}),
    )
    return script_dir


def _make_stub(base):
    bin_dir = Path(base) / "stubbin"
    bin_dir.mkdir(parents=True)
    log = Path(base) / "python-calls.log"
    stub = bin_dir / "python3"
    stub.write_text(
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$STUB_LOG\"\nexit 0\n",
        encoding="utf-8",
    )
    stub.chmod(0o755)
    return bin_dir, log


def _run_wrapper(script_dir, workspace, stub, cwd, mirror_root, global_config):
    env = os.environ.copy()
    env.pop("KILL_SWITCH", None)
    env.pop("GIT_CONFIG_COUNT", None)
    for key in list(env):
        if key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
            env.pop(key)
    env["PATH"] = f"{stub[0]}{os.pathsep}{env['PATH']}"
    env["STUB_LOG"] = str(stub[1])
    env["ARCH_SWEEP_MIRROR_ROOT"] = str(mirror_root)
    env["MULTICA_WORKSPACE_ID"] = "revy-ws"
    env["GIT_CONFIG_GLOBAL"] = str(global_config)
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    return subprocess.run(
        [
            "bash",
            str(Path(script_dir) / "architecture_sweep.sh"),
            "--execution-issue-id",
            "QA-SEE-1482",
            str(workspace),
        ],
        capture_output=True,
        text=True,
        cwd=str(cwd),
        env=env,
        timeout=60,
    )


def _global_config(path):
    path = Path(path)
    path.write_text("[user]\n\tname = qa-sentinel\n", encoding="utf-8")
    return path


def _assert_no_config_leak(parent, global_config, original_global, gitmodules):
    assert Path(global_config).read_bytes() == original_global
    assert (parent / ".gitmodules").read_bytes() == gitmodules
    configs = [parent / ".git" / "config"]
    configs.append(parent / ".git" / "modules" / REDLINE_DIR / "config")
    for config in configs:
        if not config.is_file():
            continue
        content = config.read_text(encoding="utf-8").lower()
        assert "insteadof" not in content
        assert "protocol.file.allow" not in content


def test_ab_direct_failure_mirror_fallback_before_after(tmp_path):
    base = tmp_path / "fixture with spaces"
    original_parent, pinned = _seed_parent(base)
    mirror_root = tmp_path / "mirror root with spaces"
    _seed_mirror(mirror_root, base / "subrepo")
    results = {}

    for ref in ("cb6e47a", "e34a70c"):
        workspace = tmp_path / f"{ref} workspace with spaces"
        workspace.mkdir()
        parent = workspace / REPO_NAME
        shutil.copytree(original_parent, parent)
        script_dir = _install_wrapper(tmp_path / ref, ref=ref)
        stub = _make_stub(tmp_path / f"{ref}-stub")
        global_config = _global_config(tmp_path / f"{ref}-gitconfig")
        proc = _run_wrapper(
            script_dir, workspace, stub, tmp_path, mirror_root, global_config
        )
        results[ref] = {
            "returncode": proc.returncode,
            "stderr_tail": proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else "",
            "python_invoked": stub[1].exists(),
        }
        if ref == "cb6e47a":
            assert proc.returncode != 0
            assert not stub[1].exists()
        else:
            assert proc.returncode == 0, proc.stderr
            assert (parent / REDLINE_DIR / "a.txt").read_text() == "pinned-content\n"
            assert _git("rev-parse", "HEAD", cwd=parent / REDLINE_DIR) == pinned
            assert _git("submodule", "status", cwd=parent).startswith(
                f" {pinned} {REDLINE_DIR}"
            )
            assert _git("status", "--porcelain", cwd=parent) == ""
            assert stub[1].is_file()

    print("QA_AB_EVIDENCE=" + json.dumps(results, ensure_ascii=False))


def test_fallback_empty_tree_fails_closed_before_python(tmp_path):
    workspace = tmp_path / "workspace"
    parent, pinned = _seed_parent(workspace, empty=True)
    mirror_root = tmp_path / "mirrors"
    _seed_mirror(mirror_root, workspace / "subrepo")
    script_dir = _install_wrapper(tmp_path / "after")
    stub = _make_stub(tmp_path / "stub")
    global_config = _global_config(tmp_path / "gitconfig")

    proc = _run_wrapper(script_dir, workspace, stub, tmp_path, mirror_root, global_config)

    assert proc.returncode != 0
    assert "still empty" in proc.stderr
    assert "refusing a zero-coverage sweep" in proc.stderr
    assert not stub[1].exists()
    assert _git("submodule", "status", cwd=parent).startswith(f" {pinned} {REDLINE_DIR}")


def test_missing_mirror_fails_loud_and_never_calls_python(tmp_path):
    workspace = tmp_path / "workspace"
    _seed_parent(workspace)
    script_dir = _install_wrapper(tmp_path / "after")
    stub = _make_stub(tmp_path / "stub")
    global_config = _global_config(tmp_path / "gitconfig")

    proc = _run_wrapper(
        script_dir, workspace, stub, tmp_path, DEAD_MIRROR_ROOT, global_config
    )

    assert proc.returncode != 0
    assert "refusing a redline sweep with an unmaterialized gitlink" in proc.stderr
    assert not stub[1].exists()


def test_mirror_missing_pinned_commit_fails_loud_and_never_calls_python(tmp_path):
    workspace = tmp_path / "workspace"
    _seed_parent(workspace)
    other, _ = _seed_subrepo(tmp_path / "other", empty=True)
    mirror_root = tmp_path / "mirrors"
    _seed_mirror(mirror_root, other)
    script_dir = _install_wrapper(tmp_path / "after")
    stub = _make_stub(tmp_path / "stub")
    global_config = _global_config(tmp_path / "gitconfig")

    proc = _run_wrapper(script_dir, workspace, stub, tmp_path, mirror_root, global_config)

    assert proc.returncode != 0
    assert "platform-mirror fallback both failed" in proc.stderr
    assert not stub[1].exists()


@pytest.mark.parametrize("mirror_state", ["valid", "missing_pinned", "absent"])
def test_fallback_has_no_persistent_git_config_leak(tmp_path, mirror_state):
    workspace = tmp_path / f"workspace-{mirror_state}"
    parent, _ = _seed_parent(workspace)
    mirror_root = tmp_path / f"mirrors-{mirror_state}"
    if mirror_state == "valid":
        _seed_mirror(mirror_root, workspace / "subrepo")
    elif mirror_state == "missing_pinned":
        other, _ = _seed_subrepo(tmp_path / "other", empty=True)
        _seed_mirror(mirror_root, other)
    else:
        mirror_root = Path(DEAD_MIRROR_ROOT)
    script_dir = _install_wrapper(tmp_path / f"after-{mirror_state}")
    stub = _make_stub(tmp_path / f"stub-{mirror_state}")
    global_config = _global_config(tmp_path / f"gitconfig-{mirror_state}")
    original_global = global_config.read_bytes()
    gitmodules = (parent / ".gitmodules").read_bytes()

    proc = _run_wrapper(script_dir, workspace, stub, tmp_path, mirror_root, global_config)

    assert (proc.returncode == 0) == (mirror_state == "valid"), proc.stderr
    _assert_no_config_leak(parent, global_config, original_global, gitmodules)


def test_fallback_then_immediate_rerun_is_idempotent_without_mirror(tmp_path):
    workspace = tmp_path / "workspace"
    parent, pinned = _seed_parent(workspace)
    mirror_root = tmp_path / "mirrors"
    _seed_mirror(mirror_root, workspace / "subrepo")
    script_dir = _install_wrapper(tmp_path / "after")
    stub = _make_stub(tmp_path / "stub")
    global_config = _global_config(tmp_path / "gitconfig")

    first = _run_wrapper(script_dir, workspace, stub, tmp_path, mirror_root, global_config)
    second = _run_wrapper(
        script_dir, workspace, stub, tmp_path, DEAD_MIRROR_ROOT, global_config
    )

    assert first.returncode == 0, first.stderr
    assert second.returncode == 0, second.stderr
    assert len(stub[1].read_text().splitlines()) == 2
    assert _git("submodule", "status", cwd=parent).startswith(f" {pinned} {REDLINE_DIR}")
    assert _git("status", "--porcelain", cwd=parent) == ""
