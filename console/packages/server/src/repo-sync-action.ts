import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { matchesRepoSyncDaemonCmdline } from '@forge/collectors';

export interface ExecResult {
  ok: boolean;
  stdout: string;
  stderr: string;
}

export type RepoSyncExec = (cmd: string, args: string[], timeoutMs: number) => Promise<ExecResult>;

export interface RepoSyncDeps {
  devforge: string;
  exec: RepoSyncExec;
  startTimeoutMs?: number;
  stopTimeoutMs?: number;
  pollIntervalMs?: number;
}

type Action = 'start' | 'stop' | 'restart';
type ActionResult = { ok: boolean; output: string };
type Registration = Record<string, unknown>;
type PidStatus = 'missing' | 'stale' | 'mismatch' | 'running';
type PidState = { pid: number; status: PidStatus };
type Timing = { startTimeoutMs: number; stopTimeoutMs: number; pollIntervalMs: number };

const START_COMMAND = 'mkdir -p "$3" && { nohup python3 "$1" --config "$2" >>"$4" 2>&1 & }';
const VALID_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
export const DEFAULT_START_TIMEOUT_MS = 10_000;
export const DEFAULT_STOP_TIMEOUT_MS = 5_000;
const DEFAULT_POLL_INTERVAL_MS = 100;

function resultOutput(result: ExecResult): string {
  return `${result.stdout}${result.stderr}`.trim().slice(0, 400);
}

function positiveInt(value: number | undefined, fallback: number): number {
  return value !== undefined && Number.isFinite(value) && value > 0 ? Math.max(1, Math.floor(value)) : fallback;
}

function timingOf(deps: RepoSyncDeps): Timing {
  return {
    startTimeoutMs: positiveInt(deps.startTimeoutMs, DEFAULT_START_TIMEOUT_MS),
    stopTimeoutMs: positiveInt(deps.stopTimeoutMs, DEFAULT_STOP_TIMEOUT_MS),
    pollIntervalMs: positiveInt(deps.pollIntervalMs, DEFAULT_POLL_INTERVAL_MS),
  };
}

function attemptsFor(timeoutMs: number, pollIntervalMs: number): number {
  return Math.max(1, Math.ceil(timeoutMs / pollIntervalMs));
}

function formatDuration(ms: number): string {
  return ms % 1000 === 0 ? `${ms / 1000} 秒` : `${ms}ms`;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function readRegistration(cfgPath: string): Promise<Registration> {
  const parsed: unknown = JSON.parse(await readFile(cfgPath, 'utf8'));
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('registration must be a JSON object');
  }
  return parsed as Registration;
}

function configPathValue(cfg: Registration, key: 'pid_file' | 'log_dir'): string {
  const value = cfg[key];
  return typeof value === 'string' ? value.trim() : '';
}

async function readPid(cfg: Registration, exec: RepoSyncExec): Promise<number> {
  const pidFile = configPathValue(cfg, 'pid_file');
  if (!pidFile) return 0;
  const pidText = await exec('cat', [pidFile], 3000);
  if (!pidText.ok) return 0;
  const pid = Number(pidText.stdout.trim());
  return Number.isInteger(pid) && pid > 0 ? pid : 0;
}

async function inspectPid(cfg: Registration, cfgPath: string, exec: RepoSyncExec): Promise<PidState> {
  const pid = await readPid(cfg, exec);
  if (pid <= 0) return { pid: 0, status: 'missing' };
  const proc = await exec('cat', [`/proc/${pid}/cmdline`], 3000);
  if (!proc.ok) return { pid, status: 'stale' };
  const matches = matchesRepoSyncDaemonCmdline(proc.stdout, cfgPath);
  return { pid, status: matches ? 'running' : 'mismatch' };
}

async function waitForDaemon(cfg: Registration, cfgPath: string, exec: RepoSyncExec, present: boolean, attempts: number, pollMs: number): Promise<boolean> {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const state = await inspectPid(cfg, cfgPath, exec);
    if ((state.status === 'running') === present) return true;
    if (attempt + 1 < attempts) await delay(pollMs);
  }
  return false;
}

