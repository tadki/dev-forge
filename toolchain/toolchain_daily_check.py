#!/usr/bin/env python3
"""toolchain_daily_check.py — 工具链日检静态脚本 (SEE-1183 Task 1).

Read-only daily health inspection of the KingOfLikes godot-mcp dev tool chain.

Scope (per Atlas trigger 2026-08-27):
  A 启动链配置静态   .mcp.json <-> agent-ports.json 端口表一致性; launcher env 契约;
                     launcher cwd 解析; project.godot port_override 污染; mcp-lease 侧车一致性
  B 运行态           侧车 state 为准 (排除 WARMING/RELEASED 误报); tcp 端口态为辅;
                     WSL/Windows PID 跨界检测; proxy 失败码计数 (Another client/editor_busy/error/timeout/denied);
                     双前缀 tool 名 typo 率
  C hooks 体系       cc/git hooks 调用错误率 + 最近失败尾巴; 拦截分布; 三层链路由错误;
                     .claude/settings.json 权限漂移; 每-agent mcp-config 完整性 (含 timeout)
  E autopilots 健康  run 状态 / PID 锁残留 / workspace 锁残留 / watchdog 重启节流
  F launch 脚本健康  toolchain-start.sh 硬编码路径 / systemd unit / repo_sync_daemon 存活
  G 错误度量口径 (cross-cutting) 绝对失败计数 + 失败码分类 + 每-agent/port 归属 + 与昨日 delta;
                     阈值计数 (同失败码日增 >=2 / 周累计 >=3, 2σ 弃); 日志完整性 "应采 vs 实采"
                     双源并集 (注册端口 ∪ 活跃 lease)

  (无 D 维度: 原 D = skills 版本健康, Owner 2026-08-27 指示从日检范围移除, 编号不复用)

HARD SAFETY: 本脚本完全不产生任何写操作 —— 无 spawn、无 bridge 持有、无对共享/工作树的写入、
零 token (只读本地文件 + tcp connect 探测 + 只读 multica CLI 查询)、不运行 agent。所有输出落在本地报告目录
(默认 ~/.multica/toolchain-reports/), 绝不推送到共享分支。

用法:
  python3 toolchain/toolchain_daily_check.py            # 全量检查, 输出到默认报告目录
  python3 toolchain/toolchain_daily_check.py --no-net   # 跳过 tcp 端口探测
  python3 toolchain/toolchain_daily_check.py --json     # 机器可读 stdout (供 1b autopilot 复用)

Exit code: 0 = GREEN (无红线), 2 = REDLINE (port_override 污染 / 未知根因新失败 / 2σ 越界),
          1 = 脚本自身无法完成检查 (输入缺失)。
"""

import argparse
import fnmatch
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile

try:
    import fcntl
except ImportError:  # win32: 无法 flock 探测, 退化为 PID 存活判定
    fcntl = None
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta, timezone

# --- 常量 ---------------------------------------------------------------------

HOME = os.path.expanduser("~")
MULTICA_HOME = os.path.join(HOME, ".multica")
REPORT_ROOT = os.path.join(MULTICA_HOME, "toolchain-reports")
DEFAULT_REPORT_FILE = os.path.join(REPORT_ROOT, "latest.json")
HISTORY_FILE = os.path.join(REPORT_ROOT, "history.json")
MAX_HISTORY = 30

# 输入面 (存在性缺失记为 input_missing, 不 panic)
PORT_REGISTRY = os.path.join(MULTICA_HOME, "godot-port-registry.json")
REGISTRY_LOCK = os.path.join(MULTICA_HOME, "godot-port-registry.json.lock")
LEASE_DIR = os.path.join(MULTICA_HOME, "godot-mcp-held")
DAEMON_LOG = os.path.join(MULTICA_HOME, "daemon.log")
WATCHDOG_STATE = os.path.join(MULTICA_HOME, "watchdog_state.json")
WORKSPACE_LOCK = os.path.join(MULTICA_HOME, "autopilot_workspace.lock")
HOOK_FIRE_LOG = os.path.join(HOME, ".claude", "hook-fire.log")
CLAUDE_SETTINGS = os.path.join(HOME, ".claude", "settings.json")

# SEE-1457/1458 §SPEC-103: launcher 状态目录并集。SEE-1430b .dev 合并后 launcher
# 自举曾失配, 现网状态漂移写入 env.sh 中性默认目录 (~/.config/godot-mcp) —
# 扫描源只认 ~/.multica 时当日活动一行都读不到 (G3/G5 空转 4 天)。扫描覆盖
# 双目录并集: 当日活动落在任一目录都能被 B3/G2/G3/G5 拿到。
GODOT_MCP_NEUTRAL_HOME = os.path.join(HOME, ".config", "godot-mcp")
LAUNCHER_LOG_DIRS = (MULTICA_HOME, GODOT_MCP_NEUTRAL_HOME)
LAUNCHER_LOG_PREFIX = "godot-mcp-launcher-"
LAUNCHER_LOG_SUFFIX = ".log"

# repo 相对路径 (相对脚本所在仓库)
# SEE-1408: 旧 .dev/godot-mcp/launch 已随 SEE-1273 M3 退役, 控制面现挂载为
# addons/godot_mcp (vendored submodule, 只读)。日检仅读路径探测, 不写 addon。
# SEE-1430: 工具链已迁 dev-forge（~/tools/dev-forge），检查维度改指新真源。
# A 维被测物（launcher/端口表/.mcp.json/project.godot）本体仍属 KOL 主检出
# （godot-mcp 运行域，不随本迁移移动）→ 相对路径改锚到 TARGET_REPO_ROOT。
DEV_FORGE_ROOT = os.path.expanduser("~/tools/dev-forge")
KOL_CHECKOUT_ROOT = os.environ.get("TARGET_REPO_ROOT")
if not KOL_CHECKOUT_ROOT:
    _env_file = os.path.join(DEV_FORGE_ROOT, ".toolchain.env")  # fallback 探测（无则回退）
    _cfg = os.path.expanduser("~/.config/dev-forge/toolchain.env")
    if os.path.isfile(_cfg):
        for _line in open(_cfg, encoding="utf-8", errors="replace"):
            if _line.startswith("TARGET_REPO_ROOT="):
                KOL_CHECKOUT_ROOT = _line.split("=", 1)[1].strip()
                break
KOL_CHECKOUT_ROOT = KOL_CHECKOUT_ROOT or "/mnt/d/GodotProjects/king-of-likes"
LAUNCH_DIR_REL = os.path.join("addons", "godot_mcp", "launch")
START_SH_REL = os.path.join("launch", "toolchain-start.sh")
SYSTEMD_DIR_REL = os.path.join(DEV_FORGE_ROOT, "launch", "systemd")
REPO_SYNC_DAEMON_REL = os.path.join(KOL_CHECKOUT_ROOT, ".dev", "repo-sync", "repo_sync_daemon.py")
MCP_JSON_REL = ".mcp.json"
PROJECT_GODOT_REL = "project.godot"
SIDECAR_REL = ".godot/mcp-lease.json"

# 已知 agent (agent-ports.json 的 SSOT; 检查时也动态读表, 此列表用于默认 env 契约)
KNOWN_AGENTS = ["Atlas", "Archi", "Bachi", "Fronti", "Revy", "Refacty"]

# proxy 失败码模式 → 分类 (来源 addons/godot_mcp/launch/godot-mcp-proxy.mjs)
# timeout 用负向断言排除 FORK_WIRED 配置横幅里的 quick_timeout_ms=<n>:
# 那是每次 launcher 启动成功的标志 (SEE-1234), 计入会把 2σ 检验喂成非平稳累计序列。
# proxy 真实失败文案有两种拼写: "timeout" (banner 排除后) 与 "timed out" — 两个模式并计
PROXY_FAILURE_PATTERNS = [
    ("another_client", re.compile(r"another client is already connected", re.I)),
    ("editor_busy", re.compile(r"editor_busy", re.I)),
    ("error", re.compile(r"\berror\b", re.I)),
    ("timeout", re.compile(r"\btimeout\b(?![_=]?\d|_ms=)|\btimed\s+out\b", re.I)),
    ("denied", re.compile(r"denied", re.I)),
]

# 失败码按行时间戳做当日窗口统计 (SEE-1234): launcher 日志无轮转, 全量 grep 得到的是
# 自日志诞生起的累计值, 对 2σ/日增都是非平稳失真; 只有当日窗口才是真实失败速率
LAUNCHER_LOG_LINE_TS = re.compile(r"^(\d{4}-\d{2}-\d{2})T")

# 双前缀 typo 模式: "godot-mcp-godot-mcp-*" / "mcp__mcp__*"
DOUBLE_PREFIX_PATTERNS = [
    re.compile(r"\bgodot-mcp\s*-\s*godot-mcp\b", re.I),
    re.compile(r"mcp__\s*mcp__", re.I),
]

# 阈值: 同失败码日增 >=2 且昨日基数 >=1 → 可疑; 周累计 >=3 → 可疑; 2σ 规则: 日增超过过去均值+2σ → 红线
DAILY_INCREMENT_MIN = 2
WEEKLY_CUMULATIVE_MIN = 3
SIGMA_MULTIPLIER = 2.0

# SEE-1449: history.daily 的口径切换日 (含当日, 不含次日)。SEE-1234 于 2026-09-04
# 04:33 UTC 落地, 失败码统计自「累计值」切换为「当日窗口值」; 之前写入的 daily 键
# 是旧累计口径 (timeout 2060-2366 / error 89-116, 比当日窗口值大 1-2 个数量级)。
# G5 的 σ 序列确定性排除 <= 2026-09-04 的键, 不依赖 30 天窗口自然淘汰 (本轮 6 个
# 旧口径日按淘汰进度要到 2026-10-27 才清完, 期间假阴性, 见 SEE-1448); 旧键全部
# 自然淘汰后守卫自动退化为 no-op, 行为与无守卫一致。
DAILY_WINDOW_EPOCH_LAST_LEGACY = "2026-09-04"

