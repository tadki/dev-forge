#!/bin/bash
# SEE-1285: SessionStart [gitlink-sync] hint renderer (AC-FWD-003).
#
# Reads the daemon's repo-sync-state.json and emits ONE line per submodule
# whose forward record is non-synced:
#   forwarded → [gitlink-sync] <path>: <from12>→<target12> 已自动同步（CI 绿）
#   blocked (gate1) → [gitlink-sync] <path>: ← 落后中（gate 1 未过：<原因>），详见 daemon 日志
#   blocked (gate2) → [gitlink-sync] <path>: ← 落后中（gate 2 未过：指针悬空未过 GAP-1），详见 daemon 日志
#   blocked (gate3) → [gitlink-sync] <path>: ← 落后中（gate 3 未过：区间完整性），详见 daemon 日志
#
# 零 token：本脚本被 repo-checkout.sh（SessionStart 链）包装进
# output_hint 的 additionalContext —— 不发 issue 评论（v2 计划已取消该通道）。
# state.json 缺失/损坏/无相关条目 → 无输出、rc 0（静默跳过）。
#
# 配置：GITLINK_SYNC_STATE_FILE 覆盖 state 路径；默认 TARGET_REPO_ROOT/.dev/logs/
# repo-sync-state.json（machine-neutral，与 config 同模式）。SEE-1429 最终态：
# TARGET_REPO_ROOT 未设时不再回退 WSL 挂载点硬编码候选（零检出路径耦合，修订 B）
# ——state 保持空走 fail-soft 静默退出，不断链不炸。
#
# 用法（repo-checkout.sh 内）：
#   GITLINK_SYNC_HINT=$(bash .claude/hooks/scripts/lib/gitlink-sync-hint.sh)
#   [ -n "$GITLINK_SYNC_HINT" ] && output_hint "$GITLINK_SYNC_HINT"

set -u

state="${GITLINK_SYNC_STATE_FILE:-}"
if [ -z "$state" ] && [ -n "${TARGET_REPO_ROOT:-}" ]; then
  state="${TARGET_REPO_ROOT%/}/.dev/logs/repo-sync-state.json"
fi
[ -f "$state" ] || exit 0
# python 段消费最终 state 路径（覆盖与派生均在 bash 侧统一裁定）
export GITLINK_SYNC_STATE_FILE="$state"

python3 - <<'PY'
import json, os, sys

state_path = os.environ.get("GITLINK_SYNC_STATE_FILE", "")
try:
    with open(state_path, "r", encoding="utf-8") as f:
        st = json.load(f)
except (OSError, json.JSONDecodeError):
    sys.exit(0)  # corrupt → silent skip

entries = st.get("forward") or {}
if not isinstance(entries, dict):
    sys.exit(0)

def _g1_reason(e):
    concl = str(e.get("gate1_conclusion") or e.get("detail") or "").lower()
    if concl == "fail" or "conclusion='fail'" in concl:
        return "CI 红"
    return "CI 结论未知"

lines = []
for path, e in sorted(entries.items()):
    if not isinstance(e, dict):
        continue
    status = e.get("status")
    if status == "forwarded":
        frm = (e.get("from_sha") or "")[:12]
        tgt = (e.get("target_sha") or e.get("target") or "")[:12]
        lines.append(f"[gitlink-sync] {path}: {frm}→{tgt} 已自动同步（CI 绿）")
    elif status == "blocked":
        gate = e.get("gate") or ""
        if gate == "gate1":
            reason = _g1_reason(e)
        elif gate == "gate2":
            reason = "指针悬空未过 GAP-1"
        elif gate == "gate3":
            reason = "区间完整性"
        else:
            reason = gate or "未知"
        lines.append(
            f"[gitlink-sync] {path}: ← 落后中（{gate} 未过：{reason}），详见 daemon 日志"
        )

if lines:
    print("\n".join(lines))
PY
exit 0
