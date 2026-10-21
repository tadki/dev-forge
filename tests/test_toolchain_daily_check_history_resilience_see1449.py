"""§SPEC-006 (SEE-1449): history 防单点整体覆盖 — append-only journal。

SEE-1448 实证: history.json 于 10-10/10-11 之间被外部整体覆盖, 10-05..10-10
六天丢失且唯一载体 (150) 不可达, 永久不可再生。加固: persist 每轮先把当日键
追加进 report_dir 下的 append-only journal 再原子写 history.json; 读取路径
load_history_with_recovery 用 journal 恢复缺失日。

判定点钉扎: history 缺某天但 journal 有 → 该天被恢复; journal/副本写入仅落
report_dir; 30 天淘汰语义不破坏; journal 损坏行不致命; 无 journal 行为不变。
"""

import argparse
import json
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
def env(tmp_path, monkeypatch):
    history_file = tmp_path / "history.json"
    journal_file = tmp_path / tdc.HISTORY_JOURNAL_NAME
    monkeypatch.setattr(tdc, "HISTORY_FILE", str(history_file))
    checker = tdc.DailyCheck(argparse.Namespace(
        report_dir=str(tmp_path), no_net=True, json_mode=False))
    return checker, history_file, journal_file, tmp_path


def _write_history(path, days):
    path.write_text(json.dumps({"daily": days}), encoding="utf-8")


def _journal_lines(journal_file):
    return [json.loads(l) for l in journal_file.read_text(encoding="utf-8").splitlines() if l.strip()]


# --- 读取路径恢复 --------------------------------------------------------------


def test_missing_day_recovered_from_journal(env):
    _, history_file, journal_file, _ = env
    _write_history(history_file, {"2026-10-11": {"timeout": 4}})
    journal_file.write_text(json.dumps(
        {"day": "2026-10-10", "failures": {"timeout": 3}, "ts": "t"},
        ensure_ascii=False) + "\n", encoding="utf-8")
    history, recovered = tdc.load_history_with_recovery(str(history_file))
    assert history["daily"]["2026-10-10"] == {"timeout": 3}
    assert history["daily"]["2026-10-11"] == {"timeout": 4}, "已有键不得被 journal 覆盖"
    assert recovered == ["2026-10-10"]


def test_no_journal_returns_history_unchanged(env):
    _, history_file, journal_file, _ = env
    _write_history(history_file, {"2026-10-11": {"timeout": 4}})
    history, recovered = tdc.load_history_with_recovery(str(history_file))
    assert recovered == []
    assert history["daily"] == {"2026-10-11": {"timeout": 4}}


def test_corrupt_journal_lines_skipped(env):
    _, history_file, journal_file, _ = env
    _write_history(history_file, {})
    journal_file.write_text(
        "not-json\n"
        + "\n"                                # 空白行 → 跳过
        + json.dumps({"day": "2026-10-09", "failures": {"error": 2}, "ts": "t"}) + "\n"
        + '{"day": "2026-10-08"}\n'          # 缺 failures → 跳过
        + json.dumps({"day": "2026-10-08", "failures": {"error": 1}, "ts": "t"}) + "\n",
        encoding="utf-8")
    history, recovered = tdc.load_history_with_recovery(str(history_file))
    assert sorted(recovered) == ["2026-10-08", "2026-10-09"]
    assert history["daily"]["2026-10-08"] == {"error": 1}, "后写覆盖先写"


def test_journal_unreadable_returns_empty(env):
    """journal 不可读 (目录不存在) → {} 而非抛错, 读取路径永不因 journal 中断。"""
    assert tdc.journal_read_days("/nonexistent/dir/journal.jsonl") == {}


def test_recovery_preserves_30_day_eviction(env):
    _, history_file, journal_file, _ = env
    days = {"2026-10-%02d" % d: {"timeout": d} for d in range(1, 31)}  # 30 天满窗
    _write_history(history_file, days)
    journal_file.write_text(json.dumps(
        {"day": "2026-10-31", "failures": {"timeout": 9}, "ts": "t"}) + "\n",
        encoding="utf-8")
    history, recovered = tdc.load_history_with_recovery(str(history_file))
    assert recovered == ["2026-10-31"]
    assert len(history["daily"]) == tdc.MAX_HISTORY, "恢复后仍为 30 天窗口"
    assert "2026-10-31" in history["daily"], "恢复日保留"
    assert "2026-10-01" not in history["daily"], "最旧键被淘汰, 语义不破坏"


# --- persist 写入路径 (journal 先行 + 物理自愈) --------------------------------


