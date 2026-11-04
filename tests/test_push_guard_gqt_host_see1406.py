"""§SPEC-013 GQT host 三态测试（SEE-1406 追加工作项）。

对真实 push-guard.sh 全 hook 进行行为测试（非源码镜像断言）。

SEE-1516 §SPEC-021 单轨改约（Owner「方案一 + B」2026-11-04）：push-guard.sh
的 master/main 直推门禁（Check 2a，含 Atlas/Archi 白名单）与 force 拦截段
已删除——master/force deny 唯一防线 = 引擎 gates
（rules.d/push-guard-gates.json push-guard-master-gate / force-push-gate，
repo op kol/gqt 作用域，无任何 agent 白名单；gates 层判定由
tests/test_push_guard_refspec_see1516.sh 承接）。脚本层对 master 直推不再
区分 agent——一律落入 Phase 3 通用检查后透传：

  S1 任意 agent（Bachi/Archi）在 GQT canonical 直推 master → 脚本不再 gate
     （exit 0 + passthrough；deny 归 gates 层）
  S2 Atlas 在 GQT canonical 直推 master → exit 0 + stdin passthrough（同前）
  S3 companion 检出 master 直推 → 不 gate（exit 0，零变化）
  S4 companion 零变化佐证：GQT_REPO_ROOT 指向另一检出时 companion 不受牵连
  S5 KOL host 检出 master 直推 → 脚本不再 gate（exit 0；原 Check 2a 拦截退役）
  S6 GQT canonical 共享分支普通推送仍放行（Check 3-8 保留不动）
辅助 S7：缺省探针路径与 GQT launch/systemd 硬编码一致性（防漂移）。

所有仓库均为 tempfile 临时建仓，绝不触碰 ~/tools/godot-qa-toolkit 规范检出
（S7 只读 grep 两份文件；S1-S6 用 GQT_REPO_ROOT env 指向临时目录）。
"""

import json
import os
import subprocess
from pathlib import Path

import pytest

# dev-forge 布局：hook 脚本位于仓库根 claude-hooks/scripts/（锚定仓库根，
# 不假设仓库父级布局）
HOOK_DIR = Path(__file__).resolve().parents[1]
HOOK_SCRIPT = HOOK_DIR / "claude-hooks" / "scripts" / "push-guard.sh"

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
    # push-guard Check-3 要求 origin 默认分支引用（origin/HEAD|origin/master）
    # 可解析且 HEAD 包含之；无 remote 的裸仓会在 currency 预检被拦，掩盖
    # host/companion 判定本身。补 bare origin 并推送使前置成立。
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    subprocess.run(["git", "-C", str(repo), "remote", "add", "origin", str(origin)],
                   check=True)
    subprocess.run(
        ["git", "-C", str(repo), "-c", "user.email=t@t", "-c", "user.name=t",
         "push", "-q", "-u", "origin", "master"],
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
# S1: 脚本层不再 master-gate（单轨改约）—— Bachi/Archi 同路径透传
# ---------------------------------------------------------------------------

def test_gqt_host_master_push_script_ungated_non_whitelist(tmp_path, tmp_git_repo):
    """单轨改约：脚本对 GQT canonical master 直推不再 gate（deny 归 gates 层）。"""
    (tmp_path / "audit").mkdir()
    cmd = f"cd {tmp_git_repo} && git push origin master"
    code, out, err, payload = run_hook(
        cmd, agent_id=BACHI_ID, agent_name="Bachi",
        gqt_repo_root=str(tmp_git_repo), project_root=tmp_path / "audit",
    )
    assert code == 0, f"expected script passthrough (exit 0), got {code}; stderr={err}"
    assert "禁止直接推送到 master" not in err  # Check 2a 拦截文案已退役
    assert out == payload + "\n"


def test_gqt_host_master_push_script_ungated_archi(tmp_path, tmp_git_repo):
    """Archi 同路径透传——脚本层不再有 agent 白名单分叉。"""
    (tmp_path / "audit").mkdir()
    cmd = f"cd {tmp_git_repo} && git push origin master"
    code, out, err, payload = run_hook(
        cmd, agent_id="809951ab-c70c-48c3-b0d6-7b16b49e1ce3",
        agent_name="Archi", gqt_repo_root=str(tmp_git_repo),
        project_root=tmp_path / "audit",
    )
    assert code == 0, f"expected Archi passthrough (exit 0), got {code}; stderr={err}"
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

def test_kol_host_case_master_push_script_ungated(tmp_path):
    """KOL host 检出 master 直推 → 脚本不再 gate（原 Check 2a 拦截随 E1 退役）。"""
    kol_host = tmp_path / "kol-host"
    kol_host.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "master"], cwd=kol_host, check=True)
    subprocess.run(
        ["git", "-C", str(kol_host), "-c", "user.email=t@t", "-c", "user.name=t",
         "commit", "-q", "--allow-empty", "-m", "init"],
        check=True,
    )
    (kol_host / ".claude" / "hooks").mkdir(parents=True)  # host marker
    # Check-3 前置：origin 默认分支引用可解析且 HEAD 包含之（同 tmp_git_repo）
    origin = tmp_path / "kol-origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    subprocess.run(["git", "-C", str(kol_host), "remote", "add", "origin", str(origin)],
                   check=True)
    subprocess.run(
        ["git", "-C", str(kol_host), "-c", "user.email=t@t", "-c", "user.name=t",
         "push", "-q", "-u", "origin", "master"],
        check=True,
    )
    cmd = f"cd {kol_host} && git push origin master"
    code, out, err, payload = run_hook(
        cmd, agent_id=BACHI_ID, agent_name="Bachi", project_root=kol_host,
    )
    assert code == 0, f"expected script passthrough (exit 0), got {code}; stderr={err}"
    assert "禁止直接推送到 master" not in err
    assert out == payload + "\n"


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
    # GQT 启动接线同一路径（dev-forge 仓不含该检出时守卫跳过）
    launch = HOOK_DIR / "godot-qa-toolkit" / ".dev" / "launch" / "godot-qa-toolkit-start.sh"
    if launch.is_file():
        assert "tools/godot-qa-toolkit" in launch.read_text(encoding="utf-8")


def test_gqt_repo_root_env_pattern_present():
    src = HOOK_SCRIPT.read_text(encoding="utf-8")
    # 识别方式参照 TARGET_REPO_ROOT 哨兵/env 模式
    assert "GQT_REPO_ROOT" in src
