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

  it.each(['start', 'restart'] as const)('enabled=false 拒绝 %s，且零 exec 副作用', async (action) => {
    await registration({ enabled: false });
    const { exec, calls } = fakeExec(() => ({ ok: true, stdout: '', stderr: '' }));
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', action);
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
    await registration();
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
    await registration();
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
    await registration();
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
    await registration();
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
    await registration();
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

  it.each(['../devforge', 'a b', 'gqt/../x'])('非法注册名 %s 被拒绝且零 exec 副作用', async (name) => {
    const { exec, calls } = fakeExec(() => ({ ok: true, stdout: '', stderr: '' }));
    const result = await createRepoSyncAction({ devforge: root, exec })(name, 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('非法 repo-sync 注册名');
    expect(calls).toEqual([]);
  });

  it.each(['[]', '42'])('注册 JSON 非对象（%s）时显式失败且零 exec', async (raw) => {
    await writeFile(cfgPath, raw);
    const { exec, calls } = fakeExec(() => ({ ok: true, stdout: '', stderr: '' }));
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'start');
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
      if (cmd === 'bash') {
        started = true;
        return { ok: true, stdout: '', stderr: '' };
      }
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'start');
    expect(result.ok).toBe(true);
    expect(result.output).not.toContain('已手动停用');
    expect(cmdNames(calls)).toEqual(['cat', 'mkdir', 'bash', 'cat', 'cat']);
  });

  it('nohup 执行失败时透传错误且不再轮询', async () => {
    await registration();
    const { exec, calls } = fakeExec((cmd) => {
      if (cmd === 'cat') return { ok: false, stdout: '', stderr: 'missing' };
      if (cmd === 'bash') return { ok: false, stdout: '', stderr: 'nohup: exiting' };
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'start');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('nohup: exiting');
    expect(cmdNames(calls)).toEqual(['cat', 'mkdir', 'bash']);
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
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'stop');
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
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'stop');
    expect(result.ok).toBe(true);
    expect(calls.at(-1)).toEqual({ cmd: 'kill', args: ['-TERM', '4242'] });
  });

  it('restart 旧进程 5 秒内拒不退出时取消拉起，不执行 nohup', async () => {
    await registration();
    await writeFile(pidFile, '4242\n');
    const { exec, calls } = fakeExec((cmd, args) => {
      if (cmd === 'cat' && args[0] === pidFile) return { ok: true, stdout: '4242\n', stderr: '' };
      if (cmd === 'cat' && args[0] === '/proc/4242/cmdline') return { ok: true, stdout: procCmdline, stderr: '' };
      if (cmd === 'kill') return { ok: true, stdout: '', stderr: '' };
      return undefined;
    });
    const result = await createRepoSyncAction({ devforge: root, exec })('gqt', 'restart');
    expect(result.ok).toBe(false);
    expect(result.output).toContain('5 秒内退出');
    expect(cmdNames(calls)).not.toContain('bash');
    expect(cmdNames(calls)).not.toContain('mkdir');
    // 停止前 1 次身份检查 + STOP_ATTEMPTS(50) 轮轮询：每次两读中的 cmdline 共 51 次
    expect(calls.filter((c) => c.cmd === 'cat' && c.args[0] === '/proc/4242/cmdline')).toHaveLength(51);
  }, 10_000);
});
