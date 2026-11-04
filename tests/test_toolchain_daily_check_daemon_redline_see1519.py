"""SEE-1519 §SPEC-004（Owner 2026-11-04 语义裁定修订）: F3 守护停摆 warn + 注册级 enabled 开关.

判据（issue description §SPEC-004 修订版）:
  - repo-sync 是可手动开关项：enabled 注册 daemon 停摆 → **warn**，不进 redlines、
    health 不 REDLINE（原「停摆→红线」方向被 Owner 裁定作废回退）
  - `"enabled": false` 注册（手动停用）→ 日检记 info 观测，不 warn 不红线
  - 非宿主上下文（repo_path 不存在，CI / 非宿主机）→ warn 观测
  - 配置类缺陷（未声明 pid_file / pid 内容非法）语义不变，维持 warn
  - 测试不得把开关状态硬编码为红线状态（Owner 裁定目标 4）

fixture = 临时 repo 树 + repo-sync/repos.d/ 注册文件 + pid 文件形态注入。
"""

import argparse
import json
import os
import subprocess
import sys

import pytest

TOOLCHAIN_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "toolchain",
)
sys.path.insert(0, TOOLCHAIN_DIR)

import toolchain_daily_check as tdc  # noqa: E402


def _write_registration(root, repo_path, pid_file=None, enabled=None):
    """注册文件 fixture；enabled=None = 缺省键（等同 true），仅显式传入才落键。"""
    repos_d = root / "repo-sync" / "repos.d"
    repos_d.mkdir(parents=True, exist_ok=True)
    cfg = {
        "name": "devforge",
        "repo_path": str(repo_path),
        "branch": "main",
        "pid_file": str(pid_file) if pid_file else "/tmp/see1519-unused.pid",
    }
    if enabled is not None:
        cfg["enabled"] = enabled
    (repos_d / "devforge.json").write_text(
        json.dumps(cfg), encoding="utf-8")
    return cfg


@pytest.fixture()
def host_repo(tmp_path):
    """宿主上下文 fixture: repo_path 存在（模拟工具链宿主机）。"""
    (tmp_path / "srv" / "dev-forge").mkdir(parents=True)
    return tmp_path


def _make_check(tmp_path, monkeypatch):
    # F2 运行态门注入不可判态，隔离本套件于 F3 断言（F2 语义不受本次返工影响）
    monkeypatch.setattr(
        tdc.DailyCheck, "_systemctl_output",
        lambda self, args: (None, None))
    c = tdc.DailyCheck(
        argparse.Namespace(report_dir=str(tmp_path), no_net=True, json_mode=False))
    c.root = tmp_path
    return c


def _dead_pid():
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


def test_f3_enabled_host_pid_missing_is_warn_not_redline(host_repo, tmp_path,
                                                         monkeypatch):
    # Owner 裁定核心语义: enabled 注册宿主停摆 → warn，不进 redline
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file,
                        enabled=True)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "daemon_pid_missing")
    assert f["level"] == tdc.WARN
    assert c.redlines == []
    assert c.dim_summary["F"]["status"] != tdc.REDLINE


def test_f3_enabled_host_dead_pid_is_warn_not_redline(host_repo, tmp_path,
                                                      monkeypatch):
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    pid_file.write_text("%d\n" % _dead_pid(), encoding="utf-8")
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file,
                        enabled=True)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "daemon_dead")
    assert f["level"] == tdc.WARN
    assert c.redlines == []


def test_f3_enabled_key_absent_defaults_true(host_repo, tmp_path, monkeypatch):
    # 缺省 enabled 键（gqt/kol 形态）等同启用：停摆仍走 warn 观测
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "daemon_pid_missing")
    assert f["level"] == tdc.WARN
    assert not any(x["code"] == "daemon_disabled" for x in c.findings)


def test_f3_disabled_registration_is_info(host_repo, tmp_path, monkeypatch):
    # enabled=false 手动停用 → info 观测，不 warn 不红线，且不再报 daemon 停摆
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file,
                        enabled=False)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "daemon_disabled")
    assert f["level"] == tdc.INFO
    assert not any(x["code"] == "daemon_pid_missing" for x in c.findings)
    assert not any(x["code"] == "daemon_dead" for x in c.findings)
    assert c.redlines == []


def test_f3_disabled_registration_skips_dead_pid_check(host_repo, tmp_path,
                                                       monkeypatch):
    # 停用注册即使 pid 文件指向死进程也只记 info（开关优先于存活检查）
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    pid_file.write_text("%d\n" % _dead_pid(), encoding="utf-8")
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file,
                        enabled=False)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    assert next(x for x in c.findings if x["code"] == "daemon_disabled")["level"] == tdc.INFO
    assert not any(x["code"] == "daemon_dead" for x in c.findings)
    assert c.redlines == []


def test_f3_host_alive_pid_stays_ok(host_repo, tmp_path, monkeypatch):
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    pid_file.write_text("%d\n" % os.getpid(), encoding="utf-8")
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "f3")
    assert f["level"] == tdc.OK
    assert c.redlines == []


def test_f3_non_host_pid_missing_stays_warn(host_repo, tmp_path, monkeypatch):
    # CI / 非宿主机: repo_path 不存在 → 注册不适用于本环境 → warn 不红线
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    _write_registration(host_repo, tmp_path / "nonexistent" / "checkout", pid_file)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "daemon_pid_missing")
    assert f["level"] == tdc.WARN
    assert c.redlines == []


def test_f3_non_host_dead_pid_stays_warn(host_repo, tmp_path, monkeypatch):
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    pid_file.write_text("%d\n" % _dead_pid(), encoding="utf-8")
    _write_registration(host_repo, tmp_path / "nonexistent" / "checkout", pid_file)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "daemon_dead")
    assert f["level"] == tdc.WARN
    assert c.redlines == []


def test_f3_undeclared_pid_file_unchanged_warn(host_repo, tmp_path, monkeypatch):
    cfg = _write_registration(host_repo, host_repo / "srv" / "dev-forge")
    del cfg["pid_file"]  # 未声明 pid_file
    repos_d = host_repo / "repo-sync" / "repos.d"
    (repos_d / "devforge.json").write_text(json.dumps(cfg), encoding="utf-8")
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "daemon_pid_file")
    assert f["level"] == tdc.WARN
    assert c.redlines == []


def test_f3_invalid_pid_content_unchanged_warn(host_repo, tmp_path, monkeypatch):
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    pid_file.write_text("not-a-pid\n", encoding="utf-8")
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "daemon_pid_invalid")
    assert f["level"] == tdc.WARN
    assert c.redlines == []


def test_f3_stall_does_not_drive_report_health_redline(host_repo, tmp_path,
                                                       monkeypatch):
    # Owner 裁定钉扎: repo-sync 停摆不得把整体 health 拉成 REDLINE（关掉不报红）
    _write_registration(host_repo, host_repo / "srv" / "dev-forge",
                        tmp_path / "absent.pid", enabled=True)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    report = c.build_report({"today": {}, "per_label": {}, "window": "daily"})
    assert report["health"] == tdc.GREEN
    assert report["redline_count"] == 0


def test_f3_host_real_alive_process_is_ok(host_repo, tmp_path, monkeypatch):
    # 真实现路径全链路: pid_file 指向磁盘真实文件 + 存活 PID（本测试进程）
    pid_file = tmp_path / "devforge.pid"
    pid_file.write_text("%d\n" % os.getpid(), encoding="utf-8")
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "f3")
    assert f["level"] == tdc.OK
    assert "devforge daemon 存活" in f["message"]
