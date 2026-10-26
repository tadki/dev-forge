#!/usr/bin/env python3
"""guard_pending — tests/ 内未豁免 pending(...) 站点日检（ledger 2026-09 SPEC-001）。

自 KOL tests/devtests/scripts/check_guard_pending.py 迁入生产化（SEE-1470
Track A），作为 dev-forge 日检能力，并由 architecture_sweep L0 接线
（ledger 2026-09 SPEC-001 声明的口径）。

guard pending = 把坏环境转绿成静默跳过的测试：tests/ 下所有未带
`Track[ -]D pending` 显式标识的 `pending(...)` 调用站点。

退出码：
- 0 且输出 `guard_pending=<N>`：N <= threshold（默认 0）
- 1：N > threshold（出现回归）

分类规则（须与 ledger 2026-09 §SPEC-001 一致）：
- `pending(` 字符串字面量含 "Track D pending" / "Track-D pending"（大小写
  敏感）即为 Track-D 豁免；多行 `pending(` 以本行 + 后两行拼接后匹配。
- 注释行（去首空白后以 # 开头）与 `func test_*` 签名行不计数。
- 其余一律计为 guard pending。

Usage:
    python3 autopilots/guard_pending.py [--repo-root PATH] [--threshold N]
                                        [--format json|text]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TRACK_D_PATTERN = re.compile(r"Track[ -]D pending")
PENDING_CALL = re.compile(r"\bpending\(")
DEFAULT_THRESHOLD = 0
# 多行 pending( 的 Track-D 判定窗口：本行 + 后 2 行（与 KOL 源件口径一致）
CONTEXT_LINES = 3
SNIPPET_MAX = 120


def iter_test_files(repo_root: Path) -> list[Path]:
    tests_root = repo_root / "tests"
    if not tests_root.is_dir():
        return []
    return sorted(tests_root.rglob("*.gd"))


def _is_exempt_line(line: str) -> bool:
    stripped = line.lstrip()
    # 注释行与测试函数签名行永不构成调用站点
    return stripped.startswith("#") or "func test_" in line


def classify_file(path: Path) -> list[tuple[int, str]]:
    """返回该文件未被豁免的 pending 站点 [(lineno, snippet)]。"""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        # 不可读 = 检查面缺失，显式上抛而非静默按 0 处理
        raise RuntimeError(f"guard_pending: cannot read {path}: {exc}") from exc
    total = len(lines)
    hits: list[tuple[int, str]] = []
    for idx, line in enumerate(lines):
        if _is_exempt_line(line) or not PENDING_CALL.search(line):
            continue
        window = "\n".join(lines[idx : min(idx + CONTEXT_LINES, total)])
        if TRACK_D_PATTERN.search(window):
            continue
        hits.append((idx + 1, line.lstrip()[:SNIPPET_MAX]))
    return hits


def scan(repo_root: Path) -> dict:
    by_file: dict[str, list[tuple[int, str]]] = {}
    total = 0
    for path in iter_test_files(repo_root):
        hits = classify_file(path)
        if hits:
            by_file[str(path.relative_to(repo_root))] = hits
            total += len(hits)
    return {"guard_pending": total, "by_file": by_file}


def _emit_text(result: dict, threshold: int) -> None:
    total = result["guard_pending"]
    print(f"guard_pending={total} (threshold={threshold})")
    for path, hits in result["by_file"].items():
        for line, snippet in hits:
            print(f"  {path}:{line}: {snippet}")
    print("OK" if total <= threshold else "FAIL: guard_pending regression")


def _emit_json(result: dict, threshold: int) -> None:
    total = result["guard_pending"]
    ok = total <= threshold
    payload = {
        "tool": "guard_pending",
        "ok": ok,
        "summary": {
            "guard_pending": total,
            "threshold": threshold,
            "by_file": {
                k: [f"{line}:{snip}" for line, snip in v]
                for k, v in result["by_file"].items()
            },
        },
        "failures": []
        if ok
        else [
            {"reason": f"guard_pending={total} exceeds threshold={threshold}"}
        ],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Repository root whose tests/ tree is scanned (default: CWD)",
    )
    parser.add_argument(
        "--threshold",
        type=int,
        default=DEFAULT_THRESHOLD,
        help=f"Max allowed guard pendings (default: {DEFAULT_THRESHOLD})",
    )
    parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
        help="Output format (default: text)",
    )
    args = parser.parse_args()

    result = scan(args.repo_root)
    if args.format == "json":
        _emit_json(result, args.threshold)
    else:
        _emit_text(result, args.threshold)
    return 0 if result["guard_pending"] <= args.threshold else 1


if __name__ == "__main__":
    sys.exit(main())