# SEE-1449: history.json 防单点整体覆盖 — append-only journal (与 history.json 同目录,
# 即 report_dir 内)。persist 每轮先追加当日键再原子写 history.json; 读取路径
# load_history_with_recovery 用 journal 恢复被整体覆盖/丢失的日 (SEE-1448 实证
# 10-05..10-10 六天被外部覆盖后不可再生)。journal 只写 report_dir, 不越界。
HISTORY_JOURNAL_NAME = "history-journal.jsonl"

# 三层钩子链: wrapper → dispatcher → 业务脚本（SEE-1430 后真源在 dev-forge）
HOOK_CHAIN = {
    "wrapper": os.path.join(DEV_FORGE_ROOT, "claude-hooks", "hook-wrapper.sh"),
    "dispatcher": os.path.join(DEV_FORGE_ROOT, "claude-hooks", "dispatcher.sh"),
}

GREEN = "GREEN"
REDLINE = "REDLINE"
OK = "ok"
WARN = "warn"
INFO = "info"
FAIL = "fail"
MISSING = "missing"


# --- 工具 ---------------------------------------------------------------------


def repo_root():
    """脚本所在仓库根 (脚本在 <root>/toolchain/ 下，SEE-1430 迁入 dev-forge)。"""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def safe_read(path, max_bytes=2_000_000):
    """只读文件, 超限截断, 缺失返回 None。绝不写。"""
    try:
        st = os.stat(path)
        if st.st_size > max_bytes:
            return None
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except (OSError, FileNotFoundError):
        return None


def read_json(path, default=None):
    if default is None:
        default = {}
    text = safe_read(path)
    if not text:
        return default
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return default


def journal_path_for(history_file):
    """journal 与 history.json 同目录 (report_dir 边界内, SEE-1449)。"""
    return os.path.join(os.path.dirname(history_file), HISTORY_JOURNAL_NAME)


def journal_read_days(journal_file):
    """读 journal → {day: entry} (后写覆盖先写, 与 daily 键覆盖语义一致)。

    损坏行跳过 (宁漏勿错, 与失败码扫描同口径); 文件缺失/不可读返回 {}。
    """
    days = {}
    try:
        with open(journal_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if isinstance(entry, dict) and isinstance(entry.get("day"), str) \
                        and isinstance(entry.get("failures"), dict):
                    days[entry["day"]] = entry
    except OSError:
        return {}
    return days


def journal_append(journal_file, day, failures, ts):
    """append-only 追加当日键 (write+flush+fsync), 先于 history.json 落盘。"""
    line = json.dumps({"day": day, "failures": failures, "ts": ts},
                      ensure_ascii=False) + "\n"
    with open(journal_file, "a", encoding="utf-8") as f:
        f.write(line)
        f.flush()
        os.fsync(f.fileno())


def journal_compact(journal_file, keep_days=MAX_HISTORY):
    """journal 保留最近 keep_days 个不同日的条目 (界定体积), 原子替换。

    保留窗口与 30 天淘汰窗口等长 (keep_days 默认 MAX_HISTORY), 压缩不会丢可恢复日。
    """
    days = journal_read_days(journal_file)
    if len(days) <= keep_days:
        return
    keep = set(sorted(days.keys())[-keep_days:])
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=os.path.dirname(journal_file) or ".", prefix=".journal-", suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            for day in sorted(days):
                if day in keep:
                    f.write(json.dumps(days[day], ensure_ascii=False) + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, journal_file)
    except OSError:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def evict_daily(daily, max_days=MAX_HISTORY):
    """滑动窗口淘汰 (原地): 只删最旧 key 至 <= max_days (30 天淘汰语义唯一定义点)。"""
    for old_day in sorted(daily.keys()):
        if len(daily) > max_days:
            daily.pop(old_day, None)
        else:
            break


def load_history_with_recovery(history_file):
    """读取路径自愈: history.json 缺某天而 journal 有 → 该天被恢复 (内存)。

    返回 (history, recovered_days)。不写盘 — 物理落盘由 persist 统一原子写;
    恢复合并后按 30 天淘汰语义裁剪, 不破坏现有窗口语义。
    """
    history = read_json(history_file)
    if not isinstance(history, dict):
        history = {}
    daily = history.get("daily")
    if not isinstance(daily, dict):
        daily = {}
    recovered = []
    for day, entry in journal_read_days(journal_path_for(history_file)).items():
        if day not in daily:
            daily[day] = entry["failures"]
            recovered.append(day)
    if recovered:
        evict_daily(daily)
        history["daily"] = daily
    return history, recovered


def backfill_history_failures(days, report_dir=None):
    """SEE-1458 §SPEC-105 tested 基线回填: 重扫双目录并集重算指定日失败码。

    历史基线曾只由 ~/.multica 单源扫描生成, 漂移期 (2026-09-16/09-21/09-22)
    失败码被系统性低估, 压低 G4/G5 的 2σ 门槛 — 本入口按双目录并集重扫指定日
    并覆盖写回 history["daily"][day]。

    写路径沿用 journal + 原子替换机制 (与 persist 同族, 不裸写); history.json
    改前先备份 <history>.bak-<UTC 时间戳>。仅经 --backfill-failures 显式调用
    时执行, 日检主路径保持 HARD SAFETY 只读。
    返回 (backfilled {day: codes}, backup_path)。
    """
    history_file = os.path.join(report_dir or REPORT_ROOT, "history.json")
    backup_path = history_file + ".bak-" + datetime.now(timezone.utc).strftime(
        "%Y%m%dT%H%M%SZ")
    shutil.copy2(history_file, backup_path)
    history, _recovered = load_history_with_recovery(history_file)
    daily = history.get("daily")
    if not isinstance(daily, dict):
        daily = {}
    backfilled = {}
    now = now_iso()
    journal_file = journal_path_for(history_file)
    for day in days:
        # scan_launcher_failures 按 .date().isoformat() 归一, date 对象直接可用
        per_label = scan_launcher_failures(date.fromisoformat(day))
        codes = Counter()
        for cnt in per_label.values():
            codes.update(cnt)
        day_codes = dict(codes)
        daily[day] = day_codes
        backfilled[day] = day_codes
        # journal 与 persist 同序先落 (崩溃窗口内可恢复); 不在此 compact —
        # 回填日常超出 compact 的 30 天窗口, 压缩恰好丢掉本次要保护的条目,
        # 体积由下一轮常规 persist 的 compact 收敛
        journal_append(journal_file, day, day_codes, now)
    history["daily"] = daily
    history["updated_at"] = now
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=os.path.dirname(history_file) or ".", prefix=".history-", suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(history, f, ensure_ascii=False, indent=2, default=str)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, history_file)
    except OSError:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return backfilled, backup_path


def _run_backfill(raw_days, report_dir):
    """--backfill-failures 入口: 解析日期列表 (显式拒绝非法值, 不静默跳过)。"""
    days = []
    for raw in raw_days.split(","):
        day = raw.strip()
        if not day:
            continue
        try:
            date.fromisoformat(day)
        except ValueError:
            sys.stderr.write("ERROR: --backfill-failures 非法日期 %r (需 YYYY-MM-DD)\n" % day)
            return 1
        days.append(day)
    if not days:
        sys.stderr.write("ERROR: --backfill-failures 未给出任何日期\n")
        return 1
    backfilled, backup_path = backfill_history_failures(days, report_dir)
    print(json.dumps({"backfilled": backfilled, "backup": backup_path},
                     ensure_ascii=False, indent=2))
    return 0


def _lock_holder(path):
    """只读判定锁文件当前是否被存活进程持有。

    锁是 advisory flock (SEE-956): 写锁文件不代表持有, flock 才是权威信号。
    先尝试非阻塞 flock 探测 (拿不到 → 有存活持有者); 探测不了 (win32) 时退化为
    解析文件内 PID + kill(pid,0) 存活判定。读文件不修改任何状态。
    返回 (holder_pid, live): holder_pid 为解析到的 PID (可能 None),
    live=True 表示当前有存活持有者。
    """
    holder_pid = None
    text = safe_read(path, max_bytes=4096)
    if text:
        pid_str = text.strip().splitlines()[0].strip()
        if pid_str.isdigit():
            holder_pid = int(pid_str)
    if fcntl is not None:
        try:
            fd = os.open(path, os.O_RDONLY)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)
                return holder_pid, False  # flock 空闲 → 文件只是残留
            except OSError:
                return holder_pid, True   # flock 被占 → 有存活持有者
            finally:
                os.close(fd)
        except OSError:
            pass
    # 无 fcntl 或打开失败: 退化为 PID 存活判定 (文件内的 PID)
    if holder_pid is None:
        return None, False
    try:
        os.kill(holder_pid, 0)
        return holder_pid, True
    except OSError:
        return holder_pid, False


