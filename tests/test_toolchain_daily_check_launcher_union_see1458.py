"""§SPEC-103/104 (SEE-1458): launcher 扫描源双目录并集 + 漂移哨兵。

SEE-1457 实证: 扫描只认 ~/.multica 时, 漂移写入 ~/.config/godot-mcp 的当日
活动一行都读不到 — B3/G3/G5 空转 4 天被压成 GREEN。判据钉扎:
- 并集扫描: 当日活动在任一目录都能被 scan_launcher_failures / label 采集拿到;
- 同 label 双副本: 按行多重集 max 合并 — 相同拷贝计一次, 互补历史段求和,
  归位后规范侧超集不双计;
- 双空退化: 两目录皆无日志源时 B3 显式 warn (b3_no_sources), 不再静默 ok;
- 漂移哨兵: 规范目录之外存在当日 launcher 活动 → g_drift_detected; 仅规范
  目录有当日活动 → 无哨兵 (阴性对照); 昨日活动不触发 (当日口径)。
"""

import argparse
import os
import sys
from datetime import datetime, timedelta, timezone

import pytest

TOOLCHAIN_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "toolchain",
)
sys.path.insert(0, TOOLCHAIN_DIR)

import toolchain_daily_check as tdc  # noqa: E402

TODAY = datetime.now(timezone.utc).date().isoformat()
YESTERDAY = (datetime.now(timezone.utc) - timedelta(days=1)).date().isoformat()


def _log_line(day, text):
    return "%sT12:00:00.000Z %s" % (day, text)


@pytest.fixture()
def sandbox(tmp_path, monkeypatch):
    canon = str(tmp_path / "canon-multica")
    neutral = str(tmp_path / "neutral-config")
    os.makedirs(canon)
    os.makedirs(neutral)
    monkeypatch.setattr(tdc, "MULTICA_HOME", canon)
    monkeypatch.setattr(tdc, "GODOT_MCP_NEUTRAL_HOME", neutral)
    monkeypatch.setattr(tdc, "LAUNCHER_LOG_DIRS", (canon, neutral))
    return tmp_path, canon, neutral


def _write_log(dirpath, label, lines, mtime=None):
    os.makedirs(dirpath, exist_ok=True)
    path = os.path.join(dirpath, "godot-mcp-launcher-%s.log" % label)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def _checker(tmp_path):
    return tdc.DailyCheck(argparse.Namespace(
        report_dir=str(tmp_path), no_net=True, json_mode=False))


def _codes(checker):
    return [(f["level"], f["code"]) for f in checker.findings]


# --- §SPEC-103: 并集扫描 -------------------------------------------------------


