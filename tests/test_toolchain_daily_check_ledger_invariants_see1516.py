"""§SPEC-001~003 (SEE-1516 substep A1): F 维台账期次不变量机检。

8e0c896702d2 撞号家族第三次复发（台账 PR #40 滞留 → nth 停 20 → 下期重号）
证明「台账落 main」仅靠 description 人肉条款无机器防线。本套件钉扎 F 维
新增两项核对：F6 台账最大期号 == review-state nth；F7 open 台账 PR warn
（附 PR 号与滞留天数）。含正常场景不误报（现网 main nth==台账最大期号）、
输入缺失走 missing_input 不升级、gh 不可用降 info 不恒真告警。
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


@pytest.fixture()
def checker(tmp_path, monkeypatch):
    """DailyCheck 实例，root 钉到 tmp 仓结构（review-prompts/toolchain/ledger/）。"""
    root = tmp_path / "repo"
    ledger_dir = root / "review-prompts" / "toolchain" / "ledger"
    ledger_dir.mkdir(parents=True)
    monkeypatch.setattr(tdc.DailyCheck, "__init__", tdc.DailyCheck.__init__)
    c = tdc.DailyCheck(argparse.Namespace(
        report_dir=str(tmp_path), no_net=True, json_mode=False))
    c.root = str(root)
    return c, ledger_dir


def _write_state(ledger_dir, nth):
    (ledger_dir / "review-state.json").write_text(
        json.dumps({"nth": nth}), encoding="utf-8")


def _write_ledger(ledger_dir, name, periods):
    body = "\n".join("### 2026-01-01 · 第 %d 期 · X" % n for n in periods)
    with open(os.path.join(str(ledger_dir), name), "w", encoding="utf-8") as f:
        f.write(body)


def _codes(c, level=tdc.WARN):
    return [f["code"] for f in c.findings if f["level"] == level]


# --- F6: 台账最大期号 == review-state nth -------------------------------------


def test_f6_warns_on_mismatch_with_both_values(checker):
    """期次漂移（台账 21 / nth 20，即 PR #40/#42 滞留形态）→ warn 附双数值。"""
    c, ledger_dir = checker
    _write_ledger(ledger_dir, "2026-10.md", [19, 20])
    _write_ledger(ledger_dir, "2026-11.md", [21])
    _write_state(ledger_dir, 20)
    issues = []
    c._check_f6_ledger_nth("F", issues)
    assert "ledger_nth_mismatch" in _codes(c), c.findings
    assert any("F6" in i and "21" in i and "20" in i for i in issues), issues


def test_f6_quiet_when_consistent(checker):
    """正常场景（台账最大期号 == nth）→ ok 不误报。"""
    c, ledger_dir = checker
    _write_ledger(ledger_dir, "2026-10.md", [19, 20])
    _write_state(ledger_dir, 20)
    issues = []
    c._check_f6_ledger_nth("F", issues)
    assert "ledger_nth_mismatch" not in _codes(c), c.findings
    assert issues == [], issues


def test_f6_missing_input_when_ledger_dir_empty(checker):
    """台账目录缺失/无期号条目 → missing_input，不比对不误报。"""
    c, ledger_dir = checker
    _write_state(ledger_dir, 20)
    issues = []
    c._check_f6_ledger_nth("F", issues)
    assert "input_missing" in _codes(c), c.findings
    assert "ledger_nth_mismatch" not in _codes(c), c.findings


def test_f6_missing_input_when_state_absent(checker):
    """review-state.json 缺失 → missing_input，不比对不误报。"""
    c, ledger_dir = checker
    _write_ledger(ledger_dir, "2026-10.md", [20])
    issues = []
    c._check_f6_ledger_nth("F", issues)
    assert "input_missing" in _codes(c), c.findings
    assert "ledger_nth_mismatch" not in _codes(c), c.findings


def test_ledger_max_period_scans_all_month_files():
    """期号提取跨月文件取最大值（含回填/重跑形态「第 N 期（重跑）」）。"""
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        _write_ledger(td, "2026-09.md", [8])
        _write_ledger(td, "2026-10.md", [4, 17, 20])
        _write_ledger(td, "2026-11.md", [21])
        with open(os.path.join(td, "review-state.json"), "w", encoding="utf-8") as f:
            f.write("{}")  # 非台账文件不参与
        assert tdc.ledger_max_period(td) == 21


# --- F7: open 台账 PR warn -----------------------------------------------------

GH_OPEN_PRS = [
    {"number": 42, "title": "docs(toolchain): 第 21 期半周检台账——hooks 与 autopilots 编排",
     "createdAt": "2026-11-02T18:45:41Z"},
    {"number": 51, "title": "feat(hooks): repo 门控 gates", "createdAt": "2026-10-30T00:00:00Z"},
]


