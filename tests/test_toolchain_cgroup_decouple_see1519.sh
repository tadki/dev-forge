#!/bin/bash
# SEE-1519 §SPEC-002: repo-sync 与 unit cgroup 解耦。
#
# 三段判据（issue description §SPEC-002）:
#   1. unit 静态断言: KillMode=process 落盘；旧「coarse-stop tradeoff」注释清除；
#      Restart=always 语义保持。
#   2. 脚本双跑幂等: daemon 自锁（pid_file + 存活 PID）下，第二次激活不得
#      double-start 存活实例（stub daemon 模拟自锁语义）。
#   3. 已停实例补拉: 存活实例退场后再次激活，必须为新实例拉起（补拉语义）。
#
# Hermetic: 临时树 + stub multica/python3，无网络，无 systemd 操作。
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
START_SH="$REPO_ROOT/launch/toolchain-start.sh"
UNIT_FILE="$REPO_ROOT/launch/systemd/toolchain-start-all.service"
[ -f "$START_SH" ] || { echo "start.sh missing"; exit 1; }
[ -f "$UNIT_FILE" ] || { echo "unit file missing"; exit 1; }
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# ---------- 1. unit 静态断言 ----------
grep -q "^KillMode=process" "$UNIT_FILE" \
  && pass "unit: KillMode=process 已落盘" \
  || fail "unit: 缺 KillMode=process"
if grep -qi "coarse.stop\|coarse-stop" "$UNIT_FILE"; then
  fail "unit: 旧 coarse-stop tradeoff 注释未清除"
else
  pass "unit: 旧 coarse-stop 注释已清除"
fi
grep -E "^Restart=always" "$UNIT_FILE" >/dev/null \
  && pass "unit: Restart=always 保持（自愈语义不动）" \
  || fail "unit: Restart=always 丢失"
if grep -Eq "^#.*SEE-1519" "$UNIT_FILE"; then
  pass "unit: 解耦依据注释在（可追溯）"
else
  fail "unit: 缺 SEE-1519 解耦注释"
fi

# ---------- stub 环境: daemon 自锁语义模拟 ----------
setup_sandbox() {
    rm -rf "$SANDBOX/run"
    mkdir -p "$SANDBOX/run/launch" "$SANDBOX/run/repo-sync/repos.d" \
        "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/logs"
    cp "$START_SH" "$SANDBOX/run/launch/toolchain-start.sh"
    chmod +x "$SANDBOX/run/launch/toolchain-start.sh"
    # python3 stub: 模拟 repo_sync_daemon 的 pid_file 自锁 —
    #   pid 文件存在且 PID 存活 → exit 0（自锁拒绝 double-start，不写新实例）
    #   否则 → 后台 sleep 60 充当「存活实例」，其 PID 写入 pid_file
    cat > "$SANDBOX/bin/python3" <<STUB
#!/bin/bash
for a in "\$@"; do
  case "\$prev" in
    --config) CFG="\$a" ;;
  esac
  prev="\$a"
done
PID_FILE=\$(sed -n 's/.*"pid_file"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "\$CFG")
if [ -f "\$PID_FILE" ] && kill -0 "\$(cat "\$PID_FILE")" 2>/dev/null; then
  echo "selflock: already running" >> "\$STUB_CALLS"; exit 0
fi
sleep 60 &
SPID=\$!
echo "\$SPID" > "\$PID_FILE"
echo "started: \$SPID" >> "\$STUB_CALLS"
exit 0
STUB
    chmod +x "$SANDBOX/bin/python3"
    # multica stub: daemon 未运行 → exec foreground 立即成功退出（缩短测试）
    cat > "$SANDBOX/bin/multica" <<'STUB'
#!/bin/bash
echo "multica $*" >> "$STUB_CALLS"
if [ "$1 $2" = "daemon status" ]; then echo 'not running'; exit 1; fi
if [ "$1 $2" = "daemon start" ]; then exit 0; fi
exit 0
STUB
    chmod +x "$SANDBOX/bin/multica"
    cat > "$SANDBOX/run/repo-sync/repos.d/devforge.json" <<EOF
{"name":"devforge","repo_path":"$SANDBOX/repo","branch":"main","pid_file":"$SANDBOX/devforge.pid"}
EOF
    cat > "$SANDBOX/run/repo-sync/repos.d/gqt.json" <<EOF
{"name":"gqt","repo_path":"$SANDBOX/repo2","branch":"master","pid_file":"$SANDBOX/gqt.pid"}
EOF
}

