"""§SPEC-105 (SEE-1458): tested 基线回填 — 重扫双目录并集重算指定日失败码。

SEE-1457 实证: history.json 三日基线只由 ~/.multica 单源扫描生成, 被系统性
低估 (error 6→14 / 13→36 / 9→29), 压低 G4/G5 的 2σ 门槛。钉扎:
- 回填按双目录并集重扫指定日并覆盖 daily 键;
- 改前备份 <history>.bak-<UTC ts> 必须存在;
- journal 先落 (崩溃窗口可恢复), history.json 原子替换;
- 未回填日键不受影响; 非法日期显式拒绝 (exit 1), 不静默跳过。
"""

import argparse
import glob
import json
import os
import sys
from datetime import datetime, timezone

import pytest

TOOLCHAIN_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "toolchain",
)
sys.path.insert(0, TOOLCHAIN_DIR)

import toolchain_daily_check as tdc  # noqa: E402

# SEE-1457 口径: 三日回填后 error 应为 14 / 36 / 29 (与现网重扫交叉核对)
D0916, D0921, D0922 = "2026-09-16", "2026-09-21", "2026-09-22"


def _log_lines(day, code, n, mark="proxy"):
    return ["%sT12:00:00.000Z %s %s #%d" % (day, mark, code, i) for i in range(n)]


