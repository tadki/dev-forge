"""SEE-1519 §SPEC-003: toolchain_daily_check.py F2 unit 运行态门.

判据（issue description §SPEC-003）:
  - unit 已安装且状态非 active（failed/inactive）→ fail 红线（health REDLINE、exit 2）
  - systemctl 不可用或 unit 未安装 → warn/观测，不红线（CI / 非宿主机零假阳性）
  - 三态 mock 覆盖: active / 非 active / 不可判

fixture = monkeypatch DailyCheck._systemctl_output 注入 canned systemctl 响应，
断言 dim_f 的分类输出与红线集合。只读检查，无网络，不触碰真实 systemctl。
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

UNIT = tdc.TOOLCHAIN_UNIT_NAME


@pytest.fixture()
def check(tmp_path):
    c = tdc.DailyCheck(
        argparse.Namespace(report_dir=str(tmp_path), no_net=True, json_mode=False))
    c.root = tmp_path
    return c


def _patch_systemctl(monkeypatch, enabled, active):
    """注入 canned systemctl 输出: enabled=(out, rc), active=(out, rc) 或 None。"""
    calls = []

    def fake_systemctl(check_self, args):
        calls.append(list(args))
        if args[:2] == ["is-enabled", UNIT]:
            if enabled is None:
                return None, None
            return enabled
        if args[:2] == ["is-active", UNIT]:
            if active is None:
                return None, None
            return active
        raise AssertionError("unexpected systemctl call: %r" % (args,))

    monkeypatch.setattr(tdc.DailyCheck, "_systemctl_output", fake_systemctl)
    return calls


def _f2_runtime_findings(check):
    return [f for f in check.findings
            if f["dim"] == "F" and f["code"].startswith("unit_")]


def test_f2_installed_and_active_is_ok(check, monkeypatch):
    _patch_systemctl(monkeypatch, ("enabled", 0), ("active", 0))
    check.dim_f()
    findings = _f2_runtime_findings(check)
    assert findings and findings[0]["code"] == "unit_active"
    assert findings[0]["level"] == tdc.OK
    assert check.redlines == []


def test_f2_installed_failed_is_redline(check, monkeypatch):
    _patch_systemctl(monkeypatch, ("enabled", 0), ("failed", 3))
    check.dim_f()
    findings = _f2_runtime_findings(check)
    assert findings and findings[0]["code"] == "unit_not_active"
    assert findings[0]["level"] == tdc.FAIL
    assert any(r["code"] == "unit_not_active" for r in check.redlines)
    assert check.dim_summary["F"]["status"] == tdc.REDLINE


def test_f2_installed_inactive_is_redline(check, monkeypatch):
    _patch_systemctl(monkeypatch, ("enabled", 0), ("inactive", 3))
    check.dim_f()
    findings = _f2_runtime_findings(check)
    assert findings and findings[0]["code"] == "unit_not_active"
    assert findings[0]["level"] == tdc.FAIL
    assert any(r["code"] == "unit_not_active" for r in check.redlines)


def test_f2_unit_not_installed_degrades_warn(check, monkeypatch):
    # CI / 非宿主机: is-enabled → not-found → 严禁红线
    _patch_systemctl(monkeypatch, ("not-found", 1), None)
    check.dim_f()
    findings = _f2_runtime_findings(check)
    assert findings and findings[0]["code"] == "unit_not_installed"
    assert findings[0]["level"] == tdc.WARN
    assert check.redlines == []


def test_f2_systemctl_unavailable_degrades_warn(check, monkeypatch):
    # systemctl 二进制缺失 / 调用失败 → (None, None) → 观测降级
    _patch_systemctl(monkeypatch, None, None)
    check.dim_f()
    findings = _f2_runtime_findings(check)
    assert findings and findings[0]["code"] == "unit_state_unavailable"
    assert findings[0]["level"] == tdc.WARN
    assert check.redlines == []


def test_f2_transient_state_is_undetermined_warn(check, monkeypatch):
    # 三态 mock 之「不可判」: activating/reloading 等瞬态不红线、不误报
    _patch_systemctl(monkeypatch, ("enabled", 0), ("activating", 2))
    check.dim_f()
    findings = _f2_runtime_findings(check)
    assert findings and findings[0]["code"] == "unit_state_unknown"
    assert findings[0]["level"] == tdc.WARN
    assert check.redlines == []


def test_f2_runtime_gate_drives_report_health(check, monkeypatch):
    # 红线必须推进 build_report health=REDLINE（修复 GREEN 掩盖停摆的盲区）
    _patch_systemctl(monkeypatch, ("enabled", 0), ("failed", 3))
    check.dim_f()
    report = check.build_report({"today": {}, "per_label": {}, "window": "daily"})
    assert report["health"] == tdc.REDLINE
    assert report["redline_count"] >= 1


def test_f2_runtime_query_call_contract(check, monkeypatch):
    # pin 查询契约: 先 is-enabled 判安装，后 is-active 判状态（顺序与参数钉扎）
    calls = _patch_systemctl(monkeypatch, ("enabled", 0), ("active", 0))
    check.dim_f()
    assert calls == [["is-enabled", UNIT], ["is-active", UNIT]]


def test_f2_systemctl_output_real_success_path(check, monkeypatch):
    # 真实现路径: systemctl 可用 + 子进程成功 → (stdout.strip(), rc)
    calls = []

    class _Result:
        returncode = 0
        stdout = "enabled\n"

    def fake_run(cmd, **_kw):
        calls.append(list(cmd))
        return _Result()

    monkeypatch.setattr(tdc.shutil, "which", lambda _name: "/usr/bin/systemctl")
    monkeypatch.setattr(tdc.subprocess, "run", fake_run)
    out, rc = check._systemctl_output(["is-enabled", UNIT])
    assert (out, rc) == ("enabled", 0)
    assert calls == [["systemctl", "is-enabled", UNIT]]


def test_f2_systemctl_output_binary_missing(check, monkeypatch):
    # systemctl 二进制缺失 → (None, None)，调用方降级 warn
    monkeypatch.setattr(tdc.shutil, "which", lambda _name: None)

    def _no_run(*_a, **_kw):  # pragma: no cover - 不应被调用
        raise AssertionError("subprocess.run must not be called")

    monkeypatch.setattr(tdc.subprocess, "run", _no_run)
    assert check._systemctl_output(["is-active", UNIT]) == (None, None)


def test_f2_systemctl_output_subprocess_error(check, monkeypatch):
    # 子进程异常（超时/不可执行）→ (None, None)，不向上抛
    monkeypatch.setattr(tdc.shutil, "which", lambda _name: "/usr/bin/systemctl")

    def boom(cmd, **_kw):
        raise subprocess.TimeoutExpired(cmd, timeout=10)

    monkeypatch.setattr(tdc.subprocess, "run", boom)
    assert check._systemctl_output(["is-enabled", UNIT]) == (None, None)