run_activation() { # $1 = 标签
    (
        export PATH="$SANDBOX/bin:$PATH"
        export HOME="$SANDBOX/home"
        export STUB_CALLS="$SANDBOX/stub-calls.log"
        export TOOLCHAIN_DAEMON_LOG="$SANDBOX/logs/daemon.log"
        export TOOLCHAIN_HOLD_POLL_INTERVAL=1
        timeout 15 bash "$SANDBOX/run/launch/toolchain-start.sh" >> "$SANDBOX/run-$1.log" 2>&1
        echo $? > "$SANDBOX/exit-code"
    )
}

count_started() { grep -c "^started:" "$SANDBOX/stub-calls.log" 2>/dev/null || echo 0; }
reset_calls() { : > "$SANDBOX/stub-calls.log"; }

# SEE-1525 CI 修复轮：stub 守护由 toolchain-start.sh 后台拉起，"started:" 行与
# devforge.pid 都异步落盘——激活返回后立即断言会与后台启动竞速（GitHub runner
# 实证 run1 started=0 而同批实例到 run2 才可见；本地从不可复现）。有界等待到
# 期望状态可观察再断言；永不达标仍按实际计数响亮失败——零断言弱化。
await_daemons() {
    local want="$1" tries=50 n pid
    while [ "$tries" -gt 0 ]; do
        n=$(count_started)
        pid=$(cat "$SANDBOX/devforge.pid" 2>/dev/null || true)
        if [ "$n" = "$want" ] && [ -n "$pid" ]; then
            echo "$n|$pid"
            return 0
        fi
        sleep 0.2
        tries=$((tries - 1))
    done
    echo "$n|$pid"
}

# ---------- 2. 双跑幂等: 第二次激活不 double-start ----------
setup_sandbox
: > "$SANDBOX/stub-calls.log"
run_activation "1st"
RC1=$(cat "$SANDBOX/exit-code")
[ "$RC1" = "0" ] && pass "run1: 激活成功 exit 0" || fail "run1: exit=$RC1"
STATE1=$(await_daemons 2)
S1=${STATE1%%|*}
PID1=${STATE1#*|}
[ "$S1" = "2" ] && pass "run1: 两仓实例拉起 (started=$S1)" || fail "run1: started=$S1 (期望 2)"
run_activation "2nd"
RC2=$(cat "$SANDBOX/exit-code")
[ "$RC2" = "0" ] && pass "run2: 二次激活成功 exit 0" || fail "run2: exit=$RC2"
STATE2=$(await_daemons 2)
S2=${STATE2%%|*}
PID2=${STATE2#*|}
[ "$S2" = "2" ] && pass "run2: 存活实例未被 double-start (started 仍=$S2)" \
  || fail "run2: double-start! started=$S2 (期望 2)"
[ "$PID1" = "$PID2" ] && pass "run2: pid 未变（同一实例存活）" \
  || fail "run2: pid $PID1 → $PID2（实例被换）"

# ---------- 3. 已停实例补拉 ----------
reset_calls
kill "$PID1" 2>/dev/null   # 模拟实例死亡（存活保障失效场景）
sleep 0.3
kill -0 "$PID1" 2>/dev/null && fail "setup: 模拟死亡未生效" || true
run_activation "3rd"
RC3=$(cat "$SANDBOX/exit-code")
[ "$RC3" = "0" ] && pass "run3: 补拉激活成功 exit 0" || fail "run3: exit=$RC3"
PID3=$(cat "$SANDBOX/devforge.pid" 2>/dev/null)
[ -n "$PID3" ] && [ "$PID3" != "$PID1" ] \
  && pass "run3: 已停实例被补拉（新 pid=$PID3）" \
  || fail "run3: 未补拉（pid=$PID3）"
kill -0 "$PID3" 2>/dev/null \
  && pass "run3: 补拉实例存活" \
  || fail "run3: 补拉实例未存活"

# 清理模拟实例
pkill -f "sleep 60" 2>/dev/null
rm -f "$SANDBOX"/*.pid 2>/dev/null

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