def _write_log(dirpath, label, lines):
    os.makedirs(dirpath, exist_ok=True)
    with open(os.path.join(dirpath, "godot-mcp-launcher-%s.log" % label),
              "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


@pytest.fixture()
def env(tmp_path, monkeypatch):
    canon = str(tmp_path / "canon")
    neutral = str(tmp_path / "neutral")
    os.makedirs(canon)
    os.makedirs(neutral)
    monkeypatch.setattr(tdc, "MULTICA_HOME", canon)
    monkeypatch.setattr(tdc, "LAUNCHER_LOG_DIRS", (canon, neutral))
    # 现网形态镜像: 单源扫描生成的被低估基线 + 未受影响的新口径日
    history_file = tmp_path / "history.json"
    history_file.write_text(json.dumps({"daily": {
        D0916: {"error": 6, "timeout": 6},
        D0921: {"error": 13, "timeout": 16},
        D0922: {},
        "2026-10-23": {"timeout": 5},
    }}, ensure_ascii=False), encoding="utf-8")
    # 漂移目录中的漏计活动 (canonical 侧已有 09-16 error 6 / timeout 6,
    # 09-21 error 13 / timeout 16; 中性目录补齐差额)
    _write_log(canon, "bachi",
               _log_lines(D0916, "error", 6) + _log_lines(D0916, "timeout", 6)
               + _log_lines(D0921, "error", 13) + _log_lines(D0921, "timeout", 16))
    _write_log(neutral, "bachi",
               _log_lines(D0916, "error", 8, mark="drift")
               + _log_lines(D0921, "error", 23, mark="drift")
               + _log_lines(D0922, "error", 29, mark="drift"))
    return tmp_path, str(history_file)


def test_backfill_corrects_three_days(env):
    tmp_path, history_file = env
    backfilled, _backup = tdc.backfill_history_failures(
        [D0916, D0921, D0922], report_dir=str(tmp_path))
    assert backfilled[D0916] == {"error": 14, "timeout": 6}
    assert backfilled[D0921] == {"error": 36, "timeout": 16}
    assert backfilled[D0922] == {"error": 29}


def test_backfill_backup_file_exists(env):
    tmp_path, history_file = env
    _, backup = tdc.backfill_history_failures([D0916], report_dir=str(tmp_path))
    assert os.path.exists(backup), "改前备份必须落盘"
    with open(backup, encoding="utf-8") as f:
        original = json.load(f)
    assert original["daily"][D0916] == {"error": 6, "timeout": 6}, "备份保存改前值"


def test_backfill_persists_and_journals(env):
    tmp_path, history_file = env
    tdc.backfill_history_failures([D0916, D0921, D0922], report_dir=str(tmp_path))
    with open(history_file, encoding="utf-8") as f:
        persisted = json.load(f)
    assert persisted["daily"][D0922] == {"error": 29}
    assert persisted["daily"]["2026-10-23"] == {"timeout": 5}, "未回填日不受影响"
    journal_days = tdc.journal_read_days(tdc.journal_path_for(history_file))
    for day in (D0916, D0921, D0922):
        assert day in journal_days, "journal 先落 (崩溃窗口可恢复)"
        assert journal_days[day]["failures"] == persisted["daily"][day]


def test_backfill_invalid_date_rejected(env):
    tmp_path, history_file = env
    rc = tdc._run_backfill("2026-13-99", str(tmp_path))
    assert rc == 1, "非法日期必须显式失败"
    assert not glob.glob(history_file + ".bak-*"), "拒绝路径不得产生备份"
    with open(history_file, encoding="utf-8") as f:
        assert json.load(f)["daily"][D0921] == {"error": 13, "timeout": 16}, "拒绝路径不得改写"


def test_backfill_run_entry_outputs_json(env, capsys):
    tmp_path, _history_file = env
    rc = tdc._run_backfill("%s,%s" % (D0916, D0922), str(tmp_path))
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["backfilled"][D0916] == {"error": 14, "timeout": 6}
    assert os.path.exists(out["backup"])


def test_cli_flag_routes_to_backfill(env, monkeypatch):
    tmp_path, _history_file = env
    monkeypatch.setattr(sys, "argv", [
        "toolchain_daily_check.py", "--backfill-failures", D0916,
        "--report-dir", str(tmp_path)])
    assert tdc.main() == 0, "CLI 旗标应路由到回填入口 (只回填不巡检)"


def test_backfill_missing_history_fails_loudly(tmp_path, monkeypatch):
    canon = str(tmp_path / "canon")
    neutral = str(tmp_path / "neutral")
    os.makedirs(canon)
    os.makedirs(neutral)
    monkeypatch.setattr(tdc, "LAUNCHER_LOG_DIRS", (canon, neutral))
    with pytest.raises(OSError):
        tdc.backfill_history_failures([D0916], report_dir=str(tmp_path)), \
            "history.json 缺失必须显式报错 (备份步骤自然失败), 不得静默新建"


# --- 分支补齐 -------------------------------------------------------------------


def test_backfill_history_without_daily_dict(env, monkeypatch):
    tmp_path, history_file = env
    (tmp_path / "history.json").write_text("{}", encoding="utf-8")
    backfilled, _b = tdc.backfill_history_failures([D0916], report_dir=str(tmp_path))
    assert backfilled[D0916] == {"error": 14, "timeout": 6}, "缺 daily 键也能建结构回填"


def test_backfill_atomic_write_failure_cleans_and_raises(env, monkeypatch):
    tmp_path, _history_file = env

    def boom_replace(_src, _dst):
        raise OSError("write path failed")

    def boom_unlink(_path):
        raise OSError("cleanup failed")

    monkeypatch.setattr(os, "replace", boom_replace)
    monkeypatch.setattr(os, "unlink", boom_unlink)
    with pytest.raises(OSError):
        tdc.backfill_history_failures([D0916], report_dir=str(tmp_path))
    # 清理自身失败 (unlink boom) 不掩盖原 replace 错误: 上面 pytest.raises 已钉
    # 原错误仍向外抛; tmp 残留是 unlink 失败下的预期形态, 不作 leftovers 断言


def test_backfill_run_entry_empty_and_blank_segments(env):
    tmp_path, _history_file = env
    assert tdc._run_backfill("", str(tmp_path)) == 1, "空输入显式失败"
    assert tdc._run_backfill(" , ", str(tmp_path)) == 1, "纯空白段=空输入"
    assert tdc._run_backfill("%s, ,%s" % (D0916, D0922), str(tmp_path)) == 0, \
        "夹空白段的合法列表正常回填"


# --- 复审 Finding 2: 空扫护栏 ----------------------------------------------------
# 夹具的 "2026-10-23" 日有非空基线 ({"timeout": 5}) 且双目录均无该日日志 —
# 正是「重扫得空 + 既有非空」的断供形态, 作拒绝路径用例; D0916 等有日志日作对照。


def test_backfill_refuses_empty_rescan_over_nonempty(env):
    tmp_path, history_file = env
    with pytest.raises(tdc.BackfillEmptyScanError):
        tdc.backfill_history_failures(["2026-10-23"], report_dir=str(tmp_path))
    with open(history_file, encoding="utf-8") as f:
        assert json.load(f)["daily"]["2026-10-23"] == {"timeout": 5}, \
            "拒绝路径不得清零既有基线"
    assert not glob.glob(history_file + ".bak-*"), "拒绝在备份前发生, 不留备份"
    assert "2026-10-23" not in tdc.journal_read_days(
        tdc.journal_path_for(history_file)), "拒绝路径不落 journal"


def test_backfill_partial_refusal_zero_writes(env):
    tmp_path, history_file = env
    with pytest.raises(tdc.BackfillEmptyScanError):
        tdc.backfill_history_failures([D0916, "2026-10-23"], report_dir=str(tmp_path))
    with open(history_file, encoding="utf-8") as f:
        persisted = json.load(f)["daily"]
    assert persisted[D0916] == {"error": 6, "timeout": 6}, \
        "任一日拒绝则整批零写盘 (无半套回填)"
    assert D0916 not in tdc.journal_read_days(tdc.journal_path_for(history_file))


def test_backfill_allow_empty_zeroes_explicitly(env):
    tmp_path, history_file = env
    backfilled, backup = tdc.backfill_history_failures(
        ["2026-10-23"], report_dir=str(tmp_path), allow_empty=True)
    assert backfilled["2026-10-23"] == {}, "显式放行才允许清零"
    assert os.path.exists(backup)
    with open(history_file, encoding="utf-8") as f:
        assert json.load(f)["daily"]["2026-10-23"] == {}


def test_backfill_run_entry_refusal_exit_1(env, capsys):
    tmp_path, _history_file = env
    assert tdc._run_backfill("2026-10-23", str(tmp_path)) == 1
    err = capsys.readouterr().err
    assert "2026-10-23" in err and "拒绝静默清零" in err, "报错须带日期上下文与放行指引"


def test_backfill_run_entry_allow_empty_passes_through(env, capsys):
    tmp_path, _history_file = env
    assert tdc._run_backfill("2026-10-23", str(tmp_path), allow_empty=True) == 0
    assert json.loads(capsys.readouterr().out)["backfilled"]["2026-10-23"] == {}


def test_cli_allow_empty_flag_wiring(env, monkeypatch):
    tmp_path, history_file = env
    monkeypatch.setattr(sys, "argv", [
        "toolchain_daily_check.py", "--backfill-failures", "2026-10-23",
        "--allow-empty", "--report-dir", str(tmp_path)])
    assert tdc.main() == 0, "--allow-empty 须接通护栏放行"
    with open(history_file, encoding="utf-8") as f:
        assert json.load(f)["daily"]["2026-10-23"] == {}


def test_backfill_empty_rescan_of_absent_day_allowed(env):
    tmp_path, history_file = env
    backfilled, _b = tdc.backfill_history_failures(
        ["2026-09-30"], report_dir=str(tmp_path))
    assert backfilled["2026-09-30"] == {}, "既有为空/缺失的日无基线可毁, 不拦"
