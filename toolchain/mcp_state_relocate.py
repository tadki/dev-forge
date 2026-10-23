#!/usr/bin/env python3
"""mcp_state_relocate.py — launcher 状态目录归位 (SEE-1458 §SPEC-106).

把漂移写入 ~/.config/godot-mcp (env.sh 中性默认) 的现网状态归位回 ~/.multica
(规范目录, SEE-1292 §DECPL-001):

- port-registry entries 按 rid 键合并: 并集, 无丢失无重复; 同 rid 冲突取
  updated_at 新者 (registry writer 统一 UTC ISO8601, 字典序即时间序),
  时间戳缺失/并列取规范侧 — 规范侧权威。
- launcher 日志拷贝迁移: 不覆盖既有, copy2 保留 mtime (日检并集扫描按
  label+mtime 去重依赖此语义)。

运行窗口约束: 必须在 launcher 修复 (fork shared/SEE-1458) 部署后执行, 否则
新写入继续漂移、归位后状态再度分裂。默认 dry-run 只打印计划不落盘; --apply
才执行, 两份 registry 改前均备份 <file>.bak-<UTC 时间戳>。
注 (复审 Finding 4): 归位只拷贝不删除中性侧历史日志, 归位当日中性侧仍含当日
行 → 日检 g_drift_detected 当日仍会报一次, 属预期 (当日确实漂移过), 次日起
随当日窗口推进自然消退, 不是归位失败信号。

用法:
  python3 toolchain/mcp_state_relocate.py              # dry-run 计划
  python3 toolchain/mcp_state_relocate.py --apply      # 执行归位
  python3 toolchain/mcp_state_relocate.py --json       # 机器可读输出

Exit: 0 = 成功/计划就绪; 1 = 输入或 IO 错误 (显式报错, 不静默)。
"""

import argparse
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from toolchain_daily_check import (  # noqa: E402
    GODOT_MCP_NEUTRAL_HOME,
    LAUNCHER_LOG_PREFIX,
    LAUNCHER_LOG_SUFFIX,
    MULTICA_HOME,
    _registry_entries_of,
    merge_registry_entries,
    read_json,
)

REGISTRY_NAME = "godot-port-registry.json"


class RelocateError(Exception):
    """显式归位失败 (输入缺失/前置不满足), CLI 捕获转 exit 1 + stderr。"""


def merge_registries(canonical, neutral):
    """registry entries 按 rid 键合并 → 新 dict (不改输入, 不可变语义)。

    并集: 两边 entries 全保留; 同 rid 冲突取 updated_at 新者, 缺失/并列取
    规范侧 (entries 合并复用日检 load_registry 的 merge_registry_entries
    SSOT, 复审 Finding 1 — 读侧并集与写侧归位永不语义漂移)。合并文件
    updated_at 取两侧最新输入时间戳 (缺则当前 UTC 时刻)。
    """
    merged_entries, neutral_won = merge_registry_entries(canonical, neutral)
    return {
        "schema_version": _schema_version(canonical, neutral),
        "updated_at": _newest_updated_at(canonical, neutral),
        "entries": merged_entries,
        "_neutral_won": neutral_won,
    }


def _entries_of(registry):
    # entries 解构复用日检侧 SSOT 助手 (与 merge 同源, 防两端口径漂移)
    return _registry_entries_of(registry)


def _schema_version(canonical, neutral):
    schema = canonical.get("schema_version") if isinstance(canonical, dict) else None
    if isinstance(schema, int):
        return schema
    schema = neutral.get("schema_version") if isinstance(neutral, dict) else None
    return schema if isinstance(schema, int) else 2


def _newest_updated_at(canonical, neutral):
    stamps = [r.get("updated_at") for r in (canonical, neutral)
              if isinstance(r, dict) and isinstance(r.get("updated_at"), str)]
    if stamps:
        return max(stamps)
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def plan_log_copies(neutral_dir, canonical_dir):
    """launcher 日志拷贝计划 [(src, dst)]: 仅列 dst 不存在的 (不覆盖既有)。"""
    plan = []
    try:
        names = sorted(os.listdir(neutral_dir))
    except OSError:
        return plan
    for name in names:
        if not (name.startswith(LAUNCHER_LOG_PREFIX) and name.endswith(LAUNCHER_LOG_SUFFIX)):
            continue
        dst = os.path.join(canonical_dir, name)
        if not os.path.exists(dst):
            plan.append((os.path.join(neutral_dir, name), dst))
    return plan


