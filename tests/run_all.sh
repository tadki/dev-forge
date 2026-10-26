#!/bin/bash
# SEE-1330 P4 聚合 runner（SPEC-007）：v2 hooks 全部判据套件一次跑齐。
# SEE-1381 §SPEC-002（fingerprint a1650c198995）：改目录发现——glob test_*.sh
# 覆盖 hooks/ 与 githooks/ 两棵 shell 树，不再硬编码 SUITES 枚举（曾 10/67，
# 57 个套件自建成即孤儿）。legacy-v1/ 因 glob 非递归天然排除。
# Usage: bash tests/run_all.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 预存漂移排除清单：显式声明而非静默跳过（SEE-1381 高风险通道 + §SPEC-012）。
# 条目 = 套件文件名（子串匹配）+ 机器可 grep 归因标签（env:<簇>）；基线 =
# 2026-10-08 本机实测（glob 69 套件 + validator：29 FAIL / 41 GREEN，41 = 40 套件
# + validator）。
# wsl: 基线口径为本机 WSL2（8 核）实测；CI（ubuntu-latest）首跑失败集合可能
# 不同——残余差异按实际归因后增补/删减本清单，收敛后应移除条目而非永久潜伏。
# serial: 串行污染簇 ×3（sentinel_see450/453 + v2_unified_engine_p0）经 ③ Harti
# 2026-10-08 实测推翻——精确 run_all 序列 40/40 GREEN、无顺序依赖；p0 的失败
# 为负载敏感（生产层 unified-hook read -t 3 / run_script timeout 墙钟预算），
# 已在测试层硬化后一并移出本清单，回归 run_all 覆盖。
EXCLUDED=(
  # dev-forge 迁移排除（SEE-1429 Phase 2）：被测对象未随迁移进入本仓
  test_reconcile_working_branch_args_see954.sh       # env:kol-only-script  (reconcile-working-branch.sh 保留 KOL，非注册脚本)
  test_reconcile_working_branch_flow_see1042.sh      # env:kol-only-script
  test_see954_real_env_pushguard_e2e.sh              # env:kol-worktree    (真实 KOL worktree 推送链)
  test_cherry_pick_detection_see523.sh               # env:kol-push-chain  (真实推送语义，宿主环境依赖)
  test_v2_installer_p0.sh                            # env:retired-installer (SEE-1429 §三：install-hooks.sh cp 部署分支物理退役，由 bootstrap/registry-patch 取代)
  test_v2_runscript_mounts_p1.sh                     # env:retired-installer (同上，disable-v1 通道随 v1 兼容层退役)
  test_see1388_firelog_issue_lookup.sh               # env:multica-daemon    (经真实 multica daemon.log 反查 issue id)
  # repo_checkout 系 ×13：env:multica-cli —— 依赖真实 multica CLI / workspace 布局 / daemon
  test_repo_checkout_hint_coverage_see619.sh        # env:multica-cli
  test_repo_checkout_prompt_fix_see634.sh           # env:multica-cli
  test_repo_checkout_rebase_hints_see612.sh         # env:multica-cli
  test_repo_checkout_see1008.sh                     # env:multica-cli
  test_repo_checkout_see1008_prod_sim.sh            # env:multica-cli
  test_repo_checkout_see505.sh                      # env:multica-cli
  test_repo_checkout_see505_e2e.sh                  # env:multica-cli  (teardown 已根治 module core.worktree 改写, SEE-1381 ③; SEE-1396 真机回归 recipe 见套件头注 B——TMPDIR 须指向 active task workdir 内)
  test_repo_checkout_see507.sh                      # env:multica-cli
  test_repo_checkout_see519.sh                      # env:multica-cli
  test_repo_checkout_see534.sh                      # env:multica-cli
  test_repo_checkout_see642_regression.sh           # env:multica-cli
  test_repo_checkout_submodule_see1268.sh           # env:multica-cli
  test_repo_checkout_visibility_see530.sh           # env:multica-cli  (Suite D 传递调用 see505_e2e)
  # env:test-impl-drift 簇 ×6（mention_check ×5 + see764）已于 §SPEC-014 重写
  # 对齐现行实现并移出本清单回归 run_all 覆盖（Owner「哪里发现哪里修复」指示）；
  # see764 重写同时根治其 HOOK_STATE_DIR 缺失导致的哨兵写入生产 state 问题。
  # 零散环境依赖套件 ×8：env:pwd-firelog-daemon —— hook fire log 依赖 workdir
  # PWD / autopilot（auto-pr 通知系，SEE-601）依赖 daemon
  test_auto_pr_on_stop_see465.sh                    # env:pwd-firelog-daemon
  test_auto_pr_notification_branch_var_see601.sh    # env:pwd-firelog-daemon
  test_content_matches_see1151.sh                   # env:pwd-firelog-daemon
  test_grepai_search_reminder_see1238.sh            # env:pwd-firelog-daemon
  test_push_guard_atlas_archi_master_see780.sh      # env:pwd-firelog-daemon
  test_see472_regression.sh                         # env:pwd-firelog-daemon
  test_see653_dispatcher_routing.sh                 # env:pwd-firelog-daemon
  test_see802_transcript_data_source.sh             # env:pwd-firelog-daemon
  # Final Review O1/O3 标签校正（SEE-1381 §SPEC-013）：以下两条真实归因不属
  # pwd-firelog-daemon 簇，单列标签；对 CI 口径的排除结论不变（条目不移出）
  test_see781_firelog_path.sh                       # env:real-firelog  (断言真实机器 hook firelog 存在性——CI ubuntu 无该文件必红；dev 机有即 GREEN，排除为 CI 口径而非 dev 漂移)
  # SEE-1470 Track A 裁定：原条目 test_setup.sh（env:real-repo-mutation）移除——
  # tests/test_setup.sh 在本仓已不存在，被测对象 .githooks/setup.sh 亦未随
  # SEE-1429 迁入（本仓 .githooks/ 仅 README + pre-commit）；空条目残留会让
  # is_excluded 子串匹配误伤未来同名新套件。setup.sh 语义若回迁需重评归因。

  # SEE-1381 §SPEC-016 CI 首跑/复跑归因增补（merge-ref 侧文件不在本分支树，条目
  # 仅在 CI merge checkout 生效；本机 glob 不触达 = 零行为变化）
  test_auto_pr_on_stop_boundary_cases.sh            # env:pwd-firelog-daemon  (SEE-1382 master 侧新增，auto-pr 通知系依赖 daemon)
  test_auto_pr_on_stop_skip_no_working_branch.sh    # env:pwd-firelog-daemon  (同上)
  test_hook_registration_see270.sh                  # env:real-global-hooks  (断言真实 ~/.claude 全局 hooks 注册链——CI 无全局 hooks 工具链，本机剥离 HOME 复现同败)
  test_see300_hook_visibility.sh                    # env:real-global-hooks  (经真实 ~/.claude 工具链跑 gdlint/gdformat——CI 无该环境，剥离 HOME 复现同败)
)
is_excluded() {
    local f="$1" e
    for e in "${EXCLUDED[@]}"; do
        [[ "$f" == *"$e" ]] && return 0
    done
    return 1
}

