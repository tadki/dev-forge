#!/usr/bin/env bash
# plan-mode-allow.sh - PermissionRequest: plan 模式自动放行（Mac 原始 jq 一行式等价迁移）
# stdin: CC PermissionRequest 载荷；permission_mode == "plan" → 输出 allow 协议 JSON，
# 其余模式输出为空 → 引擎按无命中透传，原审批行为保持。脚本内自检为第二道防线：
# 即使引擎 when 门控回归（payload 等值退化），非 plan 模式仍不会被误放行。
exec jq -c 'if .permission_mode == "plan" then {hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}} else empty end'
