"""§SPEC-006 (SEE-1516 substep B1, fingerprint 1df221b87557): wrapper 条件透传。

version_check.sh / issue_status_check.sh 曾无条件透传
`--kill-switch "$KILL_SWITCH"`，而 common_env 的 `autopilots_kill_switch`
把未设 env 默认成 "false" —— 显式 false 覆盖 Python 侧 kill_switch_default()
（paused 文件 OR env 单源），经 wrapper（autopilot 实际触发路径）DISABLED
文件停不掉这两个巡检。本套件钉扎 sweep 已修同款（SEE-1460 决策 6'）：
env 未设 → 不传 flag；显式设置 → 原值透传（true 拦停、false 会话级覆盖）。
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
COMMON_ENV_SRC = REPO_ROOT / "autopilots" / "lib" / "common_env.sh"

WRAPPERS = ["version_check.sh", "issue_status_check.sh"]


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


@pytest.fixture(params=WRAPPERS)
def wrapper_run(tmp_path, stub_env, request):
    """Scratch script_dir with the real wrapper + common_env; returns runner."""
    wrapper_name = request.param
    script_dir = tmp_path / "script_dir"
    (script_dir / "lib").mkdir(parents=True)
    shutil.copy(COMMON_ENV_SRC, script_dir / "lib" / "common_env.sh")
    shutil.copy(REPO_ROOT / "autopilots" / wrapper_name, script_dir / wrapper_name)

    def _run(env_extra=None):
        env = os.environ.copy()
        env.pop("KILL_SWITCH", None)  # deterministic baseline; opt in via env_extra
        env["PATH"] = f"{stub_env['bin']}{os.pathsep}{env['PATH']}"
        env["STUB_LOG"] = str(stub_env["log"])
        env.update(env_extra or {})
        return subprocess.run(
            ["bash", str(script_dir / wrapper_name)],
            capture_output=True, text=True, env=env, timeout=60,
        )

    def _args():
        return Path(stub_env["log"]).read_text(encoding="utf-8")

    return {"run": _run, "args": _args}


def test_flag_omitted_when_env_unset(wrapper_run):
    """env 未设 → 不传 --kill-switch，paused-file 契约由 Python 单源解析。"""
    proc = wrapper_run["run"]()
    assert proc.returncode == 0, proc.stderr
    assert "--kill-switch" not in wrapper_run["args"]()


def test_env_true_passed_through(wrapper_run):
    """KILL_SWITCH=true → 显式透传，主路径拦停由 Python 侧生效。"""
    proc = wrapper_run["run"](env_extra={"KILL_SWITCH": "true"})
    assert proc.returncode == 0, proc.stderr
    assert "--kill-switch true" in wrapper_run["args"]()


def test_env_false_is_explicit_override(wrapper_run):
    """KILL_SWITCH=false → 仍是显式会话级覆盖，原样透传。"""
    proc = wrapper_run["run"](env_extra={"KILL_SWITCH": "false"})
    assert proc.returncode == 0, proc.stderr
    assert "--kill-switch false" in wrapper_run["args"]()
