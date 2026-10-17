#!/usr/bin/env bash
# test_see954_real_env_pushguard_e2e.sh
# SEE-954 real-env E2E — push-guard (PreToolUse:Bash) live enforcement + parser.
#
# Two layers are covered:
#   (A) PARSER LAYER (deterministic, self-contained): feeds command JSON directly
#       to push-guard.sh and asserts the Phase-1 classification + exit code. This
#       runs anywhere — no hook involved — so it is not subject to the live hook.
#   (B) LIVE RUNTIME LAYER (observational): the live PreToolUse hook BLOCKS the
#       very Bash call that contains a violating `git push`, so those cases cannot
#       be asserted from inside this script. Their observed outcomes are recorded
#       below as evidence (collected 2026-06-25 in the Multica runtime against the
#       merged master ff238b9). Re-derive by running the probe commands by hand.
#
# A parser over-fire finding (LOW) is documented at the bottom.
set -u
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
fin(){ echo; echo "=== RESULTS ==="; echo "PASS: $PASS"; echo "FAIL: $FAIL"; [ "$FAIL" -eq 0 ]; }

# Locate push-guard.sh relative to this test (repo root /.claude/hooks).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR"
while [ "$ROOT" != "/" ] && [ ! -f "$ROOT/.claude/hooks/scripts/push-guard.sh" ]; do ROOT="$(dirname "$ROOT")"; done
PG="$ROOT/.claude/hooks/scripts/push-guard.sh"
[ -f "$PG" ] || { echo "FATAL: push-guard.sh not found"; exit 1; }

# SEE-1388 §SPEC-020 环境自隔离：push-guard 含身份白名单分支（FORCE_PUSH 认
# MULTICA_AGENT_ID=Atlas id；master 推送认 MULTICA_AGENT_NAME∈{Atlas,Archi}），
# 在 Atlas/Archi 会话身份下裸跑本套件时 (A) 层 exit=2 断言会系统性转假（曾实测
# Atlas env 裸口径 5 FAIL）。classify 一律剥离这两个身份变量，使解析层断言与
# 调用方身份无关（任意身份环境复跑结果一致）。
# classify <command-string> -> prints Phase-1 token (FORCE_PUSH/MASTER_PUSH/NO_REFSPEC/SAFE_PUSH/NOT_PUSH/DELETE_PUSH)
classify(){ printf '%s' "{\"tool_input\":{\"command\":\"$1\"}}" | env -u MULTICA_AGENT_ID -u MULTICA_AGENT_NAME bash "$PG" >/dev/null 2>&1; echo "exit=$?"; }
# raw classification token (stderr is the human message; stdout on allow is the input JSON).
# We rely on exit code: 2 = block, 0 = allow.

FIXTURE="$(mktemp -d /tmp/see954-e2e.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

echo "# (A0) ISOLATION SELF-PROOF — 身份白名单真实存在且 classify 已剥离（§SPEC-020）"
# 判别对：直接注入 Atlas 身份（不走 classify）→ 白名单放行 exit 0（证明身份敏感面
# 存在，无隔离时本套件在该环境下必假绿/假红）；同命令经 classify（外层仍带 Atlas
# 身份）→ 仍 exit 2（隔离生效）。剥离被移除时第二行即红。
ATLAS_ID="fac3e3a1-dcda-498d-8613-e8c2811f3ef5"
# 注：白名单放行路径会写 audit log，PROJECT_ROOT 指到 fixture 防污染仓库
WL_OUT=$(printf '%s' '{"tool_input":{"command":"git push --force origin master:refs/heads/x"}}' \
  | MULTICA_AGENT_ID="$ATLAS_ID" MULTICA_AGENT_NAME=Atlas PROJECT_ROOT="$FIXTURE" bash "$PG" >/dev/null 2>&1; echo "exit=$?")
[ "$WL_OUT" = "exit=0" ] && ok "Atlas 身份直喂 → force-push 白名单放行（exit 0，身份敏感面存在）" \
  || no "Atlas 白名单探针未放行（exit≠0）——身份敏感面已消失，隔离断言退化为永真"
( MULTICA_AGENT_ID="$ATLAS_ID"; MULTICA_AGENT_NAME="Atlas"; export MULTICA_AGENT_ID MULTICA_AGENT_NAME
  ISO_OUT=$(classify 'git push --force origin master:refs/heads/x'); echo "$ISO_OUT" > "$FIXTURE/iso1.out" )
[ "$(cat "$FIXTURE/iso1.out")" = "exit=2" ] && ok "Atlas 身份外层环境下 classify 仍阻断 force-push（exit 2，隔离生效）" \
  || no "classify 在 Atlas 身份下放行 force-push——env 剥离失效"
# master refspec 路径（MULTICA_AGENT_NAME 白名单）同法判别；需在 git 仓库内解析 HOST_REPO
WL_OUT2=$(cd "$ROOT" && printf '%s' '{"tool_input":{"command":"git push origin master"}}' \
  | MULTICA_AGENT_NAME=Atlas bash "$PG" >/dev/null 2>&1; echo "exit=$?")
