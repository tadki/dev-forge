"""§SPEC-106 (SEE-1458): launcher 状态目录归位 — registry 按键合并 + 日志拷贝。

归位对象是现网活跃状态, 判据钉扎 (活机执行归 QA 阶段, 本文件只钉代码语义):
- registry entries 按 rid 键并集, 无丢失无重复; 冲突取 updated_at 新者,
  缺失/并列取规范侧; 合并为新对象, 输入不被修改;
- 日志拷贝只补缺 (不覆盖既有), copy2 保留 mtime (日检并集扫描依赖);
- 默认 dry-run 零写盘; --apply 才落盘, 两份 registry 改前备份;
- 规范目录缺失显式报错 (RelocateError → exit 1), 不静默。
"""

import json
import os
import sys

import pytest

TOOLCHAIN_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "toolchain",
)
sys.path.insert(0, TOOLCHAIN_DIR)

import mcp_state_relocate as msr  # noqa: E402


def _registry(entries, updated_at="2026-10-23T00:00:00Z", schema=2):
    return {"schema_version": schema, "updated_at": updated_at, "entries": entries}


def _entry(port, updated_at):
    return {"port": port, "updated_at": updated_at}


def _write_registry(dirpath, registry):
    os.makedirs(dirpath, exist_ok=True)
    path = os.path.join(dirpath, msr.REGISTRY_NAME)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(registry, f)
    return path


