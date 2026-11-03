#!/bin/bash
# SEE-1519 §SPEC-001: toolchain-start.sh 幂等化 —— multica daemon 已在运行时
# 脚本不得走 `exec daemon start` → exit 1 的失败路径（SEE-1518: 该路径曾使
# systemd 判失败并连带 cgroup-kill 刚拉起的 repo-sync）。
#
# stub `multica` 覆盖三分支（实机 CLI 契约: `daemon status --output json` 运行时
# exit 0 且 JSON "status":"running"，code 节点 2026-11-04 实测）:
#   A. status → running   : 幂等驻留（不 exec daemon start），守护消失后 exit 0
#   B. status → 未运行    : 维持 exec `daemon start --foreground` 语义
#   C. status → 探测失败  : 不可判 → 退化为 B（改动前行为），不得 exit 1
#
# Hermetic: 临时 HOME/registry/PATH stub，无网络，不触碰真实 daemon / repos.d。
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
START_SH="$REPO_ROOT/launch/toolchain-start.sh"
[ -f "$START_SH" ] || { echo "start.sh missing: $START_SH"; exit 1; }
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# --- 沙箱: 脚本真副本 + 最小 repo-sync 注册树 + stub bin ---
setup_sandbox() {
    rm -rf "$SANDBOX/run" && mkdir -p "$SANDBOX/run/launch" "$SANDBOX/run/repo-sync/repos.d" \
        "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/logs"
    cp "$START_SH" "$SANDBOX/run/launch/toolchain-start.sh"
    chmod +x "$SANDBOX/run/launch/toolchain-start.sh"
    # python3 stub: 记录被调用（模拟 repo-sync daemon 拉起, 不跑真守护）
    cat > "$SANDBOX/bin/python3" <<'EOF'
#!/bin/bash
echo "python3 $*" >> "$STUB_CALLS"
exit 0
EOF
    chmod +x "$SANDBOX/bin/python3"
    cat > "$SANDBOX/run/repo-sync/repos.d/devforge.json" <<EOF
{"name":"devforge","repo_path":"$SANDBOX/repo","branch":"main","pid_file":"$SANDBOX/devforge.pid"}
EOF
    cat > "$SANDBOX/run/repo-sync/repos.d/gqt.json" <<EOF
{"name":"gqt","repo_path":"$SANDBOX/repo2","branch":"master","pid_file":"$SANDBOX/gqt.pid"}
EOF
}

# stub multica: 按模式回放 daemon status / start 行为, 记录全部调用
write_multica_stub() { # $1=mode (running|notrunning|garbage)
    local MODE="$1"
    cat > "$SANDBOX/bin/multica" <<EOF
#!/bin/bash
echo "multica \$*" >> "\$STUB_CALLS"
MODE="$MODE"
case "\$1 \$2" in
  "daemon status")
    case "\$MODE" in
      running)
        N=\$(cat "\$STUB_STATUS_COUNT" 2>/dev/null || echo 0)
        N=\$((N + 1)); echo "\$N" > "\$STUB_STATUS_COUNT"
        if [ "\$N" -ge "\${FLIP_AFTER:-2}" ]; then echo '{"status":"stopped","pid":0}'; exit 1; fi
        echo '{"status":"running","pid":424242}'; exit 0 ;;
      notrunning) echo 'daemon not running'; exit 1 ;;
      garbage)    echo 'not json at all'; exit 0 ;;
    esac ;;
  "daemon start")
    # 模拟前台 daemon: 阻塞至测试放行, 退出码回传 FLIP_EXIT
    sleep "\${DAEMON_HOLD:-30}" &
    wait \$!
    exit "\${DAEMON_START_EXIT:-0}" ;;
esac
exit 0
EOF
    chmod +x "$SANDBOX/bin/multica"
}

run_script() { # $1=logfile, 其余透传
    local log="$1"; shift
    (
        export PATH="$SANDBOX/bin:$PATH"
        export HOME="$SANDBOX/home"
        export STUB_CALLS="$SANDBOX/stub-calls.log"
        export STUB_STATUS_COUNT="$SANDBOX/stub-status-count"
        export TOOLCHAIN_DAEMON_LOG="$SANDBOX/logs/daemon.log"
        export TOOLCHAIN_HOLD_POLL_INTERVAL=1
        : > "$STUB_CALLS"
        rm -f "$SANDBOX/stub-status-count"
        timeout 20 bash "$SANDBOX/run/launch/toolchain-start.sh" > "$log" 2>&1
        echo $? > "$SANDBOX/exit-code"
    )
}

