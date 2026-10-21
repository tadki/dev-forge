#!/usr/bin/env python3
"""架构半周检评审 prompt 拼装器（Owner 指令复刻 toolchain v1.4，SEE-1182）

执行 agent（autopilot `a08b4ae1-737f-4c63-bc6f-fa0943b965f1`）每期运行时只需执行本脚本，
将脚本输出**直接当作本期评审任务使用**。不再要求 agent 自行阅读模板、识别四主题、
手工拼装 §N 章节、猜测期次。

用法（每期运行，一条命令）：
    python3 dev-forge/review-prompts/architecture/build_review_prompt.py --output ./review_prompt.md

脚本自动完成：期次递增（本地计数器持久化）、四主题轮换、占位符替换、Kill Switch 预检。
模板 §7.1 已含可填空报告骨架，随主题节一并拼入输出。

可选参数（一般不需要）：
    --nth N          强制指定期次（调试用；正常情况省略，由脚本自动管理）
    --date DATE      本期日期（缺省今天 UTC）
    --repo-root DIR  仓库根目录（缺省取脚本所在位置的 ../..）
    --daily-report-dir PATH  占位符 {{daily_report_dir}} 的值（缺省 ~/.multica/arch-patrol/，与 Part A 日检产物同目录）
    --ledger-path PATH       占位符 {{ledger_path}} 的值（缺省 review-prompts/architecture/ledger/YYYY-MM.md，按 --date 月份）
    --state-file PATH        期次计数器持久化文件（缺省 <daily-report-dir>/review-state.json）

退出码：
    0  拼装成功，prompt 已输出
    2  参数错误 / 模板缺失
    3  Kill Switch 命中（~/.multica/arch-patrol/DISABLED 或台账目录 DISABLED 存在）——本期跳过
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path

TEMPLATE_PATH_REL = Path("review-prompts/architecture/prompts/architecture_review_prompt.md")

# 期次 -> (主题素材节号, 主题中文名, 主题英文 key)；素材节正文经 theme_body 注入 §1.1
THEMES = [
    (4, "数据流与耦合", "dataflow-coupling"),
    (5, "状态机与生命周期", "state-lifecycle"),
    (6, "模块边界与扩展点", "module-extension"),
    (7, "可测性与反模式", "testability-antipattern"),
]

# 拼装节顺序：评审任务 / 指引和规则 / 产出（连续编号 §1-§3）
# （模板 §0 是"给调度器看的使用说明"，§4-§7 是主题素材，均不直接进拼装产物）
ASSEMBLE_SECTIONS_ORDER = [1, 2, 3]


def find_repo_root(script_path: Path) -> Path:
    return script_path.resolve().parent.parent.parent


def parse_sections(template_text: str) -> dict[int, str]:
    """按 `## N. ` 顶层节切分模板；代码块（```...```）内的 `## ` 不算节边界。

    返回 {节号: 节文本（含标题行，到下一节标题前）}。
    """
    sections: dict[int, str] = {}
    current_num: int | None = None
    current_buf: list[str] = []
    in_code_block = False

    for line in template_text.splitlines(keepends=True):
        if line.startswith("```"):
            in_code_block = not in_code_block
        m = re.match(r"^## (\d+)\.\s", line)
        if not in_code_block and m:
            if current_num is not None:
                sections[current_num] = "".join(current_buf)
            current_num = int(m.group(1))
            current_buf = [line]
        else:
            if current_num is not None:
                current_buf.append(line)
            # 模板头（第一节之前）不收集
    if current_num is not None:
        sections[current_num] = "".join(current_buf)
    return sections


def substitute(text: str, mapping: dict[str, str]) -> str:
    out = text
    for k, v in mapping.items():
        out = out.replace("{{" + k + "}}", v)
    return out


def check_kill_switch(daily_report_dir: Path, ledger_path: Path) -> str | None:
    """返回触发 Kill Switch 的位置（任一存在即触发），未触发返回 None。"""
    candidates = [
        daily_report_dir / "DISABLED",
        ledger_path.parent / "DISABLED",
    ]
    for p in candidates:
        if p.exists():
            return str(p)
    return None


def next_nth(state_file: Path, forced: int | None) -> int:
    """期次管理：forced 非 None 则用之；否则读 state_file 自增并写回。"""
    if forced is not None:
        return forced
    state = {"nth": 0}
    if state_file.is_file():
        try:
            state.update(json.loads(state_file.read_text(encoding="utf-8")))
        except (json.JSONDecodeError, OSError):
            pass
    state["nth"] = int(state.get("nth", 0)) + 1
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps(state), encoding="utf-8")
    return state["nth"]


def _resolve_date_str(args) -> str | None:
    """解析 --date；非法格式打印错误并返回 None。"""
    if args.date is None:
        today = dt.datetime.now(dt.timezone.utc).date()
        return today.isoformat()
    try:
        return dt.date.fromisoformat(args.date).isoformat()
    except ValueError:
        print(f"ERROR: --date 必须是 YYYY-MM-DD，得到 {args.date!r}", file=sys.stderr)
        return None


def _extract_theme_body(sections: dict, theme_section_num) -> str:
    # 主题素材节正文：去掉标题行与节尾分隔线，注入 §1.1 的 {{theme_body}} 占位符
    theme_body = sections.get(theme_section_num, "")
    theme_lines = theme_body.splitlines()
    # 跳过 "## N. ..." 标题行及其后的空行，去掉尾部 "---" 分隔线
    body_lines = []
    skipped_title = False
    for line in theme_lines:
        if not skipped_title:
            if line.startswith("## "):
                skipped_title = True
            continue
        body_lines.append(line)
    return "\n".join(body_lines).strip().rstrip("-").strip()


def _assemble_sections(sections: dict, mapping: dict) -> str | None:
    parts: list[str] = []
    for slot in ASSEMBLE_SECTIONS_ORDER:
        body = sections.get(slot)
        if body is None:
            print(f"ERROR: 模板缺少 §{slot}", file=sys.stderr)
            return None
        # 模板每节末尾自带分隔线，这里不重复追加；去掉节尾分隔线后拼接时统一补一条
        parts.append(substitute(body.rstrip().rstrip("-").rstrip() + "\n\n---\n\n", mapping))
    return "".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description="架构半周检评审 prompt 拼装器")
    parser.add_argument("--nth", type=int, default=None, help="期次序号（>=1，缺省自动自增）")
    parser.add_argument("--date", type=str, default=None, help="本期日期 YYYY-MM-DD（缺省今天 UTC）")
    parser.add_argument("--output", type=str, default=None, help="输出到文件（缺省 stdout）")
    parser.add_argument("--repo-root", type=str, default=None, help="仓库根目录")
    parser.add_argument("--daily-report-dir", type=str, default=None)
    parser.add_argument("--ledger-path", type=str, default=None)
    parser.add_argument("--state-file", type=str, default=None, help="期次计数器文件")
    parser.add_argument("--executor-agent", type=str, default="Refacty", help="本期执行 agent 名（默认 Refacty）")
    args = parser.parse_args()

    if args.nth is not None and args.nth < 1:
        print(f"ERROR: --nth 必须 >= 1，得到 {args.nth}", file=sys.stderr)
        return 2

    date_str = _resolve_date_str(args)
    if date_str is None:
        return 2

    script_path = Path(__file__).resolve()
    repo_root = Path(args.repo_root).resolve() if args.repo_root else find_repo_root(script_path)
    template_path = repo_root / TEMPLATE_PATH_REL
    if not template_path.is_file():
        print(f"ERROR: 模板文件不存在：{template_path}", file=sys.stderr)
        return 2

    daily_report_dir = Path(args.daily_report_dir or "~/.multica/arch-patrol/").expanduser()
    ledger_path = Path(args.ledger_path) if args.ledger_path else Path(f"review-prompts/architecture/ledger/{date_str[:7]}.md")
    state_file = Path(args.state_file).expanduser() if args.state_file else daily_report_dir / "review-state.json"

    kill = check_kill_switch(daily_report_dir, ledger_path)
    if kill is not None:
        print(f"KILL-SWITCH: {kill} 存在，本期跳过（空输出）", file=sys.stderr)
        return 3

    nth = next_nth(state_file, args.nth)

    theme_idx = (nth - 1) % 4
    theme_section_num, theme_zh, theme_key = THEMES[theme_idx]

    sections = parse_sections(template_path.read_text(encoding="utf-8"))
    theme_body_text = _extract_theme_body(sections, theme_section_num)

    mapping = {
        "date": date_str,
        "nth": str(nth),
        "theme": theme_key,
        "theme_zh": theme_zh,
        "theme_section": str(theme_section_num),
        "theme_body": theme_body_text,
        "executor_agent": args.executor_agent,
        "daily_report_dir": str(daily_report_dir),
        "ledger_path": str(ledger_path),
    }

    prompt = (
        f"# 架构半周检评审任务 · 第 {nth} 期 · {date_str}\n\n"
        f"本期主题：**{theme_zh}**。照下文执行评审，§3 产出含报告骨架与把汇报评论发到本执行 issue 的命令。\n\n"
        f"---\n\n"
    )
    body = _assemble_sections(sections, mapping)
    if body is None:
        return 2
    prompt += body

    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(prompt, encoding="utf-8")
        print(f"OK: 第 {nth} 期 prompt 已写入 {out_path}", file=sys.stderr)
    else:
        sys.stdout.write(prompt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
