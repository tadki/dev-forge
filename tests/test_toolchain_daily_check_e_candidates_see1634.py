"""§SPEC-030 (SEE-1634): 日检 E 段本批改动的行为钉。

本批 E 段两处改动：
1. E1（watchdog 重启节流）整体移除——dim_e 不再有 e1 检查；
2. E2 PID 锁残留的候选缩减为只剩 `version_check.pid`——两个已退役巡检
   （agent_watchdog、issue_status_check）的 pid 文件不再被探测。

E1 的移除是整段删除、没有可变异的现行代码；其语义用「dim_e 不调用 e1、
仍调用 e2/e3/e4」这条组成行为钉住（若有人把 e1 调用加回去即被抓住）。
E2 的候选缩减直接对候选集合断言：新老候选各造一个「flock 空闲且持有者已死」
的锁文件，只有 version_check.pid 触发残留告警。
"""

import argparse
import os
import sys

import pytest

TOOLCHAIN_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "toolchain")
sys.path.insert(0, TOOLCHAIN_DIR)

import toolchain_daily_check as tdc  # noqa: E402


@pytest.fixture()
def checker(tmp_path):
    c = tdc.DailyCheck(argparse.Namespace(
        report_dir=str(tmp_path), no_net=True, json_mode=False))
    return c


def _warn_codes(c):
    return [f["code"] for f in c.findings if f["level"] == tdc.WARN]


def _force_dead_holder(monkeypatch):
    """flock 空闲且持有者已死 → 若该文件在候选集合内即判残留。"""
    def _fake(path):
        return 99999, False  # (holder_pid, live)
    monkeypatch.setattr(tdc, "_lock_holder", _fake)


class TestE2CandidateSetReduced:
    """候选只剩 version_check.pid：其余两个退役巡检 pid 不再触发残留。"""

    @pytest.mark.parametrize("retired_pid", ["agent_watchdog.pid", "issue_status_check.pid"])
    def test_retired_watchdog_pid_is_not_probed(self, tmp_path, checker, monkeypatch, retired_pid):
        (tmp_path / retired_pid).write_text("42", encoding="utf-8")
        monkeypatch.setattr(tdc.tempfile, "gettempdir", lambda: str(tmp_path))
        _force_dead_holder(monkeypatch)
        issues = []
        checker._check_e2_pid_lock_residue("E", issues)
        assert "pid_lock_residue" not in _warn_codes(checker), _warn_codes(checker)
        assert not any("E2" in i for i in issues), issues

    def test_version_check_pid_dead_holder_is_residue(self, tmp_path, checker, monkeypatch):
        (tmp_path / "version_check.pid").write_text("42", encoding="utf-8")
        monkeypatch.setattr(tdc.tempfile, "gettempdir", lambda: str(tmp_path))
        _force_dead_holder(monkeypatch)
        issues = []
        checker._check_e2_pid_lock_residue("E", issues)
        assert "pid_lock_residue" in _warn_codes(checker), _warn_codes(checker)
        assert any("E2" in i for i in issues), issues


class TestDimEComposition:
    """dim_e 调用 e2/e3/e4、不调用 e1（E1 已在本批移除）。"""

    def test_dim_e_invokes_e2_e3_e4_and_never_e1(self, monkeypatch, checker):
        called = []

        def _make_spy(label):
            def _spy(*args, **kwargs):
                called.append(label)
            return _spy

        for name, label in [
            ("_check_e2_pid_lock_residue", "e2"),
            ("_check_e3_workspace_lock", "e3"),
            ("_check_e4_autopilot_scripts", "e4"),
            ("_check_e1_watchdog_restarts", "e1"),
        ]:
            monkeypatch.setattr(checker, name, _make_spy(label), raising=False)

        checker.dim_e()

        assert called == ["e2", "e3", "e4"], called
        assert "e1" not in called, called
