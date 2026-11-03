"""§SPEC-008 (SEE-1516 substep C1, fingerprint d441deebc01d): 日检 E2 锁残留 flock 口径。

原 E2 以锁文件存在判「PID 锁残留」: watchdog_state.json.lock 创建后永不删
(flock 一直持有→恒真), watchdog.lock/agent_watchdog.lock 全仓无创建者
(恒假)。修法: 复用 _lock_holder flock 口径 + 候选指向真实 /tmp pid 文件,
三态判定— flock 被占=存活并存, flock 空闲且持有者已死=残留(warn),
文件不存在/无 PID 文本=无锁或已释放态(ok)。
"""

import os
import argparse
import sys
from pathlib import Path
from unittest import mock

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
    monkeypatch.setattr(tdc, "WATCHDOG_STATE",
                        str(tmp_path / "nowhere" / "watchdog_state.json"))
    monkeypatch.setattr(tdc.tempfile, "gettempdir", lambda: str(tmp_path / "notmp"))
    (tmp_path / "notmp").mkdir(parents=True)
    c, _ = checker
    issues, codes = _run_e2(c, tmp_path)
    assert codes == [], codes
    assert issues == [], issues


def test_e2_live_holder_not_residue(tmp_path, checker, monkeypatch):
    """候选存在但 flock 被存活进程持有 → 非残留 (调度并存)。"""
    lock = tmp_path / "agent_watchdog.pid"
    lock.write_text("42", encoding="utf-8")
    monkeypatch.setattr(tdc.tempfile, "gettempdir", lambda: str(tmp_path))
    monkeypatch.setattr(tdc, "WATCHDOG_STATE", str(tmp_path / "wd.json"))
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
    monkeypatch.setattr(tdc, "WATCHDOG_STATE", str(tmp_path / "wd.json"))
    _force_fcntl(monkeypatch, holder_alive=False)
    c, _ = checker
    issues, codes = _run_e2(c, tmp_path)
    assert "pid_lock_residue" in codes, codes
    assert any("E2" in i for i in issues), issues


def test_e2_ok_empty_file_no_pid_text(tmp_path, checker, monkeypatch):
    """候选存在但无 PID 文本 (已释放态, PidFileLock release 后空文件) → ok。"""
    lock = tmp_path / "issue_status_check.pid"
    lock.write_text("", encoding="utf-8")
    monkeypatch.setattr(tdc.tempfile, "gettempdir", lambda: str(tmp_path))
    monkeypatch.setattr(tdc, "WATCHDOG_STATE", str(tmp_path / "wd.json"))

    def _fake(path):
        return None, False  # holder_pid None (无文本)
    monkeypatch.setattr(tdc, "_lock_holder", _fake)
    c, _ = checker
    issues, codes = _run_e2(c, tmp_path)
    assert codes == [], codes
    assert issues == [], issues


# --- watchdog_state.json.lock sidecar: 常驻但 flock 空闲 → 非残留 -------------

def test_e2_wd_sidecar_empty_flock_ok(tmp_path, checker, monkeypatch):
    """wd_state.lock 常驻(创建后不删) 但 flock 空闲且无死PID → ok, 不恒真告警。"""
    s = tmp_path / "wd.json"
    s.parent.mkdir(parents=True, exist_ok=True)
    Path(str(s) + ".lock").write_text("", encoding="utf-8")
    monkeypatch.setattr(tdc, "WATCHDOG_STATE", str(s))
    monkeypatch.setattr(tdc.tempfile, "gettempdir", lambda: str(tmp_path / "notmp"))
    (tmp_path / "notmp").mkdir(parents=True)

    def _fake(path):
        return None, False
    monkeypatch.setattr(tdc, "_lock_holder", _fake)
    c, _ = checker
    issues, codes = _run_e2(c, tmp_path)
    assert codes == [], codes
    assert issues == [], issues