def tcp_open(host, port, timeout=0.5):
    """只读探测端口是否被监听。绝不做任何协议交互。"""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def pid_alive(pid):
    """PID 存活判定：优先 /proc（Linux），无 /proc 时退化为 signal 0。"""
    if os.path.isdir("/proc"):
        return os.path.exists("/proc/%d" % pid)
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def git_out(repo_path, args):
    """只读 git 查询；单仓异常返回空串，不中断日检。"""
    try:
        r = subprocess.run(
            ["git", "-C", repo_path] + args,
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def is_launcher_log_name(name):
    return name.startswith(LAUNCHER_LOG_PREFIX) and name.endswith(LAUNCHER_LOG_SUFFIX)


def launcher_log_label(name):
    return name[len(LAUNCHER_LOG_PREFIX):-len(LAUNCHER_LOG_SUFFIX)]


def launcher_log_sources():
    """launcher 日志源并集枚举 → [(label, logs_dir, path)] (LAUNCHER_LOG_DIRS 顺序)。

    SEE-1458 §SPEC-103: 扫描源 = ~/.multica ∪ ~/.config/godot-mcp。同一 label
    的双目录副本全部返回、不去重 — 两副本可能是互补历史段 (漂移期各自追加,
    SEE-1457 的真实基线 = 两段之和), 也可能是归位拷贝的相同内容; 复制/互补
    的区分在扫描层按行多重集 max 合并处理 (见 scan_launcher_failures), 目录
    层缺乏区分依据, 不在此臆断。
    """
    sources = []
    for logs_dir in LAUNCHER_LOG_DIRS:
        try:
            names = os.listdir(logs_dir)
        except OSError:
            continue
        for name in names:
            if not is_launcher_log_name(name):
                continue
            sources.append((launcher_log_label(name), logs_dir,
                            os.path.join(logs_dir, name)))
    return sorted(sources, key=lambda s: (s[0], s[1]))


def _scan_day_lines(path, today_str):
    """单文件当日窗口行计数 → Counter(line -> n); 文件不可读返回 None。"""
    text = safe_read(path, max_bytes=20_000_000)
    if not text:
        return None
    counts = Counter()
    for line in text.splitlines():
        m = LAUNCHER_LOG_LINE_TS.match(line)
        if not m or m.group(1) != today_str:
            continue
        counts[line] += 1
    return counts


def _merge_label_line_counts(file_counts):
    """同 label 各文件当日行计数 → 行多重集 max 合并 (副本计一次, 互补段求和)。"""
    merged = Counter()
    for counts in file_counts:
        for line, n in counts.items():
            if n > merged[line]:
                merged[line] = n
    return merged


def scan_launcher_failures(today_utc):
    """当日窗口扫描 launcher 日志失败码 (扫描源 = 双目录并集, SEE-1458 §SPEC-103)。

    launcher 日志永不轮转且行首带 `YYYY-MM-DDTHH...` 时间戳: 按行归属 UTC 日期,
    只统计 today_utc 当日的失败码, 避免把自日志诞生起的累计横幅误当"今日" (SEE-1234)。
    无时间戳的行无法定位日期, 一律不计 (宁漏勿错)。

    同 label 双目录副本按行多重集 max 合并: 相同拷贝计一次 (max = 单份计数),
    互补历史段自然求和 (行不相交), 归位后规范侧超集不双计 (每行 max 取规范侧)。
    返回 {label: Counter(code -> n)}。
    """
    # 行首捕获组是纯日期 "YYYY-MM-DD": today_utc 可能是 datetime 或 date,
    # 都归一到 date().isoformat() 才能对上 (datetime.isoformat() 带时间恒不等, SEE-1234 复审 HIGH-1)
    today_str = today_utc.date().isoformat() if hasattr(today_utc, "date") \
        else today_utc.isoformat()
    per_label_files = defaultdict(list)  # label -> [各文件当日行 Counter]
    for label, _logs_dir, path in launcher_log_sources():
        counts = _scan_day_lines(path, today_str)
        if counts is not None:
            per_label_files[label].append(counts)
    per_label = defaultdict(Counter)
    for label, file_counts in per_label_files.items():
        for line, n in _merge_label_line_counts(file_counts).items():
            for code, pattern in PROXY_FAILURE_PATTERNS:
                if pattern.search(line):
                    per_label[label][code] += n
    return per_label


def parse_iso(value):
    """解析 ISO8601 → 带 tz 的 datetime; 纯日期/无 tz 输入按 UTC 处理。"""
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


# --- 各维度检查器 -------------------------------------------------------------


class DailyCheck:
    def __init__(self, args):
        self.args = args
        self.root = repo_root()
        self.report_dir = args.report_dir
        self.findings = []       # {dim, level, code, message}
        self.dim_summary = {}    # dim -> {status, checks, details}
        self.redlines = []
        self.input_missing = []
        self._registry = None
        self._lease_index = None

    # -- 输出与结果收集 --------------------------------------------------------

    def note(self, dim, level, code, message):
        self.findings.append({
            "dim": dim, "level": level, "code": code, "message": message,
        })

    def ok(self, dim, code, message):
        self.note(dim, OK, code, message)

    def warn(self, dim, code, message):
        self.note(dim, WARN, code, message)

    def fail(self, dim, code, message):
        self.note(dim, FAIL, code, message)
        self.redlines.append({"dim": dim, "code": code, "message": message})

    def info(self, dim, code, message):
        """观测项：计入 findings 但不拉升维度状态（恒真告警降级用）。"""
        self.note(dim, INFO, code, message)

    def missing_input(self, path, dim, purpose):
        self.input_missing.append(path)
        self.warn(dim, "input_missing",
                  "输入缺失 %s (%s): %s" % (path, dim, purpose))

    def section(self, dim, status, details):
        self.dim_summary[dim] = {"status": status, "details": details}

    # -- 输入准备 --------------------------------------------------------------

    def load_registry(self):
        if self._registry is not None:
            return self._registry
        self._registry = read_json(PORT_REGISTRY)
        return self._registry

    def load_ports_table(self):
        """agent-ports.json SSOT 端口表。

        SEE-1240 WS-1: default_port 字段已删除（死配置——addon 硬编码自身
        DEFAULT_PORT=6550 且从不读本文件）。仅读 .agents 静态分配表。
        """
        path = os.path.join(KOL_CHECKOUT_ROOT, LAUNCH_DIR_REL, "agent-ports.json")
        data = read_json(path)
        agents = data.get("agents", {}) if isinstance(data, dict) else {}
        return agents, path

    def load_sidecars(self):
        """扫描工作区所有 .godot/mcp-lease.json 侧车。

        Returns: list[dict] with fields + abs_path. 遍历 readdir 只读。
        """
        if self._lease_index is not None:
            return self._lease_index
        out = []
        workspaces = [KOL_CHECKOUT_ROOT]
        # 邻居工作区: Multica workdir 父目录下的其它 <hash>/workdir/KingOfLikes-Godot
        parent = os.path.dirname(os.path.dirname(KOL_CHECKOUT_ROOT))
        if os.path.isdir(parent):
            try:
                for name in sorted(os.listdir(parent)):
                    cand = os.path.join(parent, name, "workdir", "KingOfLikes-Godot")
                    if os.path.isdir(cand):
                        workspaces.append(cand)
            except OSError:
                pass
        for ws in workspaces:
            sidecar = os.path.join(ws, SIDECAR_REL)
            data = read_json(sidecar)
            if data:
                data["abs_path"] = sidecar
                data["worktree"] = data.get("worktree") or ws
                out.append(data)
        self._lease_index = out
        return out

    def list_leases(self):
        """~/.multica/godot-mcp-held/<port>/ 下的 meta/pid 持有目录。"""
        if not os.path.isdir(LEASE_DIR):
            return []
        leases = []
        try:
            for name in sorted(os.listdir(LEASE_DIR)):
                port_dir = os.path.join(LEASE_DIR, name)
                if not os.path.isdir(port_dir):
                    continue
                meta = safe_read(os.path.join(port_dir, "meta"))
                pid = safe_read(os.path.join(port_dir, "pid"))
                leases.append({
                    "port": name,
                    "runtime_id": meta.strip() if meta else "",
                    "pid": pid.strip() if pid else "",
                })
        except OSError:
            pass
        return leases

    # -- A 启动链配置静态 --------------------------------------------------------

    def _check_a1_mcp_servers(self, dim, agents_table, issues):
        # A1: .mcp.json 单静态 server (Option B) vs 端口表一致性
        mcp_path = os.path.join(KOL_CHECKOUT_ROOT, MCP_JSON_REL)
        mcp = read_json(mcp_path)
        servers = mcp.get("mcpServers", {}) if isinstance(mcp, dict) else {}
        if not servers:
            self.missing_input(mcp_path, dim, ".mcp.json 缺失/空")
        elif agents_table:
            for name, cfg in servers.items():
                args = cfg.get("args", []) if isinstance(cfg, dict) else []
                port_hints = [a for a in args if str(a).isdigit()]
                if port_hints and int(port_hints[0]) not in agents_table.values():
                    issues.append(
                        "A1 .mcp.json server '%s' 引用端口 %s 不在 agent-ports.json 表内"
                        % (name, port_hints[0]))
            # launcher 应无 --port 硬编码 (动态解析)
            for name, cfg in servers.items():
                args = cfg.get("args", []) if isinstance(cfg, dict) else []
                if any(str(a) == "--port" for a in args):
                    issues.append(
                        "A1 .mcp.json server '%s' 硬编码 --port, 违反 launcher 动态解析契约 (SEE-1070)"
                        % name)
        if agents_table:
            self.ok(dim, "a1", "端口表加载 %d agents (legacy 静态表)" % len(agents_table))

    def _load_launcher_text(self, dim, issues):
        # A2: launcher env 契约 (KOL_AGENT_NAME / GODOT_PORT / GODOT_HOST)
        launcher = os.path.join(KOL_CHECKOUT_ROOT, LAUNCH_DIR_REL, "godot-mcp-launcher.sh")
        launcher_text = safe_read(launcher)
        if launcher_text:
            env_contract = {
                "KOL_AGENT_NAME": "KOL_AGENT_NAME" in launcher_text or "CLAUDE_AGENT_NAME" in launcher_text,
                "GODOT_PORT": "GODOT_PORT" in launcher_text,
                "GODOT_HOST": "GODOT_HOST" in launcher_text,
            }
            missing_env = [k for k, v in env_contract.items() if not v]
            if missing_env:
                issues.append("A2 launcher 缺 env 契约 %s" % ",".join(missing_env))
        else:
            self.missing_input(launcher, dim, "launcher 缺失")
        return launcher_text

    def _check_a4_port_override(self, dim, issues):
        # A4: project.godot [godot_mcp] port_override 污染
        proj = os.path.join(KOL_CHECKOUT_ROOT, PROJECT_GODOT_REL)
        proj_text = safe_read(proj)
        port_override_hits = []
        if proj_text:
            # port_override_enabled / port_override / port_override_* 键
            for line in proj_text.splitlines():
                if re.search(r"\bport_override(_\w+)?\b\s*=", line):
                    port_override_hits.append(line.strip())
        if port_override_hits:
            msg = "A4 REDLINE: project.godot 含 port_override 污染 %d 行: %s" % (
                len(port_override_hits), "; ".join(port_override_hits[:3]))
            self.fail(dim, "port_override_pollution", msg)
            issues.append(msg)
        else:
            self.ok(dim, "a4", "project.godot 无 port_override 污染")

    def _check_a5_sidecar_schema(self, dim):
        # A5: mcp-lease 侧车一致性 (schema_version / 字段完整)
        sidecars = self.load_sidecars()
        schema_bad = 0
        active = 0
        released = 0
        for s in sidecars:
            if s.get("schema_version") not in (1, 2):
                schema_bad += 1
            st = s.get("state")
            if st == "active":
                active += 1
            elif st == "released":
                released += 1
        if schema_bad:
            self.warn(dim, "sidecar_schema_bad",
                      "侧车 schema 异常 %d 个 (共 %d)" % (schema_bad, len(sidecars)))
        else:
            self.ok(dim, "a5", "侧车 schema 一致 (%d 个, active=%d released=%d)"
                    % (len(sidecars), active, released))

    def dim_a(self):
        dim = "A"
        issues = []
        agents_table, ports_path = self.load_ports_table()
        # 端口表缺失时降级 warn 继续执行: A4 只依赖 project.godot, 不能因单一输入
        # 缺失而让 port_override 污染逃逸 (SEE-1183 D6)
        if not agents_table:
            self.missing_input(ports_path, dim, "端口表 agent-ports.json 缺失/空")
            issues.append("端口表 agent-ports.json 缺失/空, A1 跨表校验跳过; A4 污染检测继续")

        self._check_a1_mcp_servers(dim, agents_table, issues)
        launcher_text = self._load_launcher_text(dim, issues)

        # A3: launcher cwd 解析落到共享 master worktree
        if launcher_text:
            if "/mnt/d/GodotProjects/king-of-likes" not in launcher_text:
                # 若无硬编码 WSL 路径, 检查是否有基于 SCRIPT_DIR 的动态解析
                if "SCRIPT_DIR" not in launcher_text and "PWD" not in launcher_text:
                    issues.append("A3 launcher 无 cwd 解析线索 (既无 WSL 路径也无 SCRIPT_DIR)")

        self._check_a4_port_override(dim, issues)
        self._check_a5_sidecar_schema(dim)

        # 与 dim_b 同口径: 维度 status 由全局 redlines 判定, 不靠字符串匹配 (SEE-1183 D3)
        dim_redlines = [r for r in self.redlines if r.get("dim") == dim]
        status = REDLINE if dim_redlines else ("warn" if issues else "ok")
        self.section(dim, status, issues)

    # -- B 运行态 ----------------------------------------------------------------

    @staticmethod
    def _b1_sidecar_partitions(sidecars):
        active_sidecars = [s for s in sidecars if s.get("state") == "active"]
        released_or_warming = [s for s in sidecars
                               if s.get("state") in ("released", "WARMING", "WARMING-*") or
                               (s.get("state") or "").startswith("WARMING")]
        return active_sidecars, released_or_warming

    def _check_b1_sidecar_ports(self, dim, sidecars, issues):
        # B1: 侧车 state 为准 (lease state 主导) — active 侧车必须与持有目录/端口状态对应
        active_sidecars, released_or_warming = self._b1_sidecar_partitions(sidecars)
        port_set = {s.get("port") for s in active_sidecars if isinstance(s.get("port"), int)}
        # 双重持有是确定性状态矛盾 (state=released/WARMING 但端口仍被 active 侧车占用),
        # 无环境隔离误报可能 → 真红线走 self.fail 入全局 redlines (SEE-1183 D3)
        for s in released_or_warming:
            p = s.get("port")
            if isinstance(p, int) and p in port_set:
                msg = "B1 侧车 state=%s 但端口 %d 同时被 active 侧车占用 (双重持有)" % (
                    s.get("state"), p)
                self.fail(dim, "sidecar_double_hold", msg)
                issues.append(msg)
        # active 侧车端口不可连仅是 tcp 辅助信号 (tcp 为辅): WSL/Windows 隔离下
        # 127.0.0.1 探测可能误报, 不升级为红线 (SEE-1180 口径, SEE-1183 D3)
        if not self.args.no_net:
            for s in active_sidecars:
                p = s.get("port")
                if isinstance(p, int) and not tcp_open("127.0.0.1", p):
                    msg = ("B1 active 侧车 %s 端口 %d 不可连 (可能已 stale, 或 WSL 隔离误报)"
                           % (s.get("worktree"), p))
                    self.warn(dim, "active_sidecar_unreachable", msg)
                    issues.append(msg)

    def _check_b2_lease_pids(self, dim, leases, issues):
        # B2: WSL/Windows PID 跨界检测 — lease 持有 PID 是否存活
        if leases:
            for lease in leases:
                pid = lease.get("pid", "")
                runtime = lease.get("runtime_id", "")
                if pid and not os.path.exists("/proc/%s" % pid):
                    issues.append(
                        "B2 lease 持有目录 %s (runtime=%s) PID %s 在 WSL 侧不存在, "
                        "可能已被 Windows 侧持有或 stale" % (lease["port"], runtime, pid))
        else:
            self.ok(dim, "b2", "无 lease 持有目录残留")

    def _check_b3_failure_codes(self, dim):
        # B3: proxy 失败码计数 (当日窗口, 见 scan_launcher_failures / SEE-1234)
        failure_daily = scan_launcher_failures(datetime.now(timezone.utc))
        failure_counter = Counter()
        scanned_logs = len(failure_daily)
        for codes in failure_daily.values():
            failure_counter.update(codes)
        if not launcher_log_sources():
            # SEE-1458 §SPEC-103: 双目录皆无 launcher 日志 = 测量断供, 显式 warn
            # 而非 ok — 「无日志当作 ok」曾把 4 天扫描断供压成 GREEN (SEE-1457)
            self.warn(dim, "b3_no_sources",
                      "双目录皆无 launcher 日志源 (%s) — 失败码判据空转"
                      % ", ".join(LAUNCHER_LOG_DIRS))
        elif scanned_logs:
            self.ok(dim, "b3", "当日窗口扫描 %d 个 launcher 日志源, 失败码=%s"
                    % (scanned_logs, dict(failure_counter)))
        else:
            self.ok(dim, "b3", "有日志源但当日无失败码 (共 %d 源)"
                    % len(launcher_log_sources()))
        return failure_daily

    def _check_b4_double_prefix(self, dim):
        # B4: 双前缀 tool 名 typo 率 (在 daemon 日志 / hook 日志中)
        typo_counter = 0
        samples = []
        for log_path in (DAEMON_LOG, HOOK_FIRE_LOG):
            text = safe_read(log_path, max_bytes=32_000_000)
            if not text:
                continue
            for pattern in DOUBLE_PREFIX_PATTERNS:
                for m in pattern.finditer(text):
                    typo_counter += 1
                    if len(samples) < 3:
                        samples.append(m.group(0))
        if typo_counter:
            self.warn(dim, "double_prefix_typo",
                      "双前缀 tool 名 typo %d 次 (样例: %s)" % (typo_counter, ", ".join(samples)))
        else:
            self.ok(dim, "b4", "无双前缀 typo")

    def dim_b(self):
        dim = "B"
        issues = []
        sidecars = self.load_sidecars()
        leases = self.list_leases()

        self._check_b1_sidecar_ports(dim, sidecars, issues)
        self._check_b2_lease_pids(dim, leases, issues)
        failure_daily = self._check_b3_failure_codes(dim)
        self._check_b4_double_prefix(dim)

        # 维度 status 与全局 redlines 判定一致: 只有 self.fail() 触发的真红线才标
        # REDLINE (SEE-1183 D3); 仅有 warn 时标 warn, 避免读者误读 B 维度触发红线
        dim_redlines = [r for r in self.redlines if r.get("dim") == dim]
        status = REDLINE if dim_redlines else ("warn" if issues else "ok")
        self.section(dim, status, issues)
        return failure_daily

    # -- C hooks 体系 -----------------------------------------------------------

    @staticmethod
    def _c_count_wrapper_registrations(settings):
        hooks_cfg = settings.get("hooks", {}) if isinstance(settings, dict) else {}
        registered = 0
        for phase, entries in hooks_cfg.items():
            if not isinstance(entries, list):
                continue
            for entry in entries:
                for hook in entry.get("hooks", []):
                    cmd = hook.get("command", "")
                    if "hook-wrapper.sh" in cmd:
                        registered += 1
        return registered

    @staticmethod
    def _c_scan_firelog_lines(log_text):
        """返回 (total_lines, error_lines, recent_tail)。"""
        total_lines = log_text.count("\n")
        error_lines = []
        recent = []
        for line in log_text.splitlines():
            if "ERROR" in line or "error" in line or "failed" in line.lower():
                error_lines.append(line)
                if len(recent) < 5:
                    recent.append(line)
        return total_lines, error_lines, recent

    @staticmethod
    def _c_phase_distribution(log_text):
        distribution = Counter()
        if log_text:
            for line in log_text.splitlines():
                for phase in ("PreToolUse", "PostToolUse", "SessionStart", "Stop"):
                    if ("[%s]" % phase) in line:
                        distribution[phase] += 1
                        break
        return distribution

    def _check_c1_chain_files(self, dim, issues):
        wrapper = os.path.join(self.root, HOOK_CHAIN["wrapper"])
        dispatcher = os.path.join(self.root, HOOK_CHAIN["dispatcher"])
        wrapper_ok = os.path.isfile(wrapper)
        dispatcher_ok = os.path.isfile(dispatcher)
        if not wrapper_ok:
            self.missing_input(wrapper, dim, "wrapper 缺失")
        if not dispatcher_ok:
            self.missing_input(dispatcher, dim, "dispatcher 缺失")
        if wrapper_ok and dispatcher_ok:
            self.ok(dim, "c1", "三层链 wrapper+dispatcher 存在")
        else:
            issues.append("C1 三层链文件缺失 wrapper=%s dispatcher=%s"
                          % (wrapper_ok, dispatcher_ok))

    def _check_c2_settings_registration(self, dim, issues):
        # C2: settings.json hooks 注册完整性 (每个 alias 有 wrapper 引用)
        settings = read_json(CLAUDE_SETTINGS)
        registered = self._c_count_wrapper_registrations(settings)
        if registered:
            self.ok(dim, "c2", "settings.json 注册 %d 个 wrapper 钩子" % registered)
        else:
            self.missing_input(CLAUDE_SETTINGS, dim, "settings.json 无 wrapper 钩子注册")
            issues.append("C2 settings.json 未注册任何 wrapper 钩子 (权限漂移?)")

    def _check_c3_firelog_error_rate(self, dim, issues):
        # C3: hook-fire.log 错误率 + 最近失败尾巴
        log_text = safe_read(HOOK_FIRE_LOG, max_bytes=32_000_000)
        if log_text:
            total_lines, error_lines, _recent = self._c_scan_firelog_lines(log_text)
            err_rate = len(error_lines) / total_lines if total_lines else 0.0
            self.ok(dim, "c3", "hook-fire.log %d 行, 错误 %d (%.2f%%)"
                    % (total_lines, len(error_lines), err_rate * 100))
            if err_rate > 0.05:
                issues.append("C3 hook 错误率 %.1f%% 偏高" % (err_rate * 100))
        else:
            self.missing_input(HOOK_FIRE_LOG, dim, "hook-fire.log 缺失")
            issues.append("C3 hook-fire.log 缺失")
        return log_text

    def _check_c3p_repo_firelog(self, dim, issues):
        # C3p（SEE-1388 §SPEC-011，fingerprint 468a2757121e）：项目级 hook-fire.log 检查。
        # 全局项只覆盖全局位，各 checkout 内的项目级落点曾是盲区；保留全局项，项目级
        # 并报（盲区可报告）。
        repo_firelog = os.path.join(KOL_CHECKOUT_ROOT, ".claude", "hook-fire.log")
        repo_text = safe_read(repo_firelog, max_bytes=32_000_000)
        if repo_text:
            repo_total = repo_text.count("\n")
            repo_err = sum(1 for line in repo_text.splitlines()
                           if "ERROR" in line or "error" in line or "failed" in line.lower())
            self.ok(dim, "c3p", "项目级 hook-fire.log %d 行, 错误 %d" % (repo_total, repo_err))
        else:
            self.missing_input(repo_firelog, dim, "项目级 hook-fire.log 缺失")
            issues.append("C3p 项目级 hook-fire.log 缺失")

    def _check_c4_phase_distribution(self, dim, log_text):
        # C4: 拦截分布 — PreToolUse/PostToolUse/SessionStart/Stop 各自计数
        distribution = self._c_phase_distribution(log_text)
        if distribution:
            self.ok(dim, "c4", "拦截分布 %s" % dict(distribution))
        else:
            self.ok(dim, "c4", "无拦截记录")

    def _check_c5_agent_mcp_timeout(self, dim):
        # C5: 每-agent mcp-config 完整性 (含 timeout 字段) — 检查 agent 级 .mcp.json
        agent_mcp_dir = os.path.join(HOME, ".claude")
        agent_mcp_paths = []
        for agent in KNOWN_AGENTS:
            cand = os.path.join(agent_mcp_dir, "%s.mcp.json" % agent.lower())
            if os.path.isfile(cand):
                agent_mcp_paths.append(cand)
        if agent_mcp_paths:
            missing_timeout = []
            for path in agent_mcp_paths:
                data = read_json(path)
                for sname, scfg in data.get("mcpServers", {}).items():
                    if "timeout" not in scfg:
                        missing_timeout.append("%s:%s" % (os.path.basename(path), sname))
            if missing_timeout:
                self.warn(dim, "agent_mcp_no_timeout",
                          "agent 级 mcp-config 缺 timeout 字段: %s" % ", ".join(missing_timeout))
            else:
                self.ok(dim, "c5", "%d 个 agent 级 mcp-config 含 timeout" % len(agent_mcp_paths))
        else:
            self.ok(dim, "c5", "无独立 agent 级 mcp-config (采用共享 .mcp.json 方案)")

    def dim_c(self):
        dim = "C"
        issues = []
        self._check_c1_chain_files(dim, issues)
        self._check_c2_settings_registration(dim, issues)
        log_text = self._check_c3_firelog_error_rate(dim, issues)
        self._check_c3p_repo_firelog(dim, issues)
        self._check_c4_phase_distribution(dim, log_text)
        self._check_c5_agent_mcp_timeout(dim)

        status = "ok"
        if any(i.startswith("C1") for i in issues):
            status = "warn"
        self.section(dim, status, issues)

    # -- E autopilots 健康 --------------------------------------------------------

    def _check_e1_watchdog_restarts(self, dim, issues):
        # E1: watchdog 状态文件 (重启节流记录)
        wd = read_json(WATCHDOG_STATE)
        if isinstance(wd, dict) and wd.get("restarts"):
            restarts = wd["restarts"]
            recent = [r for r in restarts if parse_iso(r.get("at")) and
                      (datetime.now(timezone.utc) - parse_iso(r.get("at"))) < timedelta(days=7)]
            self.ok(dim, "e1", "watchdog 累计重启 %d 次, 近7天 %d 次" % (len(restarts), len(recent)))
            if len(recent) >= 5:
                issues.append("E1 近7天重启 %d 次, 超过节流容忍 (5)" % len(recent))
        elif os.path.exists(WATCHDOG_STATE):
            self.ok(dim, "e1", "watchdog 状态文件存在, 无重启记录")
        else:
            self.ok(dim, "e1", "无 watchdog 状态文件 (尚未运行过)")

    def _check_e2_pid_lock_residue(self, dim, issues):
        # E2: PID 锁残留 — watchdog_state.json.lock 或相关 .lock
        lock_files = []
        for cand in (WATCHDOG_STATE + ".lock", os.path.join(MULTICA_HOME, "watchdog.lock"),
                     os.path.join(MULTICA_HOME, "agent_watchdog.lock")):
            if os.path.exists(cand):
                lock_files.append(cand)
        if lock_files:
            self.warn(dim, "pid_lock_residue",
                      "发现 PID 锁残留文件: %s" % ", ".join(lock_files))
            issues.append("E2 PID 锁残留")
        else:
            self.ok(dim, "e2", "无 PID 锁残留")

    def _check_e3_workspace_lock(self, dim, issues):
        # E3: workspace 锁残留 (调度并存判定 SEE-1183 1b)
        # 锁是 advisory flock: 只要仍有存活进程持有 (另一 autopilot 正在运行),
        # 就属正常调度并存, 不是残留。仅 flock 空闲且无存活 PID 时才算残留。
        # release() 修复后 (SEE-1234) 稳态是"空文件 + flock 空闲": 无 PID 文本
        # 说明锁已释放且无人写过, 视为无残留, 不告警。
        if os.path.exists(WORKSPACE_LOCK):
            holder_pid, live = _lock_holder(WORKSPACE_LOCK)
            if live:
                self.ok(dim, "e3",
                        "workspace 锁由存活进程持有 (PID %s), 属调度并存, 非残留" % holder_pid)
            elif holder_pid is None:
                self.ok(dim, "e3", "workspace 锁文件为空 (已释放态), 无残留")
            else:
                self.warn(dim, "workspace_lock_residue",
                          "workspace 锁残留 (无存活持有者): %s" % WORKSPACE_LOCK)
                issues.append("E3 workspace 锁残留")
        else:
            self.ok(dim, "e3", "无 workspace 锁残留")

    def _check_e4_autopilot_scripts(self, dim):
        # E4: autopilot 目录内脚本完整性 (run/run_ok 辅助) — SEE-1430 后脚本真源在 dev-forge autopilots/
        autopilot_dir = os.path.join(DEV_FORGE_ROOT, "autopilots")
        scripts = []
        if os.path.isdir(autopilot_dir):
            scripts = sorted(n for n in os.listdir(autopilot_dir) if n.endswith(".py"))
        if scripts:
            self.ok(dim, "e4", "autopilot 脚本 %d 个: %s" % (len(scripts), ", ".join(scripts[:6])))
        else:
            self.missing_input(autopilot_dir, dim, "autopilots 目录缺失")

    def dim_e(self):
        dim = "E"
        issues = []
        self._check_e1_watchdog_restarts(dim, issues)
        self._check_e2_pid_lock_residue(dim, issues)
        self._check_e3_workspace_lock(dim, issues)
        self._check_e4_autopilot_scripts(dim)

        status = "warn" if issues else "ok"
        self.section(dim, status, issues)

    # -- F launch 脚本健康 ----------------------------------------------------------

    def _check_f1_start_sh_hardcode(self, dim, issues):
        # F1: toolchain-start.sh 硬编码路径（SEE-1430 后位于 dev-forge launch/）
        start_sh = START_SH_REL if os.path.isabs(START_SH_REL) else os.path.join(self.root, START_SH_REL)
        text = safe_read(start_sh)
        if text:
            hardcoded = []
            for line in text.splitlines():
                if re.search(r"/mnt/[a-z]/\S+", line):
                    hardcoded.append(line.strip())
            if hardcoded:
                # 已知接受的 Plan 2 tradeoff — 仅当路径指向不存在的目录时才告警
                target = "/mnt/d/GodotProjects/king-of-likes"
                if not os.path.isdir(target):
                    issues.append("F1 toolchain-start.sh 硬编码路径指向不存在目录: %s" % target)
                    self.warn(dim, "start_sh_hardcoded_missing",
                              "硬编码路径缺失: %s" % target)
                else:
                    self.ok(dim, "f1", "启动脚本硬编码路径存在 (%d 处硬编码, Plan 2 已知 tradeoff)" % len(hardcoded))
            else:
                self.ok(dim, "f1", "启动脚本无硬编码路径")
        else:
            self.missing_input(start_sh, dim, "启动脚本缺失")

    def _check_f2_systemd_unit(self, dim, issues):
        # F2: systemd unit 与 start 脚本一致性（SEE-1430 后 unit 在 dev-forge launch/systemd/）
        unit_path = os.path.join(SYSTEMD_DIR_REL, "toolchain-start-all.service")
        unit_text = safe_read(unit_path)
        if unit_text:
            exec_line = [l for l in unit_text.splitlines()
                         if l.strip().startswith("ExecStart=")]
            if exec_line and "toolchain-start.sh" not in exec_line[0]:
                issues.append("F2 systemd ExecStart 未指向 toolchain-start.sh: %s" % exec_line[0])
            restart_line = [l for l in unit_text.splitlines()
                            if l.strip().startswith("Restart=")]
            if restart_line and "always" not in restart_line[0].lower():
                issues.append("F2 systemd Restart= 非 always (%s)" % restart_line[0])
            self.ok(dim, "f2", "systemd unit 存在, ExecStart=%s" % (exec_line[0].strip() if exec_line else "?"))
        else:
            self.missing_input(unit_path, dim, "systemd unit 缺失")

    def dim_f(self):
        dim = "F"
        issues = []
        self._check_f1_start_sh_hardcode(dim, issues)
        self._check_f2_systemd_unit(dim, issues)

        # F3/F4 (SEE-1440 / fingerprint 2a3c667e2c9a)：注册制 repos.d 单源巡检 —
        #   每个注册的 repo_sync_daemon 必须存活（pid_file 指向的进程存在）；
        #   服务检出 branch 必须等于注册 branch，且 HEAD == origin/<branch>。
        # 旧 F3 读 KOL .dev/repo-sync/repo_sync_config.json，迁移后该路径已不存在。
        self._check_registrations(dim, issues)

        # F5 (SEE-1440 / fingerprint ba5ed5893ad9)：Kill Switch 单源一致性。
        self._check_kill_switch_single_source(dim, issues)

        status = "warn" if issues else "ok"
        self.section(dim, status, issues)

    def _check_registrations(self, dim, issues):
        """F3 daemon 存活 + F4 服务检出==注册分支（只读）。"""
        repos_d = os.path.join(self.root, "repo-sync", "repos.d")
        regs = []
        if os.path.isdir(repos_d):
            for name in sorted(os.listdir(repos_d)):
                if not name.endswith(".json"):
                    continue
                cfg = read_json(os.path.join(repos_d, name))
                if isinstance(cfg, dict) and cfg.get("repo_path") and cfg.get("branch"):
                    regs.append((name, cfg))
        if not regs:
            self.missing_input(repos_d, dim, "repo-sync 注册目录缺失/空")
        for name, cfg in regs:
            label = cfg.get("name") or os.path.splitext(name)[0]
            self._check_registration_daemon(dim, issues, label, cfg)
            self._check_registration_checkout(dim, issues, label, cfg)

    def _check_registration_daemon(self, dim, issues, label, cfg):
        pid_file = cfg.get("pid_file")
        if not pid_file:
            issues.append("F3 %s 注册未声明 pid_file" % label)
            self.warn(dim, "daemon_pid_file", "%s 注册未声明 pid_file" % label)
            return
        pid_path = os.path.expanduser(str(pid_file).replace("$HOME", HOME))
        pid_text = safe_read(pid_path)
        if not pid_text:
            issues.append("F3 %s daemon pid 文件缺失: %s" % (label, pid_path))
            self.warn(dim, "daemon_pid_missing",
                      "%s daemon 未运行（pid 文件缺失: %s）" % (label, pid_path))
            return
        try:
            pid = int(pid_text.strip())
        except ValueError:
            issues.append("F3 %s pid 文件内容非法: %r" % (label, pid_text.strip()))
            self.warn(dim, "daemon_pid_invalid",
                      "%s pid 文件内容非法: %r" % (label, pid_text.strip()))
            return
        if pid_alive(pid):
            self.ok(dim, "f3", "%s daemon 存活 (pid=%d)" % (label, pid))
        else:
            issues.append("F3 %s daemon PID %d 不存在" % (label, pid))
            self.warn(dim, "daemon_dead",
                      "%s daemon PID %d 不存在（进程已退出/未启动）" % (label, pid))

    def _check_registration_checkout(self, dim, issues, label, cfg):
        repo_path = cfg["repo_path"]
        branch = cfg["branch"]
        cur = git_out(repo_path, ["branch", "--show-current"])
        head = git_out(repo_path, ["rev-parse", "HEAD"])
        remote_ref = "origin/%s" % branch
        remote = git_out(repo_path, ["rev-parse", remote_ref])
        if not cur or not head:
            issues.append("F4 %s 服务检出不可读: %s" % (label, repo_path))
            self.warn(dim, "checkout_unreadable", "%s 服务检出不可读: %s" % (label, repo_path))
        elif cur != branch:
            issues.append("F4 %s 服务检出在 %s, 注册分支 %s" % (label, cur, branch))
            self.warn(dim, "checkout_branch_drift",
                      "%s 服务检出 branch=%s != 注册 branch=%s" % (label, cur, branch))
        elif not remote:
            issues.append("F4 %s 缺少 %s 引用" % (label, remote_ref))
            self.warn(dim, "checkout_remote_ref_missing",
                      "%s 缺少 %s 引用（无法核对 HEAD）" % (label, remote_ref))
        elif head != remote:
            issues.append("F4 %s HEAD(%s) != %s(%s)"
                          % (label, head[:8], remote_ref, remote[:8]))
            self.warn(dim, "checkout_head_drift",
                      "%s HEAD(%s) != %s(%s)，服务检出未跟随远端"
                      % (label, head[:8], remote_ref, remote[:8]))
        else:
            self.ok(dim, "f4", "%s 服务检出与 %s 一致 (%s)" % (label, remote_ref, head[:8]))

    def _check_kill_switch_single_source(self, dim, issues):
        """F5：规范 paused 文件为单一入口；历史别名仅告警提示收敛。"""
        canonical_paused = os.path.join(REPORT_ROOT, "DISABLED")
        legacy_paused = os.path.join(self.root, "review-prompts", "toolchain", "ledger", "DISABLED")
        active = [p for p in (canonical_paused, legacy_paused) if os.path.exists(p)]
        if not active:
            self.ok(dim, "f5", "Kill Switch 未激活（单源 %s 不存在）" % canonical_paused)
            return
        self.info(dim, "kill_switch_active",
                  "Kill Switch 激活: %s（autopilots 与评审拼装器共用单源）" % ", ".join(active))
        if os.path.exists(legacy_paused) and not os.path.exists(canonical_paused):
            issues.append("F5 Kill Switch 使用历史路径 %s" % legacy_paused)
            self.warn(dim, "kill_switch_legacy_path",
                      "paused 文件位于历史别名，建议统一到 %s" % canonical_paused)

    # -- G 错误度量口径 (cross-cutting) -------------------------------------------

    def _g_registry_inventory(self, entries):
        registered_ports = set()
        per_agent = defaultdict(Counter)
        for label, entry in entries.items():
            p = entry.get("port")
            agent = entry.get("agent") or label
            if isinstance(p, int):
                registered_ports.add(p)
            per_agent[agent]["registered"] += 1
        return registered_ports, per_agent

    def _g_active_leases(self):
        # 活跃 lease (双源并集的一源)
        sidecars = self.load_sidecars()
        active_ports = set()
        for s in sidecars:
            if s.get("state") == "active" and isinstance(s.get("port"), int):
                active_ports.add(s["port"])
        return active_ports

    def _g_launcher_log_labels(self):
        # SEE-1458 §SPEC-103: label 采集覆盖双目录并集 (原只扫 ~/.multica)
        return {label for label, _logs_dir, _path in launcher_log_sources()}

    def _check_g1_log_completeness(self, dim, registered_ports, active_ports, per_agent, issues):
        # G1: 日志完整性 — 应采 vs 实采: 注册端口 ∪ 活跃 lease 均应被 launcher 日志覆盖
        launcher_labels = self._g_launcher_log_labels()
        expected = {"port-%d" % p for p in registered_ports}
        expected.update("port-%d" % p for p in active_ports)
        expected.update(agent.lower() for agent in per_agent)
        missing_logs = expected - launcher_labels
        if missing_logs:
            self.warn(dim, "log_completeness",
                      "应采 %d 个日志源, 实采 %d; 缺失 %s"
                      % (len(expected), len(launcher_labels), sorted(missing_logs)[:8]))
            issues.append("G1 日志源缺失 %d 个" % len(missing_logs))
        else:
            self.ok(dim, "g1", "日志完整性 OK (应采 %d, 实采 %d)" % (len(expected), len(launcher_labels)))

    def _check_g_drift(self, dim):
        # SEE-1458 §SPEC-104 漂移哨兵: 规范目录 (~/.multica) 之外存在当日 launcher
        # 活动 = 状态写入漂出规范目录 (GODOT_MCP_HOME 钉扎失效的指纹, SEE-1457
        # 曾因此 4 天漏报), 显式标记而非静默 ok。「当日」沿用行首时间戳口径
        # (LAUNCHER_LOG_LINE_TS), 与失败码当日窗口同源。
        today_str = datetime.now(timezone.utc).date().isoformat()
        drift_labels = []
        for label, logs_dir, path in launcher_log_sources():
            if logs_dir == MULTICA_HOME:
                continue
            text = safe_read(path, max_bytes=20_000_000)
            if not text:
                continue
            for line in text.splitlines():
                m = LAUNCHER_LOG_LINE_TS.match(line)
                if m and m.group(1) == today_str:
                    drift_labels.append(label)
                    break
        if drift_labels:
            self.warn(dim, "g_drift_detected",
                      "中性目录存在当日 launcher 活动 %d 个源 (%s) — 状态目录漂移, "
                      "GODOT_MCP_HOME 钉扎失效?"
                      % (len(drift_labels), ", ".join(sorted(drift_labels)[:8])))
        else:
            self.ok(dim, "g_drift", "无规范目录之外的当日 launcher 活动")

    def _check_g3_daily_delta(self, dim, failure_attr, issues):
        # G3: 与昨日 delta — 读 history.json 昨日当日窗口计数
        # (经 journal 自愈读取路径, SEE-1449: history 被整体覆盖丢日时可恢复)
        history, recovered_days = load_history_with_recovery(HISTORY_FILE)
        if recovered_days:
            self.info(dim, "history_recovered",
                      "history 缺失 %d 天已由 journal 恢复: %s"
                      % (len(recovered_days), ", ".join(sorted(recovered_days))))
        previous = {}
        if isinstance(history, dict):
            prev_total = history.get("failures", {})
            if isinstance(prev_total, dict):
                previous = prev_total
        today = Counter()
        for label, codes in failure_attr.items():
            for code, n in codes.items():
                today[code] += n
        # 旧口径迁移哨兵: previous 任何一项大于今日全码总和 → 是旧累计值, 本轮跳过告警
        if previous and previous.get("timeout", 0) + previous.get("error", 0) + \
                previous.get("denied", 0) + previous.get("editor_busy", 0) + \
                previous.get("another_client", 0) > max(sum(today.values()), 0) + 1:
            self.ok(dim, "g3", "history 为旧累计口径, 本轮跳过日增比对 (下轮起正常)")
        else:
            suspicious, deltas = self._g3_suspicious_deltas(today, previous)
            if suspicious:
                self.warn(dim, "threshold_daily",
                          "失败码日增越界: %s (日增>=%d 且昨日基数>=1)"
                          % (", ".join("%s+%d" % (c, deltas[c]) for c in suspicious),
                             DAILY_INCREMENT_MIN))
                issues.append("G3 日增越界: %s" % suspicious)
        return history, today

    @staticmethod
    def _g3_suspicious_deltas(today, previous):
        """日增越界码: 日增 >= DAILY_INCREMENT_MIN, 昨日基数 >=1 且 <= 今日值。

        today 与 previous 同为"当日窗口"口径 (SEE-1234 修复后)。首次以新口径运行时
        history 里仍是旧累计值, 会算出巨大 delta — 全局旧口径哨兵在调用方
        (_check_g3_daily_delta) 先行拦截; 这里的「昨日 <= 今日」条件再滤掉单码尺度上
        昨日偏高造成的负 delta 残留。
        """
        deltas = {}
        for code in today:
            prev = previous.get(code, 0)
            d = today[code] - prev
            if d > 0:
                deltas[code] = d
        suspicious = [code for code, d in deltas.items()
                      if previous.get(code, 0) >= 1 and previous.get(code, 0) <= today[code]
                      and d >= DAILY_INCREMENT_MIN]
        return suspicious, deltas

    @staticmethod
    def _g_daily_series(history):
        """G5 σ 输入序列 + 被跳过的旧累计口径日列表。

        daily 键 <= DAILY_WINDOW_EPOCH_LAST_LEGACY (2026-09-04, SEE-1234 口径
        切换落地当日) 的是旧累计口径日, 确定性排除 — 巨大累计值混入会把
        mean+2σ 抬高约 22 倍造成假阴性 (SEE-1448), 不依赖 30 天窗口自然淘汰。
        """
        series = defaultdict(list)
        skipped = []
        if isinstance(history, dict):
            daily = history.get("daily", {})
            if isinstance(daily, dict):
                for day, codes in daily.items():
                    dt = parse_iso(day)
                    if dt and isinstance(codes, dict):
                        if dt.date().isoformat() <= DAILY_WINDOW_EPOCH_LAST_LEGACY:
                            skipped.append(day)
                            continue
                        for code, n in codes.items():
                            series[code].append(n)
        return series, skipped

    def _check_g4_weekly(self, dim, history):
        # G4: 周累计 >=3 (用 history 近7天累加, 不含今日 — 今日已在 today 计数里)
        weekly = Counter()
        if isinstance(history, dict):
            daily = history.get("daily", {})
            if isinstance(daily, dict):
                cutoff = datetime.now(timezone.utc) - timedelta(days=7)
                today_date = datetime.now(timezone.utc).date()
                for day, codes in daily.items():
                    dt = parse_iso(day)
                    if (dt and dt >= cutoff and dt.date() != today_date
                            and isinstance(codes, dict)):
                        for code, n in codes.items():
                            weekly[code] += n
        weekly_bad = [code for code, n in weekly.items() if n >= WEEKLY_CUMULATIVE_MIN]
        if weekly_bad:
            # SEE-1440 / ae4dac961ce9 裁决：周累计随整点 trigger 钉扎放大，错峰属
            # 平台侧编排（仓内 autopilots/configs 无 cron 定义）——降 info 保留观测。
            self.info(dim, "threshold_weekly",
                      "周累计越界: %s (>=%d)；接受理由：错峰整改在平台侧调度，仓库侧不可控"
                      % (", ".join(weekly_bad), WEEKLY_CUMULATIVE_MIN))

    def _check_g5_sigma(self, dim, history, today, issues):
        # G5: 2σ 越界 — 用 history.daily 的过去值序列判断今日异常
        # 口径守卫 (SEE-1449): σ 序列只含新当日窗口口径日 (> DAILY_WINDOW_EPOCH_LAST_LEGACY);
        # 旧累计口径日被 _g_daily_series 确定性跳过, 跳过天数以 info 观测。守卫与
        # 30 天窗口自然淘汰互相独立: 旧键淘汰完 (约 2026-10-27) 后跳过集为空、
        # 守卫退化为 no-op, 但排除语义不依赖淘汰进度, 口径切换类污染不再复发。
        series, skipped = self._g_daily_series(history)
        if skipped:
            self.info(dim, "g5_legacy_window_skipped",
                      "σ 序列跳过 %d 个旧累计口径日 (<=%s): %s"
                      % (len(skipped), DAILY_WINDOW_EPOCH_LAST_LEGACY,
                         ", ".join(sorted(skipped))))
        sigma_bad = []
        for code, n in today.items():
            vals = series.get(code, [])
            if len(vals) >= 5:
                mean = sum(vals) / len(vals)
                var = sum((v - mean) ** 2 for v in vals) / len(vals)
                sigma = var ** 0.5
                if sigma > 0 and n > mean + SIGMA_MULTIPLIER * sigma:
                    sigma_bad.append("%s(%d>%.1f+2σ)" % (code, n, mean))
        if sigma_bad:
            self.fail(dim, "sigma_overflow",
                      "2σ 越界: %s" % ", ".join(sigma_bad))
            issues.append("G5 2σ 越界: %s" % sigma_bad)
        else:
            self.ok(dim, "g5", "无 2σ 越界")
        return sigma_bad

    @staticmethod
    def _g_pinned_triggers_for(aid):
        tl = subprocess.run(
            ["multica", "autopilot", "trigger-list", aid, "--output", "json"],
            capture_output=True, text=True, timeout=10,
        )
        if tl.returncode != 0 or not tl.stdout:
            return []
        pinned = []
        for t in json.loads(tl.stdout).get("triggers", []):
            if t.get("kind") != "schedule" or not t.get("enabled"):
                continue
            cron = (t.get("cron_expression") or "").strip()
            # Strip optional `TZ=... ` prefix
            cron_body = cron.split(None, 1)[1] if cron.startswith("TZ=") else cron
            fields = cron_body.split()
            if fields and fields[0] == "0":
                pinned.append("%s(%s)" % (aid[:8], cron_body))
        return pinned

    def _check_g6_integer_pinned(self, dim):
        # G6: autopilot 整点碰撞检测 (SEE-1224 #6) — 只读调用 `multica autopilot
        # trigger-list`, 汇总所有 schedule trigger 的 cron, 凡是分钟字段钉在 `0`
        # 的视为整点钉扎, 是 workspace 锁自撞 / launcher timeout 噪声的来源之一
        # (systemd RandomizedDelaySec / K8s CronJob 惯例都避整点)。脚本 HARD
        # SAFETY 仍保持: 单次只读 CLI, 失败/缺失仅 warn, 不升级 redline。
        integer_pinned = []
        trigger_scan_note = ""
        try:
            ap = subprocess.run(
                ["multica", "autopilot", "list", "--output", "json"],
                capture_output=True, text=True, timeout=10,
            )
            if ap.returncode == 0 and ap.stdout:
                autopilots = json.loads(ap.stdout).get("autopilots", [])
                for a in autopilots:
                    aid = a.get("id", "")
                    if not aid:
                        continue
                    integer_pinned.extend(self._g_pinned_triggers_for(aid))
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            trigger_scan_note = "trigger-list scan failed: %s" % e

        if trigger_scan_note:
            self.warn(dim, "trigger_scan", trigger_scan_note)
        elif integer_pinned:
            # SEE-1440 / ae4dac961ce9 裁决：trigger 由 multica 平台侧管理（仓内无
            # cron 定义、无法错峰），降 info 并注明接受理由，避免恒真 warn 稀释信号。
            self.info(dim, "integer_pinned_triggers",
                      "整点钉扎 trigger %d 个: %s；接受理由：autopilot schedule 属平台侧编排，"
                      "仓内不可控，错峰动作归平台运维"
                      % (len(integer_pinned), ", ".join(integer_pinned[:10])))
        else:
            self.ok(dim, "g6", "无整点钉扎 trigger")

    def dim_g(self, failure_daily):
        dim = "G"
        issues = []
        registry = self.load_registry()
        entries = registry.get("entries", {}) if isinstance(registry, dict) else {}
        registered_ports, per_agent = self._g_registry_inventory(entries)
        active_ports = self._g_active_leases()
        self._check_g1_log_completeness(dim, registered_ports, active_ports, per_agent, issues)
        self._check_g_drift(dim)

        # G2: 失败码归属 (复用 B3 的当日窗口扫描结果, 归到 port/agent)
        self.ok(dim, "g2", "当日失败码归属 %d 个源" % len(failure_daily))

        history, today = self._check_g3_daily_delta(dim, failure_daily, issues)
        self._check_g4_weekly(dim, history)
        sigma_bad = self._check_g5_sigma(dim, history, today, issues)
        self._check_g6_integer_pinned(dim)

        status = REDLINE if sigma_bad else ("warn" if issues else "ok")
        self.section(dim, status, issues)
        return {"today": dict(today), "per_label": {
            l: dict(c) for l, c in failure_daily.items()
        }, "window": "daily"}

    # -- 汇总与输出 ---------------------------------------------------------------

    def build_report(self, g_payload):
        now = now_iso()
        redline_count = len(self.redlines)
        dims = {}
        for dim, summary in self.dim_summary.items():
            dims[dim] = summary
        report = {
            "schema_version": 1,
            "generated_at": now,
            "script": os.path.basename(__file__),
            "repo": self.root,
            "health": REDLINE if redline_count else GREEN,
            "redline_count": redline_count,
            "redlines": self.redlines,
            "input_missing": self.input_missing,
            "dimensions": dims,
            "findings": self.findings,
            "failures": g_payload["today"],
            "failures_per_label": g_payload["per_label"],
            "failures_window": g_payload.get("window", "unknown"),
        }
        draft = self.draft_issue(report)
        if draft:
            report["draft_issue"] = draft
        return report

    def persist(self, report):
        """只写本地报告目录 (默认 ~/.multica/toolchain-reports/), 绝不写共享树。"""
        report_root = self.report_dir
        report_file = os.path.join(report_root, "latest.json")
        history_file = os.path.join(report_root, "history.json")
        os.makedirs(report_root, exist_ok=True)
        tmp_fd, tmp_path = tempfile.mkstemp(dir=report_root, prefix=".report-", suffix=".tmp")
        try:
            with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
                json.dump(report, f, ensure_ascii=False, indent=2, default=str)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, report_file)
        except OSError:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

        # history 追加 (滑动窗口); 经 journal 自愈读取 (SEE-1449), 被外部整体
        # 覆盖丢掉的日随本轮 persist 物理写回 history.json。
        history, _recovered = load_history_with_recovery(history_file)
        daily = history.get("daily")
        if not isinstance(daily, dict):
            daily = {}
        day_key = report["generated_at"][:10]
        daily[day_key] = report["failures"]
        evict_daily(daily)
        history["daily"] = daily
        history["failures"] = report["failures"]
        history["updated_at"] = report["generated_at"]
        # journal 先于 history.json 落盘: 两写之间崩溃时, journal 保有当日键,
        # 下轮读取路径可恢复 (append-only, 只写 report_dir)
        journal_file = journal_path_for(history_file)
        try:
            journal_append(journal_file, day_key, report["failures"],
                           report["generated_at"])
            journal_compact(journal_file)
        except OSError as exc:
            # journal 是 resilience 通道, 失败不阻断主报告落盘, 但必须显式可闻
            sys.stderr.write("[toolchain] history journal write failed (%s): %s\n"
                             % (journal_file, exc))
        tmp_fd2, tmp_path2 = tempfile.mkstemp(dir=report_root, prefix=".history-", suffix=".tmp")
        try:
            with os.fdopen(tmp_fd2, "w", encoding="utf-8") as f:
                json.dump(history, f, ensure_ascii=False, indent=2, default=str)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path2, history_file)
        except OSError:
            try:
                os.unlink(tmp_path2)
            except OSError:
                pass
            raise

    def render_text(self, report):
        lines = []
        lines.append("=" * 60)
        lines.append("toolchain_daily_check  %s  health=%s" % (
            report["generated_at"], report["health"]))
        lines.append("=" * 60)
        lines.append("报告目录: %s" % self.report_dir)
        for dim, summary in sorted(report["dimensions"].items()):
            lines.append("[%s] %s" % (dim, summary.get("status", "?")))
            for detail in summary.get("details", []):
                lines.append("    - %s" % detail)
        if report["redlines"]:
            lines.append("")
            lines.append("REDLINES:")
            for r in report["redlines"]:
                lines.append("  [%s] %s: %s" % (r["dim"], r["code"], r["message"]))
        if report["failures"]:
            lines.append("")
            lines.append("失败码计数 (今日): %s" % json.dumps(report["failures"], ensure_ascii=False))
        lines.append("")
        lines.append("报告文件: %s" % os.path.join(self.report_dir, "latest.json"))
        return "\n".join(lines)

    def draft_issue(self, report):
        """红线 → 草拟 issue 提案文本 (不自动 @, 不自动指派)。"""
        if not report["redlines"]:
            return None
        body = ["## 工具链日检红线 (自动草稿, 未经人工确认)",
                "",
                "生成时间: %s" % report["generated_at"],
                "",
                "来源: `%s`" % __file__,
                "",
                "### 红线明细"]
        for i, r in enumerate(report["redlines"], 1):
            body.append("%d. **[%s] %s**: %s" % (i, r["dim"], r["code"], r["message"]))
        body += ["",
                 "### 处理建议",
                 "- 由工具链负责人确认根因后再创建正式 issue",
                 "- 不要直接 @ 或指派 — 人工分流",
                 ""]
        return "\n".join(body)


