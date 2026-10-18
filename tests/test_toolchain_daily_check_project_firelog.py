"""SEE-1388 §SPEC-011（fingerprint 468a2757121e）：toolchain_daily_check.py 项目级 firelog 检查。

fixture = 临时 repo（.claude/hook-fire.log 项目级落点）+ monkeypatch self.root，
断言 dim_c 输出包含项目级 firelog 项（c3p）且全局项（c3）仍在。只读检查，无网络。
"""

import argparse
import os
import sys

import pytest

TOOLCHAIN_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "toolchain",
)
sys.path.insert(0, TOOLCHAIN_DIR)

import toolchain_daily_check as tdc  # noqa: E402


@pytest.fixture()
def project_repo(tmp_path):
    (tmp_path / ".claude").mkdir(parents=True)
    (tmp_path / ".dev" / "hooks").mkdir(parents=True)
    (tmp_path / ".dev" / "hooks" / "hook-wrapper.sh").write_text("#!/bin/sh\n")
    (tmp_path / ".dev" / "hooks" / "dispatcher.sh").write_text("#!/bin/sh\n")
    log = tmp_path / ".claude" / "hook-fire.log"
    log.write_text(
        "2026-10-10T00:00:00Z [PreToolUse] alias=unified-hook tool=Bash\n"
        "2026-10-10T00:00:01Z [dispatcher.sh] alias=unified-hook\n",
        encoding="utf-8",
    )
    return tmp_path


@pytest.fixture()
def global_firelog(tmp_path, monkeypatch):
    # 隔离缺口修复（CI 红灯棒次）：c3 全局项读模块常量 tdc.HOOK_FIRE_LOG，
    # 原测试依赖宿主 $HOME/.claude/hook-fire.log 存在——干净 runner 上假红。
    # 落点 monkeypatch 到 fixture 内自建临时全局 firelog，任意 HOME 口径下确定。
    home = tmp_path / "global-home"
    (home / ".claude").mkdir(parents=True)
    log = home / ".claude" / "hook-fire.log"
    log.write_text(
        "2026-10-10T00:00:00Z [SessionStart] alias=unified-hook\n"
        "2026-10-10T00:00:01Z [result] alias=unified-hook exit=0\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(tdc, "HOOK_FIRE_LOG", str(log))
    return log


def _check(tmp_path, monkeypatch=None):
    # SEE-1430 §SPEC-012 后 repo_firelog 锚定模块常量 KOL_CHECKOUT_ROOT（不再随 c.root），
    # fixture 隔离需同步 monkeypatch 该常量（与 global_firelog 对 HOOK_FIRE_LOG 同型）。
    if monkeypatch is not None:
        monkeypatch.setattr(tdc, "KOL_CHECKOUT_ROOT", str(tmp_path))
    c = tdc.DailyCheck(argparse.Namespace(report_dir=str(tmp_path), no_net=True, json_mode=False))
    c.root = tmp_path
    return c


def test_dim_c_reports_project_level_firelog(project_repo, global_firelog, monkeypatch):
    c = _check(project_repo, monkeypatch)
    c.dim_c()
    f = next(x for x in c.findings if x["code"] == "c3p")
    assert f["level"] == tdc.OK
    assert "项目级 hook-fire.log" in f["message"]


def test_dim_c_reports_project_firelog_missing(tmp_path, global_firelog, monkeypatch):
    c = _check(tmp_path, monkeypatch)
    c.dim_c()
    f = next(x for x in c.findings if "项目级 hook-fire.log 缺失" in x["message"])
    assert f["level"] in (tdc.MISSING, tdc.WARN)


def test_dim_c_keeps_global_firelog_check(project_repo, global_firelog, monkeypatch):
    c = _check(project_repo, monkeypatch)
    c.dim_c()
    f = next(x for x in c.findings if x["code"] == "c3")
    assert f["level"] == tdc.OK
