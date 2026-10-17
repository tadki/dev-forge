"""§SPEC-013 GQT host 三态测试（SEE-1406 追加工作项）。

对真实 push-guard.sh 全 hook 进行行为测试（非源码镜像断言）：
GQT canonical 检出纳入 host 判定后——
  S1 非白名单 agent（Bachi）在 GQT canonical 直推 master → exit 2
  S2 Atlas 在 GQT canonical 直推 master → exit 0 + stdin passthrough
  S3 companion 检出（GQT task checkout 等价物）master 直推 → 不 gate（exit 0）
  S4 companion 零变化佐证：GQT_REPO_ROOT 指向另一检出时 companion 不受牵连
  S5 KOL host 路径零变化锚点（PROJECT_ROOT=.claude/hooks marker 仍拦截）
  S6 GQT canonical 共享分支普通推送仍放行（master-only 拦截，共享分支照推）
辅助 S7：缺省探针路径与 GQT launch/systemd 硬编码一致性（防漂移）。

所有仓库均为 tempfile 临时建仓，绝不触碰 ~/tools/godot-qa-toolkit 规范检出
（S7 只读 grep 两份文件；S1-S6 用 GQT_REPO_ROOT env 指向临时目录）。
"""

import json
import os
import subprocess
from pathlib import Path

import pytest

HOOK_DIR = Path(__file__).resolve().parents[3]
HOOK_SCRIPT = HOOK_DIR / ".claude" / "hooks" / "scripts" / "push-guard.sh"

ATLAS_ID = "fac3e3a1-dcda-498d-8613-e8c2811f3ef5"
BACHI_ID = "a5c250e8-7257-466e-b45a-03f995c7206c"


@pytest.fixture
def tmp_git_repo(tmp_path):
    """Create a minimal git repo with one empty master commit."""
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "master"], cwd=repo, check=True)
    subprocess.run(
        ["git", "-C", str(repo), "-c", "user.email=t@t", "-c", "user.name=t",
         "commit", "-q", "--allow-empty", "-m", "init"],
        check=True,
    )
    return repo


def run_hook(command: str, *, agent_id: str, agent_name: str,
             gqt_repo_root: str | None = None, project_root: Path | None = None) -> tuple[int, str, str, str]:
    """Run the real push-guard hook on a synthetic PreToolUse payload.

    PROJECT_ROOT defaults to the test's tmp_path (NOT the KOL checkout) so the
    KOL-host PROJECT_ROOT branch is inert by default; MULTICA_TASK_ID empty
    skips working-branch resolution. Returns (exit, stdout, stderr, passthrough_json).
    """
    env = dict(os.environ)
    env.pop("GQT_REPO_ROOT", None)
    env["PROJECT_ROOT"] = str(project_root or Path("/nonexistent-see1406-audit"))
    env["MULTICA_AGENT_ID"] = agent_id
    env["MULTICA_AGENT_NAME"] = agent_name
    env["MULTICA_TASK_ID"] = ""
    if gqt_repo_root is not None:
        env["GQT_REPO_ROOT"] = gqt_repo_root
    payload = json.dumps({"tool_input": {"command": command}})
    proc = subprocess.run(
        ["bash", str(HOOK_SCRIPT)],
        input=payload, capture_output=True, text=True, env=env, timeout=30,
    )
    return proc.returncode, proc.stdout, proc.stderr, payload


# ---------------------------------------------------------------------------
# S1: 非白名单 deny — Bachi 在 GQT canonical 直推 master
# ---------------------------------------------------------------------------

def test_gqt_host_master_push_denied_for_non_whitelist(tmp_path, tmp_git_repo):
    # S1 用 GQT_REPO_ROOT 显式指向临时 canonical —— PATH 边界不碰规范检出
    (tmp_path / "audit").mkdir()
    cmd = f"cd {tmp_git_repo} && git push origin master"
    code, _out, err, _payload = run_hook(
        cmd, agent_id=BACHI_ID, agent_name="Bachi",
        gqt_repo_root=str(tmp_git_repo), project_root=tmp_path / "audit",
    )
    assert code == 2, f"expected deny (exit 2), got {code}; stderr={err}"
    assert "master" in err


def test_gqt_host_master_push_denied_for_whitelist_affect_check(tmp_path, tmp_git_repo):
    # ARCHI 同属白名单：抽查 Archi 放行（KOL host 行为一致性）
    (tmp_path / "audit").mkdir()
    cmd = f"cd {tmp_git_repo} && git push origin master"
    code, out, err, payload = run_hook(
        cmd, agent_id="809951ab-c70c-48c3-b0d6-7b16b49e1ce3",
        agent_name="Archi", gqt_repo_root=str(tmp_git_repo),
        project_root=tmp_path / "audit",
    )
    assert code == 0, f"expected Archi allow (exit 0), got {code}; stderr={err}"
    assert out == payload + "\n"


# ---------------------------------------------------------------------------
# S2/S3: Atlas allow / companion 不 gate
# ---------------------------------------------------------------------------

