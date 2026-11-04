import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createRepoSyncAction, type RepoSyncExec } from './repo-sync-action.js';

interface Call {
  cmd: string;
  args: string[];
}

type Result = { ok: boolean; stdout: string; stderr: string };

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

  function withPidFile(over: Record<string, unknown> = {}): Promise<void> {
    return registration({ pid_file: pidFile, ...over });
  }

  it.each(['start', 'restart'] as const)('enabled=false 拒绝 %s，且零 exec 副作用', async (action) => {
    await registration({ enabled: false });
    const { exec, calls } = fakeExec(() => ({ ok: true, stdout: '', stderr: '' }));
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', action);
    expect(result.ok).toBe(false);
    expect(result.output).toContain('enabled=false');
    expect(calls).toEqual([]);
  });

  it('enabled=false 仍允许 stop；核对 daemon 身份后按注册 pid 发 SIGTERM', async () => {
    await withPidFile({ enabled: false });
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'kill') return { ok: true, stdout: '', stderr: '' };
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'stop');
    expect(result.ok).toBe(true);
    expect(result.output).toContain('kill TERM 4242');
    expect(calls).toEqual([
      { cmd: 'cat', args: [pidFile] },
      { cmd: 'cat', args: ['/proc/4242/cmdline'] },
      { cmd: 'kill', args: ['-TERM', '4242'] },
    ]);
  });

  it('stop 遇到 PID 复用/身份不匹配时拒绝 kill', async () => {
    await withPidFile();
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: ['sleep', '100', ''].join('\0'), stderr: '' };
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'stop');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('身份不匹配');
    expect(cmdNames(calls)).toEqual(['cat', 'cat']);
  });

  it('enabled start 通过 nohup 拉起并追加注册日志，随后验证 pid 与进程身份', async () => {
    await withPidFile();
    let started = false;
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) {
        return started ? { ok: true, stdout: '4242\n', stderr: '' } : { ok: false, stdout: '', stderr: 'missing' };
      }
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'bash') {
        started = true;
        return { ok: true, stdout: '', stderr: '' };
      }
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'start');
    expect(result.ok).toBe(true);
    expect(cmdNames(calls)).toEqual(['cat', 'mkdir', 'bash', 'cat', 'cat']);
    expect(cmdNames(calls)).not.toContain('systemd-run');
    expect(cmdNames(calls)).not.toContain('systemctl');
    expect(calls[1]).toEqual({ cmd: 'mkdir', args: ['-p', join(root, 'repo-sync', 'logs')] });
    expect(calls[2].args[1]).toContain('nohup python3 "$1" --config "$2" >>"$3" 2>&1 &');
    expect(calls[2].args.slice(3)).toEqual([daemonScript, cfgPath, join(root, 'repo-sync', 'logs', 'repo-sync-daemon.log')]);
    expect(calls[4].args).toEqual(['/proc/4242/cmdline']);
  });

  it('enabled start 在注册 pid 属于同一 daemon 时幂等，不 mkdir / nohup / kill', async () => {
    await withPidFile();
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'start');
    expect(result.ok).toBe(true);
    expect(cmdNames(calls)).toEqual(['cat', 'cat']);
    expect(result.output).toContain('已在运行');
  });

  it('enabled restart = SIGTERM、等待旧进程退出后重新 nohup 拉起', async () => {
    await withPidFile();
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
      if (cmd === 'bash') {
        alive = true;
        return { ok: true, stdout: '', stderr: '' };
      }
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'restart');
    expect(result.ok).toBe(true);
    expect(cmdNames(calls)).toEqual(['cat', 'cat', 'kill', 'cat', 'cat', 'mkdir', 'bash', 'cat', 'cat']);
  });

  it('日志目录创建失败时显式失败，不执行 nohup', async () => {
    await registration();
    const { exec, calls } = fakeExec((cmd) => {
      if (cmd === 'cat') return { ok: false, stdout: '', stderr: 'missing' };
      if (cmd === 'mkdir') return { ok: false, stdout: '', stderr: 'permission denied' };
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('permission denied');
    expect(cmdNames(calls)).toEqual(['cat', 'mkdir']);
  });

  it('stop 在 pid 缺失时不调用 kill，保持可执行', async () => {
    await registration();
    const { exec, calls } = fakeExec((cmd) => {
      if (cmd === 'cat') return { ok: false, stdout: '', stderr: 'missing' };
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'stop');
    expect(result.ok).toBe(true);
    expect(result.output).toContain('未运行');
    expect(cmdNames(calls)).toEqual(['cat']);
  });

  it('kill 失败时显式返回失败', async () => {
    await withPidFile();
    await writeFile(pidFile, '4242\n');
    const { exec } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'kill') return { ok: false, stdout: '', stderr: 'operation not permitted' };
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'stop');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('operation not permitted');
  });

  it('nohup 后未注册匹配 daemon 时不得回报启动成功', async () => {
    await withPidFile();
    const { exec, calls } = fakeExec((cmd) => {
      if (cmd === 'cat') return { ok: false, stdout: '', stderr: 'missing' };
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('未检测到匹配 pid/daemon');
    expect(cmdNames(calls).filter((cmd) => cmd === 'bash')).toHaveLength(1);
    expect(cmdNames(calls).filter((cmd) => cmd === 'cat')).toHaveLength(21);
  }, 5000);

  it('restart 轮询等待慢退出，旧进程消失后才 nohup', async () => {
    await withPidFile();
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
      if (cmd === 'bash') {
        alive = true;
        return { ok: true, stdout: '', stderr: '' };
      }
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'restart');
    expect(result.ok).toBe(true);
    expect(procReads).toBe(4);
    expect(cmdNames(calls)).toEqual(['cat', 'cat', 'kill', 'cat', 'cat', 'cat', 'cat', 'cat', 'mkdir', 'bash', 'cat', 'cat']);
  });

  it('缺少 log_dir 时拒绝启动且不执行 nohup', async () => {
    await registration({ log_dir: '' });
    const { exec, calls } = fakeExec((cmd) => {
      if (cmd === 'cat') return { ok: false, stdout: '', stderr: 'missing' };
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('log_dir');
    expect(cmdNames(calls)).toEqual(['cat']);
  });
});
