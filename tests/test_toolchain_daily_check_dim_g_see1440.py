"""§SPEC-028 hardening (SEE-1440-b): dim_g split must not weaken guards.

G 维（错误度量口径）在 §SPEC-026 复杂度重构中被拆分为 _check_g* 子检查，
拆分前 G3 阈值语义（日增 >= DAILY_INCREMENT_MIN 且昨日基数 >=1 → threshold_daily
warn）无任何自动化守护——阈值边界反转变异全绿存活。本套件钉扎 G3 的
阈值边界、低于阈值静默、无基线静默三个语义点。
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
def checker(tmp_path, monkeypatch):
    history = tmp_path / "history.json"
    monkeypatch.setattr(tdc, "HISTORY_FILE", str(history))
    c = tdc.DailyCheck(argparse.Namespace(
        report_dir=str(tmp_path), no_net=True, json_mode=False))
    return c, history


def _write_history(path, failures):
    import json
    path.write_text(json.dumps({"failures": failures}), encoding="utf-8")


def _run_g3(c, failure_attr):
    issues = []
    c._check_g3_daily_delta("G", failure_attr, issues)
    codes = [f["code"] for f in c.findings if f["level"] == tdc.WARN]
    return issues, codes


def test_g3_warns_at_threshold_boundary(checker):
    """d == DAILY_INCREMENT_MIN(2) 且昨日基数 >=1 → threshold_daily warn。
    阈值比较反转（>=→>）变异使边界日增 2 漏报，本用例击杀。"""
    c, history = checker
    _write_history(history, {"timeout": 1})
    issues, codes = _run_g3(c, {"launcher-a": {"timeout": 3}})  # d=2
    assert "threshold_daily" in codes, c.findings
    assert any("G3" in i for i in issues), issues


def test_g3_quiet_below_threshold(checker):
    """d < 阈值（昨日 1 → 今日 2，d=1）→ 不得告警。"""
    c, history = checker
    _write_history(history, {"timeout": 1})
    issues, codes = _run_g3(c, {"launcher-a": {"timeout": 2}})
    assert "threshold_daily" not in codes, c.findings
    assert issues == [], issues


def test_g3_quiet_without_baseline(checker):
    """昨日基数为 0 的新失败码：即便日增大也静默（无基线不构成「越界」）。"""
    c, history = checker
    _write_history(history, {})
    issues, codes = _run_g3(c, {"launcher-a": {"error": 9}})
    assert "threshold_daily" not in codes, c.findings