def test_gqt_host_master_push_allowed_for_atlas(tmp_path, tmp_git_repo):
    (tmp_path / "audit").mkdir()
    cmd = f"cd {tmp_git_repo} && git push origin master"
    code, out, err, payload = run_hook(
        cmd, agent_id=ATLAS_ID, agent_name="Atlas",
        gqt_repo_root=str(tmp_git_repo), project_root=tmp_path / "audit",
    )
    assert code == 0, f"expected allow (exit 0), got {code}; stderr={err}"
    # passthrough：stdin JSON 原样透传
    assert out == payload + "\n"


def test_companion_master_push_not_gated(tmp_path, tmp_git_repo):
    """companion（非 canonical、无 .claude/hooks、≠PROJECT_ROOT）master 直推放行。

    佐证 see526/see1268 companion 决策零变化：GQT canonical 判定不吞并
    非同名 git root 的其他检出。
    """
    # 本 fixture repo 不带 .claude/hooks，也未设 GQT_REPO_ROOT —— 是纯 companion
    cmd = f"cd {tmp_git_repo} && git push origin master"
    code, out, err, payload = run_hook(
        cmd, agent_id=BACHI_ID, agent_name="Bachi",
    )
    assert code == 0, f"expected companion ungated (exit 0), got {code}; stderr={err}"
    assert out == payload + "\n"


def test_companion_master_push_not_gated_when_gqt_root_points_elsewhere(tmp_path, tmp_git_repo):
    """GQT_REPO_ROOT 指向另一检出时，本 repo 不得被误判为 GQT host。"""
    (tmp_path / "other-gqt").mkdir()
    other = tmp_path / "other-gqt"
    subprocess.run(["git", "init", "-q", "-b", "master"], cwd=other, check=True)
    (tmp_path / "audit").mkdir()
    cmd = f"cd {tmp_git_repo} && git push origin master"
    code, out, err, payload = run_hook(
        cmd, agent_id=BACHI_ID, agent_name="Bachi",
        gqt_repo_root=str(other), project_root=tmp_path / "audit",
    )
    assert code == 0, f"pointing env elsewhere must keep companion ungated; got exit {code}, stderr={err}"
    assert out == payload + "\n"


# ---------------------------------------------------------------------------
# S5: KOL host 路径零变化锚点（.claude/hooks marker host 仍拦截非白名单）
# ---------------------------------------------------------------------------

def test_kol_host_case_master_push_still_denied(tmp_path):
    """KOL host 判定（.claude/hooks marker 等价物 + PROJECT_ROOT）零变化。"""
    kol_host = tmp_path / "kol-host"
    kol_host.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "master"], cwd=kol_host, check=True)
    subprocess.run(
        ["git", "-C", str(kol_host), "-c", "user.email=t@t", "-c", "user.name=t",
         "commit", "-q", "--allow-empty", "-m", "init"],
        check=True,
    )
    (kol_host / ".claude" / "hooks").mkdir(parents=True)  # host marker
    cmd = f"cd {kol_host} && git push origin master"
    code, _out, err, _payload = run_hook(
        cmd, agent_id=BACHI_ID, agent_name="Bachi", project_root=kol_host,
    )
    assert code == 2, f"expected KOL host deny (exit 2), got {code}; stderr={err}"
    assert "master" in err


# ---------------------------------------------------------------------------
# S6: GQT canonical 内共享分支普通推送放行（master-only 拦截）
# ---------------------------------------------------------------------------

def test_gqt_host_shared_branch_push_allowed(tmp_path, tmp_git_repo):
    (tmp_path / "audit").mkdir()
    cmd = f"cd {tmp_git_repo} && git push origin HEAD:refs/heads/shared/SEE-1406"
    code, out, err, payload = run_hook(
        cmd, agent_id=BACHI_ID, agent_name="Bachi",
        gqt_repo_root=str(tmp_git_repo), project_root=tmp_path / "audit",
    )
    assert code == 0, f"expected shared-branch allow (exit 0), got {code}; stderr={err}"
    assert out == payload + "\n"


# ---------------------------------------------------------------------------
# S7: 缺省探针路径漂移锁——与 GQT launch/systemd 硬编码一致
# ---------------------------------------------------------------------------

def test_default_probe_path_matches_gqt_wiring():
    """缺省探针路径与 GQT 检出的 launch 硬编码必须同源（~/tools/godot-qa-toolkit）。"""
    src = HOOK_SCRIPT.read_text(encoding="utf-8")
    assert "tools/godot-qa-toolkit" in src, "push-guard default probe path missing"
    # GQT 启动接线同一路径（本文件所在 KOL 检出的 sibling checkout 载体）
    launch = HOOK_DIR / "godot-qa-toolkit" / ".dev" / "launch" / "godot-qa-toolkit-start.sh"
    if launch.is_file():
        assert "tools/godot-qa-toolkit" in launch.read_text(encoding="utf-8")


def test_gqt_repo_root_env_pattern_present():
    src = HOOK_SCRIPT.read_text(encoding="utf-8")
    # 识别方式参照 TARGET_REPO_ROOT 哨兵/env 模式
    assert "GQT_REPO_ROOT" in src
