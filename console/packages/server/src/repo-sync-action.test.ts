import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createRepoSyncAction, type RepoSyncDeps, type RepoSyncExec } from './repo-sync-action.js';

interface Call {
  cmd: string;
  args: string[];
}

type Result = { ok: boolean; stdout: string; stderr: string };

const LAUNCHER = 'see1522-test-repo-sync-launcher';

function fakeExec(handle: (cmd: string, args: string[]) => Result | undefined): { exec: RepoSyncExec; calls: Call[] } {
  const calls: Call[] = [];
  const exec: RepoSyncExec = async (cmd, args) => {
    calls.push({ cmd, args });
    return handle(cmd, args) ?? { ok: true, stdout: '', stderr: '' };
  };
  return { exec, calls };
}

function cmdNames(calls: Call[]): string[] {
  return calls.map((c) => c.cmd);
}

describe('repo-sync action', () => {
  let root = '';
  let cfgPath = '';
  let pidFile = '';
  let daemonScript = '';
  let procCmdline = '';

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'see1522-repo-sync-'));
    cfgPath = join(root, 'repo-sync', 'repos.d', 'gqt.json');
    pidFile = join(root, 'gqt.pid');
    daemonScript = join(root, 'repo-sync', 'repo_sync_daemon.py');
    procCmdline = ['python3', daemonScript, '--config', cfgPath, ''].join('\0');
    await mkdir(join(root, 'repo-sync', 'repos.d'), { recursive: true });
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  async function registration(over: Record<string, unknown> = {}): Promise<void> {
    await writeFile(
      cfgPath,
      JSON.stringify({
        name: 'gqt',
        repo_path: '/sandbox/gqt',
        pid_file: pidFile,
        log_dir: join(root, 'repo-sync', 'logs'),
        ...over,
      })
    );
  }

  function action(exec: RepoSyncExec, over: Partial<RepoSyncDeps> = {}) {
    return createRepoSyncAction({
      devforge: root,
      exec,
      launchUnit: LAUNCHER,
      startTimeoutMs: 200,
      stopTimeoutMs: 200,
      pollIntervalMs: 10,
      ...over,
    });
  }

  function launcherCall(calls: Call[]): Call {
    const call = calls.find((c) => c.cmd === 'systemd-run');
    if (!call) throw new Error('systemd-run launcher call missing');
    return call;
  }

  it.each(['start', 'restart'] as const)('enabled=false 拒绝 %s，且零 exec 副作用', async (runAction) => {
    await registration({ enabled: false });
    const { exec, calls } = fakeExec(() => ({ ok: true, stdout: '', stderr: '' }));
    const result = await action(exec)('gqt', runAction);
    expect(result.ok).toBe(false);
    expect(result.output).toContain('enabled=false');
    expect(calls).toEqual([]);
  });

  it('enabled=false 仍允许 stop；核对 daemon 身份后按注册 pid 发 SIGTERM', async () => {
    await registration({ enabled: false });
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'kill') return { ok: true, stdout: '', stderr: '' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'stop');
    expect(result.ok).toBe(true);
    expect(result.output).toContain('kill TERM 4242');
    expect(calls).toEqual([
      { cmd: 'cat', args: [pidFile] },
      { cmd: 'cat', args: ['/proc/4242/cmdline'] },
      { cmd: 'kill', args: ['-TERM', '4242'] },
    ]);
  });

  it('stop 遇到 PID 复用/活进程身份不匹配时拒绝 kill', async () => {
    await registration();
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: ['sleep', '100', ''].join('\0'), stderr: '' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'stop');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('身份不匹配');
    expect(cmdNames(calls)).toEqual(['cat', 'cat']);
  });

  it('stale pid（文件在但进程不存在）按未运行处理，stop 不谎报也不 kill', async () => {
    await registration();
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: false, stdout: '', stderr: 'gone' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'stop');
    expect(result.ok).toBe(true);
    expect(result.output).toContain('stale');
    expect(result.output).toContain('未运行');
    expect(cmdNames(calls)).not.toContain('kill');
  });

  it('stale pid 的 restart 可直接恢复：无需 kill，随后通过 launcher 拉起', async () => {
    await registration();
    await writeFile(pidFile, '4242\n');
    let started = false;
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) {
        return started ? { ok: true, stdout: '5252\n', stderr: '' } : { ok: true, stdout: '4242\n', stderr: '' };
      }
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: false, stdout: '', stderr: 'gone' };
      if (cmd === 'cat' && args[0] === '/proc/5252/cmdline') {
        return { ok: true, stdout: ['python3', daemonScript, '--config', cfgPath, ''].join('\0'), stderr: '' };
      }
      if (cmd === 'systemd-run') {
        started = true;
        return { ok: true, stdout: '', stderr: '' };
      }
      return undefined;
    });
    const result = await action(exec)('gqt', 'restart');
    expect(result.ok).toBe(true);
    expect(cmdNames(calls)).not.toContain('kill');
    expect(cmdNames(calls)).toContain('systemd-run');
  });

  it.each(['start', 'stop', 'restart'] as const)('注册缺 pid_file 时 %s 零 exec 拒绝，避免失控 daemon', async (runAction) => {
    await registration({ pid_file: '' });
    const { exec, calls } = fakeExec(() => ({ ok: true, stdout: '', stderr: '' }));
    const result = await action(exec)('gqt', runAction);
    expect(result.ok).toBe(false);
    expect(result.output).toContain('pid_file');
    expect(calls).toEqual([]);
  });

  it('enabled start 经单一 shared launcher 越沙箱，daemon 仍走 nohup 并验证 pid 身份', async () => {
    await registration();
    let started = false;
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) {
        return started ? { ok: true, stdout: '4242\n', stderr: '' } : { ok: false, stdout: '', stderr: 'missing' };
      }
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'systemd-run') {
        started = true;
        return { ok: true, stdout: '', stderr: '' };
      }
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec, startTimeoutMs: 200, pollIntervalMs: 10 })('gqt', 'start');
    expect(result.ok).toBe(true);
    expect(cmdNames(calls)).toEqual(['cat', 'systemd-run', 'cat', 'cat']);
    expect(cmdNames(calls)).not.toContain('systemctl');
    const launch = launcherCall(calls);
    expect(launch.args.slice(0, 6)).toEqual([
      '--user',
      '--unit=forge-console-repo-sync-launcher',
      '--property=Type=oneshot',
      '--property=KillMode=process',
      '--collect',
      '/bin/bash',
    ]);
    expect(launch.args[7]).toContain('mkdir -p "$3" && nohup python3 "$1" --config "$2" >>"$4" 2>&1 &');
    expect(launch.args.slice(8)).toEqual(['repo-sync-start', daemonScript, cfgPath, join(root, 'repo-sync', 'logs'), join(root, 'repo-sync', 'logs', 'repo-sync-daemon.log')]);
    expect(launch.args.some((arg) => arg === '--unit=repo-sync-gqt')).toBe(false);
    expect(calls[3].args).toEqual(['/proc/4242/cmdline']);
  });

  it('enabled start 在注册 pid 属于同一 daemon 时幂等，不 mkdir / launcher / kill', async () => {
    await registration();
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'start');
    expect(result.ok).toBe(true);
    expect(cmdNames(calls)).toEqual(['cat', 'cat']);
    expect(result.output).toContain('已在运行');
  });

  it('enabled restart = SIGTERM、等待旧进程退出后经 launcher 重新 nohup 拉起', async () => {
    await registration();
    let alive = true;
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) {
        return alive ? { ok: true, stdout: '4242\n', stderr: '' } : { ok: false, stdout: '', stderr: 'missing' };
      }
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') {
        return alive ? { ok: true, stdout: procCmdline, stderr: '' } : { ok: false, stdout: '', stderr: 'gone' };
      }
      if (cmd === 'kill') {
        alive = false;
        return { ok: true, stdout: '', stderr: '' };
      }
      if (cmd === 'systemd-run') {
        alive = true;
        return { ok: true, stdout: '', stderr: '' };
      }
      return undefined;
    });
    const result = await action(exec)('gqt', 'restart');
    expect(result.ok).toBe(true);
    expect(cmdNames(calls)).toEqual(['cat', 'cat', 'kill', 'cat', 'cat', 'systemd-run', 'cat', 'cat']);
  });

  it('launcher 内日志目录创建失败时显式失败且不再轮询', async () => {
    await registration();
    const { exec, calls } = fakeExec((cmd) => {
      if (cmd === 'cat') return { ok: false, stdout: '', stderr: 'missing' };
      if (cmd === 'systemd-run') return { ok: false, stdout: '', stderr: 'mkdir: Permission denied' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('Permission denied');
    expect(cmdNames(calls)).toEqual(['cat', 'systemd-run']);
  });

  it('stop 在 pid 缺失时不调用 kill，保持可执行', async () => {
    await registration();
    const { exec, calls } = fakeExec((cmd) => {
      if (cmd === 'cat') return { ok: false, stdout: '', stderr: 'missing' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'stop');
    expect(result.ok).toBe(true);
    expect(result.output).toContain('未运行');
    expect(cmdNames(calls)).toEqual(['cat']);
  });

  it('kill 失败时显式返回失败', async () => {
    await registration();
    await writeFile(pidFile, '4242\n');
    const { exec } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'kill') return { ok: false, stdout: '', stderr: 'operation not permitted' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'stop');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('operation not permitted');
  });

  it('launcher 后超时未注册匹配 daemon 时失败，文案由配置窗口推导', async () => {
    await registration();
    const { exec, calls } = fakeExec((cmd) => {
      if (cmd === 'cat') return { ok: false, stdout: '', stderr: 'missing' };
      return undefined;
    });
    const result = await action(exec, { startTimeoutMs: 200, pollIntervalMs: 10 })('gqt', 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('未检测到匹配 pid/daemon');
    expect(result.output).toContain('200ms');
    expect(cmdNames(calls).filter((cmd) => cmd === 'systemd-run')).toHaveLength(1);
    expect(cmdNames(calls).filter((cmd) => cmd === 'cat')).toHaveLength(21);
  });

  it('冷启动超过单轮轮询时继续等待并在配置窗口内成功', async () => {
    await registration();
    let launched = false;
    let pidChecks = 0;
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) {
        pidChecks += 1;
        return launched && pidChecks >= 6
          ? { ok: true, stdout: '4242\n', stderr: '' }
          : { ok: false, stdout: '', stderr: 'not yet' };
      }
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'systemd-run') {
        launched = true;
        return { ok: true, stdout: '', stderr: '' };
      }
      return undefined;
    });
    const result = await action(exec, { startTimeoutMs: 500, pollIntervalMs: 10 })('gqt', 'start');
    expect(result.ok).toBe(true);
    expect(pidChecks).toBeGreaterThan(5);
    expect(cmdNames(calls).filter((cmd) => cmd === 'systemd-run')).toHaveLength(1);
  });

  it('restart 轮询等待慢退出，旧进程消失后才经 launcher 拉起', async () => {
    await registration();
    let alive = true;
    let procReads = 0;
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) {
        return alive ? { ok: true, stdout: '4242\n', stderr: '' } : { ok: false, stdout: '', stderr: 'missing' };
      }
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') {
        procReads += 1;
        if (procReads === 3) alive = false;
        return alive ? { ok: true, stdout: procCmdline, stderr: '' } : { ok: false, stdout: '', stderr: 'gone' };
      }
      if (cmd === 'kill') return { ok: true, stdout: '', stderr: '' };
      if (cmd === 'systemd-run') {
        alive = true;
        return { ok: true, stdout: '', stderr: '' };
      }
      return undefined;
    });
    const result = await action(exec)('gqt', 'restart');
    expect(result.ok).toBe(true);
    expect(procReads).toBe(4);
    expect(cmdNames(calls)).toEqual(['cat', 'cat', 'kill', 'cat', 'cat', 'cat', 'cat', 'cat', 'systemd-run', 'cat', 'cat']);
  });

  it('缺少 log_dir 时拒绝启动且不执行 launcher', async () => {
    await registration({ log_dir: '' });
    const { exec, calls } = fakeExec((cmd) => {
      if (cmd === 'cat') return { ok: false, stdout: '', stderr: 'missing' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('log_dir');
    expect(cmdNames(calls)).toEqual(['cat']);
  });

  it.each(['../devforge', 'a b', 'gqt/../x'])('非法注册名 %s 被拒绝且零 exec 副作用', async (name) => {
    const { exec, calls } = fakeExec(() => ({ ok: true, stdout: '', stderr: '' }));
    const result = await action(exec)(name, 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('非法 repo-sync 注册名');
    expect(calls).toEqual([]);
  });

  it.each(['[]', '42'])('注册 JSON 非对象（%s）时显式失败且零 exec', async (raw) => {
    await writeFile(cfgPath, raw);
    const { exec, calls } = fakeExec(() => ({ ok: true, stdout: '', stderr: '' }));
    const result = await action(exec)('gqt', 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('读取注册失败');
    expect(calls).toEqual([]);
  });

  it('数字 enabled=0 不触发停用门控，仍走启动流程', async () => {
    await registration({ enabled: 0 });
    let started = false;
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) {
        return started ? { ok: true, stdout: '4242\n', stderr: '' } : { ok: false, stdout: '', stderr: 'missing' };
      }
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'systemd-run') {
        started = true;
        return { ok: true, stdout: '', stderr: '' };
      }
      return undefined;
    });
    const result = await action(exec)('gqt', 'start');
    expect(result.ok).toBe(true);
    expect(result.output).not.toContain('已手动停用');
    expect(cmdNames(calls)).toEqual(['cat', 'systemd-run', 'cat', 'cat']);
  });

  it('共享 launcher 已在运行时视为另一启动进行中，等待既有 daemon 而不重复拉起', async () => {
    await registration();
    let launched = false;
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) {
        return launched ? { ok: true, stdout: '4242\n', stderr: '' } : { ok: false, stdout: '', stderr: 'missing' };
      }
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'systemd-run') {
        launched = true;
        return { ok: false, stdout: '', stderr: 'Unit forge-console-repo-sync-launcher already active' };
      }
      return undefined;
    });
    const result = await action(exec)('gqt', 'start');
    expect(result.ok).toBe(true);
    expect(cmdNames(calls).filter((cmd) => cmd === 'systemd-run')).toHaveLength(1);
  });

  it('launcher 执行失败时透传错误且不再轮询', async () => {
    await registration();
    const { exec, calls } = fakeExec((cmd) => {
      if (cmd === 'cat') return { ok: false, stdout: '', stderr: 'missing' };
      if (cmd === 'systemd-run') return { ok: false, stdout: '', stderr: 'launcher failed' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('launcher failed');
    expect(cmdNames(calls)).toEqual(['cat', 'systemd-run']);
  });

  it('daemon 脚本相同但 --config 指向其它注册时拒绝 kill', async () => {
    await registration();
    await writeFile(pidFile, '4242\n');
    const otherCfg = join(root, 'repo-sync', 'repos.d', 'kol.json');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') {
        return { ok: true, stdout: ['python3', daemonScript, '--config', otherCfg, ''].join('\0'), stderr: '' };
      }
      if (cmd === 'kill') return { ok: true, stdout: '', stderr: '' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'stop');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('身份不匹配');
    expect(cmdNames(calls)).toEqual(['cat', 'cat']);
  });

  it('脚本作为 cmdline 首参（argv0）也能识别 daemon 身份并按 pid 停止', async () => {
    await registration();
    await writeFile(pidFile, '4242\n');
    const scriptFirst = [daemonScript, '--config', cfgPath, ''].join('\0');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: scriptFirst, stderr: '' };
      if (cmd === 'kill') return { ok: true, stdout: '', stderr: '' };
      return undefined;
    });
    const result = await action(exec)('gqt', 'stop');
    expect(result.ok).toBe(true);
    expect(calls.at(-1)).toEqual({ cmd: 'kill', args: ['-TERM', '4242'] });
  });

  it('restart 旧进程在配置窗口内拒不退出时取消拉起，不执行 launcher', async () => {
    await registration();
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'kill') return { ok: true, stdout: '', stderr: '' };
      return undefined;
    });
    const result = await action(exec, { stopTimeoutMs: 200, pollIntervalMs: 10 })('gqt', 'restart');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('200ms内退出');
    expect(cmdNames(calls)).not.toContain('systemd-run');
    expect(cmdNames(calls)).not.toContain('mkdir');
    // 停止前 1 次身份检查 + 20 轮轮询：每次两读中的 cmdline 共 21 次
    expect(calls.filter((c) => c.cmd === 'cat' && c.args[0] === '/proc/4242/cmdline')).toHaveLength(21);
  });
});
