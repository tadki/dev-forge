"""§SPEC-010 + §SPEC-014 (SEE-1516 substep C3/C7): persist 互斥 + G1 残骸过滤。

C3 (fingerprint 13d0bbd59690): persist 与 backfill 都是 history.json 读-改-写,
并发 last-writer-wins 丢当日计数 — 接 _ReportMutex (等价 flock) 串行化,
并发写不丢当日计数。
C7 (fingerprint 9b9de0b89cdb): 端口注册表残骸条目 (无 port 无 agent, 仅
heartbeat_at 占位, 如 Old-slot1) 曾被 `agent or label` 喂进 per_agent 应采
集合且无日志源 → G1「缺失 old-slot1」恒 warn。过滤后 G1 恢复 GREEN。
"""

import argparse
import json
import os
import sys
import threading

import pytest

TOOLCHAIN_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "toolchain")
sys.path.insert(0, TOOLCHAIN_DIR)

import toolchain_daily_check as tdc  # noqa: E402


@pytest.fixture()
def checker(tmp_path):
    return tdc.DailyCheck(argparse.Namespace(
        report_dir=str(tmp_path), no_net=True, json_mode=False)), tmp_path


# --- C3: persist 并发互斥 ------------------------------------------------------


def _report(c, day, failures):
    return {
        "generated_at": day + "T00:00:00+00:00",
        "failures": failures,
        "redlines": [], "redline_count": 0, "dimensions": {},
        "findings": [], "input_missing": [],
        "health": "green", "schema_version": 1,
        "script": "x", "repo": c.root,
        "failures_per_label": {}, "failures_window": "daily",
    }


def test_concurrent_persist_keeps_both_days(checker):
    """两线程并发 persist 不同日 → 双日计数都落盘 (加锁前 last-writer-wins 丢一日)。"""
    c, report_dir = checker
    barrier = threading.Barrier(2)

    def _persist(day, failures):
        barrier.wait()
        c.persist(_report(c, day, failures))

    t1 = threading.Thread(target=_persist, args=("2026-11-01", {"timeout": 3}))
    t2 = threading.Thread(target=_persist, args=("2026-11-02", {"error": 5}))
    t1.start(); t2.start(); t1.join(); t2.join()

    history = json.load(open(os.path.join(str(report_dir), "history.json"),
                             encoding="utf-8"))
    assert history["daily"]["2026-11-01"] == {"timeout": 3}, history["daily"]
    assert history["daily"]["2026-11-02"] == {"error": 5}, history["daily"]
    assert os.path.exists(os.path.join(str(report_dir), "latest.json"))


def test_backfill_runs_under_same_mutex(checker, monkeypatch):
    """backfill 与 persist 走同一把锁 (互斥面一致), backfill 正常落盘。"""
    c, report_dir = checker
    c.persist(_report(c, "2026-11-01", {"timeout": 1}))
    # scan_launcher_failures 打桩: 避免真实日志扫描; 返回单 label 计数
    from collections import Counter
    monkeypatch.setattr(tdc, "scan_launcher_failures",
                        lambda day: {"port-1": Counter({"error": 2})})
    backfilled, _backup = tdc.backfill_history_failures(
        ["2026-11-01"], str(report_dir), allow_empty=True)
    assert backfilled == {"2026-11-01": {"error": 2}}
    history = json.load(open(os.path.join(str(report_dir), "history.json"),
                             encoding="utf-8"))
    assert history["daily"]["2026-11-01"] == {"error": 2}


# --- C7: 注册表残骸条目过滤 ----------------------------------------------------


def test_registry_tombstone_not_expected(checker):
    """无 port 无 agent 的占位条目 (Old-slot1 形态) → 不进 per_agent 应采集合。"""
    c, _ = checker
    entries = {
        "Old-slot1": {"heartbeat_at": "2024-01-01T00:00:00Z"},
        "Bachi-6e532520923f": {"agent": "Bachi", "port": 6560},
    }
    registered_ports, per_agent = c._g_registry_inventory(entries)
    assert "old-slot1" not in per_agent, per_agent
    assert "Bachi" in per_agent, per_agent
    assert registered_ports == {6560}


def test_registry_valid_entry_still_expected(checker):
    """有 agent 的正常条目仍进入应采集合 (过滤不误伤)。"""
    c, _ = checker
    entries = {"Atlas-x": {"agent": "Atlas", "port": 6562}}
    registered_ports, per_agent = c._g_registry_inventory(entries)
    assert "Atlas" in per_agent
    assert registered_ports == {6562}


def test_agent_without_port_still_expected(checker):
    """有 agent 无 port (lease 未绑定端口的活条目) → 保留, 不当残骸过滤。"""
    c, _ = checker
    entries = {"Revy-live": {"agent": "Revy"}}
    _, per_agent = c._g_registry_inventory(entries)
    assert "Revy" in per_agent
