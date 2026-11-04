import { describe, expect, it } from 'vitest';
import { servicesCollector, makeContext, defaultConfig } from '../index.js';

const LIST_SYS = `  toolchain-start-all.service loaded active running dev-forge toolchain root
  user@1000.service          loaded active running User Manager for UID 1000
  systemd-journald.service   loaded active running Journal Service`;

const LIST_USER = `  grepai-watch.service        loaded active running grepai watch kol
  forge-console.service       loaded active running forge-console
  dbus.service                loaded inactive dead    D-Bus User Message Bus`;

const PS_OUT = `   333      1 15h multica daemon start --foreground
  373    333 15h python3 repo_sync_daemon.py --config repos.d/devforge.json
 3737    333 15h tail -f /dev/null`;

const SHOW_TOOLCHAIN = `ExecStart={ path=/bin/bash ; argv[]=/bin/bash -l /home/jerry/tools/dev-forge/launch/toolchain-start.sh ; ignore_errors=no }
EnvironmentFile=/home/jerry/.config/dev-forge/toolchain.env (ignore_errors=no)
ExecMainPID=333
ActiveEnterTimestamp=Tue 2026-11-02 07:55:00 CST
Description=toolchain root`;

function fakeExec(cmd: string, args: string[]) {
  const joined = args.join(' ');
  if (cmd === 'systemctl' && joined.includes('list-units')) {
    return Promise.resolve({
      ok: true,
      stdout: joined.includes('--user') ? LIST_USER : LIST_SYS,
      stderr: '',
    });
  }
  if (cmd === 'systemctl' && joined.includes('is-enabled')) {
    return Promise.resolve({ ok: true, stdout: 'enabled\n', stderr: '' });
  }
  if (cmd === 'systemctl' && joined.includes('show')) {
    return Promise.resolve({ ok: true, stdout: SHOW_TOOLCHAIN, stderr: '' });
  }
  if (cmd === 'ps') return Promise.resolve({ ok: true, stdout: PS_OUT, stderr: '' });
  if (cmd.includes('schtasks')) {
    const tn = args[args.indexOf('/tn') + 1] ?? '';
    if (tn === 'multica-daemon') {
      return Promise.resolve({ ok: false, stdout: '', stderr: 'ERROR: The system cannot find the file specified.' });
    }
    return Promise.resolve({ ok: true, stdout: `Folder: \\\nTaskName     Next Run   Status\n=========    ========   ======\nwsl-keepalive N/A Running\n`, stderr: '' });
  }
  return Promise.resolve({ ok: false, stdout: '', stderr: 'not implemented' });
}

function ctxWithFakeExec() {
  const cfg = defaultConfig({ devforge: '/tmp/nonexistent-devforge' });
  return makeContext(cfg, { exec: (cmd, args) => fakeExec(cmd, args) });
}