def build_plan(canonical_dir, neutral_dir):
    """dry-run 计划 (只读): registry 合并摘要 + 日志拷贝清单, 零写盘。"""
    canonical = read_json(os.path.join(canonical_dir, REGISTRY_NAME))
    neutral = read_json(os.path.join(neutral_dir, REGISTRY_NAME))
    merged = merge_registries(canonical or {}, neutral or {})
    plan = {
        "dry_run": True,
        "canonical_registry": os.path.join(canonical_dir, REGISTRY_NAME),
        "neutral_registry": os.path.join(neutral_dir, REGISTRY_NAME),
        "entries_canonical": len(_entries_of(canonical)),
        "entries_neutral": len(_entries_of(neutral)),
        "entries_after": len(merged["entries"]),
        "neutral_won": merged["_neutral_won"],
        "log_copies": [[src, dst] for src, dst in
                       plan_log_copies(neutral_dir, canonical_dir)],
    }
    if not os.path.isdir(canonical_dir):
        plan["error"] = "规范目录不存在: %s (--apply 将拒绝)" % canonical_dir
    return plan


def _backup_file(path):
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = path + ".bak-" + ts
    shutil.copy2(path, backup)
    return backup


def _atomic_write_json(path, data):
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=os.path.dirname(path) or ".", prefix=".registry-", suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except OSError:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def apply_relocation(canonical_dir, neutral_dir):
    """执行归位 → 结果 dict。registry 改前备份 + 原子替换; 日志 copy2。"""
    if not os.path.isdir(canonical_dir):
        raise RelocateError("规范目录不存在: %s" % canonical_dir)
    canon_reg_path = os.path.join(canonical_dir, REGISTRY_NAME)
    neut_reg_path = os.path.join(neutral_dir, REGISTRY_NAME)
    canonical = read_json(canon_reg_path)
    neutral = read_json(neut_reg_path)
    backups = {}
    entries_after = len(_entries_of(canonical))
    neutral_won = 0
    merged = False
    if _entries_of(neutral):
        # 无中性条目时不动 registry: 避免以空合并覆盖规范侧文件时间戳
        for reg_path in (canon_reg_path, neut_reg_path):
            if os.path.exists(reg_path):
                backups[reg_path] = _backup_file(reg_path)
        result = merge_registries(canonical or {}, neutral or {})
        neutral_won = result.pop("_neutral_won")
        _atomic_write_json(canon_reg_path, result)
        merged = True
        entries_after = len(result["entries"])
    copied = []
    for src, dst in plan_log_copies(neutral_dir, canonical_dir):
        shutil.copy2(src, dst)
        copied.append(dst)
    return {
        "dry_run": False,
        "merged_registry": canon_reg_path if merged else None,
        "entries_after": entries_after,
        "neutral_won": neutral_won,
        "backups": backups,
        "copied_logs": copied,
    }


def main():
    parser = argparse.ArgumentParser(
        description="launcher 状态目录归位 (SEE-1458 §SPEC-106, 默认 dry-run)")
    parser.add_argument("--apply", action="store_true",
                        help="执行归位 (默认 dry-run 只打印计划)")
    parser.add_argument("--json", action="store_true", help="机器可读输出")
    parser.add_argument("--canonical-dir", default=MULTICA_HOME,
                        help="规范状态目录 (默认 %s)" % MULTICA_HOME)
    parser.add_argument("--neutral-dir", default=GODOT_MCP_NEUTRAL_HOME,
                        help="漂移源目录 (默认 %s)" % GODOT_MCP_NEUTRAL_HOME)
    args = parser.parse_args()
    try:
        if args.apply:
            result = apply_relocation(args.canonical_dir, args.neutral_dir)
        else:
            result = build_plan(args.canonical_dir, args.neutral_dir)
    except (RelocateError, OSError) as exc:
        sys.stderr.write("ERROR: %s\n" % exc)
        return 1
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        mode = "APPLY" if result["dry_run"] is False else "DRY-RUN"
        print("mcp_state_relocate %s" % mode)
        print("  registry 合并后 entries: %s (中性侧胜出 %s)"
              % (result["entries_after"], result["neutral_won"]))
        for item in result.get("log_copies", result.get("copied_logs", [])):
            if isinstance(item, (list, tuple)):
                print("  log: %s → %s" % (item[0], item[1]))
            else:
                print("  log: %s" % item)
        for reg, backup in sorted(result.get("backups", {}).items()):
            print("  backup: %s → %s" % (reg, backup))
        if result.get("error"):
            print("  ERROR: %s" % result["error"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