# =============== A. 已运行分支: 幂等驻留, 绝不 exec daemon start ===============
setup_sandbox
write_multica_stub running
# stub 第 3 次 status 回调 stopped: detect#1(running) → hold 轮询#2(running) →
# #3(stopped) → 脚本感知守护消失自行 exit 0（无需外部 kill，确定性收束）。
run_script "$SANDBOX/out-a.log"
RC=$(cat "$SANDBOX/exit-code" 2>/dev/null || echo missing)
CALLS=$(cat "$SANDBOX/stub-calls.log")
if [ "$RC" = "0" ]; then pass "A: 已运行分支脚本 exit 0 (幂等成功, 无失败路径)"; else fail "A: 已运行分支 exit=$RC (期望 0)"; fi
if echo "$CALLS" | grep -q "daemon start"; then fail "A: 已运行分支不得 exec daemon start"; else pass "A: 已运行分支未 exec daemon start"; fi
if grep -q "already running" "$SANDBOX/out-a.log"; then pass "A: 输出幂等驻留标记"; else fail "A: 缺幂等驻留标记 (out-a.log)"; fi
# repo-sync 拉起仍发生（每个注册一条 python3 调用）
NSYNC=$(grep -c "repo_sync_daemon.py" "$SANDBOX/stub-calls.log")
if [ "$NSYNC" -ge 2 ]; then pass "A: repo-sync 拉起照常执行 ($NSYNC)"; else fail "A: repo-sync 拉起缺失 ($NSYNC)"; fi
# 驻留轮询在守护消失后退出（stub 第 3 次 status 回 stopped）
if grep -q "no longer running" "$SANDBOX/out-a.log"; then pass "A: 守护消失后退出交 systemd 重启补位"; else fail "A: 守护消失未退出 (out-a.log)"; fi

# =============== B. 未运行分支: 维持 exec foreground 语义 ===============
setup_sandbox
write_multica_stub notrunning
DAEMON_HOLD=0 run_script "$SANDBOX/out-b.log"
RC=$(cat "$SANDBOX/exit-code")
CALLS=$(cat "$SANDBOX/stub-calls.log")
if [ "$RC" = "0" ]; then pass "B: 未运行分支 exec foreground 成功"; else fail "B: 未运行分支 exit=$RC (期望 0)"; fi
if echo "$CALLS" | grep -q "daemon start --foreground"; then pass "B: exec daemon start --foreground 语义保持"; else fail "B: 未走 daemon start --foreground"; fi
if grep -q "foreground" "$SANDBOX/out-b.log"; then pass "B: foreground 启动标记在"; else fail "B: 缺 foreground 标记"; fi

# =============== C. 探测失败分支: 不可判 → 退化 exec foreground ===============
setup_sandbox
write_multica_stub garbage
DAEMON_HOLD=0 run_script "$SANDBOX/out-c.log"
RC=$(cat "$SANDBOX/exit-code")
CALLS=$(cat "$SANDBOX/stub-calls.log")
if [ "$RC" = "0" ]; then pass "C: 探测失败不触发 exit-1 失败路径"; else fail "C: 探测失败 exit=$RC (期望退化 foreground)"; fi
if echo "$CALLS" | grep -q "daemon start --foreground"; then pass "C: 不可判退化为 exec foreground"; else fail "C: 不可判未退化 exec foreground"; fi

# =============== D. foreground 失败回传: 未运行分支保留失败语义 ===============
setup_sandbox
write_multica_stub notrunning
DAEMON_HOLD=0 DAEMON_START_EXIT=1 run_script "$SANDBOX/out-d.log"
RC=$(cat "$SANDBOX/exit-code")
if [ "$RC" = "1" ]; then pass "D: daemon start 失败时脚本如实回传非零"; else fail "D: daemon start 失败未回传 (exit=$RC)"; fi

echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"
if [ "$FAIL" -eq 0 ]; then
  echo "Overall: PASS"
  exit 0
else
  echo "Overall: FAIL ($FAIL failures)"
  exit 1
fi