def _report_for(day, failures):
    return {
        "generated_at": "%sT19:30:00+00:00" % day,
        "failures": failures,
        "failures_per_label": {},
        "failures_window": "daily",
        "health": tdc.GREEN,
        "redline_count": 0,
        "redlines": [],
        "input_missing": [],
        "dimensions": {},
        "findings": [],
        "schema_version": 1,
        "script": "toolchain_daily_check.py",
        "repo": "/tmp/x",
    }


def test_persist_appends_journal_and_physically_heals_overwrite(env):
    """端到端: persist 写 journal → history 被外部整体覆盖 → 下轮 persist 物理恢复。"""
    c, history_file, journal_file, tmp_path = env
    c.persist(_report_for("2026-10-11", {"timeout": 4}))
    assert json.loads((tmp_path / "latest.json").read_text(encoding="utf-8"))
    days = json.loads(history_file.read_text(encoding="utf-8"))["daily"]
    assert days == {"2026-10-11": {"timeout": 4}}
    entries = _journal_lines(journal_file)
    assert entries[-1]["day"] == "2026-10-11"
    assert entries[-1]["failures"] == {"timeout": 4}

    # 模拟 SEE-1448 式外部整体覆盖: history.json 只剩更旧的一天
    _write_history(history_file, {"2026-10-05": {"timeout": 6}})
    c2 = tdc.DailyCheck(argparse.Namespace(
        report_dir=str(tmp_path), no_net=True, json_mode=False))
    c2.persist(_report_for("2026-10-12", {"timeout": 5}))
    days = json.loads(history_file.read_text(encoding="utf-8"))["daily"]
    assert days["2026-10-11"] == {"timeout": 4}, "被覆盖日由 journal 物理恢复"
    assert days["2026-10-05"] == {"timeout": 6}, "既有键保留"
    assert days["2026-10-12"] == {"timeout": 5}, "当日键正常追加"


def test_journal_write_confined_to_report_dir(env):
    c, _, journal_file, tmp_path = env
    c.persist(_report_for("2026-10-11", {"timeout": 4}))
    assert str(journal_file) == os.path.join(str(tmp_path), tdc.HISTORY_JOURNAL_NAME)
    assert journal_file.exists()
    assert set(os.listdir(str(tmp_path))) == {
        "latest.json", "history.json", tdc.HISTORY_JOURNAL_NAME}, os.listdir(str(tmp_path))


def test_journal_compaction_keeps_last_30_days(env):
    _, _, journal_file, _ = env
    for d in range(1, 34):  # 33 个不同日
        tdc.journal_append(str(journal_file), "2026-09-%02d" % d,
                           {"timeout": d}, "t")
    tdc.journal_compact(str(journal_file))
    days = set(tdc.journal_read_days(str(journal_file)))
    assert len(days) == tdc.MAX_HISTORY
    assert not {"2026-09-01", "2026-09-02", "2026-09-03"} & days, "最旧 3 日被压缩"
    assert "2026-09-04" in days and "2026-09-33" in days, "窗口内日保留"


def test_compaction_noop_below_threshold(env):
    _, _, journal_file, _ = env
    tdc.journal_append(str(journal_file), "2026-10-11", {"timeout": 4}, "t")
    before = journal_file.read_text(encoding="utf-8")
    tdc.journal_compact(str(journal_file))
    assert journal_file.read_text(encoding="utf-8") == before, "未超窗不得重写"


def test_evict_daily_shared_semantics():
    daily = {"2026-10-%02d" % d: {"timeout": d} for d in range(1, 33)}
    tdc.evict_daily(daily)
    assert len(daily) == tdc.MAX_HISTORY
    assert "2026-10-01" not in daily and "2026-10-02" not in daily
    assert "2026-10-32" in daily


# --- 防御路径 (SEE-1449 新增分支全覆盖) ----------------------------------------


def test_loader_treats_corrupt_history_as_empty_and_recovers(env):
    """history.json 损坏 (非法 JSON) → 视为空, journal 恢复不受阻。"""
    _, history_file, journal_file, _ = env
    history_file.write_text("{not-json", encoding="utf-8")
    journal_file.write_text(json.dumps(
        {"day": "2026-10-10", "failures": {"timeout": 3}, "ts": "t"}) + "\n",
        encoding="utf-8")
    history, recovered = tdc.load_history_with_recovery(str(history_file))
    assert recovered == ["2026-10-10"]
    assert history["daily"] == {"2026-10-10": {"timeout": 3}}


def test_loader_treats_non_dict_history_as_empty(env):
    """history.json 是合法 JSON 但非 dict (如被整体替换成列表) → 视为空。"""
    _, history_file, _, _ = env
    history_file.write_text("[1, 2, 3]", encoding="utf-8")
    history, recovered = tdc.load_history_with_recovery(str(history_file))
    assert recovered == [] and history.get("daily", {}) == {}