def _mock_gh(monkeypatch, payload, returncode=0, gh_exists=True):
    calls = {}

    def fake_run(cmd, capture_output=True, text=True, timeout=10):
        calls["cmd"] = cmd
        if not gh_exists and cmd[0] == "gh":
            raise FileNotFoundError("gh")
        return subprocess.CompletedProcess(
            cmd, returncode, stdout=json.dumps(payload), stderr="")

    monkeypatch.setattr(tdc.subprocess, "run", fake_run)
    return calls


def test_f7_warns_on_open_ledger_pr_with_number_and_days(checker, monkeypatch):
    """open 台账 PR → warn 附 PR 号与滞留天数；非台账 PR（#51）不过滤进告警。"""
    c, _ledger_dir = checker
    _mock_gh(monkeypatch, GH_OPEN_PRS)
    monkeypatch.setattr(tdc, "origin_repo_slug", lambda root: "tadki/dev-forge")
    issues = []
    c._check_f7_open_ledger_pr("F", issues)
    assert "open_ledger_pr" in _codes(c), c.findings
    joined = " ".join(issues)
    assert "#42" in joined and "滞留" in joined, issues
    assert "#51" not in joined, issues  # 非台账标题不误报


def test_f7_quiet_when_no_open_ledger_pr(checker, monkeypatch):
    """正常场景（无 open 台账 PR）→ ok 不误报。"""
    c, _ledger_dir = checker
    _mock_gh(monkeypatch, [GH_OPEN_PRS[1]])  # 只有非台账 PR
    monkeypatch.setattr(tdc, "origin_repo_slug", lambda root: "tadki/dev-forge")
    issues = []
    c._check_f7_open_ledger_pr("F", issues)
    assert "open_ledger_pr" not in _codes(c), c.findings
    assert issues == [], issues


def test_f7_degrades_to_info_when_gh_unavailable(checker, monkeypatch):
    """gh 缺失/未认证/查询失败 → info 降级，不 warn（避免环境性恒真告警）。"""
    c, _ledger_dir = checker
    _mock_gh(monkeypatch, [], gh_exists=False)
    monkeypatch.setattr(tdc, "origin_repo_slug", lambda root: "tadki/dev-forge")
    issues = []
    c._check_f7_open_ledger_pr("F", issues)
    assert "open_ledger_pr" not in _codes(c), c.findings
    assert "ledger_pr_scan_unavailable" in _codes(c, level=tdc.INFO), c.findings
    assert issues == [], issues


def test_f7_degrades_to_info_when_gh_fails(checker, monkeypatch):
    c, _ledger_dir = checker
    _mock_gh(monkeypatch, [], returncode=1)
    monkeypatch.setattr(tdc, "origin_repo_slug", lambda root: "tadki/dev-forge")
    issues = []
    c._check_f7_open_ledger_pr("F", issues)
    assert "open_ledger_pr" not in _codes(c), c.findings
    assert "ledger_pr_scan_unavailable" in _codes(c, level=tdc.INFO), c.findings


def test_f7_degrades_when_slug_unresolvable(checker, monkeypatch):
    """origin URL 解析不出 slug → 视为扫描不可用（info），不猜仓库名。"""
    c, _ledger_dir = checker
    monkeypatch.setattr(tdc, "origin_repo_slug", lambda root: None)
    issues = []
    c._check_f7_open_ledger_pr("F", issues)
    assert "ledger_pr_scan_unavailable" in _codes(c, level=tdc.INFO), c.findings
    assert "open_ledger_pr" not in _codes(c), c.findings


# --- origin slug 解析 ----------------------------------------------------------


@pytest.mark.parametrize("url,expected", [
    ("https://github.com/tadki/dev-forge.git", "tadki/dev-forge"),
    ("https://github.com/tadki/dev-forge", "tadki/dev-forge"),
    ("git@github.com:tadki/dev-forge.git", "tadki/dev-forge"),
    ("ssh://git@github.com/tadki/dev-forge.git", "tadki/dev-forge"),
    ("https://gitlab.com/tadki/dev-forge.git", None),
    ("", None),
])
def test_origin_repo_slug(url, expected):
    assert tdc.origin_repo_slug_from_url(url) == expected


# --- dim_f 零回归：F1-F5 检查点仍被调用 ----------------------------------------


def test_dim_f_still_runs_f5_and_new_checks(checker, monkeypatch):
    """dim_f 装配零回归：F5（kill_switch 单源）与 F6/F7 都在 findings 留痕。"""
    c, ledger_dir = checker
    _write_ledger(ledger_dir, "2026-10.md", [20])
    _write_state(ledger_dir, 20)
    monkeypatch.setattr(tdc, "REPORT_ROOT", str(checker[0].args.report_dir))
    monkeypatch.setattr(tdc, "origin_repo_slug", lambda root: None)
    c.dim_f()
    codes_ok = {f["code"] for f in c.findings if f["level"] == tdc.OK}
    assert "f5" in codes_ok, c.findings          # 既有 F5 不回归
    assert "f6" in codes_ok, c.findings          # 新 F6 一致场景 ok
    assert "ledger_pr_scan_unavailable" in _codes(c, level=tdc.INFO)
