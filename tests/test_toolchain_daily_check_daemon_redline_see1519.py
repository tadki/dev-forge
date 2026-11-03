"""SEE-1519 §SPEC-004: toolchain_daily_check.py F3 守护停摆 warn → 红线升级.

判据（issue description §SPEC-004 / 高风险通道 CI 假阳性约束）:
  - 宿主上下文（注册 repo_path 存在）且 pid 文件缺失或 PID 不存活 → fail 红线
  - 非宿主上下文（repo_path 不存在，CI / 非宿主机）→ 保持 warn，严禁假阳性红线
  - 配置类缺陷（未声明 pid_file / pid 内容非法）语义不变，维持 warn
  - 新增分支全部受测（§SPEC-006 覆盖目标）

fixture = 临时 repo 树 + repo-sync/repos.d/ 注册文件 + pid 文件形态注入。
"""

import argparse
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


def _write_registration(root, repo_path, pid_file=None):
    repos_d = root / "repo-sync" / "repos.d"
    repos_d.mkdir(parents=True, exist_ok=True)
    cfg = {
        "name": "devforge",
        "repo_path": str(repo_path),
        "branch": "main",
        "pid_file": str(pid_file) if pid_file else "/tmp/see1519-unused.pid",
    }
    (repos_d / "devforge.json").write_text(
        __import__("json").dumps(cfg), encoding="utf-8")
    return cfg


@pytest.fixture()
def host_repo(tmp_path):
    """宿主上下文 fixture: repo_path 存在（模拟工具链宿主机）。"""
    (tmp_path / "srv" / "dev-forge").mkdir(parents=True)
    return tmp_path


def _make_check(tmp_path, monkeypatch):
    # F2 运行态门注入不可判态，隔离本套件于 F3 断言
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


def test_f3_host_pid_missing_is_redline(host_repo, tmp_path, monkeypatch):
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "daemon_pid_missing")
    assert f["level"] == tdc.FAIL
    assert any(r["code"] == "daemon_pid_missing" for r in c.redlines)
    assert c.dim_summary["F"]["status"] == tdc.REDLINE


def test_f3_host_dead_pid_is_redline(host_repo, tmp_path, monkeypatch):
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    pid_file.write_text("%d\n" % _dead_pid(), encoding="utf-8")
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "daemon_dead")
    assert f["level"] == tdc.FAIL
    assert any(r["code"] == "daemon_dead" for r in c.redlines)


def test_f3_host_alive_pid_stays_ok(host_repo, tmp_path, monkeypatch):
    pid_file = tmp_path / "devforge-sync-daemon.pid"
    pid_file.write_text("%d\n" % os.getpid(), encoding="utf-8")
    _write_registration(host_repo, host_repo / "srv" / "dev-forge", pid_file)
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    f = next(x for x in c.findings if x["code"] == "f3")
    assert f["level"] == tdc.OK
    assert not any(r["dim"] == "F" and "daemon" in r["code"] for r in c.redlines)


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
    import json
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


def test_f3_redline_drives_report_health(host_repo, tmp_path, monkeypatch):
    _write_registration(host_repo, host_repo / "srv" / "dev-forge",
                        tmp_path / "absent.pid")
    c = _make_check(tmp_path, monkeypatch)
    c.dim_f()
    report = c.build_report({"today": {}, "per_label": {}, "window": "daily"})
    assert report["health"] == tdc.REDLINE


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