def test_persist_journal_append_failure_warns_but_does_not_block(env, monkeypatch, capsys):
    """journal 通道失败不阻断主报告落盘, 但 stderr 显式可闻 (§SPEC-007 禁静默)。"""
    c, history_file, journal_file, tmp_path = env

    def boom(*_a, **_k):
        raise OSError("disk full")

    monkeypatch.setattr(tdc, "journal_append", boom)
    c.persist(_report_for("2026-10-11", {"timeout": 4}))
    assert (tmp_path / "latest.json").exists(), "主报告不受 journal 失败影响"
    assert history_file.exists(), "history.json 不受 journal 失败影响"
    assert "journal write failed" in capsys.readouterr().err


def test_persist_journal_compact_failure_warns_but_does_not_block(env, monkeypatch, capsys):
    c, history_file, journal_file, _ = env

    def boom(*_a, **_k):
        raise OSError("compact failed")

    monkeypatch.setattr(tdc, "journal_compact", boom)
    c.persist(_report_for("2026-10-11", {"timeout": 4}))
    assert history_file.exists()
    assert "journal write failed" in capsys.readouterr().err


def test_journal_compact_replace_failure_cleans_tmp_and_raises(env, monkeypatch):
    _, _, journal_file, _ = env
    for d in range(1, 34):  # >30 个不同日才会走到 replace
        tdc.journal_append(str(journal_file), "2026-09-%02d" % d, {"timeout": d}, "t")
    real_replace = os.replace

    def boom(src, dst):
        if str(dst) == str(journal_file):
            raise OSError("replace failed")
        return real_replace(src, dst)

    monkeypatch.setattr(os, "replace", boom)
    with pytest.raises(OSError):
        tdc.journal_compact(str(journal_file))
    leftovers = [f for f in os.listdir(str(journal_file.parent))
                 if f.startswith(".journal-")]
    assert leftovers == [], "失败路径必须清理临时文件"


def test_journal_compact_unlink_failure_still_raises_original(env, monkeypatch):
    _, _, journal_file, _ = env
    for d in range(1, 34):
        tdc.journal_append(str(journal_file), "2026-09-%02d" % d, {"timeout": d}, "t")
    real_replace = os.replace
    real_unlink = os.unlink

    def boom_replace(src, dst):
        if str(dst) == str(journal_file):
            raise OSError("replace failed")
        return real_replace(src, dst)

    def boom_unlink(path):
        if str(path).startswith(str(journal_file.parent / ".journal-")):
            raise OSError("unlink failed")
        return real_unlink(path)

    monkeypatch.setattr(os, "replace", boom_replace)
    monkeypatch.setattr(os, "unlink", boom_unlink)
    with pytest.raises(OSError):
        tdc.journal_compact(str(journal_file))


# --- G3 读取路径联动 (恢复可观测) ----------------------------------------------


def test_g3_emits_recovery_info(env):
    c, history_file, journal_file, _ = env
    history_file.write_text(json.dumps(
        {"failures": {"timeout": 1}, "daily": {}}), encoding="utf-8")
    journal_file.write_text(json.dumps(
        {"day": "2026-10-10", "failures": {"timeout": 3}, "ts": "t"}) + "\n",
        encoding="utf-8")
    issues = []
    c._check_g3_daily_delta("G", {"launcher-a": {"timeout": 2}}, issues)
    codes = [f["code"] for f in c.findings if f["level"] == tdc.INFO]
    assert "history_recovered" in codes, c.findings


def test_g3_legacy_cumulative_sentinel_still_guards(env):
    """G3 旧口径迁移哨兵语义不回归 (SEE-1234 判据, 重构后仍生效)。"""
    c, history_file, _, _ = env
    history_file.write_text(json.dumps(
        {"failures": {"timeout": 2317}, "daily": {}}), encoding="utf-8")
    issues = []
    c._check_g3_daily_delta("G", {"launcher-a": {"timeout": 3}}, issues)
    levels = [(f["level"], f["code"]) for f in c.findings]
    assert (tdc.OK, "g3") in levels, levels
    assert not any(lvl == tdc.WARN for lvl, _ in levels), levels


def test_g3_daily_increment_warn_still_fires(env):
    """G3 日增越界语义不回归 (d=2 >= MIN 且昨日基数>=1 → threshold_daily warn)。"""
    c, history_file, _, _ = env
    history_file.write_text(json.dumps(
        {"failures": {"timeout": 1}, "daily": {}}), encoding="utf-8")
    issues = []
    c._check_g3_daily_delta("G", {"launcher-a": {"timeout": 3}}, issues)
    codes = [f["code"] for f in c.findings if f["level"] == tdc.WARN]
    assert "threshold_daily" in codes, c.findings