def _write_log(dirpath, name, content):
    os.makedirs(dirpath, exist_ok=True)
    path = os.path.join(dirpath, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return path


def _read_registry(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# --- merge_registries 纯函数 ---------------------------------------------------


def test_merge_union_no_loss():
    canon = _registry({"rid-a": _entry(1, "t1"), "rid-b": _entry(2, "t2")})
    neut = _registry({"rid-c": _entry(3, "t3")})
    merged = msr.merge_registries(canon, neut)
    assert set(merged["entries"]) == {"rid-a", "rid-b", "rid-c"}, "并集无丢失"


def test_merge_conflict_newer_neutral_wins():
    canon = _registry({"rid-x": _entry(1, "2026-10-01T00:00:00Z")})
    neut = _registry({"rid-x": _entry(9, "2026-10-20T00:00:00Z")})
    merged = msr.merge_registries(canon, neut)
    assert merged["entries"]["rid-x"]["port"] == 9, "updated_at 新者胜"
    assert merged["_neutral_won"] == 1


def test_merge_conflict_older_neutral_loses():
    canon = _registry({"rid-x": _entry(1, "2026-10-20T00:00:00Z")})
    neut = _registry({"rid-x": _entry(9, "2026-10-01T00:00:00Z")})
    merged = msr.merge_registries(canon, neut)
    assert merged["entries"]["rid-x"]["port"] == 1, "规范侧权威 (中性侧更旧)"
    assert merged["_neutral_won"] == 0


def test_merge_tie_and_missing_timestamp_canonical_wins():
    canon = _registry({
        "rid-tie": _entry(1, "2026-10-10T00:00:00Z"),
        "rid-nomiss": _entry(2, "2026-10-10T00:00:00Z"),
    })
    neut = _registry({
        "rid-tie": _entry(9, "2026-10-10T00:00:00Z"),
        "rid-nomiss": {"port": 8},  # 无时间戳
    })
    merged = msr.merge_registries(canon, neut)
    assert merged["entries"]["rid-tie"]["port"] == 1, "并列取规范侧"
    assert merged["entries"]["rid-nomiss"]["port"] == 2, "缺时间戳取规范侧"


def test_merge_does_not_mutate_inputs():
    canon = _registry({"rid-a": _entry(1, "t1")})
    neut = _registry({"rid-a": _entry(9, "t9"), "rid-b": _entry(3, "t3")})
    canon_before = json.dumps(canon, sort_keys=True)
    neut_before = json.dumps(neut, sort_keys=True)
    msr.merge_registries(canon, neut)
    assert json.dumps(canon, sort_keys=True) == canon_before
    assert json.dumps(neut, sort_keys=True) == neut_before


# --- plan_log_copies -----------------------------------------------------------


def test_plan_copies_only_missing_dst(tmp_path):
    canon = str(tmp_path / "canon")
    neut = str(tmp_path / "neutral")
    _write_log(neut, "godot-mcp-launcher-bachi.log", "neutral log")
    _write_log(neut, "godot-mcp-launcher-revy.log", "revy log")
    _write_log(canon, "godot-mcp-launcher-bachi.log", "canonical original")
    plan = msr.plan_log_copies(neut, canon)
    assert plan == [(os.path.join(neut, "godot-mcp-launcher-revy.log"),
                     os.path.join(canon, "godot-mcp-launcher-revy.log"))], \
        "只补缺, 既有 bachi.log 不在计划内 (不覆盖)"


def test_plan_copies_ignores_non_launcher_files(tmp_path):
    canon = str(tmp_path / "canon")
    neut = str(tmp_path / "neutral")
    _write_log(neut, "godot-port-registry.json", "{}")
    _write_log(neut, "unrelated.txt", "x")
    assert msr.plan_log_copies(neut, canon) == []


def test_plan_copies_missing_neutral_dir(tmp_path):
    assert msr.plan_log_copies(str(tmp_path / "nope"), str(tmp_path)) == []


# --- build_plan / apply_relocation ---------------------------------------------


@pytest.fixture()
def live(tmp_path):
    canon = str(tmp_path / "canon")
    neut = str(tmp_path / "neutral")
    _write_registry(canon, _registry(
        {"rid-x": _entry(1, "2026-10-01T00:00:00Z")},
        updated_at="2026-10-01T00:00:00Z"))
    _write_registry(neut, _registry(
        {"rid-x": _entry(9, "2026-10-20T00:00:00Z"),
         "rid-y": _entry(3, "2026-10-21T00:00:00Z")},
        updated_at="2026-10-21T00:00:00Z"))
    _write_log(neut, "godot-mcp-launcher-bachi.log", "neutral activity")
    _write_log(canon, "godot-mcp-launcher-bachi.log", "canonical original")
    _write_log(neut, "godot-mcp-launcher-revy.log", "revy activity")
    return canon, neut


def test_build_plan_is_read_only(live):
    canon, neut = live
    canon_reg = os.path.join(canon, msr.REGISTRY_NAME)
    neut_reg = os.path.join(neut, msr.REGISTRY_NAME)
    with open(canon_reg, encoding="utf-8") as f:
        canon_before = f.read()
    with open(neut_reg, encoding="utf-8") as f:
        neut_before = f.read()
    listings_before = (sorted(os.listdir(canon)), sorted(os.listdir(neut)))
    plan = msr.build_plan(canon, neut)
    assert plan["dry_run"] is True
    assert plan["entries_canonical"] == 1
    assert plan["entries_neutral"] == 2
    assert plan["entries_after"] == 2
    assert len(plan["log_copies"]) == 1, "只有 revy.log 需补缺"
    assert (sorted(os.listdir(canon)), sorted(os.listdir(neut))) == listings_before, \
        "dry-run 零写盘 (双目录均无文件增删)"
    with open(canon_reg, encoding="utf-8") as f:
        assert f.read() == canon_before, "dry-run 不改写规范侧 registry 内容"
    with open(neut_reg, encoding="utf-8") as f:
        assert f.read() == neut_before, "dry-run 不改写中性侧 registry 内容"


def test_apply_merges_and_copies(live):
    canon, neut = live
    canon_reg = os.path.join(canon, msr.REGISTRY_NAME)
    neut_reg = os.path.join(neut, msr.REGISTRY_NAME)
    # apply 前快照 (原文级): 备份与「不改写」断言的比对基准
    with open(canon_reg, encoding="utf-8") as f:
        canon_snapshot = f.read()
    with open(neut_reg, encoding="utf-8") as f:
        neut_snapshot = f.read()
    result = msr.apply_relocation(canon, neut)
    merged = _read_registry(canon_reg)
    assert set(merged["entries"]) == {"rid-x", "rid-y"}, "并集落盘"
    assert merged["entries"]["rid-x"]["port"] == 9, "中性侧更新者胜出"
    assert result["neutral_won"] == 1
    # 两份 registry 改前备份均存在, 且内容与各自 apply 前快照逐字节一致
    # (备份时机/对象错误 — 如备份的是合并后内容 — 在此转红)
    assert len(result["backups"]) == 2
    snapshots = {canon_reg: canon_snapshot, neut_reg: neut_snapshot}
    for reg_path, backup_path in result["backups"].items():
        assert os.path.exists(backup_path)
        assert backup_path.startswith(reg_path + ".bak-")
        with open(backup_path, encoding="utf-8") as f:
            assert f.read() == snapshots[reg_path], \
                "备份必须等于 apply 前该 registry 快照: %s" % backup_path
    # 中性侧 registry 只备份不改写 (合并结果只落规范侧)
    with open(neut_reg, encoding="utf-8") as f:
        assert f.read() == neut_snapshot, "apply 不改写中性侧 registry"
    # 日志: 既有 bachi.log 内容不被覆盖; revy.log 补缺且 mtime 保留
    with open(os.path.join(canon, "godot-mcp-launcher-bachi.log"),
              encoding="utf-8") as f:
        assert f.read() == "canonical original", "不覆盖既有"
    revy_dst = os.path.join(canon, "godot-mcp-launcher-revy.log")
    assert os.path.exists(revy_dst)
    assert os.path.getmtime(revy_dst) == os.path.getmtime(
        os.path.join(neut, "godot-mcp-launcher-revy.log")), "copy2 保留 mtime"


def test_apply_default_dry_run_no_write(live):
    canon, neut = live
    before = sorted(os.listdir(canon))
    plan = msr.build_plan(canon, neut)
    assert plan["dry_run"] is True
    assert sorted(os.listdir(canon)) == before


def test_apply_missing_canonical_dir_raises(tmp_path):
    with pytest.raises(msr.RelocateError):
        msr.apply_relocation(str(tmp_path / "nope"), str(tmp_path / "neutral"))


def test_apply_neutral_entries_empty_keeps_canonical_registry(live, tmp_path):
    canon, _neut = live
    quiet = str(tmp_path / "quiet")
    os.makedirs(quiet)
    before = _read_registry(os.path.join(canon, msr.REGISTRY_NAME))
    result = msr.apply_relocation(canon, quiet)
    assert result["merged_registry"] is None, "无中性条目不重写规范侧 registry"
    assert _read_registry(os.path.join(canon, msr.REGISTRY_NAME)) == before


def test_cli_dry_run_default_then_apply(live, monkeypatch, capsys):
    canon, neut = live
    monkeypatch.setattr(sys, "argv", [
        "mcp_state_relocate.py", "--json",
        "--canonical-dir", canon, "--neutral-dir", neut])
    assert msr.main() == 0
    assert json.loads(capsys.readouterr().out)["dry_run"] is True
    monkeypatch.setattr(sys, "argv", [
        "mcp_state_relocate.py", "--apply", "--json",
        "--canonical-dir", canon, "--neutral-dir", neut])
    assert msr.main() == 0
    result = json.loads(capsys.readouterr().out)
    assert result["dry_run"] is False
    assert result["entries_after"] == 2


def test_cli_missing_canonical_dir_exit_1(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", [
        "mcp_state_relocate.py", "--apply",
        "--canonical-dir", str(tmp_path / "nope"),
        "--neutral-dir", str(tmp_path)])
    assert msr.main() == 1
    assert "规范目录不存在" in capsys.readouterr().err


# --- 分支补齐 -------------------------------------------------------------------


def test_merge_schema_version_fallback_chain():
    assert msr.merge_registries({}, {})["schema_version"] == 2, "双缺省回退默认 2"
    canon = {"schema_version": "bad", "entries": {}}
    neut = {"schema_version": 3, "entries": {}}
    assert msr.merge_registries(canon, neut)["schema_version"] == 3, \
        "规范侧非 int 时取中性侧"


def test_merge_updated_at_fallback_now_when_both_missing():
    merged = msr.merge_registries({"entries": {}}, {"entries": {}})
    assert isinstance(merged["updated_at"], str), "双缺时间戳回退当前时刻"


def test_build_plan_flags_missing_canonical_dir(tmp_path):
    plan = msr.build_plan(str(tmp_path / "nope"), str(tmp_path))
    assert "规范目录不存在" in plan["error"], "dry-run 预告 --apply 将拒绝"


def test_atomic_write_failure_cleans_and_raises(tmp_path, monkeypatch):
    target = tmp_path / "reg.json"
    target.write_text("{}", encoding="utf-8")
    real_replace = os.replace

    def boom(src, dst):
        raise OSError("replace failed")

    monkeypatch.setattr(os, "replace", boom)
    with pytest.raises(OSError):
        msr._atomic_write_json(str(target), {"entries": {}})
    leftovers = [f for f in os.listdir(str(tmp_path)) if f.startswith(".registry-")]
    assert leftovers == [], "失败路径必须清理临时文件"
    assert target.read_text(encoding="utf-8") == "{}", "原文件不被半写破坏"


def test_cli_human_readable_output(live, monkeypatch, capsys):
    canon, neut = live
    monkeypatch.setattr(sys, "argv", [
        "mcp_state_relocate.py", "--canonical-dir", canon, "--neutral-dir", neut])
    assert msr.main() == 0
    out = capsys.readouterr().out
    assert "DRY-RUN" in out
    assert "godot-mcp-launcher-revy.log" in out
    monkeypatch.setattr(sys, "argv", [
        "mcp_state_relocate.py", "--apply",
        "--canonical-dir", canon, "--neutral-dir", neut])
    assert msr.main() == 0
    out = capsys.readouterr().out
    assert "APPLY" in out and ".bak-" in out, "人类可读输出含备份明细"


def test_cli_human_output_shows_dry_run_error_note(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", [
        "mcp_state_relocate.py",
        "--canonical-dir", str(tmp_path / "nope"),
        "--neutral-dir", str(tmp_path)])
    assert msr.main() == 0
    assert "ERROR: 规范目录不存在" in capsys.readouterr().out


def test_atomic_write_cleanup_failure_does_not_mask_original(tmp_path, monkeypatch):
    target = tmp_path / "reg.json"
    target.write_text("{}", encoding="utf-8")

    def boom_replace(_src, _dst):
        raise OSError("io failed")

    def boom_unlink(_path):
        raise OSError("cleanup failed")

    monkeypatch.setattr(os, "replace", boom_replace)
    monkeypatch.setattr(os, "unlink", boom_unlink)
    with pytest.raises(OSError):
        msr._atomic_write_json(str(target), {"entries": {}})
    assert target.read_text(encoding="utf-8") == "{}", "原文件不被半写破坏"