describe('services collector（假 exec 驱动）', () => {
  it('parses real systemd units: active/enabled/execStart/children（endsWith 回归）', async () => {
    const r = await servicesCollector.collect(ctxWithFakeExec());
    const tc = r.assets.find((a) => a.id === 'service:systemd-toolchain-start-all.service');
    expect(tc).toBeDefined();
    expect((tc!.payload as { active: string }).active).toBe('active');
    expect((tc!.payload as { enabled: string }).enabled).toBe('enabled');
    expect(String((tc!.payload as { execStart: string }).execStart)).toContain('toolchain-start.sh');
    expect((tc!.payload as { mainPid: number }).mainPid).toBe(333);
    expect((tc!.payload as { trigger: string }).trigger).toBe('系统开机自启');
    const kids = (tc!.payload as { children: unknown[] }).children ?? [];
    expect(kids.length).toBeGreaterThanOrEqual(2); // multica daemon + repo-sync 子进程
  });

  it('user-scope units are tagged 用户级开机自启', async () => {
    const r = await servicesCollector.collect(ctxWithFakeExec());
    const grepai = r.assets.find((a) => a.id === 'service:systemd-grepai-watch.service');
    expect(grepai).toBeDefined();
    expect((grepai!.payload as { trigger: string }).trigger).toBe('用户级开机自启');
    expect((grepai!.payload as { scope: string }).scope).toBe('user');
  });

  it('proc-multica-daemon 文案说明独立 daemon 与缺失补拉/驻留监督，不再声称前台 exec', async () => {
    const r = await servicesCollector.collect(ctxWithFakeExec());
    const daemon = r.assets.find((a) => a.id === 'service:proc-multica-daemon')!;
    const payload = daemon.payload as { trigger: string };
    expect(daemon.summary).toContain('独立 daemon');
    expect(daemon.summary).toContain('缺失补拉');
    expect(payload.trigger).toContain('驻留监督');
    expect(`${daemon.summary} ${payload.trigger}`).not.toMatch(/前台\s*exec|前台子进程/);
  });

  it('proc-multica-daemon 未运行分支也保留独立 daemon 与监督语义', async () => {
    const cfg = defaultConfig({ devforge: '/tmp/nonexistent-devforge' });
    const ctx = makeContext(cfg, {
      exec: (cmd, args) => {
        if (cmd === 'ps' && args.join(' ') === '-eo args --no-headers') {
          return Promise.resolve({ ok: true, stdout: '', stderr: '' });
        }
        return fakeExec(cmd, args);
      },
    });
    const r = await servicesCollector.collect(ctx);
    const daemon = r.assets.find((a) => a.id === 'service:proc-multica-daemon')!;
    const payload = daemon.payload as { active: string; trigger: string };
    expect(payload.active).toBe('dead');
    expect(daemon.summary).toContain('进程未运行');
    expect(daemon.summary).toContain('独立 daemon');
    expect(payload.trigger).toContain('驻留监督');
    expect(`${daemon.summary} ${payload.trigger}`).not.toMatch(/前台\s*exec|前台子进程/);
  });

  it('ps 仅含非 start 的 multica daemon 子命令时不得误报运行中', async () => {
    const cfg = defaultConfig({ devforge: '/tmp/nonexistent-devforge' });
    const ctx = makeContext(cfg, {
      exec: (cmd, args) => {
        if (cmd === 'ps' && args.join(' ') === '-eo args --no-headers') {
          return Promise.resolve({ ok: true, stdout: 'multica daemon status --output json\n', stderr: '' });
        }
        return fakeExec(cmd, args);
      },
    });
    const r = await servicesCollector.collect(ctx);
    const daemon = r.assets.find((a) => a.id === 'service:proc-multica-daemon')!;
    const payload = daemon.payload as { active: string; trigger: string };
    expect(payload.active).toBe('dead');
    expect(daemon.summary).toContain('进程未运行');
    expect(daemon.summary).toContain('独立 daemon');
    expect(payload.trigger).toContain('驻留监督');
    expect(`${daemon.summary} ${payload.trigger}`).not.toMatch(/前台\s*exec|前台子进程/);
  });

  it('windows bridge status is PROBED via schtasks（机制而非手工标注）', async () => {
    const r = await servicesCollector.collect(ctxWithFakeExec());
    const keep = r.assets.find((a) => a.id === 'service:winbridge-wsl-keepalive');
    expect(keep).toBeDefined();
    expect((keep!.payload as { active: string }).active).toBe('active'); // fake: Running
    expect((keep!.payload as { taskStatus: string }).taskStatus).toBe('Running');
    expect((keep!.payload as { trigger: string }).trigger).toBe('windows-logon');
    // 已删除的任务（multica-daemon：任务不存在）不再产生 legacy 行
    const ghost = r.assets.filter((a) => (a.payload as { active?: string }).active === 'legacy');
    expect(ghost).toHaveLength(0);
  });
});