async function stopOne(cfg: Registration, cfgPath: string, exec: RepoSyncExec): Promise<ActionResult> {
  const state = await inspectPid(cfg, cfgPath, exec);
  if (state.status === 'missing') return { ok: true, output: 'repo-sync 未运行（pid_file 无存活记录）' };
  if (state.status === 'stale') return { ok: true, output: `repo-sync 未运行（stale pid ${state.pid}，进程不存在）` };
  if (state.status === 'mismatch') return { ok: false, output: `pid ${state.pid} 身份不匹配，拒绝发送 SIGTERM` };
  const stopped = await exec('kill', ['-TERM', String(state.pid)], 5000);
  return stopped.ok
    ? { ok: true, output: `kill TERM ${state.pid}` }
    : { ok: false, output: `kill TERM ${state.pid} 失败：${resultOutput(stopped)}` };
}

async function launchOne(name: string, cfgPath: string, cfg: Registration, deps: RepoSyncDeps, timing: Timing): Promise<ActionResult> {
  const logDir = configPathValue(cfg, 'log_dir');
  if (!logDir) return { ok: false, output: `repo-sync-${name} 缺少有效 log_dir，拒绝启动` };

  const script = join(deps.devforge, 'repo-sync', 'repo_sync_daemon.py');
  const logFile = join(logDir, 'repo-sync-daemon.log');
  const run = await deps.exec(
    'systemd-run',
    ['--user', '--property=Type=oneshot', '--property=KillMode=process', '--collect', '/bin/bash', '-c', START_COMMAND, 'repo-sync-start', script, cfgPath, logDir, logFile],
    15_000
  );
  if (!run.ok) return { ok: false, output: `${resultOutput(run)}；请检查 journalctl --user --since '-5 min'` };

  const attempts = attemptsFor(timing.startTimeoutMs, timing.pollIntervalMs);
  const started = await waitForDaemon(cfg, cfgPath, deps.exec, true, attempts, timing.pollIntervalMs);
  return started
    ? { ok: true, output: `nohup 启动 repo-sync-${name}；日志 ${logFile}` }
    : { ok: false, output: `启动后未检测到匹配 pid/daemon（等待 ${formatDuration(timing.startTimeoutMs)}）；请检查 ${logFile}` };
}

async function startOne(name: string, cfgPath: string, cfg: Registration, deps: RepoSyncDeps, timing: Timing): Promise<ActionResult> {
  if ((await inspectPid(cfg, cfgPath, deps.exec)).status === 'running') return { ok: true, output: `repo-sync-${name} 已在运行` };
  return launchOne(name, cfgPath, cfg, deps, timing);
}

export function createRepoSyncAction(deps: RepoSyncDeps): (name: string, action: Action) => Promise<ActionResult> {
  const timing = timingOf(deps);
  return async (name, action) => {
    if (!VALID_NAME.test(name)) return { ok: false, output: `非法 repo-sync 注册名：${name}` };
    const cfgPath = join(deps.devforge, 'repo-sync', 'repos.d', `${name}.json`);
    let cfg: Registration;
    try {
      cfg = await readRegistration(cfgPath);
    } catch (error) {
      console.error(`[repo-sync] 读取注册失败 ${cfgPath}: ${String(error).slice(0, 300)}`);
      return { ok: false, output: `读取注册失败 ${cfgPath}；请检查 JSON 与文件权限` };
    }

    // restart 也必须在 stop 前拒绝，避免停用注册被间接停止后重新拉起。
    if (cfg.enabled === false && action !== 'stop') {
      return { ok: false, output: `repo-sync-${name} 已手动停用（enabled=false），拒绝 ${action}` };
    }
    if (!configPathValue(cfg, 'pid_file')) {
      return { ok: false, output: `repo-sync-${name} 缺少有效 pid_file，拒绝 ${action}（零 exec）` };
    }
    if (action === 'stop') return stopOne(cfg, cfgPath, deps.exec);
    if (action === 'start') return startOne(name, cfgPath, cfg, deps, timing);

    const stopped = await stopOne(cfg, cfgPath, deps.exec);
    if (!stopped.ok) return stopped;
    const attempts = attemptsFor(timing.stopTimeoutMs, timing.pollIntervalMs);
    const exited = await waitForDaemon(cfg, cfgPath, deps.exec, false, attempts, timing.pollIntervalMs);
    if (!exited) return { ok: false, output: `${stopped.output}; 旧进程未在 ${formatDuration(timing.stopTimeoutMs)}内退出，取消拉起` };
    const started = await startOne(name, cfgPath, cfg, deps, timing);
    return { ok: started.ok, output: `${stopped.output}; ${started.output}` };
  };
}
