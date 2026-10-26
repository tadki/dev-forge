"""Tests for autopilots/guard_pending.py (SEE-1470 Track A production port).

迁移自 KOL tests/devtests/scripts/test_check_guard_pending.py，改为 pytest
收集的真实用例：
- 分类矩阵（计数 / Track-D 单行与多行豁免 / 注释与签名行不计数）全部运行在
  合成 tests/ 树上；
- CLI 退出码与 text/json 输出语义；
- architecture_sweep.check_guard_pending 的 L0 接线（findings 结构 + metrics）。

与源件的关键差异：不再对「当前仓状态」做硬断言（源件的 real-repo 断言依赖
KOL tests/ 现状，Track B 删除后不可持续）；扫描行为全部由合成输入钉定。
"""

from __future__ import annotations

import importlib
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

import guard_pending
import architecture_sweep as sweep

SCRIPT = Path(guard_pending.__file__)


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _make_tree(root: Path) -> None:
    """合成树：sample_a 恰 1 个 guard pending；sample_b 全部豁免。"""
    _write(
        root / "tests" / "sample_a.gd",
        'extends "res://addons/gut/test.gd"\n'
        "func test_x() -> void:\n"
        "\tif foo == null:\n"
        '\t\tpending("X not available")\n'
        "\t\treturn\n"
        "\n"
        "func test_y() -> void:\n"
        '\t# pending("in comment") — must be ignored\n'
        "\tpass\n"
        "\n"
        "func test_z_pending() -> void:\n"  # 签名行不得命中
        "\tpass\n",
    )
    _write(
        root / "tests" / "sample_b.gd",
        "func test_a() -> void:\n"
        "\t# Single-line Track-D pending — excluded\n"
        '\tpending("Feature not implemented yet (Track D pending)")\n'
        "\n"
        "func test_b() -> void:\n"
        "\t# Multi-line Track-D pending — excluded\n"
        "\tpending(\n"
        '\t\t"SEE-1137 Track-D pending (SLA 2026-10-15): reason"\n'
        "\t)\n",
    )


def test_synthetic_tree_counts_exactly_one_guard_pending(tmp_path: Path) -> None:
    _make_tree(tmp_path)
    result = guard_pending.scan(tmp_path)
    assert result["guard_pending"] == 1
    assert list(result["by_file"].keys()) == ["tests/sample_a.gd"]
    lineno, snippet = result["by_file"]["tests/sample_a.gd"][0]
    assert lineno == 4
    assert "X not available" in snippet


def test_threshold_zero_exit_semantics(tmp_path: Path) -> None:
    _make_tree(tmp_path)
    # 超 threshold → 1；豁免后只剩 Track-D → 0
    rc_over = subprocess.run(
        [sys.executable, str(SCRIPT), "--repo-root", str(tmp_path), "--format", "json"],
        capture_output=True, text=True, check=False,
    )
    assert rc_over.returncode == 1
    payload = json.loads(rc_over.stdout)
    assert payload["ok"] is False
    assert payload["summary"]["guard_pending"] == 1
    assert payload["failures"][0]["reason"].startswith("guard_pending=1")

    clean = tmp_path / "clean"
    (clean / "tests").mkdir(parents=True)
    _write(
        clean / "tests" / "only_trackd.gd",
        "func test_only() -> void:\n"
        '\tpending("ErrorFlowEngineV2 not implemented yet (Track D pending)")\n',
    )
    rc_ok = subprocess.run(
        [sys.executable, str(SCRIPT), "--repo-root", str(clean)],
        capture_output=True, text=True, check=False,
    )
    assert rc_ok.returncode == 0
    assert "guard_pending=0" in rc_ok.stdout
    assert "OK" in rc_ok.stdout


def test_multiline_and_hyphenated_track_d_exemptions(tmp_path: Path) -> None:
    tests = tmp_path / "tests"
    tests.mkdir()
    _write(
        tests / "hyphen.gd",
        "func test_a() -> void:\n"
        '\tpending("FlowTelemetry not implemented yet (Track-D pending)")\n',
    )
    # 窗口边界：pending( 后 Track-D 标识落在第 3 行（本行+2）仍在窗口内
    _write(
        tests / "window.gd",
        "func test_b() -> void:\n"
        "\tpending(\n"
        '\t\t"arg",\n'
        '\t\t"Track D pending marker"\n'
        "\t)\n",
    )
    # 窗口外：Track-D 标识落在 pending( 后第 3 行（超出本行+2 窗口）→ 不豁免
    _write(
        tests / "outside.gd",
        "func test_c() -> void:\n"
        "\tpending(\n"
        '\t\t"arg",\n'
        '\t\t"more",\n'
        '\t\t"Track D pending far below"\n'
        "\t)\n",
    )
    result = guard_pending.scan(tmp_path)
    assert result["by_file"].keys() == {"tests/outside.gd"}
    assert result["guard_pending"] == 1


def test_missing_tests_tree_is_empty_not_error(tmp_path: Path) -> None:
    # 目标仓无 tests/ 树 = 零站点，不是违规也不是异常
    result = guard_pending.scan(tmp_path)
    assert result == {"guard_pending": 0, "by_file": {}}


def test_unreadable_file_raises_not_silent_zero(tmp_path: Path) -> None:
    tests = tmp_path / "tests"
    tests.mkdir()
    target = tests / "bad.gd"
    target.write_text("func test_x():\n\tpending(\"nope\")\n", encoding="utf-8")
    target.chmod(0o000)
    try:
        with pytest.raises(RuntimeError):
            guard_pending.scan(tmp_path)
    finally:
        target.chmod(0o644)


def test_sweep_l0_wiring_emits_findings_and_metric(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _make_tree(repo)
    # 直接重放 L0 的第 9 项接线逻辑（不拉起整个 sweep main 的锁/状态面）：
    # all_findings.extend(gp) + metrics["guard_pending"] = len(gp)
    all_findings: list = []
    metrics: dict = {}
    gp = sweep.check_guard_pending(str(repo))
    all_findings.extend(gp)
    metrics["guard_pending"] = len(gp)
    assert len(gp) == 1
    f = gp[0]
    assert f["rule_id"] == "GUARD_PENDING"
    assert f["severity"] == sweep.SEVERITY_ERROR
    assert f["file"] == "tests/sample_a.gd"
    assert f["line"] == 4
    # metrics 口径：sweep L0 把站点数计入 metrics["guard_pending"]
    assert metrics["guard_pending"] == 1
    assert len(all_findings) == 1


def test_sweep_l0_no_tests_tree_is_zero(tmp_path: Path) -> None:
    assert sweep.check_guard_pending(str(tmp_path)) == []