[ "$WL_OUT2" = "exit=0" ] && ok "Atlas 名字直喂 → master 推送白名单放行（exit 0）" \
  || no "Atlas 名字白名单探针未放行（exit≠0）"
( MULTICA_AGENT_NAME="Archi"; export MULTICA_AGENT_NAME
  ISO_OUT2=$(cd "$ROOT" && classify 'git push origin master'); echo "$ISO_OUT2" > "$FIXTURE/iso2.out" )
[ "$(cat "$FIXTURE/iso2.out")" = "exit=2" ] && ok "Archi 身份外层环境下 classify 仍阻断 master 推送（exit 2，隔离生效）" \
  || no "classify 在 Archi 身份下放行 master 推送——env 剥离失效"


echo "# (A) PARSER LAYER — deterministic classification + exit code"
echo "  (C3) --force token -> FORCE_PUSH -> exit 2 (block)"
[ "$(classify 'git push --force origin master:refs/heads/x')" = "exit=2" ] && ok "force-push blocked (exit 2)" || no "force-push NOT blocked"
echo "  (C3) --force-with-lease token -> FORCE_PUSH -> exit 2"
[ "$(classify 'git push --force-with-lease origin x')" = "exit=2" ] && ok "force-with-lease blocked (exit 2)" || no "force-with-lease NOT blocked"
echo "  (C3) -f short token -> exit 2"
[ "$(classify 'git push -f origin x')" = "exit=2" ] && ok "-f blocked (exit 2)" || no "-f NOT blocked"
echo "  (SC1) explicit master refspec -> MASTER_PUSH -> exit 2"
[ "$(classify 'git push origin master')" = "exit=2" ] && ok "master refspec blocked (exit 2)" || no "master refspec NOT blocked"
echo "  (SC1) local:remote master remote -> MASTER_PUSH -> exit 2"
[ "$(classify 'git push origin HEAD:master')" = "exit=2" ] && ok "HEAD:master blocked (exit 2)" || no "HEAD:master NOT blocked"
echo "  non-push command -> NOT_PUSH -> exit 0 (allow)"
[ "$(classify 'git status')" = "exit=0" ] && ok "non-push allowed (exit 0)" || no "non-push mis-classified"
echo "  NOTE: a SAFE_PUSH refspec (e.g. HEAD:refs/heads/feature/x) is classified SAFE in"
echo "  Phase-1, but the FULL script then enters Phase-2 Check5 which requires the runtime"
echo "  WORKING_BRANCH context (resolved from issue metadata via the multica CLI). In this"
echo "  isolated shell that context is absent, so the script blocks (exit 2) here. The ALLOW"
echo "  arm is therefore only observable LIVE — see probe T6 in section (B), which proved it."

echo
echo "# (B) LIVE RUNTIME LAYER — observed outcomes (Multica runtime, master ff238b9, 2026-06-25)"
cat <<'EVIDENCE'
  Probe P1  git push --force --dry-run origin master:refs/heads/revy-p1-probe
            -> BLOCKED live: "[push-guard] 错误：禁止 force-push（--force / --force-with-lease / -f）"
               (C3 enforced; the --dry-run never executed — whole Bash call denied)        PASS
  Probe P2  git push --dry-run   (from master, upstream=origin/master, wb=feature/SEE-954-low-fix)
            -> BLOCKED live: "[push-guard] 错误：当前任务的共享分支是 feature/SEE-954-low-fix，
               不允许推送到 2>&1"  (Check5 upstream-mismatch enforced)                       PASS
  Probe P3  git push --dry-run origin master
            -> BLOCKED live: "[push-guard] 错误：禁止直接推送到 master 分支"  (SC1 enforced) PASS
  Probe T6  git push --dry-run   (on feature/SEE-954-low-fix, upstream=origin/<wb>)
            -> ALLOWED live: "Everything up-to-date"  (Check5 allow arm enforced)           PASS
  Metadata  push-guard resolved WORKING_BRANCH=feature/SEE-954-low-fix from issue metadata
            (visible in P2 message) -> push-guard <-> issue-metadata integration live        PASS
EVIDENCE
echo "  (Live probes are observational; the hook denies the containing Bash call, so"
echo "   they cannot be asserted from inside this script. Re-derive by hand as above.)"

echo
echo "# DEFECT (LOW) — push-guard Phase-1 token scanner is not shell-aware"
cat <<'DEFECT'
  Symptom 1: shell redirects are parsed as refspec tokens.
            `git push --dry-run 2>&1` -> block message leaks "...不允许推送到 2>&1".
  Symptom 2: multi-line scripts over-fire. A Bash call containing BOTH a `git push`
            somewhere AND the bare word `master`/`main` (e.g. a later `git checkout master`)
            is classified MASTER_PUSH and blocked; a stray `--force` later in the script
            triggers C3. The scanner does not respect shell command separators (`;`, `&&`, `\n`).
  Impact:   Errs SAFE (over-blocks, never under-blocks). No security hole. Usability/cosmetic.
  Root:     Phase-1 Node parser tokenizes the whole command string after the first `push` token.
  Fix hint: shell-aware tokenization — split on `;`/`&&`/`||`/newlines first, then classify
            only the actual `git push` sub-command; ignore redirection tokens.
DEFECT

fin