def test_neutral_today_activity_scanned(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(neutral, "bachi", [_log_line(TODAY, "proxy timeout exceeded")])
    per_label = tdc.scan_launcher_failures(datetime.now(timezone.utc))
    assert per_label["bachi"]["timeout"] == 1, "中性目录当日活动必须被并集扫描拿到"


def test_distinct_labels_both_dirs_counted(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(canon, "atlas", [_log_line(TODAY, "marker error occurred")])
    _write_log(neutral, "bachi", [_log_line(TODAY, "proxy timeout exceeded")])
    per_label = tdc.scan_launcher_failures(datetime.now(timezone.utc))
    assert per_label["atlas"]["error"] == 1
    assert per_label["bachi"]["timeout"] == 1


def test_same_label_identical_copy_counted_once(sandbox):
    tmp_path, canon, neutral = sandbox
    lines = [_log_line(TODAY, "n1 error"), _log_line(TODAY, "n2 error"),
             _log_line(TODAY, "n3 error")]
    _write_log(canon, "bachi", list(lines))
    _write_log(neutral, "bachi", list(lines))
    per_label = tdc.scan_launcher_failures(datetime.now(timezone.utc))
    assert per_label["bachi"]["error"] == 3, "归位拷贝的相同行不双计 (多重集 max)"


def test_same_label_complementary_segments_sum(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(canon, "bachi", [_log_line(TODAY, "canonical period error")])
    _write_log(neutral, "bachi",
               [_log_line(TODAY, "n1 error"), _log_line(TODAY, "n2 error"),
                _log_line(TODAY, "n3 error")])
    per_label = tdc.scan_launcher_failures(datetime.now(timezone.utc))
    assert per_label["bachi"]["error"] == 4, "互补历史段自然求和 (SEE-1457 基线 6+8=14 场景)"


def test_same_label_superset_after_relocate_no_double_count(sandbox):
    tmp_path, canon, neutral = sandbox
    shared = [_log_line(TODAY, "s1 error"), _log_line(TODAY, "s2 error")]
    _write_log(canon, "bachi", shared + [_log_line(TODAY, "new error")])
    _write_log(neutral, "bachi", list(shared))
    per_label = tdc.scan_launcher_failures(datetime.now(timezone.utc))
    assert per_label["bachi"]["error"] == 3, "归位后规范侧超集: 共享行计一次 + 新行"


def test_repeated_identical_lines_within_one_file_preserved(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(canon, "bachi",
               [_log_line(TODAY, "same error"), _log_line(TODAY, "same error")])
    per_label = tdc.scan_launcher_failures(datetime.now(timezone.utc))
    assert per_label["bachi"]["error"] == 2, "同文件内真实重复行不因合并而坍缩"


def test_sources_union_enumerates_both_dirs(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(canon, "atlas", [_log_line(TODAY, "x")])
    _write_log(neutral, "bachi", [_log_line(TODAY, "y")])
    paths = [path for _l, _d, path in tdc.launcher_log_sources()]
    assert any(p.startswith(canon) for p in paths)
    assert any(p.startswith(neutral) for p in paths)


def test_production_launcher_log_dirs_are_real_union():
    # 其余用例全部 sandbox 覆盖 LAUNCHER_LOG_DIRS, 生产常量的真实双目录布线
    # 若被退化 (单源/错序/漏目录) 此处转红 — SEE-1457 的病根即单源扫描
    home = os.path.expanduser("~")
    assert tdc.LAUNCHER_LOG_DIRS == (
        os.path.join(home, ".multica"),
        os.path.join(home, ".config", "godot-mcp"),
    ), "生产扫描源必须是 ~/.multica ∪ ~/.config/godot-mcp 双目录并集"


def test_g_labels_union(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(canon, "atlas", [_log_line(TODAY, "x")])
    _write_log(neutral, "bachi", [_log_line(TODAY, "y")])
    labels = _checker(tmp_path)._g_launcher_log_labels()
    assert labels == {"atlas", "bachi"}


def test_b3_double_empty_warns_not_ok(sandbox):
    tmp_path, canon, neutral = sandbox
    checker = _checker(tmp_path)
    checker._check_b3_failure_codes("B")
    assert ("warn", "b3_no_sources") in _codes(checker), "双空必须显式 warn"
    assert not any(level == "ok" for level, _c in _codes(checker))


def test_b3_ok_with_sources_no_failures_today(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(neutral, "bachi", [_log_line(YESTERDAY, "old error")])
    checker = _checker(tmp_path)
    checker._check_b3_failure_codes("B")
    codes = _codes(checker)
    assert ("warn", "b3_no_sources") not in codes, "有日志源只是当日无失败码, 不该 warn"
    assert any(level == "ok" and code == "b3" for level, code in codes)


def test_b3_ok_with_sources_and_failures_today(sandbox):
    # B3 happy path (有源 + 当日有失败码 → ok 且带明细): 日检 B 维度主路径,
    # 此分支此前无 fixture 触达 — 现网有失败码当日若该分支崩溃, 整轮日检必炸
    tmp_path, canon, neutral = sandbox
    _write_log(neutral, "bachi", [_log_line(TODAY, "proxy timeout exceeded")])
    checker = _checker(tmp_path)
    checker._check_b3_failure_codes("B")
    codes = _codes(checker)
    assert ("warn", "b3_no_sources") not in codes, "有源有失败码不是断供"
    ok_b3 = [f for f in checker.findings
             if f["level"] == "ok" and f["code"] == "b3"]
    assert len(ok_b3) == 1, "有源有失败码必须走 ok 分支 (带明细)"
    assert "'timeout': 1" in ok_b3[0]["message"], "ok 明细须携带当日失败码计数"


# --- §SPEC-104: 漂移哨兵 -------------------------------------------------------


def test_drift_sentinel_fires_on_neutral_today(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(neutral, "bachi", [_log_line(TODAY, "proxy timeout exceeded")])
    checker = _checker(tmp_path)
    checker._check_g_drift("G")
    assert ("warn", "g_drift_detected") in _codes(checker)


def test_drift_negative_canonical_only(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(canon, "bachi", [_log_line(TODAY, "proxy timeout exceeded")])
    checker = _checker(tmp_path)
    checker._check_g_drift("G")
    codes = _codes(checker)
    assert ("warn", "g_drift_detected") not in codes, "阴性对照: 规范侧活动无哨兵"
    assert ("ok", "g_drift") in codes


def test_drift_ignores_yesterday_activity(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(neutral, "bachi", [_log_line(YESTERDAY, "proxy timeout exceeded")])
    checker = _checker(tmp_path)
    checker._check_g_drift("G")
    assert ("warn", "g_drift_detected") not in _codes(checker), "哨兵只看当日"


# --- 分支补齐: 退化 / OSError 路径 ----------------------------------------------


def test_sources_tolerate_missing_dir(sandbox, monkeypatch):
    tmp_path, canon, neutral = sandbox
    monkeypatch.setattr(tdc, "LAUNCHER_LOG_DIRS",
                        (canon, str(tmp_path / "gone")))
    _write_log(canon, "bachi", [_log_line(TODAY, "proxy timeout exceeded")])
    assert tdc.scan_launcher_failures(datetime.now(timezone.utc))[
        "bachi"]["timeout"] == 1, "目录缺失不致命, 只跳过"


def test_sources_skip_non_log_names(sandbox):
    tmp_path, canon, neutral = sandbox
    _write_log(canon, "bachi", [_log_line(TODAY, "x")])
    with open(os.path.join(canon, "unrelated.txt"), "w", encoding="utf-8") as f:
        f.write("noise\n")
    labels = [lbl for lbl, _d, _p in tdc.launcher_log_sources()]
    assert labels == ["bachi"], "非 launcher 日志文件不入源"


def test_scan_day_lines_unreadable_returns_none(sandbox, monkeypatch):
    tmp_path, canon, neutral = sandbox

    def empty_read(_path, **_kw):
        return ""

    monkeypatch.setattr(tdc, "safe_read", empty_read)
    assert tdc._scan_day_lines(os.path.join(canon, "x.log"), TODAY) is None


def test_drift_tolerates_unreadable_neutral_log(sandbox, monkeypatch):
    tmp_path, canon, neutral = sandbox
    _write_log(neutral, "bachi", [_log_line(TODAY, "proxy timeout exceeded")])

    def selective_read(path, **_kw):
        return "" if path.startswith(neutral) else "text"

    monkeypatch.setattr(tdc, "safe_read", selective_read)
    checker = _checker(tmp_path)
    checker._check_g_drift("G")
    assert ("warn", "g_drift_detected") not in _codes(checker), "不可读不误报"
