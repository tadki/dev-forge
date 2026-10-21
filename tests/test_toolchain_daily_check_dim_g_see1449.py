"""§SPEC-001 (SEE-1449): G5 2σ 旧口径守卫回归。

SEE-1448 实证: history.daily 里的 6 个旧累计口径日 (2026-08-29/08-31/09-01..09-04,
timeout 2060-2366, error 89-116) 混入 σ 序列, 把触发阈值从 139.4 抬到 3127.8
(约 22 倍), 真实尖峰 (09-11 timeout=140) 不再触发 — 假阴性。

守卫语义钉扎:
- `_g_daily_series` 确定性排除 <= DAILY_WINDOW_EPOCH_LAST_LEGACY (2026-09-04,
  SEE-1234 口径切换落地当日) 的键, 不依赖 30 天窗口自然淘汰;
- 跳过行为以 info (g5_legacy_window_skipped) 观测, 无旧口径日时不发 info;
- 阈值语义用真实基线序列钉扎 (Leader 2026-10-22 复核值: timeout 新口径 n=8
  mean=37.5 σ=50.9 → 阈值 139.4; error 新口径 n=6 mean=12.7 σ=4.1 → 阈值 20.8)。
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

# 真实 history.json 的新口径序列 (2026-10-22 快照, 与 §SPEC-002 复算命令一致)
REAL_TIMEOUT_NEW = [7, 109, 140, 12, 6, 16, 5, 5]      # mean=37.5 σ=50.9 thr=139.4
REAL_ERROR_NEW = [18, 9, 16, 14, 6, 13]                # mean=12.7 σ=4.1  thr=20.8
REAL_TIMEOUT_LEGACY = [2060, 2132, 2175, 2224, 2317, 2366]
REAL_ERROR_LEGACY = [89, 95, 95, 102, 115, 116]
LEGACY_DAYS = ["2026-08-29", "2026-08-31", "2026-09-01",
               "2026-09-02", "2026-09-03", "2026-09-04"]
NEW_DAYS = ["2026-09-09", "2026-09-10", "2026-09-11", "2026-09-12",
            "2026-09-16", "2026-09-21", "2026-10-12", "2026-10-15"]


def _history(legacy, new, code):
    """构造 history.daily: legacy 为 (day, value) 列表, new 为纯值列表。"""
    daily = {}
    for day, v in legacy:
        daily[day] = {code: v}
    for day, v in zip(NEW_DAYS, new):
        daily[day] = {code: v}
    return {"daily": daily}


@pytest.fixture()
def checker(tmp_path):
    return tdc.DailyCheck(argparse.Namespace(
        report_dir=str(tmp_path), no_net=True, json_mode=False))


def _run_g5(checker, history, today):
    issues = []
    bad = checker._check_g5_sigma("G", history, today, issues)
    codes = [(f["level"], f["code"]) for f in checker.findings]
    return bad, codes, issues


# --- §SPEC-001 ①: 旧口径值不进入 σ 序列 --------------------------------------


def test_legacy_values_excluded_from_series():
    history = _history(list(zip(LEGACY_DAYS, REAL_TIMEOUT_LEGACY)),
                       REAL_TIMEOUT_NEW, "timeout")
    series, skipped = tdc.DailyCheck._g_daily_series(history)
    assert sorted(skipped) == LEGACY_DAYS
    assert sorted(series["timeout"]) == sorted(REAL_TIMEOUT_NEW)
    for v in REAL_TIMEOUT_LEGACY:
        assert v not in series["timeout"]


def test_boundary_day_2026_09_04_is_legacy_and_09_05_is_new():
    history = _history([("2026-09-04", 2317)], REAL_TIMEOUT_NEW, "timeout")
    history["daily"]["2026-09-05"] = {"timeout": 8}
    series, skipped = tdc.DailyCheck._g_daily_series(history)
    assert skipped == ["2026-09-04"]
    assert 2317 not in series["timeout"]
    assert 8 in series["timeout"]


# --- §SPEC-001 ②③: 真实阈值语义 (修复前 140 不触发 → 修复后触发) ---------------


def test_real_spike_140_triggers_with_legacy_days_present(checker):
    """修复后阈值 139.4: 真实尖峰 timeout=140 触发 2σ 红线 (修复前阈值 3127.8 不触发)。"""
    history = _history(list(zip(LEGACY_DAYS, REAL_TIMEOUT_LEGACY)),
                       REAL_TIMEOUT_NEW, "timeout")
    bad, codes, issues = _run_g5(checker, history, {"timeout": 140})
    assert bad == ["timeout(140>37.5+2σ)"], codes
    assert (tdc.FAIL, "sigma_overflow") in codes
    assert checker.redlines, "must raise redline"
    assert any("G5" in i for i in issues), issues
    assert (tdc.INFO, "g5_legacy_window_skipped") in codes


def test_mean_level_5_does_not_trigger(checker):
    history = _history(list(zip(LEGACY_DAYS, REAL_TIMEOUT_LEGACY)),
                       REAL_TIMEOUT_NEW, "timeout")
    bad, codes, _ = _run_g5(checker, history, {"timeout": 5})
    assert bad == []
    assert (tdc.OK, "g5") in codes
    assert checker.redlines == []


def test_real_error_spike_25_triggers_after_guard(checker):
    """error 档: 修复前阈值 148.0 不触发, 修复后阈值 20.8 触发。"""
    history = _history(list(zip(LEGACY_DAYS, REAL_ERROR_LEGACY)),
                       REAL_ERROR_NEW, "error")
    bad, codes, _ = _run_g5(checker, history, {"error": 25})
    assert bad == ["error(25>12.7+2σ)"], codes
    assert (tdc.FAIL, "sigma_overflow") in codes


def test_error_mean_level_below_threshold_quiet(checker):
    history = _history(list(zip(LEGACY_DAYS, REAL_ERROR_LEGACY)),
                       REAL_ERROR_NEW, "error")
    bad, _, _ = _run_g5(checker, history, {"error": 20})
    assert bad == [], "20 < 20.8 不得触发"


# --- §SPEC-001 ④: 无旧口径日时行为与守卫前一致 --------------------------------


def test_no_legacy_days_no_skip_info_and_unchanged_behavior(checker):
    history = _history([], REAL_TIMEOUT_NEW, "timeout")
    bad_spike, codes, _ = _run_g5(checker, history, {"timeout": 140})
    assert (tdc.INFO, "g5_legacy_window_skipped") not in codes
    assert bad_spike, "无旧口径日时 140 仍触发 (行为不变)"
    c2 = tdc.DailyCheck(argparse.Namespace(
        report_dir=str(checker.report_dir), no_net=True, json_mode=False))
    bad_quiet, codes2, _ = _run_g5(c2, history, {"timeout": 5})
    assert bad_quiet == [] and (tdc.OK, "g5") in codes2


def test_legacy_only_history_still_has_new_enough_baseline(checker):
    """6 新口径日 + 6 旧口径日共存: 守卫后基线 n=8/6, 满足 len>=5 门槛。"""
    history = _history(list(zip(LEGACY_DAYS, REAL_TIMEOUT_LEGACY)),
                       REAL_TIMEOUT_NEW, "timeout")
    series, skipped = tdc.DailyCheck._g_daily_series(history)
    assert len(series["timeout"]) == 8 and len(skipped) == 6
