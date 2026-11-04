import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

export interface ExecResult {
  ok: boolean;
  stdout: string;
  stderr: string;
}

export type RepoSyncExec = (cmd: string, args: string[], timeoutMs: number) => Promise<ExecResult>;

export interface RepoSyncDeps {
  devforge: string;
  exec: RepoSyncExec;
}

type Action = 'start' | 'stop' | 'restart';
type ActionResult = { ok: boolean; output: string };
type Registration = Record<string, unknown>;
type PidState = { pid: number; matches: boolean };

const START_COMMAND = 'nohup python3 "$1" --config "$2" >>"$3" 2>&1 &';
const VALID_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const POLL_INTERVAL_MS = 100;
const START_ATTEMPTS = 20;
const STOP_ATTEMPTS = 50;

function resultOutput(result: ExecResult): string {
  return `${result.stdout}${result.stderr}`.trim().slice(0, 400);
}

function delay(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
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

async function matchesDaemon(pid: number, cfgPath: string, exec: RepoSyncExec): Promise<boolean> {
  const proc = await exec('cat', [`/proc/${pid}/cmdline`], 3000);
  if (!proc.ok) return false;
  const args = proc.stdout.split('\0');
  const scriptIndex = args.findIndex((arg) => arg === 'repo_sync_daemon.py' || arg.endsWith('/repo_sync_daemon.py'));
  return scriptIndex >= 0 && args[scriptIndex + 1] === '--config' && args[scriptIndex + 2] === cfgPath;
}

async function inspectPid(cfg: Registration, cfgPath: string, exec: RepoSyncExec): Promise<PidState> {
  const pid = await readPid(cfg, exec);
  return { pid, matches: pid > 0 && (await matchesDaemon(pid, cfgPath, exec)) };
}

async function waitForDaemon(cfg: Registration, cfgPath: string, exec: RepoSyncExec, present: boolean, attempts: number): Promise<boolean> {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const state = await inspectPid(cfg, cfgPath, exec);
    if (state.matches === present) return true;
    if (attempt + 1 < attempts) await delay();
  }
  return false;
}

async function stopOne(cfg: Registration, cfgPath: string, exec: RepoSyncExec): Promise<ActionResult> {
  const state = await inspectPid(cfg, cfgPath, exec);
  if (state.pid <= 0) return { ok: true, output: 'repo-sync 未运行（pid_file 无存活记录）' };
  if (!state.matches) return { ok: false, output: `pid ${state.pid} 身份不匹配，拒绝发送 SIGTERM` };
  const stopped = await exec('kill', ['-TERM', String(state.pid)], 5000);
  return stopped.ok
    ? { ok: true, output: `kill TERM ${state.pid}` }
    : { ok: false, output: `kill TERM ${state.pid} 失败：${resultOutput(stopped)}` };
}

async function startOne(name: string, cfgPath: string, cfg: Registration, deps: RepoSyncDeps): Promise<ActionResult> {
  if ((await inspectPid(cfg, cfgPath, deps.exec)).matches) return { ok: true, output: `repo-sync-${name} 已在运行` };

  const logDir = configPathValue(cfg, 'log_dir');
  if (!logDir) return { ok: false, output: `repo-sync-${name} 缺少有效 log_dir，拒绝启动` };
  const made = await deps.exec('mkdir', ['-p', logDir], 5000);
  if (!made.ok) return { ok: false, output: `创建日志目录失败：${resultOutput(made)}` };

  const script = join(deps.devforge, 'repo-sync', 'repo_sync_daemon.py');
  const logFile = join(logDir, 'repo-sync-daemon.log');
  const run = await deps.exec('bash', ['-lc', START_COMMAND, 'repo-sync-start', script, cfgPath, logFile], 5000);
  if (!run.ok) return { ok: false, output: resultOutput(run) };

  const started = await waitForDaemon(cfg, cfgPath, deps.exec, true, START_ATTEMPTS);
  return started
    ? { ok: true, output: `nohup 启动 repo-sync-${name}；日志 ${logFile}` }
    : { ok: false, output: `启动后未检测到匹配 pid/daemon（2 秒）；请检查 ${logFile}` };
}

export function createRepoSyncAction(deps: RepoSyncDeps): (name: string, action: Action) => Promise<ActionResult> {
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
    if (action === 'stop') return stopOne(cfg, cfgPath, deps.exec);
    if (action === 'start') return startOne(name, cfgPath, cfg, deps);

    const stopped = await stopOne(cfg, cfgPath, deps.exec);
    if (!stopped.ok) return stopped;
    const exited = await waitForDaemon(cfg, cfgPath, deps.exec, false, STOP_ATTEMPTS);
    if (!exited) return { ok: false, output: `${stopped.output}; 旧进程未在 5 秒内退出，取消拉起` };
    const started = await startOne(name, cfgPath, cfg, deps);
    return { ok: started.ok, output: `${stopped.output}; ${started.output}` };
  };
}