# --- 主入口 ---------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="工具链日检 (只读)")
    parser.add_argument("--no-net", action="store_true",
                        help="跳过 tcp 端口探测 (纯静态)")
    parser.add_argument("--json", action="store_true",
                        help="stdout 输出 JSON (供 1b autopilot 复用)")
    parser.add_argument("--report-dir", default=REPORT_ROOT,
                        help="报告输出目录 (默认 %s)" % REPORT_ROOT)
    parser.add_argument("--backfill-failures", default=None, metavar="YYYY-MM-DD[,..]",
                        help="tested 基线回填 (SEE-1458 §SPEC-105): 重扫双目录并集重算"
                             "指定日失败码并写回 history.json, 写前自动备份; "
                             "与日检主流程互斥, 只回填不巡检")
    args = parser.parse_args()

    if args.backfill_failures:
        return _run_backfill(args.backfill_failures, args.report_dir)

    check = DailyCheck(args)
    check.dim_a()
    failure_daily = check.dim_b()
    check.dim_c()
    check.dim_e()
    check.dim_f()
    g_payload = check.dim_g(failure_daily)

    report = check.build_report(g_payload)
    try:
        check.persist(report)
    except OSError as exc:
        sys.stderr.write("无法写报告目录 %s: %s\n" % (REPORT_ROOT, exc))
        return 1

    # GREEN heartbeat (防 SEE-1109 静默失败): 即使 0 红线也输出明确心跳。
    # JSON 模式心跳走 stderr, 保证 stdout 是纯 JSON 供 1b autopilot 解析;
    # 红线草稿在两种模式下都可得: 文本模式打印, JSON 模式进 report["draft_issue"]。
    heartbeat = "HEARTBEAT: health=%s redlines=%d generated=%s" % (
        report["health"], report["redline_count"], report["generated_at"])
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2, default=str))
        sys.stderr.write(heartbeat + "\n")
    else:
        print(check.render_text(report))
        if report.get("draft_issue"):
            print("\n--- 红线 → issue 草稿 (未提交) ---\n%s" % report["draft_issue"])
        print(heartbeat)

    return 0 if report["health"] == GREEN else 2


if __name__ == "__main__":
    sys.exit(main())