SUITES=()
for f in "$REPO_ROOT"/tests/test_*.sh; do
    [[ -f "$f" ]] || continue
    # *_live_*.sh = 真平台依赖脚本（multica CLI / 真实 hook 链），runner 永久
    # 黑名单——对齐 pytest requires_daemon（约定见 .dev/docs/devtests.md §5，
    # SEE-1381 §SPEC-008）。e2e/ 树不在本 glob 内；黑名单防未来扩 glob 触达。
    [[ "$(basename "$f")" == *_live_*.sh ]] && continue
    is_excluded "$f" && continue
    SUITES+=("$f")
done
echo "run_all: discovered ${#SUITES[@]} suites (hooks/ + githooks/, glob test_*.sh)"
# §SPEC-012：排除清单显式入输出——EXCLUDED 行 = 预存漂移（带归因标签，
# 见清单注释）；后续任何 FAIL 行 = 真回归（或环境瞬态，需归因）。
echo "run_all: excluded ${#EXCLUDED[@]} suites (pre-existing drift, attributed):"
for e in "${EXCLUDED[@]}"; do
    echo "  EXCLUDED $e"
done

TOTAL_FAIL=0
for S in "${SUITES[@]}"; do
    echo "=== $S"
    if bash "$S" > /tmp/runall-suite.log 2>&1; then
        echo "  GREEN"
    else
        # SEE-1381 §SPEC-016：FAIL 时直出套件输出尾段（CI 归因必需，否则败因不可见）
        echo "  FAIL"
        tail -40 /tmp/runall-suite.log 2>/dev/null | sed 's/^/    /'
        TOTAL_FAIL=$((TOTAL_FAIL+1))
    fi
done
echo "=== node --test validator"
# SEE-1381 §SPEC-016：validator 位置双落点回退——本分支在 .claude/hooks/tests/，
# SEE-1382 于 master 归位至 .dev/tests/hooks/（merge checkout 任一态取在者）。
VALIDATOR=""
for _c in "$REPO_ROOT/claude-hooks/tests/validator.test.mjs" "$REPO_ROOT/tests/validator.test.mjs"; do
    [ -f "$_c" ] && { VALIDATOR="$_c"; break; }
done
if [ -n "$VALIDATOR" ] && node --test "$VALIDATOR" > /tmp/runall-validator.err 2>&1; then
    echo "  GREEN"
else
    # SEE-1381 §SPEC-016：失败诊断直出（CI run_all 吞套件 stdout，无此行则无法归因）
    echo "  FAIL (validator=${VALIDATOR:-<none-found>}, node=$(node --version 2>&1))"
    tail -3 /tmp/runall-validator.err 2>/dev/null | sed 's/^/    /'
    TOTAL_FAIL=$((TOTAL_FAIL+1))
fi
echo ""
if [ "$TOTAL_FAIL" -eq 0 ]; then
    echo "run_all: ALL GREEN"
    exit 0
else
    echo "run_all: $TOTAL_FAIL suite(s) FAILED"
    exit 1
fi
