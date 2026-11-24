"""§SPEC-008 (SEE-1516 substep C1, fingerprint d441deebc01d): 日检 E2 锁残留 flock 口径。

原 E2 以锁文件存在判「PID 锁残留」: 常驻 sidecar 创建后永不删(flock 一直持有
→恒真), 旧锁名全仓无创建者(恒假)。修法: 复用 _lock_holder flock 口径 + 候选
指向真实 /tmp pid 文件, 三态判定— flock 被占=存活并存, flock 空闲且持有者已
死=残留(warn), 文件不存在/无 PID 文本=无锁或已释放态(ok)。

SEE-1634: 两个已退役巡检的 E1 与 sidecar/pid 候选随之移除；本套件保留现存
候选 version_check.pid 的同一组三态断言。
"""

import os
import argparse
import sys
from pathlib import Path

import pytest

TOOLCHAIN_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "toolchain")
sys.path.insert(0, TOOLCHAIN_DIR)

import toolchain_daily_check as tdc  # noqa: E402


@pytest.fixture()
def checker(tmp_path, monkeypatch):
    c = tdc.DailyCheck(argparse.Namespace(
        report_dir=str(tmp_path), no_net=True, json_mode=False))
    return c, tmp_path


def _run_e2(c, tmp):
    issues = []
    c._check_e2_pid_lock_residue("E", issues)
    codes = [f["code"] for f in c.findings if f["level"] == tdc.WARN]
    return issues, codes


def _force_fcntl(monkeypatch, holder_alive):
    """monkeypatch _lock_holder 模拟 flock+死PID 判定，避免真实文件系统竞态。"""
    def _fake(path):
        return 99999, holder_alive  # (holder_pid, live)
    monkeypatch.setattr(tdc, "_lock_holder", _fake)


def test_e2_ok_no_candidate(tmp_path, checker, monkeypatch):
    """无任何候选锁文件 → ok 不告警。"""
    monkeypatch.setattr(tdc.tempfile, "gettempdir", lambda: str(tmp_path / "notmp"))
    (tmp_path / "notmp").mkdir(parents=True)
    c, _ = checker
    issues, codes = _run_e2(c, tmp_path)
    assert codes == [], codes
    assert issues == [], issues


def test_e2_live_holder_not_residue(tmp_path, checker, monkeypatch):
    """候选存在但 flock 被存活进程持有 → 非残留 (调度并存)。"""
    lock = tmp_path / "version_check.pid"
    lock.write_text("42", encoding="utf-8")
    monkeypatch.setattr(tdc.tempfile, "gettempdir", lambda: str(tmp_path))
    _force_fcntl(monkeypatch, holder_alive=True)
    c, _ = checker
    issues, codes = _run_e2(c, tmp_path)
    assert codes == [], codes
    assert issues == [], issues


def test_e2_dead_holder_is_residue(tmp_path, checker, monkeypatch):
    """flock 空闲且持有者已死 → warn 残留 (原 c1 恒真/恒假族的修复目标)。"""
    lock = tmp_path / "version_check.pid"
    lock.write_text("42", encoding="utf-8")
    monkeypatch.setattr(tdc.tempfile, "gettempdir", lambda: str(tmp_path))
    _force_fcntl(monkeypatch, holder_alive=False)
    c, _ = checker
    issues, codes = _run_e2(c, tmp_path)
    assert "pid_lock_residue" in codes, codes
    assert any("E2" in i for i in issues), issues


def test_e2_ok_empty_file_no_pid_text(tmp_path, checker, monkeypatch):
    """候选存在但无 PID 文本 (已释放态, PidFileLock release 后空文件) → ok。"""
    lock = tmp_path / "version_check.pid"
    lock.write_text("", encoding="utf-8")
    monkeypatch.setattr(tdc.tempfile, "gettempdir", lambda: str(tmp_path))

    def _fake(path):
        return None, False  # holder_pid None (无文本)
    monkeypatch.setattr(tdc, "_lock_holder", _fake)
    c, _ = checker
    issues, codes = _run_e2(c, tmp_path)
    assert codes == [], codes
    assert issues == [], issues
